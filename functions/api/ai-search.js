/* ══════════════════════════════════════════════════════════════════
   RISE — AI proxy  (Cloudflare Pages Functions)

   Same contract as netlify/functions/ai-search.js — these are two
   adapters over the same behaviour, and you deploy whichever matches
   your host. The client tries /api/ai-search first (this file), then
   /.netlify/functions/ai-search.

   SETUP
     Pages → Settings → Environment variables → add as SECRETS:
       GEMINI_API_KEY     AIza...          (free tier is fine)
       ANTHROPIC_API_KEY  sk-ant-...       (optional, preferred)
     Then set both key constants in index.html back to "".

   Uses the Workers Cache API rather than an in-memory Map, so the
   cache is shared across every isolate in the colo instead of dying
   with a single warm container.
   ══════════════════════════════════════════════════════════════════ */

const CACHE_TTL = 1800; // seconds — personalised responses
/* Cohort discovery is cached for a full day, up from six hours.
   "What volunteer roles exist for music in Brantford" has one answer for
   every student in that town, and a deep run now costs around 60 cents:
   four searches, twelve page fetches, and the reading of all of them. At six
   hours a school class spread across an afternoon and evening paid for it
   twice. Volunteer postings do not turn over between breakfast and bedtime,
   and the shared pass is deliberately impersonal, so the only thing a longer
   window costs is freshness measured in hours on listings that change over
   weeks. It is the single largest cost lever in the app: one paid run
   serving thirty students instead of one. */
const SHARED_TTL = 24 * 3600;
const MAX_TTL = 24 * 3600;
const RATE_MAX = 40; // requests per IP
const RATE_WINDOW = 60 * 1000;
const MAX_BODY = 60 * 1024;

/* Spend guard — this proxy holds a key that bills real money on a URL anyone
   can find. Rate limiting caps requests; this caps cost. Per isolate and
   best-effort, but it turns an unbounded bill into a bounded one.
   Set DAILY_BUDGET_USD=0 to disable. */
const SPEND = { day: "", total: 0 };
function spendToday() {
  const today = new Date().toISOString().slice(0, 10);
  if (SPEND.day !== today) { SPEND.day = today; SPEND.total = 0; }
  return SPEND.total;
}

const RATE = new Map(); // best-effort per-isolate throttle

export async function onRequestOptions({ env }) {
  return new Response(null, { status: 204, headers: cors(env) });
}

