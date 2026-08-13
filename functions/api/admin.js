/* ══════════════════════════════════════════════════════════════════════
   RISE — admin actions  (/api/admin)

   The only place in the system that holds the Supabase service_role key.
   That key bypasses RLS and every column privilege, so this file is the one
   place where the guarantees built in 001–003 could be undone. It is written
   defensively on purpose.

   THE GATE, IN ORDER, ON EVERY REQUEST

     1. The caller's token is verified by asking Supabase — GET /auth/v1/user.
        Anything other than a clean 200 is a failure. This is delegated
        rather than verified locally because it also catches a user who has
        been deleted, banned, or had their session revoked, which a locally
        validated signature would happily accept until expiry.

     2. The caller's role is re-fetched from `profiles` using the service key.
        The token's claims are never trusted for authority: a revoked admin
        keeps a technically valid token until it expires.

     3. The action is checked against an allowlist. One route with one gate,
        rather than several routes each of which could forget it.

     4. The action runs, and an audit row is written naming who did what.

   THE KEY NEVER LEAVES

     It is read from env, sent only to Supabase, and never placed in a
     response body, an error message, or a log line. Upstream error text is
     deliberately NOT echoed the way the AI proxy echoes Anthropic's — a
     Supabase error can quote the request that caused it.
   ══════════════════════════════════════════════════════════════════════ */

const RATE_MAX = 60;
const RATE_WINDOW = 60 * 1000;
const RATE = new Map();

/* ── THE BAR ────────────────────────────────────────────────────────────
   The single definition of what "RISE Verified" requires. The admin UI
   renders this list by fetching it, so there is one place to edit when the
   bar is tightened — change it here and the checklist, the enforcement and
   the audit record all move together.

   `kind` decides how each item is satisfied:
     automated    a passing org_checks row
     attestation  the organization's own written statement
     human        the reviewer ticking it, recorded in the audit detail
     approval     implicit in verified_by; cannot be ticked, only performed
   ─────────────────────────────────────────────────────────────────────── */
const VERIFICATION_BAR = [
  {
    id: "automated_checks",
    kind: "automated",
    label: "Automated checks pass",
    detail: "Business-number format is valid and the contact email domain matches the website domain."
  },
  {
    id: "real_entity",
    kind: "human",
    label: "A real, registered entity",
    detail: "I have confirmed this organization exists and is currently registered."
  },
  {
    id: "works_with_youth",
    kind: "human",
    label: "Plausibly works with youth, and is not inappropriate",
    detail: "I have confirmed the work suits 14–18 year olds and nothing about it is inappropriate for minors."
  },
  {
    id: "screening_attestation",
    kind: "attestation",
    label: "Screening attested in writing",
    detail: "The organization has attested that anyone who would contact minors is appropriately screened per their local requirements."
  },
  {
    id: "named_approval",
    kind: "approval",
    label: "Approved by a named person",
    detail: "Recorded in verified_by. The database refuses 'verified' without it."
  }
];

const ACTIONS = new Set([
  "get-bar",
  "run-checks",
  "verify-org",
  "publish-opportunity",
  "unpublish-opportunity"
]);

export async function onRequestOptions({ env }) {
  return new Response(null, { status: 204, headers: cors(env) });
}

