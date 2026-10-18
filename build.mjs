#!/usr/bin/env node
/* Keeps the three things that must agree in agreement.
 *
 * public/app.<hash>.js carries a content hash so it can be cached for a year.
 * That hash is referenced from index.html, and index.html's own inline theme
 * block is named by sha256 in the Content-Security-Policy inside the Worker.
 * Edit the app and all three have to move together. Doing that by hand is how
 * a site ends up serving a bundle nobody can load, or booting with no theme
 * because the policy refuses a script whose hash changed.
 *
 * Run: node build.mjs
 */
import { readFileSync, writeFileSync, renameSync, readdirSync, unlinkSync } from "fs";
import { createHash } from "crypto";

const sha = (s, n) => createHash("sha256").update(s).digest("hex").slice(0, n);
const b64 = s => createHash("sha256").update(s).digest("base64");

const bundles = readdirSync("public").filter(f => /^app\.[a-f0-9]+\.js$/.test(f));
if (bundles.length !== 1) { console.error(`expected 1 bundle, found ${bundles.length}`); process.exit(1); }
const oldName = bundles[0];
const code = readFileSync(`public/${oldName}`, "utf8");
const newName = `app.${sha(code, 10)}.js`;

let html = readFileSync("public/index.html", "utf8");
if (oldName !== newName) {
  renameSync(`public/${oldName}`, `public/${newName}`);
  html = html.replaceAll(oldName, newName);
  console.log(`bundle  ${oldName} -> ${newName}`);
} else {
  console.log(`bundle  ${newName} (unchanged)`);
}
writeFileSync("public/index.html", html);

/* The CSP names the one EXECUTABLE inline script by hash; recompute it from
   what ships.
 *
 * The type filter is load-bearing. index.html also carries a
 * <script type="application/ld+json"> block of structured data, which sits
 * above the theme script. A plain "first inline script" match grabbed that
 * instead and wrote its hash into the policy, which would have shipped a site
 * whose theme script the browser refuses: no dark mode, a flash of the wrong
 * colours, and nothing in the console pointing at the real cause.
 *
 * A data block is not executed, so CSP never applies to it. Only a script with
 * no type, or an explicitly JavaScript one, needs a hash. */
const executable = [...html.matchAll(/<script(?![^>]*\bsrc=)([^>]*)>([\s\S]*?)<\/script>/g)]
  .filter(m => {
    const type = (m[1].match(/\btype\s*=\s*["']([^"']+)["']/) || [,""])[1].toLowerCase();
    return !type || type === "text/javascript" || type === "module" || type === "application/javascript";
  });
if (executable.length !== 1) {
  console.error(`expected exactly 1 executable inline script in index.html, found ${executable.length}`);
  process.exit(1);
}
const inline = executable[0].slice(1); // [full, attrs, body] -> [attrs, body]; body is [1]
const want = b64(inline[1]);
let worker = readFileSync("src/index.js", "utf8");
const have = worker.match(/'sha256-([^']+)'/);
if (!have) { console.error("no CSP script hash found in src/index.js"); process.exit(1); }
if (have[1] !== want) {
  worker = worker.replace(`'sha256-${have[1]}'`, `'sha256-${want}'`);
  writeFileSync("src/index.js", worker);
  console.log(`csp     hash updated -> sha256-${want.slice(0, 16)}...`);
} else {
  console.log(`csp     hash already correct`);
}

const refs = (html.match(/app\.[a-f0-9]+\.js/g) || []);
if (!refs.length || refs.some(r => r !== newName)) { console.error("index.html does not reference the bundle correctly"); process.exit(1); }
console.log(`ok      index.html -> ${newName}, ${refs.length} reference(s)`);
