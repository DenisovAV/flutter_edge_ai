// Headless-Chromium gate for the web vec0 build. Serves tool/web_vec0_probe's
// compiled output (which loads the custom sqlite3.wasm, creates a vec0 TEXT-pk
// table, inserts 3 vectors, runs a KNN MATCH) under COOP/COEP and asserts the
// page logs RESULT=PASS. Exit 0 = pass, 1 = fail. This is the web half of the
// migration keystone proof (native half: test/vec0_text_pk_test.dart).
//
// Setup (one-time): `npm i playwright && npx playwright install chromium`.
// Build the probe first:
//   tool/build_vec0_wasm.sh tool/web_vec0_probe/web        # produces sqlite3.wasm
//   cd tool/web_vec0_probe && dart pub get && \
//     dart run build_runner build --release -o web:build
// Then run:  node tool/verify_web_vec0.mjs
import { chromium } from 'playwright';
import { createServer } from 'http';
import { readFileSync, existsSync } from 'fs';
import { extname, join } from 'path';

const MIME = { '.html':'text/html', '.js':'text/javascript', '.wasm':'application/wasm', '.json':'application/json' };
// Serve the compiled probe. Override with $PROBE_DIR (defaults to the
// build_runner output of tool/web_vec0_probe).
const root = process.env.PROBE_DIR || join(process.cwd(), 'tool', 'web_vec0_probe', 'build');

// Serve with COOP/COEP (needed for wasm + future OPFS/SharedArrayBuffer).
const server = createServer((req, res) => {
  let p = req.url.split('?')[0];
  if (p === '/') p = '/index.html';
  const file = join(root, p);
  if (!existsSync(file)) { res.writeHead(404); res.end('nf'); return; }
  res.setHeader('Cross-Origin-Opener-Policy', 'same-origin');
  res.setHeader('Cross-Origin-Embedder-Policy', 'require-corp');
  res.setHeader('Content-Type', MIME[extname(file)] || 'application/octet-stream');
  res.end(readFileSync(file));
});

await new Promise(r => server.listen(8099, r));
const browser = await chromium.launch({ headless: true });
const page = await browser.newPage();
let result = null;
page.on('console', m => { const t = m.text(); if (t.includes('RESULT=')) result = t; });
await page.goto('http://localhost:8099/');
// wait up to 15s for the wasm to init + run
for (let i = 0; i < 60 && !result; i++) await page.waitForTimeout(250);
if (!result) result = await page.locator('#out').textContent().catch(() => null);
console.log('--- PAGE RESULT ---');
console.log(result || '(no result)');
await browser.close();
server.close();
process.exit(result && result.includes('RESULT=PASS') ? 0 : 1);