export async function onRequestPost(ctx) {
  const { request, env } = ctx;
  const H = cors(env);
  const reply = (code, obj, extra) =>
    new Response(JSON.stringify(obj), {
      status: code,
      headers: { ...H, "Content-Type": "application/json", ...(extra || {}) }
    });

  const ip = request.headers.get("cf-connecting-ip") || "anon";
  if (!allow(ip)) return reply(429, { error: "Too many requests. Wait a minute." }, { "Retry-After": "60" });

  const raw = await request.text();
  if (raw.length > MAX_BODY) return reply(413, { error: "Request too large" });

  let body;
  try {
    body = JSON.parse(raw || "{}");
  } catch {
    return reply(400, { error: "Invalid JSON" });
  }

  const anthropicKey = env.ANTHROPIC_API_KEY || "";
  const geminiKey = env.GEMINI_API_KEY || "";

  // Liveness probe. The client uses this to find which proxy path exists before
  // committing to a slow request — it must never cost a token. Declared after
  // the keys on purpose: reading them above their `const` throws.
  if (body.action === "ping") {
    return reply(200, {
      ok: true,
      provider: anthropicKey ? "anthropic" : "gemini",
      search: !!anthropicKey
    });
  }
  // Link verification — a browser can't read cross-origin status codes, so the
  // anti-hallucination check has to run here.
  if (body.action === "verify") return reply(200, { results: await verifyUrls(body.urls) });

  if (!Array.isArray(body.messages) || !body.messages.length) {
    return reply(400, { error: "messages required" });
  }
  if (!anthropicKey && !geminiKey) {
    return reply(500, { error: "No provider key configured. Set ANTHROPIC_API_KEY or GEMINI_API_KEY." });
  }

  /* Colo-wide cache. Guarded because the cache is an optimisation, not a
     dependency — if `caches` is unavailable in whatever runtime this lands in,
     matching should still work, just without the saving. An optional speed-up
     must never be able to 500 the request.

     Two keying modes:

       default    hash of the whole request body. Correct, but in practice it
                  almost never hits: every matching request embeds the
                  student's own capabilities, languages and free text, so two
                  students asking the same question of the same city produce
                  different bodies and each pays for its own web search.

       cacheKey   an explicit identity supplied by the caller, used when the
                  caller knows the answer is shared. Discovery — "what
                  volunteer roles for music exist in Toronto?" — has the same
                  answer for every student in that cohort, and web search is
                  where essentially all the money goes. Keying it on
                  city+talent+angle means the cohort buys that search once
                  instead of once per student.

     `cacheKey` must never carry anything personal; it is the cache identity
     and is shared by definition. The caller is responsible for that, so
     personalised calls simply omit it and fall back to the body hash. */
  const cache = typeof caches !== "undefined" && caches.default ? caches.default : null;
  const cacheId = typeof body.cacheKey === "string" && body.cacheKey
    ? "k/" + (await hash(body.cacheKey))
    : "b/" + (await hash(raw));
  const cacheUrl = new URL(request.url);
  cacheUrl.pathname = "/api/ai-search/" + cacheId;
  const cacheReq = new Request(cacheUrl.toString(), { method: "GET" });

  if (cache && !body.fresh) {
    try {
      const cached = await cache.match(cacheReq);
      if (cached) return reply(200, await cached.json(), { "X-Cache": "HIT" });
    } catch (e) {}
  }

  const budget = env.DAILY_BUDGET_USD == null ? 5 : Number(env.DAILY_BUDGET_USD);
  if (budget > 0 && spendToday() >= budget) {
    return reply(429, {
      error: "Daily AI budget reached. Live matching resumes tomorrow.",
      budget,
      spent: Number(spendToday().toFixed(4))
    }, { "Retry-After": "3600" });
  }

  let out;
  try {
    out = anthropicKey ? await callAnthropic(body, anthropicKey, env) : await callGemini(body, geminiKey, env);
    spendToday();
    SPEND.total += out.cost || 0;
    out.spentToday = Number(SPEND.total.toFixed(4));
  } catch (e) {
    // Transient upstream failures only. A 4xx is our bug and must stay visible
    // rather than being quietly answered by the weaker provider.
    const transient = !e.status || e.status === 429 || e.status >= 500;
    if (anthropicKey && geminiKey && transient) {
      try {
        out = await callGemini(body, geminiKey, env);
      } catch (e2) {
        /* Report the Anthropic failure, not the fallback's. The fallback is the
           understudy; when both fail, the useful fact is why the lead went
           down. This surfaced as a live outage reading "gemini auth: 401" while
           the actual cause was on the Anthropic call, which sent debugging in
           precisely the wrong direction. The fallback's own error is kept as a
           second field rather than thrown away. */
        return reply(502, {
          error: String(e.message || e),
          fallbackError: String(e2.message || e2)
        });
      }
    } else {
      return reply(502, { error: String(e.message || e) });
    }
  }

  /* ── Every link the model produced, opened before it is handed over ──
     The model is told to open an application page before recommending it, and
     mostly does. Mostly is not good enough when the failure lands on a
     fifteen year old as a page-not-found: that is the moment they conclude
     the site does not work and stop.

     So the claim is checked rather than trusted. A dead applyLink is removed
     rather than the whole match discarded, because the organization is
     usually real even when the deep link has rotted, and a student is far
     better off on a working homepage than on nothing. A link confirmed
     reachable is marked so the card can say so.

     Unknown stays unknown. A timeout from our edge is not evidence a charity
     is gone, and guessing would strip good placements. */
  if (out && Array.isArray(out.parsed) && out.parsed.length) {
    try {
      const wanted = [];
      for (const it of out.parsed) {
        if (it && typeof it.applyLink === "string") wanted.push(it.applyLink);
        if (it && typeof it.link === "string") wanted.push(it.link);
      }
      if (wanted.length) {
        const seen = await verifyUrls([...new Set(wanted)]);
        let dropped = 0;
        for (const it of out.parsed) {
          const a = it && it.applyLink && seen[it.applyLink];
          if (a && a.ok === false) { delete it.applyLink; dropped++; }
          else if (a && a.ok === true) it.applyVerified = true;
          const l = it && it.link && seen[it.link];
          if (l) it.linkOk = l.ok;
        }
        out.linksChecked = Object.keys(seen).length;
        out.deadApplyLinksDropped = dropped;
      }
    } catch (e) {
      // Verification is a safeguard, not a gate. If it fails, still answer.
    }
  }

  /* Shared entries live much longer than personalised ones. Volunteer postings
     do not turn over every half hour, and a cohort cache that expires in 30
     minutes buys the same search again for the next class. Callers can ask for
     a specific TTL; anything explicitly keyed defaults to the longer one. */
  const ttl = Math.min(Number(body.cacheTtl) || (body.cacheKey ? SHARED_TTL : CACHE_TTL), MAX_TTL);
  if (cache && !body.fresh && ctx.waitUntil) {
    try {
      ctx.waitUntil(cache.put(cacheReq, new Response(JSON.stringify(out), {
        headers: { "Content-Type": "application/json", "Cache-Control": "max-age=" + ttl }
      })));
    } catch (e) {}
  }
  return reply(200, out, { "X-Cache": "MISS", "X-Cache-Ttl": String(ttl) });
}

