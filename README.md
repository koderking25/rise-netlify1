# RISE

Born in Canada. Reaching the world.

`index.html` is the whole app — one self-contained file, same as before. The two
new folders are optional server pieces you deploy alongside it.

```
index.html                      the app
netlify/functions/ai-search.js  AI proxy — Netlify
functions/api/ai-search.js      AI proxy — Cloudflare Pages
```

---

## Setup — Cloudflare Pages

**Build configuration** (Pages → Settings → Builds & deployments):

| Setting | Value |
|---|---|
| Framework preset | None |
| Build command | *(leave empty)* |
| Build output directory | `public` |

**Environment variable** (Pages → Settings → Environment variables → Production):

- `ANTHROPIC_API_KEY` = your `sk-ant-api03-...` key — click **Encrypt**

Redeploy after adding it. `functions/api/ai-search.js` maps automatically to
`/api/ai-search`, which is the path the app calls first.

Check it worked:

```bash
curl -s -X POST https://YOUR-SITE.pages.dev/api/ai-search \
  -H 'content-type: application/json' -d '{"action":"ping"}'
```

You want `{"ok":true,"provider":"anthropic","search":true}`. If `provider` is
`gemini` or `search` is `false`, the key didn't take — that is the single cause
of "these are starting points, not live matches".

`netlify.toml` and `netlify/functions/` are unused on Cloudflare. Harmless, and
they keep Netlify available as a second option.

## Setup: your Sonnet 5 key

The app now runs on **Claude Sonnet 5 with real web search**. Your key is in
`.env` (gitignored, chmod 600) and **not** in `index.html`.

```bash
netlify env:set ANTHROPIC_API_KEY "sk-ant-..."
netlify deploy --prod
```

Cloudflare: add it as a **secret** under Pages → Settings → Environment
variables. Locally, `netlify dev` or the app falls back to recall-only.

### Why the key is not in index.html

You asked for it in the site. I need to be straight about why I didn't do that,
because this key is different from the Gemini one:

- A Gemini key can be locked to your domain in Google Cloud, so a thief gets a
  useless string. **Anthropic has no such restriction** — a key is a key.
- It bills **real money per token** with no free tier to absorb abuse.
- `index.html` is served to every visitor. View Source is all it takes.

A Gemini key in the page costs you a quota reset. This one costs you a bill with
no ceiling. So it lives server-side, where "works on the website" and "can't be
stolen" are both true at once. The proxy was already built and now defaults to
Anthropic.

If you want it client-side anyway, that's your call — say so and I'll wire it —
but set a spend limit in the Anthropic console first, and treat the key as
public from that moment.

---

## What you get, and what it costs

Measured on real searches, not estimated:

| | |
|---|---|
| Discovery (3 live web searches) | **$0.150** · ~30s |
| Judge (scores + evidence, no search) | **$0.021** · ~9s |
| **Total per search** | **~$0.17** |

A search always costs — it always goes out to the web. Judging and email
drafting are cached, since the same input genuinely should give the same answer.

Real output for a Toronto student who plays jazz piano and speaks Arabic:

```
Volunteer Pianist, Arts at the Grace Music Program
  Toronto Grace Health Centre
  torontograce.org/work-volunteer/volunteering-at-tghc/arts-at-the-grace/

Music Program Volunteer, Long-Term Care Home
  City of Toronto Seniors Services   ssltcstudents@toronto.ca

Cultural Ambassador (Arabic), Welcome Group Program
  Together Project
```

Real postings, real page URLs, a real intake address — not "contact your local
YMCA". Every card links the exact page it came from.

### Where the money goes, and the dials

Web-search results are injected into context, so **`max_uses` is the spend dial**,
not `max_tokens`. Four searches ≈ $0.19; three ≈ $0.15; two ≈ $0.09. Set
`MAX_SEARCHES` to change the ceiling.

Efficiency changes made:

- **Four discovery engines collapsed to one.** The old design ran four every
  search — four web-search bills for heavily overlapping results, the same three
  organizations found by four routes. Rigour comes from the judge, not repetition.
- **Per-card AI calls removed entirely.** One request per result, per search, to
  write a blurb the judge then overwrote. Pure waste.
