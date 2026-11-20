#!/usr/bin/env python3
"""Reject Web release artifacts missing or corrupting resolved SDK runtime assets."""

import argparse
import json
import os
import shutil
import subprocess
from html.parser import HTMLParser
from urllib.parse import urlparse
from pathlib import Path

PACKAGE = Path(__file__).resolve().parents[1]


def resolve_dart(dart=None):
    if dart:
        return str(dart)
    found = shutil.which("dart")
    if found:
        return found
    flutter = shutil.which("flutter")
    if flutter:
        sibling = Path(flutter).resolve().parent / ("dart.bat" if os.name == "nt" else "dart")
        if sibling.exists():
            return str(sibling)
    return "dart"


def find_app_root(directory, app_dir=None):
    if app_dir is not None:
        candidate = Path(app_dir).resolve()
        for parent in (candidate, *candidate.parents):
            if (parent / ".dart_tool/package_config.json").is_file():
                return parent
        raise RuntimeError(
            f"Could not find .dart_tool/package_config.json at or above {candidate}; run `flutter pub get` first"
        )
    resolved = Path(directory).resolve()
    for base in (resolved, Path.cwd().resolve()):
        for parent in (base, *base.parents):
            if (parent / ".dart_tool/package_config.json").is_file():
                return parent
    raise RuntimeError(
        "Could not find .dart_tool/package_config.json for the consuming app; run from the app directory or pass --app-dir"
    )