function cors(env) {
  return {
    "Access-Control-Allow-Origin": (env && env.ALLOW_ORIGIN) || "*",
    "Access-Control-Allow-Headers": "Content-Type",
    "Access-Control-Allow-Methods": "POST, OPTIONS"
  };
}

function allow(ip) {
  const now = Date.now();
  const r = RATE.get(ip);
  if (!r || now > r.resetAt) {
    RATE.set(ip, { n: 1, resetAt: now + RATE_WINDOW });
    if (RATE.size > 5000) RATE.clear();
    return true;
  }
  r.n++;
  return r.n <= RATE_MAX;
}

async function hash(s) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
  return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, "0")).join("");
}

/* ── Anthropic (Sonnet 5) ──
   The good path. Real web_search means results are current listings the model
   actually opened, not recalled knowledge — which is the entire difference
   between "here are some organizations" and "here is a posting with a named
   coordinator and a start date".

   Three things learned the hard way, all load-bearing:

   1. THINKING MUST BE OFF. With extended thinking on, reasoning ate the output
      budget and the response was truncated *before* the model reached its
      final tool call — so the request cost full price and returned zero
      results. Measured: $0.32 for nothing. Disabled, the same request costs
      ~$0.15 and reliably returns matches.

   2. WEB SEARCH RESULTS DOMINATE COST. Each search injects page content into
      context, so max_uses is the real spend dial, not max_tokens. Four
      searches ≈ $0.19; two ≈ $0.09. Capped and configurable.

   3. PROMPT CACHING pays for itself immediately. The system block is marked
      ephemeral, so repeat calls read it at a tenth of the input price. */

const ANTHROPIC_VERSION = "2023-06-01";
/* Ceilings, not targets. The model uses what it needs and stops.

   Searches were capped at 4 and fetches at 5, which was enough to name five
   organizations and open one or two of them. Reaching an application form
   costs two or three fetches per organization on its own: the site, its
   volunteer page, and usually an outside portal. Ten results with a real form
   each cannot fit in five.

   Search is billed per request and fetch is billed as the page content it
   pulls into context, so both are real money. What makes raising them
   affordable is that the pass which uses them is cohort-cached: one run
   answers "what exists for music in Brantford" for every student who asks,
   and the personal work happens downstream on a few thousand tokens. */
const MAX_SEARCHES_DEFAULT = 8;
const MAX_FETCHES_DEFAULT = 14;

// Sonnet pricing per million tokens; web search billed per 1k requests.
/* Sonnet 5 list price. These were Sonnet 4.6's numbers ($3/$15) and were never
   updated when the model moved to Sonnet 5, so every call was billed to the
   spend guard 50% high and DAILY_BUDGET_USD tripped a third early. Cache write
   is 1.25x input, cache read 0.1x. Web fetch has no per-use fee; its cost is
   the page content it pulls into context, which is why max_content_tokens
   below is the real dial for it. */
const PRICE_BY_MODEL = {
  "claude-sonnet-5": { input: 2, cacheWrite: 2.5, cacheRead: 0.2, output: 10 },
  "claude-opus-5":   { input: 5, cacheWrite: 6.25, cacheRead: 0.5, output: 25 },
  "claude-haiku-4-5": { input: 1, cacheWrite: 1.25, cacheRead: 0.1, output: 5 }
};
/* Sonnet's numbers are the fallback, because it is what an unrecognised model
   is most likely to be here and guessing low on an unknown model is the wrong
   way to be wrong: the spend guard would let it run longer than intended. */
