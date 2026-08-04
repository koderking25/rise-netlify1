/* ══════════════════════════════════════════════════════════════════
   RISE — AI proxy  (Netlify Functions)

   The client used to carry a Gemini API key in its page source, where
   anyone could read it and spend your quota. This function moves the key
   server-side: the browser posts a request shape, this decides which
   provider to use and answers with the same shape back.

   SETUP
     netlify env:set GEMINI_API_KEY    "AIza..."      # free tier is fine
     netlify env:set ANTHROPIC_API_KEY "sk-ant-..."   # optional, preferred
   Then set both constants in index.html back to "".

   Set at least one. With ANTHROPIC_API_KEY present the app gets real
   web_search tool use; with only GEMINI_API_KEY it uses Google Search
   grounding, which is free but returns fewer verifiable citations.
   ══════════════════════════════════════════════════════════════════ */

const ANTHROPIC_KEY = process.env.ANTHROPIC_API_KEY || "";
const GEMINI_KEY = process.env.GEMINI_API_KEY || "";
const ALLOW_ORIGIN = process.env.ALLOW_ORIGIN || "*";

// Cheap in-memory guards. Netlify keeps a warm container alive between
// invocations, so these hold for the life of that container — enough to blunt
// a burst without standing up Redis for a student project.
const RATE = new Map(); // ip -> { n, resetAt }
const CACHE = new Map(); // key -> { at, body }
const RATE_MAX = Number(process.env.RATE_MAX || 40); // requests
const RATE_WINDOW = 60 * 1000; // per minute
const CACHE_TTL = 30 * 60 * 1000;
const MAX_BODY = 60 * 1024;

/* ── Spend guard ──
   This proxy holds a key that bills real money per token, on a URL anyone can
   find. Rate limiting caps requests per IP; this caps total spend, so a bug, a
   scraper, or one very enthusiastic afternoon can't quietly run up a bill.
   Resets daily. Set DAILY_BUDGET_USD=0 to disable. */
const DAILY_BUDGET = process.env.DAILY_BUDGET_USD == null ? 5 : Number(process.env.DAILY_BUDGET_USD);
const SPEND = { day: new Date().toISOString().slice(0, 10), total: 0 };
function spendToday() {
  const today = new Date().toISOString().slice(0, 10);
  if (SPEND.day !== today) {
    SPEND.day = today;
    SPEND.total = 0;
  }
  return SPEND.total;
}
function recordSpend(usd) {
  spendToday();
  SPEND.total += usd || 0;
}
const cors = {
  "Access-Control-Allow-Origin": ALLOW_ORIGIN,
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json"
};
const reply = (code, obj, extra) => ({
  statusCode: code,
  headers: Object.assign({}, cors, extra || {}),
  body: JSON.stringify(obj)
});