def validate_runtime_assets(directory, app_dir=None, dart=None):
    resolved_app_dir = find_app_root(directory, app_dir=app_dir)
    result = subprocess.run(
        [
            resolve_dart(dart),
            "run",
            "llamadart:web_setup",
            "--check",
            "--no-index-html",
            "--web-dir",
            str(Path(directory).resolve()),
        ],
        cwd=resolved_app_dir,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
    if result.returncode:
        message = result.stdout.strip() or f"llamadart:web_setup --check failed with exit code {result.returncode}"
        raise RuntimeError(f"Release artifact failed resolved SDK Web asset check: {message}")


def validate(directory, app_dir=None, dart=None):
    directory = Path(directory)
    if not directory.is_dir():
        raise FileNotFoundError(f"Release artifact directory does not exist: {directory}")
    validate_runtime_assets(directory, app_dir=app_dir, dart=dart)
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
  const expectedTag = data.tag;
  const expectedUrlFor = (file) => {
    const url = new URL('https://app.invalid/webgpu_bridge/' + file);
    url.searchParams.set('v', expectedTag);
    return url.href;
  };
  const imported = [];
  const violations = [];
  async function loadManifest(resource, init = {}) {
    const rawUrl = typeof resource === 'string'
      ? resource
      : (resource && typeof resource.url === 'string' ? resource.url : String(resource));
    const resolvedUrl = new URL(rawUrl, 'https://app.invalid/');
    if (resolvedUrl.href !== 'https://app.invalid/webgpu_bridge/manifest.json') {
      violations.push(resolvedUrl.href);
      throw Error('Bootstrap must only fetch the local pinned manifest: ' + resolvedUrl.href);
    }
    if (init?.cache !== 'no-store') {
      throw Error('Bootstrap must fetch webgpu_bridge/manifest.json with cache: "no-store"');
    }
    return {
      ok: true,
      status: 200,
      async json() { return JSON.parse(data.manifestText); },
      async text() { return data.manifestText; },
    };
  }
  const context = vm.createContext({URL, fetch: loadManifest, navigator:{hardwareConcurrency:4},
    crossOriginIsolated:true,console:{error(){},log(){}},
    document:{baseURI:'https://app.invalid/',createElement(){return {};},body:{appendChild(){}}}
  }, {codeGeneration:{strings:false,wasm:false}});
  context.window = context;
  async function loadModule(address, referencingModule) {
    const resolvedUrl = new URL(address, referencingModule.identifier);
    const resolved = resolvedUrl.href;
    imported.push(resolved);
    if (resolvedUrl.origin + resolvedUrl.pathname !== 'https://app.invalid/webgpu_bridge/llama_webgpu_bridge.js') {
      violations.push(resolved);
      throw Error('Bootstrap must load the local pinned bridge: ' + resolved);
    }
    const expectedModule = expectedUrlFor('llama_webgpu_bridge.js');
    if (resolved !== expectedModule) {
      throw Error('Bootstrap bridge import version must match manifest (' + expectedTag + '): ' + resolved);
    }
    const module = new vm.SyntheticModule(['LlamaWebGpuBridge'], function() {
      this.setExport('LlamaWebGpuBridge', function(){});
    }, {context,identifier:resolved});
    await module.link(() => {});
    await module.evaluate();
    return module;
  }
  for (const source of data.modules) {
    // Node links static and dynamic imports through the same local-only loader.
    // No network access or runtime artifact code executes, even on CDN fallback.
    const module = new vm.SourceTextModule(source, {
      context, identifier:'https://app.invalid/index.html',
      initializeImportMeta(meta){meta.url='https://app.invalid/index.html';},
      importModuleDynamically:loadModule
    });
    await module.link(loadModule);
    await module.evaluate({timeout:1000});
  }
  if (violations.length) throw Error('Bootstrap must use local pinned assets; attempted nonlocal runtime imports: ' + violations.join(', '));
  const window = context;
  if (window.__llamadartBridgeLoadError) {
    throw Error('Bootstrap failed closed: ' + window.__llamadartBridgeLoadError);
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
    const actual = window[name];
    if (typeof actual !== 'string') {
      throw Error('Bootstrap must select the local pinned asset: ' + name);
    }
    let parsed;
    try {
      parsed = new URL(actual);
    } catch {
      throw Error('Bootstrap must select the local pinned asset: ' + name);
    }
    if (parsed.origin + parsed.pathname !== 'https://app.invalid/webgpu_bridge/' + file) {
      throw Error('Bootstrap must select the local pinned asset: ' + name);
    }
    const expected = expectedUrlFor(file);
    if (actual !== expected) {
      throw Error('Bootstrap asset version mismatch for ' + name + ': expected ' + expected + ', got ' + actual);
    }
  }
  console.log('WEB_STATIC_CHECKS_PASS');
})().catch(error => {console.error(error.message);process.exitCode=1;});
"""


def read_manifest_tag(directory):
    manifest_path = Path(directory) / "webgpu_bridge/manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError("Release artifact is missing webgpu_bridge/manifest.json")
    manifest_text = manifest_path.read_text()
    try:
        manifest = json.loads(manifest_text)
    except json.JSONDecodeError as error:
        raise RuntimeError(f"webgpu_bridge/manifest.json is not valid JSON: {error}") from error
    if not isinstance(manifest, dict):
        raise RuntimeError("webgpu_bridge/manifest.json must be a JSON object")
    release_tag = manifest.get("release_tag")
    bridge_tag = manifest.get("bridge_assets_tag")
    if release_tag is not None and (not isinstance(release_tag, str) or not release_tag.strip()):
        raise RuntimeError("webgpu_bridge/manifest.json has invalid release_tag")
    if bridge_tag is not None and (not isinstance(bridge_tag, str) or not bridge_tag.strip()):
        raise RuntimeError("webgpu_bridge/manifest.json has invalid bridge_assets_tag")
    if release_tag and bridge_tag and release_tag.strip() != bridge_tag.strip():
        raise RuntimeError(f"webgpu_bridge/manifest.json has mismatched tags: {release_tag!r} vs {bridge_tag!r}")
    tag = (release_tag or bridge_tag or "").strip()
    if not tag:
        raise RuntimeError("webgpu_bridge/manifest.json is missing release_tag")
    return manifest_text, tag


def validate_javascript(directory):
    directory = Path(directory)
    manifest_text, tag = read_manifest_tag(directory)
    scripts = BootstrapScripts()
    scripts.feed((directory / "index.html").read_text())
    if urlparse(scripts.base).scheme or urlparse(scripts.base).netloc:
        raise RuntimeError("Bootstrap must use an app-relative base for local pinned assets")
    if "cache_api.js" not in scripts.sources:
        raise RuntimeError("Bootstrap must load its local cache_api.js helper")
    result = subprocess.run(["node", "--experimental-vm-modules", "-e", JS_CHECK], input=json.dumps({
        "helper": (directory / "cache_api.js").read_text(),
        "modules": [source for source in scripts.modules if "LlamaWebGpuBridge" in source or "__llamadartBridge" in source],
        "manifestText": manifest_text,
        "tag": tag,
    }), text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    if result.returncode or result.stdout.strip() != "WEB_STATIC_CHECKS_PASS":
        raise RuntimeError(result.stderr.strip() or "Local pinned bootstrap validation did not complete")


def validate_headers(source):
    policies = {"cross-origin-opener-policy": {"same-origin"},
                "cross-origin-embedder-policy": {"require-corp", "credentialless"}}
    wildcard = set()
    seen = set()
    scope = None
    for line in source.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if not line[0].isspace():
            scope = line.strip()
            continue
        stripped = line.strip()
        if stripped.startswith("!") and stripped[1:].strip().lower() in policies:
            raise RuntimeError("Conflicting isolation header removal")
        name, separator, value = stripped.partition(":")
        name = name.lower()
        if separator and name in policies:
            # Cloudflare joins matching rules, even identical header values.
            if name in seen:
                raise RuntimeError(f"Repeated isolation header: {name}")
            seen.add(name)
            policy = value.split(";", 1)[0].strip().lower()
            if policy not in policies[name]:
                raise RuntimeError(f"Conflicting isolation header: {name}")
            if scope == "/*": wildcard.add(name)
    if wildcard != policies.keys():
        raise RuntimeError("_headers must apply COOP same-origin and COEP require-corp/credentialless to /*")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", nargs="?", type=Path, default=PACKAGE / "example/build/web")
    parser.add_argument("--app-dir", type=Path, help="Consuming app or workspace directory with .dart_tool/package_config.json")
    parser.add_argument("--dart", help="Dart executable used to invoke llamadart:web_setup")
    args = parser.parse_args()
    validate(args.directory, app_dir=args.app_dir, dart=args.dart)
    print("Web release artifact integrity: PASS")


if __name__ == "__main__":
    main()