const PRICE = PRICE_BY_MODEL["claude-sonnet-5"];
const SEARCH_PER_1K = 10;

function priceFor(model) {
  const m = String(model || "");
  for (const key of Object.keys(PRICE_BY_MODEL)) if (m.startsWith(key)) return PRICE_BY_MODEL[key];
  return PRICE;
}

/* Priced per model. The app now runs two: Sonnet reads the web, Opus judges
   what it found. Opus costs 2.5x Sonnet, so charging every call at Sonnet
   rates billed the spend guard roughly 40% of what a judging call actually
   costs, which is exactly the direction you do not want a budget to be wrong
   in. The model is taken from the response rather than the request, so a
   server-side substitution is priced as what actually ran. */
function estimateCost(u, model) {
  if (!u) return 0;
  const P = priceFor(model);
  const st = u.server_tool_use || {};
  return (
    (u.input_tokens || 0) * P.input / 1e6 +
    (u.cache_creation_input_tokens || 0) * P.cacheWrite / 1e6 +
    (u.cache_read_input_tokens || 0) * P.cacheRead / 1e6 +
    (u.output_tokens || 0) * P.output / 1e6 +
    (st.web_search_requests || 0) * SEARCH_PER_1K / 1000
  );
}

/* A thinking request that runs out of output budget is the exact failure note 1
   recorded: full price, nothing usable. Rather than forbid thinking to avoid
   it, notice it and take the answer without thinking, once. The retry is
   cheaper than the attempt that failed and the costs of both are reported, so
   the spend guard still sees the true total rather than only the second try. */
async function callAnthropic(body, key, env) {
  const first = await callAnthropicOnce(body, key, env);
  if (!first.truncated || !body.think) return first;

  const second = await callAnthropicOnce({ ...body, think: false }, key, env);
  second.cost = Number(((first.cost || 0) + (second.cost || 0)).toFixed(4));
  second.retriedWithoutThinking = true;
  return second;
}

/* Rebuilds a Messages response from the event stream.

   Content blocks arrive as a start event, zero or more deltas, and a stop.
   Text arrives as text_delta, tool arguments as input_json_delta fragments
   that only parse once concatenated, and server tool results (web search, web
   fetch) arrive whole in the start event. Usage is split: input tokens come
   with message_start, output tokens with message_delta at the end. */
async function readAnthropicStream(res) {
  const reader = res.body.getReader();
  const decoder = new TextDecoder();
  let buf = "";
  const msg = { content: [], usage: {} };
  const partialJson = {};

  const handle = (evt) => {
    switch (evt.type) {
      case "message_start":
        Object.assign(msg, evt.message || {}, { content: [] });
        break;
      case "content_block_start":
        msg.content[evt.index] = JSON.parse(JSON.stringify(evt.content_block || {}));
        if (msg.content[evt.index].type === "tool_use") partialJson[evt.index] = "";
        break;
      case "content_block_delta": {
        const b = msg.content[evt.index]; const d = evt.delta || {};
        if (!b) break;
        if (d.type === "text_delta") b.text = (b.text || "") + d.text;
        else if (d.type === "thinking_delta") b.thinking = (b.thinking || "") + d.thinking;
        else if (d.type === "input_json_delta") partialJson[evt.index] = (partialJson[evt.index] || "") + d.partial_json;
        break;
      }
      case "content_block_stop": {
        const raw = partialJson[evt.index];
        if (raw != null && msg.content[evt.index]) {
          try { msg.content[evt.index].input = raw ? JSON.parse(raw) : {}; } catch (e) {}
          delete partialJson[evt.index];
        }
        break;
      }
      case "message_delta":
        Object.assign(msg, evt.delta || {});
        Object.assign(msg.usage, evt.usage || {});
        break;
      case "error":
        throw Object.assign(new Error("anthropic stream: " + JSON.stringify(evt.error).slice(0, 300)), { status: 502 });
    }
  };

  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    buf += decoder.decode(value, { stream: true });
    let nl;
    while ((nl = buf.indexOf("\n")) !== -1) {
      const line = buf.slice(0, nl).trim();
      buf = buf.slice(nl + 1);
      if (!line.startsWith("data:")) continue;
      const payload = line.slice(5).trim();
      if (!payload || payload === "[DONE]") continue;
      let evt; try { evt = JSON.parse(payload); } catch (e) { continue; }
      handle(evt);
    }
  }
  msg.content = msg.content.filter(Boolean);
  return msg;
}