export async function onRequestPost(ctx) {
  const { request, env } = ctx;
  const H = cors(env);
  const reply = (code, obj) =>
    new Response(JSON.stringify(obj), {
      status: code,
      headers: { ...H, "Content-Type": "application/json" }
    });

  const ip = request.headers.get("cf-connecting-ip") || "anon";
  if (!allow(ip)) return reply(429, { error: "Too many requests." });

  const SERVICE_KEY = env.SUPABASE_SERVICE_ROLE_KEY || "";
  const SUPA_URL = env.SUPABASE_URL || "";
  if (!SERVICE_KEY || !SUPA_URL) {
    // Says what is missing without hinting at the value of anything.
    return reply(500, { error: "Admin actions are not configured on this server." });
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return reply(400, { error: "Invalid JSON" });
  }

  const action = String(body.action || "");
  if (!ACTIONS.has(action)) return reply(400, { error: "Unknown action." });

  // The bar is public: the org-facing UI explains it too, and there is
  // nothing sensitive in it. Served before the auth gate so an unauthenticated
  // page can render "here is what verification requires".
  if (action === "get-bar") return reply(200, { bar: VERIFICATION_BAR });

  /* ── 1. Verify the token by asking Supabase ── */
  const authz = request.headers.get("authorization") || "";
  const token = authz.startsWith("Bearer ") ? authz.slice(7).trim() : "";
  if (!token) return reply(401, { error: "Sign in required." });

  let caller;
  try {
    const r = await fetch(SUPA_URL + "/auth/v1/user", {
      headers: { apikey: SERVICE_KEY, Authorization: "Bearer " + token }
    });
    // Anything but a clean 200 is a failure — expired, revoked, forged,
    // deleted user, or Supabase itself being unhappy.
    if (r.status !== 200) return reply(401, { error: "Sign in required." });
    caller = await r.json();
    if (!caller || !caller.id) return reply(401, { error: "Sign in required." });
  } catch (e) {
    return reply(503, { error: "Couldn't verify your session. Try again." });
  }

  /* ── 2. Re-fetch the role. The token's claims are not authority. ── */
  const sb = supa(SUPA_URL, SERVICE_KEY);
  let role = null;
  try {
    const rows = await sb.get(`/rest/v1/profiles?id=eq.${caller.id}&select=role`);
    role = rows && rows[0] ? rows[0].role : null;
  } catch (e) {
    return reply(503, { error: "Couldn't check your permissions. Try again." });
  }
  if (role !== "admin") {
    // Same shape for "not an admin" and "not signed in" so this endpoint is
    // not an oracle for who holds a role.
    return reply(403, { error: "Not permitted." });
  }

  /* ── 3 & 4. Act, then record. ── */
  try {
    switch (action) {
      case "run-checks":
        return reply(200, await runChecks(sb, body.orgId));
      case "verify-org":
        return reply(200, await verifyOrg(sb, caller, body));
      case "publish-opportunity":
        return reply(200, await setPublished(sb, caller, body.opportunityId, true));
      case "unpublish-opportunity":
        return reply(200, await setPublished(sb, caller, body.opportunityId, false));
      default:
        return reply(400, { error: "Unknown action." });
    }
  } catch (e) {
    // Deliberately does not echo the upstream body. A Supabase error can quote
    // the request that produced it, and this request carries the service key
    // in its headers.
    const msg = e && e.riseSafe ? e.message : "That action didn't complete.";
    return reply(e && e.status === 400 ? 400 : 500, { error: msg });
  }
}

/* ── Advisory checks ────────────────────────────────────────────────────
   Assists for the reviewer. Neither can approve anything: results land in
   org_checks, which has no path to verification_status. */
async function runChecks(sb, orgId) {
  if (!orgId) throw safeErr("Which organization?", 400);
  const rows = await sb.get(`/rest/v1/organizations?id=eq.${orgId}&select=*`);
  const org = rows && rows[0];
  if (!org) throw safeErr("Organization not found.", 400);

  const results = [];

  // CRA business number: 9 digits, RP/RR/RC/RT program identifier, 4 digits.
  // This proves SHAPE ONLY. It does not prove the number is registered, or
  // registered to this organization — a human still confirms that.
  const bn = (org.registration_number || "").replace(/\s/g, "").toUpperCase();
  const bnOk = /^\d{9}(RR|RC|RP|RT)\d{4}$/.test(bn);
  results.push({
    org_id: orgId,
    check_key: "business_number_format",
    passed: bnOk,
    detail: bn
      ? bnOk
        ? "Format is valid. This proves shape only — confirm the number is really registered to this organization."
        : "Not a valid CRA business number format (expected 9 digits, then RR/RC/RP/RT, then 4 digits)."
      : "No registration number supplied."
  });

  // Does the contact email live on the organization's own domain? A weak but
  // useful signal: a coordinator at a gmail address is not disqualifying, it
  // is a reason to look harder.
  const emailDomain = ((org.contact_email || "").split("@")[1] || "").toLowerCase();
  let siteDomain = "";
  try {
    siteDomain = new URL(org.website_url).hostname.toLowerCase().replace(/^www\./, "");
  } catch (e) {}
  const domainOk = !!emailDomain && !!siteDomain &&
    (emailDomain === siteDomain || emailDomain.endsWith("." + siteDomain) || siteDomain.endsWith("." + emailDomain));
  results.push({
    org_id: orgId,
    check_key: "email_domain_match",
    passed: domainOk,
    detail: !emailDomain || !siteDomain
      ? "Missing a website or a contact email, so this could not be checked."
      : domainOk
        ? `Contact email is on ${siteDomain}.`
        : `Contact email is on ${emailDomain}, the website is ${siteDomain}. Not disqualifying — a reason to verify by another route.`
  });

  await sb.post("/rest/v1/org_checks", results);
  return { checks: results };
}

/* ── Verification ───────────────────────────────────────────────────────
   Enforces the bar server-side rather than trusting the UI to have shown it.
   The database refuses 'verified' without verified_by regardless; this makes
   the rest of the bar load-bearing too. */
