# Security notes

Two kinds of thing live here. The first is a list of linter findings that are
**the design working correctly**, written down so nobody looks at a red badge
in six months and helpfully "fixes" it. The second is what is actually
protecting the money and the data, and where the honest gaps still are.

---

## Advisor findings that are deliberate. Do not "fix" these.

### Security Definer View on `public.public_opportunities`

**Supabase reports this as an Error. Leave it alone.**

The design is that volunteers have **no read access to the `opportunities`
table at all**. The only thing they can read is this view, whose WHERE clause
hard-codes *published AND the owning organization is verified*.

For a view to read a table the caller cannot read, it has to run with the
definer's permissions. That is the entire mechanism. It makes the guarantee
structural rather than a filter the frontend could forget.

The linter's suggested remedy, switching the view to `security_invoker`, would
require granting volunteers direct read access to `opportunities` plus a new
RLS policy to re-impose the filter. That reintroduces exactly the risk the
design removes, and swaps a guarantee the database enforces for one a policy
has to remember. **Do not do it.**

Worth re-checking whenever the view changes: which columns it exposes, and that
nothing about an unverified organization leaks through it.

### Four "Signed-In Users Can Execute SECURITY DEFINER Function" warnings

On `submit_opportunity`, `withdraw_opportunity`, `submit_application` and
`withdraw_application`.

These are **supposed** to be callable. Migration 002 describes them as the only
client-reachable way to change status, with ownership checked inside each
function precisely because SECURITY DEFINER bypasses RLS. The linter cannot
tell the difference between a function exposed by accident and one exposed on
purpose with its own checks. These are on purpose.

The fifth function in that group, `handle_new_user`, was **not** deliberate.
It is a trigger with no legitimate RPC surface, and migration 005 revokes
EXECUTE from `anon` and `authenticated`. If it ever reappears in that list,
something has re-granted it.

---

## What actually protects the Anthropic budget

In order of how much they are load-bearing:

1. **The spend limit on the Anthropic account.** The only control outside the
   trust boundary of our own code. Everything below depends on this repository
   being correct; that one does not. It should exist regardless of anything
   here.
2. **`DAILY_BUDGET_USD`**, counted in Cloudflare KV so every isolate sees one
   running total. KV is eventually consistent, roughly a minute, so the cap can
   be overshot slightly when several isolates spend at once before seeing each
   other's writes. Bounded by a minute of traffic.
3. **The per-IP rate limit**, counted by Cloudflare's own rate limiter at the
   edge rather than in isolate memory.
4. **`ALLOW_ORIGIN`.** Worth setting and **not** what is protecting anything.
   CORS is enforced by browsers, so it stops another website spending the
   budget through its visitors. A script ignores CORS entirely.

Both of the first two guards fall back to per-isolate counters when their
binding is missing, so the site keeps working. That fallback is silent, which
is what makes it dangerous: a spend cap that has quietly reverted looks
identical from outside. `POST /api/ai-search {"action":"ping"}` reports which
are actually attached:

```json
{ "guards": { "sharedSpend": true, "edgeRateLimit": true } }
```

**If either reads `false`, the budget is per-isolate again.**

## Why these were per-isolate to begin with

Both counters used to be module-scope variables. On Workers that is one copy
per isolate, and Cloudflare runs many isolates across many data centres,
starting fresh ones freely. Each began at zero, so `DAILY_BUDGET_USD=5` meant
five dollars *per isolate per day*, and 40 requests a minute meant 40 *per
isolate*. Traffic arriving from several countries at once got a fresh
allowance in each one.

## The edge is part of the attack surface

On 19 September 2026 a second Worker, `worker-billowing-tooth-7c4f`, was found
routed at `*rise4impact.org/*` in front of the real one. It pulled a base64
payload from a BNB Smart Chain contract and appended it to every HTML response,
showing visitors a fake reCAPTCHA that told them to paste a command into their
terminal.

**The repository was never touched.** The local `index.html` was clean while
the edge served 2,371 extra bytes. Nothing in a code review would have found
it. The likely way in was a Cloudflare API token with 20+ permissions across
all zones.

What came out of that:

- The Content-Security-Policy in `src/index.js` allows scripts only from this
  origin plus one inline block named by its sha256. The injected script carried
  no hash and would have been refused by the browser whatever appended it.
- `connect-src` is restricted to this origin and Supabase, so a script that
  somehow ran still could not reach a blockchain RPC to fetch its payload.
- API tokens should be scoped to **one account, one zone, Workers only**.
  Nothing in this repository needs a Cloudflare API token; deploys use
  `wrangler login`, which is OAuth.

Checking the zone for Workers and routes nobody added is worth doing
occasionally. It is not visible from the code.

---

## Known gaps, written down rather than quietly carried

- **No automatic backups.** The Supabase Free plan does not include them.
  Until that changes, the only copies are manual `supabase db dump` exports.
  An untested backup is a guess, so one should actually be restored into a
  scratch project at least once.
- **The Free plan pauses after seven days of low activity.** A daily cron in
  `wrangler.toml` keeps the database awake, which is a stopgap rather than an
  answer.
- **Hours are self-reported.** The app does not claim otherwise, and should
  not start claiming otherwise without a verification path.
- **Test coverage is thin where it matters most.** `submit_application`,
  `submit_opportunity` and `enforce_named_verifier` are the three places where
  a mistake has a safeguarding consequence rather than a cosmetic one, and
  none of them has a test.