async function callAnthropicOnce(body, key, env) {
  const MAX_SEARCHES = Number((env && env.MAX_SEARCHES) || MAX_SEARCHES_DEFAULT);
  const req = {
    model: body.model || "claude-sonnet-5",
    /* 8192 was the ceiling while calls were non-streaming, where a large
       max_tokens risks an HTTP timeout. Every call streams now, so the cap can
       be what the work actually needs.

       It needs a lot. A deep search spends output on thinking, on narration
       between tool calls, and only then on the emit arguments. Measured: one
       run used 22,889 output tokens and was cut off before emit could be
       filled, returning nothing after 345 seconds and 57 cents. The ceiling
       was the whole reason. */
    max_tokens: Math.min(body.max_tokens || 1800, 32000),
    messages: body.messages
  };

  /* Note 1 above recorded that thinking had to be off: reasoning ate the output
     budget and the answer was truncated before the model reached its final tool
     call, so a request cost full price and returned nothing.

     That measurement was real, but the cause was not thinking itself. Thinking
     tokens are drawn from max_tokens, and max_tokens was 1800. Any reasoning at
     all crowded out the answer. The note was written before `effort` existed,
     when the only dial was a fixed token budget.

     Effort is that dial now, so thinking is opt-in per call and arrives with
     room to land: a thinking request is floored at 6000 output tokens. Low
     effort is the default because most searches are routine and the depth is
     not worth paying for. The failure the note describes is guarded against
     directly below, where a truncated thinking response is retried once
     without thinking rather than billed for nothing. */
  if (body.think) {
    req.thinking = { type: "adaptive" };
    req.output_config = { effort: body.effort || "low" };
    req.max_tokens = Math.max(req.max_tokens, 6000);
  }

  // Cache the system prompt: it's identical across every call in a search.
  if (body.system) {
    req.system = typeof body.system === "string"
      ? [{ type: "text", text: body.system, cache_control: { type: "ephemeral" } }]
      : body.system;
  }
  // Sonnet 5 rejects `temperature` outright ("deprecated for this model"), and
  // the request 400s. Callers still pass it for the Gemini path, so drop it here
  // rather than making every call site model-aware.
  if (body.temperature != null && !/sonnet-5|opus-5|haiku-4-5/.test(req.model)) {
    req.temperature = body.temperature;
  }

  const tools = [];

  // Live web search, geo-hinted so "volunteer tutor" finds the right city's
  // listings rather than the largest city that matches the words.
  if (body.search) {
    const s = {
      // The 2026-02-09 variant filters results before they reach context, so a
      // search costs fewer input tokens than the 2025-03-05 one it replaces.
      type: "web_search_20260209",
      name: "web_search",
      max_uses: Math.min(Number(body.search.maxUses) || MAX_SEARCHES, MAX_SEARCHES)
    };
    if (body.search.city || body.search.region || body.search.country) {
      s.user_location = {
        type: "approximate",
        country: body.search.country || "CA",
        ...(body.search.region ? { region: body.search.region } : {}),
        ...(body.search.city ? { city: body.search.city } : {})
      };
    }
    tools.push(s);

    /* Web search returns snippets. That is enough to name an organization and
       no more, which is why the matcher could only ever hand a student a
       homepage and an instruction to go looking for the volunteer page
       themselves. Fetch lets the model open the page it found, read the real
       navigation, and follow "Volunteer" or "Get Involved" through to the
       application form — including when a charity hands its intake to a
       third-party portal, which small food banks and libraries routinely do.

       It only fetches URLs already in the conversation, so it cannot wander:
       search finds the door, fetch walks through it.

       max_content_tokens is the spend dial. A charity volunteer page is small;
       6000 tokens is a whole page with room to spare, and it stops one
       accidentally enormous page from costing more than the entire search. */
    if (body.fetch !== false) {
      tools.push({
        type: "web_fetch_20260209",
        name: "web_fetch",
        max_uses: Math.min(Number(body.fetchUses) || MAX_FETCHES_DEFAULT, MAX_FETCHES_DEFAULT),
        max_content_tokens: 6000,
        citations: { enabled: true }
      });
    }
  }

  // Structured output. Not forced when web search is present — forcing the tool
  // stops the model searching at all — so the prompt asks it to finish with the
  // call instead, and we fall back to parsing text if it doesn't.
  if (body.schema) {
    tools.push({
      name: "emit",
      description: "Return the final result. Call this exactly once, at the end, after any searching is finished.",
      input_schema: toJsonSchema(body.schema)
    });
    if (!body.search) req.tool_choice = { type: "tool", name: "emit" };
  }
  if (tools.length) req.tools = tools;

  /* Streamed, always, then reassembled here into the same object a
     non-streamed call returns.

     A deep search is slow by nature: seven web searches and up to fourteen
     page fetches, each one a real round trip on Anthropic's side. Held open
     as a single non-streaming request that reliably died at roughly 100
     seconds with a 524, after doing and billing all of the work. Measured:
     125 seconds to a timeout, full price, nothing returned.

     Streaming keeps bytes moving so nothing upstream decides the connection
     is dead. The browser contract is unchanged, because the stream is
     consumed here and only the finished result is sent on. That keeps the
     client simple and, more importantly, keeps the link verification below
     possible: it needs the whole answer before it can check anything. */
  req.stream = true;

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": key,
      "anthropic-version": ANTHROPIC_VERSION
    },
    body: JSON.stringify(req)
  });
  if (!res.ok) {
    const text = await res.text();
    const err = new Error("anthropic " + res.status + " " + text.slice(0, 300));
    err.status = res.status;
    throw err;
  }
  const data = await readAnthropicStream(res);

  const out = {
    content: data.content || [],
    sources: anthropicSources(data),
    model: data.model,
    grounded: !!body.search,
    stop_reason: data.stop_reason,
    usage: data.usage,
    cost: Number(estimateCost(data.usage, data.model).toFixed(4)),
    searches: (data.usage && data.usage.server_tool_use && data.usage.server_tool_use.web_search_requests) || 0,
    fetches: (data.usage && data.usage.server_tool_use && data.usage.server_tool_use.web_fetch_requests) || 0
  };

  const tool = (data.content || []).find(c => c.type === "tool_use" && c.name === "emit");
  if (tool) {
    const got = (tool.input && tool.input.items) || tool.input;
    /* An emit whose arguments were cut off mid-stream arrives as {}, which is
       truthy, so it counted as a successful parse and the caller was handed
       zero results as though that were the honest answer. A run that cost
       real money and produced nothing has to be visible as a failure, not
       reported as an empty search. */
    const empty = got == null || (Array.isArray(got) ? got.length === 0 : Object.keys(got).length === 0);
    if (!empty) out.parsed = got;
  } else if (body.schema) {
    // The model answered in prose instead of calling the tool. Rare, but it
    // costs the same either way — salvage it rather than binning the spend.
    const text = (data.content || []).filter(c => c.type === "text").map(c => c.text).join("\n");
    const m = text.match(/\[[\s\S]*\]/);
    if (m) {
      try {
        out.parsed = JSON.parse(m[0]);
      } catch (e) {}
    }
  }
  /* Truncation is judged outside the schema branch on purpose. It was only set
     when a schema was asked for, so a thinking request that ran out of budget
     mid-sentence looked like a perfectly good short answer, and the retry above
     would never fire for the plain-prose calls that need it most. */
  if (!out.parsed && data.stop_reason === "max_tokens") {
    out.truncated = true;
  }
  return out;
}