- **Prompt caching** on system blocks: repeat calls read them at a tenth of price.
- **`DAILY_BUDGET_USD`** (default **$5**) hard-stops spend. This proxy holds a
  paid key on a URL anyone can find; rate limiting caps requests, this caps cost.
  Set to 0 to disable.

---

## Every search is a real search

Results were repeating because **four separate layers were replaying stored
answers**, and I had made the worst of them worse by extending the client cache
to two hours to save money. Pressing search was returning a recording.

All four now honour a `fresh` flag that discovery calls always set:

| Layer | Before | Now |
|---|---|---|
| Client response cache | 2h replay | bypassed for searches |
| `rise_cache::` result prefill | painted last run's matches instantly | **removed** |
| Netlify proxy cache | 30 min | bypassed for searches |
| Cloudflare Cache API | 30 min | bypassed for searches |

Caching still applies to judging and email drafting, where the same input really
should give the same answer and re-billing would be waste.

### And every search looks somewhere different

Even with caching off, a model asked the same question reaches for the same
obvious national charities. So each run now rotates through four opening search
angles — exact-skill-as-role-title, local listing boards, institution types that
structurally need the skill, and population-first — and the prompt is dated,
asking for postings open *this week* with real deadlines and intake sessions.

Verified: three identical searches, back to back, same student.

```
run 1  EchoHorizon · Circle of Care · City of Toronto Long-Term Care
run 2  Toronto Grace Health Centre · Together Project
run 3  Toronto Grace Health Centre

6 unique organizations · 0 appearing in all three · 3 live API calls, 0 cache hits
```

There is also a **Search again** button on the results header now. Retake throws
your answers away; this keeps them and just looks again.

---

## Three bugs found by testing against the live API

**1. `temperature` is deprecated on Sonnet 5.** Every request the app sent
included it, so every request 400'd — and the proxy quietly answered from Gemini
instead. Results looked mediocre rather than broken. Fixed, and the silent
fallback is fixed too: it now only covers transient upstream failures (429/5xx).
A 4xx is our bug and must stay visible.

**2. Extended thinking silently ate the answer.** With thinking on, reasoning
consumed the output budget and the response was truncated *before* the model
reached its final tool call — full price, zero results. Measured $0.32 for
nothing. Disabled everywhere.

**3. The proxy was killed before it could answer.** Unproven proxies got a
4-second leash, but a grounded web search legitimately takes 25-40s. It was
aborted every time, marked dead, and the app dropped to no-search mode. Proxy
discovery is now a separate free `ping`, and real requests get their full time.

Also: `sourceUrl` was in the prompt but not the schema, so the model physically
could not return one however hard it was asked.

---

## Read this first: why the AI results kept coming back the same

The build had a Gemini API key hard-coded in the page source. That key is on
Google's **free tier, which allows 20 requests per day per project**. Every
person who opened the site drew from that same 20.

Each search fired four discovery engines plus a follow-up call per result card,
so a *single* search could exhaust the day's quota. After that every request
returned HTTP 429, the old code caught the error and silently served the
built-in offline library instead — with no indication anything had failed.

That is the whole explanation for "the results are the same": the live AI was
almost never running. The offline library has a fixed set of entries, so it
returns the same organizations every time, forever.

Two things now stop this recurring: the model ladder above (one empty bucket no
longer means no AI), and the fact that a failure is visible instead of silent.

Confirmed against the live API:

```
"Quota exceeded ... generate_content_free_tier_requests"
"quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier"
"quotaValue": "20"
```

### Fixing it

Pick one:

**Deploy the proxy (recommended).** Keys live in environment variables, never in
the page. See "Deploying the proxy" below.

**Or let each student bring their own key.** When live search fails, the results
page now says so and offers a one-minute path to a free personal key
(aistudio.google.com/apikey). Stored in their browser only, and also reachable
any time from **Settings → Your own AI key** — not just at the moment a search
breaks, which is the worst possible time to discover a setting exists. A key a
student generates themselves sits in their own project, so it comes with its own
quota rather than sharing yours.

Either way: **rotate the key that is currently in `index.html`.** It has been
published, so treat it as compromised — anyone can spend its quota. Once the
proxy is deployed, set `BUILT_IN_GEMINI_KEY` back to `""`.

