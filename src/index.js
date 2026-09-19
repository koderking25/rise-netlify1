/* ══════════════════════════════════════════════════════════════════
   RISE — Worker entry point

   Cloudflare deploys this project as a Worker with static assets, which
   is a different thing from a Pages project. Pages auto-mounts anything
   in `functions/`; Workers does not. Without this file the deployment
   is static-only, `/api/ai-search` 404s, and the dashboard refuses to
   accept environment variables at all — "Variables cannot be added to a
   Worker that only has static assets" is Cloudflare telling you there
   is no server here.

   So: this handles the one API route and hands everything else to the
   asset server.

   The proxy logic itself is shared with the Pages adapter in
   functions/api/ai-search.js, so there is one implementation to keep
   correct rather than two that drift.
   ══════════════════════════════════════════════════════════════════ */

import { onRequestPost, onRequestOptions } from "../functions/api/ai-search.js";
import { onRequestPost as adminPost, onRequestOptions as adminOptions } from "../functions/api/admin.js";

const API_PATH = "/api/ai-search";
/* Admin actions run with the Supabase service_role key, which bypasses RLS
   and every column privilege. The handler gates itself — token verified with
   Supabase, role re-fetched per request — and this route exists so that gate
   lives in exactly one place rather than once per action. */
const ADMIN_PATH = "/api/admin";


/* ── MAINTENANCE LOCK ──────────────────────────────────────────────
   Set while rise4impact.org was found serving an injected script that
   pulled an executable payload from a BNB Smart Chain contract and ran
   it through eval(), showing visitors a fake reCAPTCHA. The injected
   bytes were never in this repository: the local index.html was 7,785
   bytes and clean while the edge served 10,156.

   This page is built as a string inside the Worker rather than served
   from the assets directory. That is deliberate and diagnostic: if the
   injection still appears in a response this code generated, then it
   is being added after the Worker runs, which means a Cloudflare
   Snippet, Transform Rule, or a second Worker on the route, and not a
   tampered asset.

   Flip to false only once the source is found and removed.
   ────────────────────────────────────────────────────────────────── */
const MAINTENANCE = false;
const MAINTENANCE_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>RISE is temporarily offline</title>
<style>
:root{color-scheme:light}
body{margin:0;min-height:100vh;display:grid;place-items:center;background:#F4F1EB;color:#1a1714;
font:16px/1.6 ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;padding:24px}
main{max-width:34rem}
h1{font:600 28px/1.25 ui-serif,Georgia,serif;margin:0 0 14px}
p{margin:0 0 12px;color:#4a443d}
.note{margin-top:20px;padding:14px 16px;background:#FEF0E6;border:1px solid rgba(214,86,12,.18);border-radius:10px;font-size:14.5px}
strong{color:#D6560C}
</style></head><body><main>
<h1>RISE is temporarily offline</h1>
<p>We took the site down ourselves after finding that something had been added to it that we did not put there. Nobody needs to do anything.</p>
<p class="note"><strong>If a page on this site ever asked you to prove you are not a robot, and then told you to copy a command into Terminal, do not run it.</strong> That was not us. Closing the tab is enough. We are sorry it was there at all.</p>
<p style="margin-top:20px">We will be back once we are certain the site is clean.</p>
<p style="font-size:14px;color:#8a8178">Neil and Rayan</p>
</main></body></html>`;


/* ── Security headers ─────────────────────────────────────────────
   On 19 September 2026 a second Worker was found on this zone, routed
   at *rise4impact.org/*, sitting in front of this one. It pulled a
   base64 payload from a BNB Smart Chain contract and appended it to
   every HTML response, which is how visitors were shown a fake
   reCAPTCHA telling them to paste a command into their terminal. The
   repository was never touched: the local index.html was clean while
   the edge served 2,371 extra bytes.

   The rogue Worker is gone. These headers are so that the same trick
   cannot work again even if something does get in front of us:

   script-src allows this origin and exactly one inline block, named by
   its sha256. The injected script carried no hash and would have been
   refused by the browser before it ran, whatever appended it.

   connect-src is the second lock. The payload lived on a blockchain
   RPC, so even a script that somehow executed could not fetch it: the
   only hosts reachable are this origin and Supabase.

   If the inline theme block in index.html is ever edited, this hash
   must be regenerated or the site will boot without its saved theme.
   ───────────────────────────────────────────────────────────────── */
const CSP = [
  "default-src 'self'",
  "script-src 'self' 'sha256-3uOI/KEIhaMCvox6OrYxlCW0W/f+bzU8Fl5P65UXixM='",
  "style-src 'self' 'unsafe-inline' https://fonts.googleapis.com",
  "font-src 'self' https://fonts.gstatic.com data:",
  "img-src 'self' data:",
  /* formsubmit.co is here because the contact form posts to it with fetch(),
     and fetch is governed by connect-src, not form-action. Caught by reading
     the bundle's absolute fetch targets rather than by a user finding the
     contact form silently broken.

     Deliberately absent: api.anthropic.com and generativelanguage.googleapis.com.
     The bundle still contains direct-to-provider calls from before the server
     proxy existed. They cannot work, because no key is in the browser, and
     leaving them blocked means a stolen page cannot reach a paid API either. */
  "connect-src 'self' https://okpqytfeyjkbxgjrbaen.supabase.co https://formsubmit.co",
  "form-action 'self' https://formsubmit.co",
  "frame-ancestors 'none'",
  "base-uri 'none'",
  "object-src 'none'",
  "upgrade-insecure-requests"
].join("; ");

function harden(resp) {
  const h = new Headers(resp.headers);
  h.set("content-security-policy", CSP);
  h.set("x-content-type-options", "nosniff");
  h.set("referrer-policy", "strict-origin-when-cross-origin");
  h.set("x-frame-options", "DENY");
  h.set("strict-transport-security", "max-age=31536000; includeSubDomains");
  return new Response(resp.body, { status: resp.status, statusText: resp.statusText, headers: h });
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    /* Everything except the API is held closed while the site is locked.
       The API stays reachable so the gate tests can still be run. */
    if (MAINTENANCE && url.pathname !== API_PATH && url.pathname !== ADMIN_PATH) {
      return harden(new Response(MAINTENANCE_HTML, {
        status: 503,
        headers: {
          "content-type": "text/html;charset=UTF-8",
          "cache-control": "no-store, must-revalidate",
          "retry-after": "3600"
        }
      }));
    }

    if (url.pathname === API_PATH || url.pathname === ADMIN_PATH) {
      // The Pages-style handlers expect a context object. Build one from the
      // Worker arguments — same shape, same behaviour.
      const pagesCtx = {
        request,
        env,
        // Cache writes happen after the response is returned, so waitUntil has
        // to be forwarded or they get cancelled.
        waitUntil: ctx.waitUntil.bind(ctx)
      };
      const isAdmin = url.pathname === ADMIN_PATH;

      if (request.method === "OPTIONS") return isAdmin ? adminOptions(pagesCtx) : onRequestOptions(pagesCtx);
      if (request.method === "POST") return isAdmin ? adminPost(pagesCtx) : onRequestPost(pagesCtx);

      return new Response(JSON.stringify({ error: "POST only" }), {
        status: 405,
        headers: { "content-type": "application/json", allow: "POST, OPTIONS" }
      });
    }

    // Everything else is the app itself.
    return harden(await env.ASSETS.fetch(request));
  }
};