// Pull the pages the web_search tool actually fetched, for citation chips.
function anthropicSources(data) {
  const out = [];
  const seen = new Set();
  for (const block of data.content || []) {
    /* Fetched pages are sources too. Without this the citation chips showed the
       search hits but not the volunteer page the model actually opened and read
       to find the form, which is the one link a student most wants to click. */
    if (block.type === "web_fetch_tool_result") {
      const r = block.content;
      const url = r && (r.url || (r.document && r.document.source && r.document.source.url));
      if (url && !seen.has(url)) {
        seen.add(url);
        /* Key is `uri`, matching the search branch below. They were `url` and
           `uri` respectively at first, so fetched pages silently failed to
           render as citation chips: the object was there, the field the UI
           reads was not. */
        out.push({ uri: url, title: (r && r.document && r.document.title) || url, fetched: true });
      }
      continue;
    }
    const results = block.type === "web_search_tool_result" ? block.content || [] : [];
    for (const r of results) {
      if (!r.url || seen.has(r.url)) continue;
      seen.add(r.url);
      out.push({ title: r.title || "", uri: r.url });
      if (out.length >= 10) return out;
    }
  }
  return out;
}

/* Free-tier Gemini quota is metered per model, per project, per day — so
   pinning one model means the whole proxy dies when that single bucket empties,
   while other models on the same key still have quota sitting unused. This
   walks a ladder instead, parking exhausted models until the daily reset.

   Kept deliberately in sync with GEMINI_LADDER in index.html. */
