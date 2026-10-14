#!/usr/bin/env python3
"""Reject Web release artifacts missing or corrupting pinned runtime assets."""

import argparse
import hashlib
import json
import subprocess
from html.parser import HTMLParser
from urllib.parse import urlparse
from pathlib import Path

from fetch_web_assets import FILES, MANIFEST_SHA256, PACKAGE


def validate(directory):
    runtime = directory / "webgpu_bridge"
    data = (runtime / "manifest.json").read_bytes()
    if hashlib.sha256(data).hexdigest() != MANIFEST_SHA256:
        raise RuntimeError("Release artifact has the wrong Web runtime manifest")
    manifest = json.loads(data)
    for filename in FILES:
        path = runtime / filename
        expected = manifest["artifacts"][filename]
        digest = hashlib.sha256()
        with path.open("rb") as source:
            for block in iter(lambda: source.read(1024 * 1024), b""):
                digest.update(block)
        if path.stat().st_size != expected["size_bytes"] or digest.hexdigest() != expected["sha256"]:
            raise RuntimeError(f"Release artifact has a corrupt runtime asset: {filename}")
    for filename in ("index.html", "flutter_bootstrap.js", "main.dart.wasm", "cache_api.js", "cache_api.LICENSE", "_headers"):
        if not (directory / filename).is_file():
            raise RuntimeError(f"Release artifact is missing {filename}")
    validate_headers((directory / "_headers").read_text())
    validate_javascript(directory)
    if (directory / "cache_api.LICENSE").read_bytes() != (PACKAGE / "example/web/cache_api.LICENSE").read_bytes():
        raise RuntimeError("Release artifact changed cache_api.LICENSE")


class BootstrapScripts(HTMLParser):
    def __init__(self):
        super().__init__()
        self.modules = []
        self.sources = []
        self.base = ""
        self.active = False
        self.code = []

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "base": self.base = attrs.get("href", "")
        if tag != "script": return
        if "src" in attrs: self.sources.append(attrs["src"])
        self.active = attrs.get("type") == "module" and "src" not in attrs
        self.code = []

    def handle_data(self, data):
        if self.active: self.code.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.active:
            self.modules.append("".join(self.code))
            self.active = False


JS_CHECK = r"""
const vm = require('node:vm');
const fs = require('node:fs');
const data = JSON.parse(fs.readFileSync(0, 'utf8'));
(async () => {
  const required = ['cacheHas','cacheGetBlobUrl','cachePut','cacheDelete',
    'cacheDeleteCache','cacheGetAllKeys','storageRequestPersistent',
    'storageGetQuota','blobUrlRevoke','createBlob'];
  const helper = {window: {}, console: {error() {}, log() {}}};
  helper.globalThis = helper.window;
  vm.runInNewContext(data.helper, helper, {timeout: 1000, contextCodeGeneration: {strings:false,wasm:false}});
  for (const name of required) {
    if (typeof helper.window[name] !== 'function') throw Error('Storage helper is missing ' + name);
  }
  const imported = [];
  const window = {crossOriginIsolated: true};
  const context = {window, URL, navigator:{hardwareConcurrency:4}, console:{error(){},log(){}},
    document:{baseURI:'https://app.invalid/',createElement(){return {};},body:{appendChild(){}}},
    async loadModule(address) {
      imported.push(address);
      if (address !== 'https://app.invalid/webgpu_bridge/llama_webgpu_bridge.js') {
        throw Error('Bootstrap must load the local pinned bridge');
      }
      return {LlamaWebGpuBridge:function(){}};
    }
  };
  for (const source of data.modules) {
    // The module's dynamic import is intercepted; no network or runtime bytes execute.
    const script = source.replace(/\bimport\s*\(/g, 'loadModule(');
    await vm.runInNewContext('(async () => {' + script + '})()', context,
      {timeout:1000,contextCodeGeneration:{strings:false,wasm:false}});
  }
  const bindings = {
    __llamadartBridgeModuleUrl:'llama_webgpu_bridge.js',
    __llamadartBridgeCoreModuleUrl:'llama_webgpu_core.js',
    __llamadartBridgeWasmUrl:'llama_webgpu_core.wasm',
    __llamadartBridgeCoreModuleUrlMem64:'llama_webgpu_core_mem64.js',
    __llamadartBridgeWasmUrlMem64:'llama_webgpu_core_mem64.wasm',
    __llamadartBridgeWorkerUrl:'llama_webgpu_bridge_worker.js'
  };
  if (!imported.length || typeof window.LlamaWebGpuBridge !== 'function') {
    throw Error('Bootstrap must load the local pinned bridge');
  }
  for (const [name,file] of Object.entries(bindings)) {
    if (window[name] !== 'https://app.invalid/webgpu_bridge/' + file) {
      throw Error('Bootstrap must select the local pinned asset: ' + name);
    }
  }
  console.log('WEB_STATIC_CHECKS_PASS');
})().catch(error => {console.error(error.message);process.exitCode=1;});
"""


def validate_javascript(directory):
    scripts = BootstrapScripts()
    scripts.feed((directory / "index.html").read_text())
    if urlparse(scripts.base).scheme or urlparse(scripts.base).netloc:
        raise RuntimeError("Bootstrap must use an app-relative base for local pinned assets")
    if "cache_api.js" not in scripts.sources:
        raise RuntimeError("Bootstrap must load its local cache_api.js helper")
    result = subprocess.run(["node", "-e", JS_CHECK], input=json.dumps({
        "helper": (directory / "cache_api.js").read_text(),
        "modules": [source for source in scripts.modules if "LlamaWebGpuBridge" in source or "__llamadartBridge" in source],
    }), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    if result.returncode or result.stdout.strip() != "WEB_STATIC_CHECKS_PASS":
        raise RuntimeError(result.stderr.strip() or "Local pinned bootstrap validation did not complete")


def validate_headers(source):
    required = {"cross-origin-opener-policy": "same-origin",
                "cross-origin-embedder-policy": "require-corp"}
    wildcard = {}
    scope = None
    for line in source.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            scope = line.strip()
            continue
        stripped = line.strip()
        if stripped.startswith("!") and stripped[1:].strip().lower() in required:
            raise RuntimeError("Conflicting isolation header removal")
        name, separator, value = stripped.partition(":")
        name, value = name.lower(), value.strip().lower()
        if separator and name in required:
            if value != required[name]:
                raise RuntimeError(f"Conflicting isolation header: {name}")
            if scope == "/*": wildcard[name] = value
    if wildcard != required:
        raise RuntimeError("_headers must apply COOP same-origin and COEP require-corp to /*")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=PACKAGE / "example/build/web")
    args = parser.parse_args()
    validate(args.directory)
    print("Web release artifact integrity: PASS")


if __name__ == "__main__":
    main()