exports.handler = async function (event) {
  if (event.httpMethod === "OPTIONS") return { statusCode: 204, headers: cors, body: "" };
  if (event.httpMethod !== "POST") return reply(405, { error: "POST only" });

  const ip =
    (event.headers["x-nf-client-connection-ip"] ||
      (event.headers["x-forwarded-for"] || "").split(",")[0] ||
      "anon").trim();
  if (!allow(ip)) return reply(429, { error: "Too many requests. Wait a minute." }, { "Retry-After": "60" });

  if ((event.body || "").length > MAX_BODY) return reply(413, { error: "Request too large" });

  let body;
  try {
    body = JSON.parse(event.body || "{}");
  } catch (e) {
    return reply(400, { error: "Invalid JSON" });
  }

  // Link verification — the browser can't read cross-origin status codes, so
  // the anti-hallucination check has to happen here.
  // Liveness probe. The client uses this to find which proxy path exists
  // before committing to a slow request — it must never cost a token.
  if (body.action === "ping") {
    return reply(200, {
      ok: true,
      provider: ANTHROPIC_KEY ? "anthropic" : "gemini",
      search: !!ANTHROPIC_KEY
    });
  }
  if (body.action === "verify") return reply(200, { results: await verifyUrls(body.urls) });

  if (!Array.isArray(body.messages) || !body.messages.length) {
    return reply(400, { error: "messages required" });
  }
  if (!ANTHROPIC_KEY && !GEMINI_KEY) {
    return reply(500, { error: "No provider key configured. Set ANTHROPIC_API_KEY or GEMINI_API_KEY." });
  }

  const key = cacheKey(body);
  // `fresh` means the caller wants a real lookup, not a replay. Honour it, or
  // "search again" silently becomes "show me the same thing again".
  const hit = body.fresh ? null : CACHE.get(key);
  if (hit && Date.now() - hit.at < CACHE_TTL) {
    return reply(200, hit.body, { "X-Cache": "HIT" });
  }

  if (DAILY_BUDGET > 0 && spendToday() >= DAILY_BUDGET) {
    return reply(429, {
      error: "Daily AI budget reached. Live matching resumes tomorrow.",
      budget: DAILY_BUDGET,
      spent: Number(spendToday().toFixed(4))
    }, { "Retry-After": "3600" });
  }

  try {
    const out = ANTHROPIC_KEY ? await callAnthropic(body) : await callGemini(body);
    recordSpend(out.cost);
    out.spentToday = Number(spendToday().toFixed(4));
    if (!body.fresh) CACHE.set(key, { at: Date.now(), body: out });
    if (CACHE.size > 200) CACHE.delete(CACHE.keys().next().value);
    return reply(200, out, { "X-Cache": "MISS" });
  } catch (e) {
    /* Fall back only on transient upstream failures. A 4xx means WE sent a bad
       request, and silently answering from the weaker provider hides that bug
       forever — which is exactly what happened with the deprecated
       `temperature` field: every call 400'd, quietly degraded to Gemini, and
       the results looked merely mediocre instead of broken. */
    const transient = !e.status || e.status === 429 || e.status >= 500;
    if (ANTHROPIC_KEY && GEMINI_KEY && transient) {
      try {
        const out = await callGemini(body);
        CACHE.set(key, { at: Date.now(), body: out });
        return reply(200, out, { "X-Cache": "MISS", "X-Fallback": "gemini" });
      } catch (e2) {
        return reply(502, { error: String(e2.message || e2) });
      }
    }
    return reply(502, { error: String(e.message || e) });
  }
};

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