/* NOTE: no `process.env` anywhere in this file. Cloudflare Workers has no
   `process` global, so reading it at module scope throws a ReferenceError
   before the handler ever runs and every request 500s. Config arrives through
   the `env` argument instead. */
const GEMINI_LADDER_DEFAULT = ["gemini-3.5-flash", "gemini-3.6-flash", "gemini-3-flash-preview", "gemini-3.1-flash-lite", "gemini-3.5-flash-lite", "gemini-flash-lite-latest", "gemini-2.5-flash"];

function ladderFor(env) {
  const custom = ((env && env.GEMINI_MODELS) || "").trim();
  return custom ? custom.split(",").map(s => s.trim()).filter(Boolean) : GEMINI_LADDER_DEFAULT;
}

const modelBlocked = Object.create(null); // model -> unblock timestamp
let groundingOff = false;

function msUntilQuotaReset() {
  const now = new Date();
  const reset = new Date(now);
  reset.setHours(24, 5, 0, 0);
  return Math.max(60000, reset - now);
}

function availableModels(env) {
  const now = Date.now();
  const ladder = ladderFor(env);
  const free = ladder.filter(m => !(modelBlocked[m] > now));
  return free.length ? free : ladder.slice();
}

function geminiPayload(body, model, withSearch, extraRoom) {
  const prompt = (body.messages || [])
    .map(m => (typeof m.content === "string" ? m.content : ""))
    .join("\n");
  // Gemini 3.x spends output tokens thinking before it answers. Without
  // headroom the reasoning eats the budget and the JSON comes back truncated.
  const thinking = /gemini-3/.test(model);
  const want = body.max_tokens || 1800;
  const payload = {
    contents: [{ parts: [{ text: prompt }] }],
    generationConfig: {
      maxOutputTokens: Math.min(thinking ? want + 2600 + (extraRoom || 0) : want, 16000),
      temperature: body.temperature != null ? body.temperature : 0.5,
      topP: 0.95
    }
  };
  if (thinking) payload.generationConfig.thinkingConfig = { thinkingLevel: "low" };
  if (body.system) payload.systemInstruction = { parts: [{ text: body.system }] };
  // Gemini rejects responseSchema together with google_search, so grounded
  // calls fall back to text output and the client's tolerant JSON reader.
  if (withSearch) payload.tools = [{ google_search: {} }];
  else if (body.schema) {
    payload.generationConfig.responseMimeType = "application/json";
    payload.generationConfig.responseSchema = body.schema;
  }
  return payload;
}