---

## What changed

### Matching

The old pipeline generated candidates and trusted them. Nothing was ever asked
to be skeptical, and the ranking was keyword overlap.

It is now four stages:

1. **Discover** — grounded web search plus recall engines, each with a different
   strategy so they surface different organizations.
2. **Normalize** — validate, dedupe by organization *and* by domain.
3. **Judge** — one model pass scores every surviving candidate together (not one
   at a time, which is where "everything is a 9/10" comes from) on four named
   dimensions: does the role *need* their skill (0-40), who it serves (0-20),
   whether the logistics work (0-20), and how confident it is the role is real
   (0-20). It must cite the specific duty that needs their capability, and it
   can reject a candidate outright.
4. **Blend** — 70% judge, 30% deterministic keyword score. A confident model
   can't fully override the offline scorer, and vice versa.

The student sees all of it: a match score, an expandable breakdown of the four
dimensions, the concern the judge raised, and the web sources the search read.

### Specificity gate

Results that read as ideas rather than matches are dropped before display:
category titles ("Volunteer", "Music Volunteer"), duties under 60 characters,
filler phrases ("help out", "various tasks", "as needed"), and a stated reason
that never references what the student actually said about themselves.

Curated library entries are exempt — they're deliberately broad, and the card
now labels them **Starting point** so they don't pass as tailored matches.

### Volunteering Interest Card

Per the notes, the questionnaire now covers the full five dimensions: **when,
where, who, how, and why** to serve. Two were missing and are new:

- **How you want to show up** — from home / in your community / somewhere you're
  travelling.
- **Why you're doing this** — build a skill, meet people, a cause you care
  about, career exposure, give back, build a record.

"Why" matters more than it looks. Two students with identical talents and
identical availability belong in different rooms, and this is the field that
tells them apart. It feeds both the search prompts and the judge's rubric: a
role that fits the skill but fights the motivation is capped, not rewarded.

One thing this shook loose: "Preferred setting" used to offer *Virtual /
remote* alongside *Group* and *1-on-1*, which meant a student could answer
"In my community" and "Virtual / remote" at once. Setting now asks only about
the shape of the work; whether the room is physical at all is the new
show-up question's job, and `virtualOnly` derives from that.

### Proficiency and languages

The prompts had always instructed the model not to send an advanced player to a
beginner's role — but nothing ever collected a level, so that instruction had no
data behind it. A checkbox saying "I play piano" can't tell a first-year student
apart from someone who's competed for eight years.

Selecting a skill now reveals a level (still learning / solid / advanced /
certified). It's four coarse buckets on purpose — a teenager answers it honestly
in one tap, and finer resolution wouldn't survive self-report. Level mismatch now
cuts the capability score **in both directions**: a role that needs more than
they claim is a risk to them and to the organization, and one that needs far less
wastes them. "Still learning" additionally requires that the role have
supervision built in, and says where it comes from.

**Languages** are structured now (36 options × 3 levels) rather than arriving by
accident when a student happened to type them into the free-text box. They're one
of the sharpest signals there is — a settlement program needs the specific
language, not "someone good with people" — so when a student lists a non-English
language, the search is told to actively look for at least one role where that
language is *the reason* they'd be chosen.

The email drafter also won't upgrade their level: if they said they're still
learning, the email says so. That honesty is what gets a 15-year-old taken
seriously, and overselling gets found out in week one.

### A global library, not just a global search

The offline library was entirely Canadian, so the "reaching the world" half of
the promise depended completely on live search being up — which, per the quota
problem above, it often wasn't.

There's now a second tier of real organizations that accept contributions from
anywhere: Wikipedia, Translators without Borders, Zooniverse, iNaturalist,
Humanitarian OpenStreetMap, LibriVox, Be My Eyes, UN Online Volunteering, and
others. Choosing a region outside Canada or "from home" reaches for this shelf
instead of the local one, so a student in Regina gets remote roles rather than
"your local YMCA branch".

Remote-first on purpose. Placement programs that fly minors abroad are a
different thing with real safeguarding questions attached, and they don't belong
in a list a 14-year-old browses alone.