function cacheKey(b) {
  return JSON.stringify([b.model, b.system, b.messages, !!b.tools, b.schema, b.temperature, b.search]);
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
const MAX_SEARCHES = Number(process.env.MAX_SEARCHES || 4);

// Sonnet pricing per million tokens; web search billed per 1k requests.
const PRICE = { input: 3, cacheWrite: 3.75, cacheRead: 0.3, output: 15, searchPer1k: 10 };

function estimateCost(u) {
  if (!u) return 0;
  const st = u.server_tool_use || {};
  return (
    (u.input_tokens || 0) * PRICE.input / 1e6 +
    (u.cache_creation_input_tokens || 0) * PRICE.cacheWrite / 1e6 +
    (u.cache_read_input_tokens || 0) * PRICE.cacheRead / 1e6 +
    (u.output_tokens || 0) * PRICE.output / 1e6 +
    (st.web_search_requests || 0) * PRICE.searchPer1k / 1000
  );
}

async function callAnthropic(body) {
  const req = {
    model: body.model || "claude-sonnet-5",
    max_tokens: Math.min(body.max_tokens || 1800, 8192),
    messages: body.messages,
    // See note 1 above. Never remove without re-measuring tool-call reliability.
    thinking: { type: "disabled" }
  };

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
      type: "web_search_20250305",
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

  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": ANTHROPIC_KEY,
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
  const data = await res.json();

  const out = {
    content: data.content || [],
    sources: anthropicSources(data),
    model: data.model,
    grounded: !!body.search,
    stop_reason: data.stop_reason,
    usage: data.usage,
    cost: Number(estimateCost(data.usage).toFixed(4)),
    searches: (data.usage && data.usage.server_tool_use && data.usage.server_tool_use.web_search_requests) || 0
  };

  const tool = (data.content || []).find(c => c.type === "tool_use" && c.name === "emit");
  if (tool) {
    out.parsed = (tool.input && tool.input.items) || tool.input;
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
    // stop_reason "max_tokens" means we paid and got nothing usable — worth
    // surfacing so it shows up as a real failure rather than empty results.
    if (!out.parsed && data.stop_reason === "max_tokens") {
      out.truncated = true;
    }
  }
  return out;
}

// Pull the pages the web_search tool actually fetched, for citation chips.
function anthropicSources(data) {
  const out = [];
  const seen = new Set();
  for (const block of data.content || []) {
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
const GEMINI_LADDER = (process.env.GEMINI_MODELS || "").trim()
  ? process.env.GEMINI_MODELS.split(",").map(s => s.trim()).filter(Boolean)
  : [
      "gemini-3.5-flash",
      "gemini-3.6-flash",
      "gemini-3-flash-preview",
      "gemini-3.1-flash-lite",
      "gemini-3.5-flash-lite",
      "gemini-flash-lite-latest",
      "gemini-2.5-flash"
    ];

const modelBlocked = Object.create(null); // model -> unblock timestamp
let groundingOff = false;

function msUntilQuotaReset() {
  const now = new Date();
  const reset = new Date(now);
  reset.setHours(24, 5, 0, 0);
  return Math.max(60000, reset - now);
}

function availableModels() {
  const now = Date.now();
  const free = GEMINI_LADDER.filter(m => !(modelBlocked[m] > now));
  return free.length ? free : GEMINI_LADDER.slice();
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

async function geminiOnce(model, payload) {
  const url =
    "https://generativelanguage.googleapis.com/v1beta/models/" +
    model +
    ":generateContent?key=" +
    encodeURIComponent(GEMINI_KEY);
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

async function callGemini(body) {
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
    for (const model of availableModels()) {
      const r = await geminiOnce(model, geminiPayload(body, model, searchOn, attempt * 3000));

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
          const r2 = await geminiOnce(model, geminiPayload(body, model, false, attempt * 3000));
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
  const chunks = (cand && cand.groundingMetadata && cand.groundingMetadata.groundingChunks) || [];
  const out = [];
  const seen = new Set();
  for (const c of chunks) {
    const uri = c.web && c.web.uri;
    if (!uri) continue;
    const title = (c.web && c.web.title) || "";
    const k = title || uri;
    if (seen.has(k)) continue;
    seen.add(k);
    out.push({ title, uri });
    if (out.length >= 8) break;
  }
  return out;
}

/* Check that each suggested organization link actually resolves. A model can
   produce a plausible-looking homepage for an organization that folded years
   ago; this is the cheapest way to catch that before a student emails them. */
async function verifyUrls(urls) {
  const list = (Array.isArray(urls) ? urls : []).filter(u => /^https:\/\//.test(u)).slice(0, 24);
  const results = {};
  await Promise.all(
    list.map(async u => {
      const ctrl = new AbortController();
      const t = setTimeout(() => ctrl.abort(), 6000);
      try {
        let res = await fetch(u, { method: "HEAD", redirect: "follow", signal: ctrl.signal });
        // Plenty of sites reject HEAD but answer GET fine.
        if (res.status === 405 || res.status === 501) {
          res = await fetch(u, { method: "GET", redirect: "follow", signal: ctrl.signal });
        }
        results[u] = { ok: res.status >= 200 && res.status < 400, status: res.status };
      } catch (e) {
        // A timeout or DNS failure is not proof the site is dead, so this is
        // reported as unknown rather than as a failure.
        results[u] = { ok: null, status: 0 };
      } finally {
        clearTimeout(t);
      }
    })
  );
  return results;
}

// Gemini uses SCREAMING type names; Anthropic wants standard JSON Schema.
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