async function geminiOnce(model, payload, key) {
  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/" +
    model +
    ":generateContent?key=" +
    encodeURIComponent(key);
  const res = await fetch(url, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(payload)
  });
  if (res.status === 429 || res.status === 503) {
    const text = await res.text().catch(() => "");
    return {
      kind: "quota",
      status: res.status,
      daily: /PerDay/i.test(text) || /limit: 0\b/.test(text),
      // Grounding is metered separately from generation, and on the free tier
      // it usually has no allowance at all.
      grounding: !!payload.tools && !/generate_content_free_tier_requests/.test(text)
    };
  }
  if (res.status === 404) return { kind: "nomodel" };
  if (!res.ok) {
    const text = await res.text().catch(() => "");
    if (res.status === 400 || res.status === 401 || res.status === 403) {
      return { kind: "auth", text: text.slice(0, 200) };
    }
    return { kind: "error", status: res.status, text: text.slice(0, 200) };
  }
  const data = await res.json();
  const cand = data.candidates && data.candidates[0];
  const text = ((cand && cand.content && cand.content.parts) || [])
    .map(p => p.text || "")
    .join("");
  if (!text) return { kind: "empty" };
  if (cand.finishReason === "MAX_TOKENS") return { kind: "truncated", text, cand };
  return { kind: "ok", text, cand };
}
async function callGemini(body, key, env) {
  const wantSearch = !!(body.tools && body.tools.length);
  let searchOn = wantSearch && !groundingOff;
  let lastErr = null;

  const finish = (r, model, grounded) => {
    const out = {
      content: [{ type: "text", text: r.text }],
      sources: grounded ? geminiSources(r.cand) : [],
      model,
      grounded
    };
    if (body.schema && !grounded) {
      try {
        out.parsed = JSON.parse(r.text);
      } catch (e) {}
    }
    return out;
  };

  for (let attempt = 0; attempt < 2; attempt++) {
    for (const model of availableModels(env)) {
      const r = await geminiOnce(model, geminiPayload(body, model, searchOn, attempt * 3000), key);

      if (r.kind === "ok") return finish(r, model, searchOn);

      if (r.kind === "truncated") {
        if (attempt < 1) {
          lastErr = new Error("gemini truncated");
          continue;
        }
        // Out of retries: hand back the partial text rather than nothing —
        // the client's tolerant reader can often still recover whole objects.
        return finish(r, model, searchOn);
      }

      if (r.kind === "auth") throw new Error("gemini auth: " + r.text);

      if (r.kind === "nomodel") {
        modelBlocked[model] = Date.now() + 24 * 3600 * 1000;
        continue;
      }

      if (r.kind === "quota") {
        // Grounding being out of quota isn't the model's fault. Drop search and
        // let the same model answer from its own knowledge rather than losing
        // the request entirely.
        if (searchOn && r.grounding) {
          groundingOff = true;
          searchOn = false;
          const r2 = await geminiOnce(model, geminiPayload(body, model, false, attempt * 3000), key);
          if (r2.kind === "ok" || r2.kind === "truncated") return finish(r2, model, false);
        }
        modelBlocked[model] = Date.now() + (r.daily ? msUntilQuotaReset() : 30000);
        lastErr = new Error("gemini " + r.status);
        continue;
      }

      lastErr = new Error("gemini " + (r.status || r.kind) + " " + (r.text || ""));
    }
    if (attempt < 1) await new Promise(r => setTimeout(r, 1200));
  }
  throw lastErr || new Error("gemini unavailable — every model is out of quota");
}

function geminiSources(cand) {
  const chunks = cand?.groundingMetadata?.groundingChunks || [];
  const out = [];
  const seen = new Set();
  for (const c of chunks) {
    const uri = c.web?.uri;
    if (!uri) continue;
    const title = c.web.title || "";
    const k = title || uri;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push({ title, uri });
    if (out.length >= 8) break;
  }
  return out;
}

/* Confirm each suggested organization link actually resolves, so a student
   never emails an organization that folded years ago. */
async function verifyUrls(urls) {
  const list = (Array.isArray(urls) ? urls : []).filter(u => /^https:\/\//.test(u)).slice(0, 24);
  const results = {};
  await Promise.all(
    list.map(async u => {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 6000);
      try {
        let res = await fetch(u, { method: "HEAD", redirect: "follow", signal: ctrl.signal });
        if (res.status === 405 || res.status === 501) {
          res = await fetch(u, { method: "GET", redirect: "follow", signal: ctrl.signal });
        }
        /* 401/403/405/406/429 mean "not to you, not like that", not "not
           here". Several large charities refuse any client that is not a
           browser, and Red Cross, Scouts, Tree Canada and Best Buddies all
           answer 403 to this check while working perfectly for a student.
           Marking those dead would delete the most reputable placements on
           the site. Only a real 404 or 410 counts as gone. */
        const blocked = [401, 403, 405, 406, 429].includes(res.status);
        const gone = res.status === 404 || res.status === 410;
        results[u] = { ok: gone ? false : (blocked ? null : res.status >= 200 && res.status < 400), status: res.status };
      } catch {
        // Timeout or DNS failure isn't proof the site is dead — report unknown.
        results[u] = { ok: null, status: 0 };
      } finally {
        clearTimeout(t);
      }
    })
  );
  return results;
}

function toJsonSchema(g) {
  const conv = n => {
    if (!n || typeof n !== "object") return n;
    const t = String(n.type || "").toLowerCase();
    const o = { type: t || "string" };
    if (n.enum) o.enum = n.enum;
    if (t === "array") o.items = conv(n.items);
    if (t === "object") {
      o.properties = {};
      for (const k in n.properties || {}) o.properties[k] = conv(n.properties[k]);
      if (n.required) o.required = n.required;
    }
    return o;
  };
  if (String(g.type).toLowerCase() === "array") {
    return { type: "object", properties: { items: conv(g) }, required: ["items"] };
  }
  return conv(g);
}