### Global

- Hero eyebrow is now **Born in Canada. Reaching the world.**
- Locations extend past Canada: nine world regions plus a remote option that is
  no longer "anywhere in Canada".
- Prompts are region-aware. For a student in Canada serving abroad, the search
  is told to favour remote-first roles, chapters of international organizations,
  or roles that fit a visit — not roles that assume they live there.
- The hours tracker is framed as a record, not the purpose.

### Engine internals

- **Structured output** — Gemini `responseSchema` and Anthropic forced tool
  calls replace "reply with JSON and nothing else" plus regex scraping. The
  tolerant parser is still there for grounded searches, which can't use schemas.
- **Rate limiting that matches reality** — a token bucket paced to the free
  tier's 5 requests/minute, and retries that honour the exact delay Google
  returns instead of guessing.
- **Request budget** — on the constrained free path the pipeline runs two
  engines instead of four and skips per-card follow-up calls, spending what's
  left on the judge, which is worth more.
- **Cache, dedupe, concurrency pool** — identical questions asked in the same
  moment share one network call; answers stay warm for 30 minutes.
- Model IDs updated (`claude-sonnet-4-6` no longer exists).

### Volunteering Activity Cards

The hours log recorded a project name, a number, and a supervisor email. That
answers "how long were you there" — which is the least interesting thing about a
volunteer session, and useless to anyone writing you a reference.

Logging a session now optionally records the **organization, where, who you
served, and why it mattered** — the same five dimensions as the interest card,
pointed backwards. Every field is optional; a student halfway through logging a
shift should never be blocked by a form.

**On verification, deliberately:** nothing in this app can confirm that a
session happened. It has no server that owns a mailbox and no relationship with
the organization. So it doesn't pretend to:

- *Ask them to confirm* opens a prefilled email from the student to their
  supervisor and records that they asked. The entry moves to **Awaiting reply**.
- *They replied — mark confirmed* is the student's own attestation, and is
  labelled as exactly that.
- Nothing flips to confirmed on its own.

The exported PDF carries a per-entry confirmation column and a plain-language
note: RISE does not contact organizations and does not verify hours, "Confirmed"
means the student states their supervisor replied, and here is how many of the
total hours that covers — with a nudge to contact the supervisors listed. The
previous footer implied a verification process that does not exist.

This matters more than it might look. A volunteer record is a document students
hand to schools and employers, and one that quietly looks official while being
entirely self-reported is a problem for the student holding it as much as for
whoever reads it.

### Outreach drafting

Every card has **Draft my email**, which writes a first enquiry email in the
student's voice from their own profile — editable, with Gmail / mail app / copy.
It won't invent grades, awards, hours, or references, and when there's no
verified contact address it says so rather than guessing one.

This also wires up `splitPitch` and `gmailComposeUrl`, which existed in the old
file but were never called by anything.

---

## Deploying the proxy

Both files do the same thing; deploy the one matching your host. Keys stay
server-side, responses are cached, and there's per-IP rate limiting.

**Netlify**

```bash
netlify env:set GEMINI_API_KEY "AIza..."
netlify env:set ANTHROPIC_API_KEY "sk-ant-..."   # optional, better results
netlify deploy --prod
```

**Cloudflare Pages** — add `GEMINI_API_KEY` (and optionally
`ANTHROPIC_API_KEY`) as **secrets** under Settings → Environment variables.

Then set both key constants in `index.html` to `""`. The client tries
`/api/ai-search`, then `/.netlify/functions/ai-search`, and remembers which one
answered.

With `ANTHROPIC_API_KEY` set you get real `web_search` tool use and proper
citations, which is a visible quality jump over Google Search grounding.

The proxy also serves link verification: it fetches each suggested URL
server-side and reports whether it resolves, which is where the **Link verified**
badge comes from. A browser can't do this — cross-origin response codes aren't
readable. Without the proxy, links are shown as unchecked rather than verified.

---

## Running locally

```bash
python3 -m http.server 8791
```

Open <http://localhost:8791>. Note that the proxy paths don't exist under a
plain static server, so it falls through to the in-page key — use `netlify dev`
or `wrangler pages dev` to exercise the proxy.
