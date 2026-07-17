// RISE AI proxy — keeps API keys server-side (set them in Netlify env vars).
// Accepts Anthropic-shaped requests from the site; answers in the same shape.
// Priority: ANTHROPIC_API_KEY (full web search) → GEMINI_API_KEY (free tier).

export default async (req) => {
  if (req.method !== "POST") return new Response("Method not allowed", { status: 405 });
  let body;
  try { body = await req.json(); } catch { return Response.json({ error: "bad json" }, { status: 400 }); }

  const A = process.env.ANTHROPIC_API_KEY;
  const G = process.env.GEMINI_API_KEY;
  if (!A && !G) return Response.json({ error: "No AI key configured on the server" }, { status: 501 });

  try {
    if (A) {
      // Straight pass-through to Anthropic (supports the web_search tool)
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "Content-Type": "application/json", "x-api-key": A, "anthropic-version": "2023-06-01" },
        body: JSON.stringify(body),
      });
      const data = await r.json();
      return Response.json(data, { status: r.ok ? 200 : r.status });
    }

    // Gemini free tier — adapt request/response shapes
    const prompt = (body.messages || []).map(m => (typeof m.content === "string" ? m.content : "")).join("\n");
    const useSearch = !!(body.tools && body.tools.length);
    const payload = {
      contents: [{ parts: [{ text: prompt }] }],
      generationConfig: { maxOutputTokens: (body.max_tokens || 1200) > 2000 ? 3000 : 1400, temperature: 0.6 },
    };
    if (useSearch) payload.tools = [{ google_search: {} }];
    const r = await fetch(
      "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=" + G,
      { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify(payload) }
    );
    const data = await r.json();
    if (!r.ok) return Response.json({ error: data.error?.message || "gemini error" }, { status: r.status });
    const text = data.candidates?.[0]?.content?.parts?.map(p => p.text || "").join("") || "";
    return Response.json({ content: [{ type: "text", text }] });
  } catch (e) {
    return Response.json({ error: String(e && e.message || e) }, { status: 502 });
  }
};