async function verifyOrg(sb, caller, body) {
  const orgId = body.orgId;
  const decision = String(body.decision || "");
  if (!orgId) throw safeErr("Which organization?", 400);
  if (!["unverified", "in_review", "verified", "suspended"].includes(decision)) {
    throw safeErr("Unknown decision.", 400);
  }

  const patch = {
    verification_status: decision,
    review_notes: typeof body.notes === "string" ? body.notes.slice(0, 2000) : null
  };

  if (decision === "verified") {
    const rows = await sb.get(`/rest/v1/organizations?id=eq.${orgId}&select=*`);
    const org = rows && rows[0];
    if (!org) throw safeErr("Organization not found.", 400);

    const confirmations = body.confirmations || {};
    const missing = [];

    for (const item of VERIFICATION_BAR) {
      if (item.kind === "automated") {
        const checks = await sb.get(
          `/rest/v1/org_checks?org_id=eq.${orgId}&select=check_key,passed,checked_at&order=checked_at.desc`
        );
        const latest = {};
        for (const c of checks || []) if (!(c.check_key in latest)) latest[c.check_key] = c.passed;
        const keys = ["business_number_format", "email_domain_match"];
        if (!keys.every(k => latest[k] === true)) missing.push(item.label);
      } else if (item.kind === "attestation") {
        if (!org.screening_attested) missing.push(item.label);
      } else if (item.kind === "human") {
        if (confirmations[item.id] !== true) missing.push(item.label);
      }
      // 'approval' is satisfied by verified_by below, and by the DB trigger.
    }

    if (missing.length) {
      throw safeErr("Not yet met: " + missing.join("; "), 400);
    }
    // The named human. The trigger in 003 refuses 'verified' without this.
    patch.verified_by = caller.id;
    patch.verified_at = new Date().toISOString();
  }

  await sb.patch(`/rest/v1/organizations?id=eq.${orgId}`, patch);
  await audit(sb, caller, "verify-org", "organization", orgId, {
    decision,
    confirmations: body.confirmations || null,
    notes: patch.review_notes
  });
  return { ok: true, decision };
}

/* ── Publishing ─────────────────────────────────────────────────────────
   The only way an opportunity becomes visible to a volunteer, and it refuses
   unless the owning organization is verified — so publishing can never
   outrun verification. */
async function setPublished(sb, caller, oppId, publish) {
  if (!oppId) throw safeErr("Which opportunity?", 400);
  const rows = await sb.get(`/rest/v1/opportunities?id=eq.${oppId}&select=*,organizations(verification_status,name)`);
  const opp = rows && rows[0];
  if (!opp) throw safeErr("Opportunity not found.", 400);

  if (publish) {
    const orgStatus = opp.organizations && opp.organizations.verification_status;
    if (orgStatus !== "verified") {
      throw safeErr("That organization is not verified, so its postings cannot be published.", 400);
    }
    await sb.patch(`/rest/v1/opportunities?id=eq.${oppId}`, {
      status: "published",
      published_at: new Date().toISOString(),
      published_by: caller.id
    });
  } else {
    await sb.patch(`/rest/v1/opportunities?id=eq.${oppId}`, {
      status: "submitted",
      published_at: null,
      published_by: null
    });
  }

  await audit(sb, caller, publish ? "publish-opportunity" : "unpublish-opportunity",
    "opportunity", oppId, { title: opp.title });
  return { ok: true, published: publish };
}

async function audit(sb, caller, action, targetType, targetId, detail) {
  try {
    await sb.post("/rest/v1/admin_audit", [{
      actor_id: caller.id,
      actor_email: caller.email || null,
      action,
      target_type: targetType,
      target_id: targetId,
      detail: detail || null
    }]);
  } catch (e) {
    // An action that succeeded but went unlogged is worse than one that
    // failed cleanly, so this is surfaced rather than swallowed.
    throw safeErr("The action ran but could not be logged. Tell an engineer.", 500);
  }
}

/* ── Supabase helper ────────────────────────────────────────────────────
   The key is set here and nowhere else, and no response from these calls is
   ever returned verbatim to the caller. */
function supa(url, key) {
  const headers = {
    apikey: key,
    Authorization: "Bearer " + key,
    "Content-Type": "application/json"
  };
  const check = async r => {
    if (!r.ok) throw safeErr("Database rejected that.", r.status === 400 ? 400 : 500);
    return r;
  };
  return {
    async get(path) {
      const r = await check(await fetch(url + path, { headers }));
      return await r.json();
    },
    async post(path, rows) {
      await check(await fetch(url + path, {
        method: "POST",
        headers: { ...headers, Prefer: "return=minimal" },
        body: JSON.stringify(rows)
      }));
    },
    async patch(path, patchBody) {
      await check(await fetch(url + path, {
        method: "PATCH",
        headers: { ...headers, Prefer: "return=minimal" },
        body: JSON.stringify(patchBody)
      }));
    }
  };
}

/* Marks a message as safe to show a caller. Anything without this flag is
   replaced with a generic string, so an upstream body can never leak. */
function safeErr(message, status) {
  const e = new Error(message);
  e.riseSafe = true;
  e.status = status || 500;
  return e;
}

function cors(env) {
  return {
    "Access-Control-Allow-Origin": (env && env.ALLOW_ORIGIN) || "*",
    "Access-Control-Allow-Headers": "Content-Type, Authorization",
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
