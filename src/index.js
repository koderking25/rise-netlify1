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

const API_PATH = "/api/ai-search";

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);

    if (url.pathname === API_PATH) {
      // The Pages-style handlers expect a context object. Build one from the
      // Worker arguments — same shape, same behaviour.
      const pagesCtx = {
        request,
        env,
        // Cache writes happen after the response is returned, so waitUntil has
        // to be forwarded or they get cancelled.
        waitUntil: ctx.waitUntil.bind(ctx)
      };

      if (request.method === "OPTIONS") return onRequestOptions(pagesCtx);
      if (request.method === "POST") return onRequestPost(pagesCtx);

      return new Response(JSON.stringify({ error: "POST only" }), {
        status: 405,
        headers: { "content-type": "application/json", allow: "POST, OPTIONS" }
      });
    }

    // Everything else is the app itself.
    return env.ASSETS.fetch(request);
  }
};
