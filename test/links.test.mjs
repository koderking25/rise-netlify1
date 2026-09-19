/* Every link the site ships, actually requested.
 *
 * A student clicked "Library Program Volunteer" and got a page-not-found. The
 * url was https://www.canada.ca/en/services/culture/libraries.html, which has
 * never existed: libraries in Canada are municipal, there is no federal
 * libraries service page. Two more entries carried the same invented shape.
 * Nothing caught it because nothing had ever asked the web whether these
 * pages were real.
 *
 * This does. It is deliberately not part of the unit suite: it makes real
 * network calls, it is slow, and it can fail for reasons that are nobody's
 * fault. Run it before shipping a change to the opportunity list.
 *
 *   node --test test/links.test.mjs
 *
 * A 403 is not a failure. Several large charities refuse non-browser clients
 * outright, and a checker that cries wolf about redcross.ca every run is a
 * checker people stop reading. Only "the page is genuinely not there" fails.
 */
import { test } from "node:test";
import assert from "node:assert";
import { readFileSync, readdirSync } from "node:fs";

const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36";
const BLOCKED = new Set([401, 403, 405, 406, 429]); // bot walls, not broken pages
const DEAD = new Set([404, 410]);

function shippedUrls() {
  const bundle = readdirSync("public").find(f => /^app\.[a-f0-9]+\.js$/.test(f));
  const src = readFileSync(`public/${bundle}`, "utf8");
  const start = src.indexOf("const BUILTIN_OPPS = {");
  let depth = 0, end = start;
  for (let i = src.indexOf("{", start); i < src.length; i++) {
    if (src[i] === "{") depth++;
    else if (src[i] === "}" && --depth === 0) { end = i; break; }
  }
  const block = src.slice(start, end + 1);
  const out = new Map();
  for (const m of block.matchAll(/title: "([^"]+)"[\s\S]{0,900}?(?:apply)?[Ll]ink: "(https?:\/\/[^"]+)"/g)) {
    if (!out.has(m[2])) out.set(m[2], m[1]);
  }
  return out;
}

async function status(url) {
  for (const method of ["HEAD", "GET"]) {
    try {
      const c = new AbortController();
      const t = setTimeout(() => c.abort(), 20000);
      const r = await fetch(url, { method, redirect: "follow", signal: c.signal, headers: { "user-agent": UA, accept: "text/html" } });
      clearTimeout(t);
      if (method === "HEAD" && (r.status === 405 || r.status === 501)) continue; // some hosts refuse HEAD
      return r.status;
    } catch { if (method === "GET") return "unreachable"; }
  }
  return "unreachable";
}

test("no opportunity links 404", { timeout: 300000 }, async () => {
  const urls = shippedUrls();
  assert.ok(urls.size > 20, `expected the opportunity list, found ${urls.size} urls`);

  const results = [];
  const entries = [...urls.entries()];
  // Six at a time. Enough to finish quickly, gentle enough not to look like an
  // attack to a small charity's server.
  for (let i = 0; i < entries.length; i += 6) {
    const batch = entries.slice(i, i + 6);
    results.push(...await Promise.all(batch.map(async ([url, title]) => ({ url, title, code: await status(url) }))));
  }

  const dead = results.filter(r => DEAD.has(r.code));
  const unreachable = results.filter(r => r.code === "unreachable");
  const blocked = results.filter(r => BLOCKED.has(r.code));

  for (const r of blocked) console.log(`  blocked (fine)  ${r.code}  ${r.url}`);
  for (const r of unreachable) console.log(`  UNREACHABLE      ${r.url}  <- "${r.title}"`);
  for (const r of dead) console.log(`  DEAD             ${r.code}  ${r.url}  <- "${r.title}"`);
  console.log(`  ${results.length} links | ${dead.length} dead | ${unreachable.length} unreachable | ${blocked.length} bot-blocked`);

  assert.deepEqual(dead.map(d => `${d.title}: ${d.url}`), [], "these links 404 and would show a student a dead page");
});
