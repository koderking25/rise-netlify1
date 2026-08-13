// Exercises the real /api/admin handler against a stubbed Supabase, to prove
// the gate refuses everyone it should and that the bar is enforced server-side.
import { onRequestPost } from '/Users/neilmekouar/rise claude code/functions/api/admin.js';

const SUPA = 'https://stub.supabase.co';
const SERVICE = 'service-role-key-SHOULD-NEVER-APPEAR';

// --- stub state -------------------------------------------------------
let db;
function reset() {
  db = {
    users: { 'tok-admin': { id: 'u-admin', email: 'admin@rise.org' },
             'tok-vol':   { id: 'u-vol',   email: 'kid@school.ca' },
             'tok-org':   { id: 'u-org',   email: 'org@charity.ca' } },
    roles: { 'u-admin': 'admin', 'u-vol': 'volunteer', 'u-org': 'organization' },
    orgs: [{ id: 'org-1', name: 'Test Charity', registration_number: '123456789RR0001',
             contact_email: 'a@charity.ca', website_url: 'https://charity.ca',
             verification_status: 'unverified', screening_attested: false }],
    checks: [], opps: [{ id: 'opp-1', title: 'Tutor', org_id: 'org-1',
                         organizations: { verification_status: 'unverified', name: 'Test Charity' } }],
    audit: [], patches: []
  };
}

globalThis.fetch = async (url, opts = {}) => {
  const u = String(url); const m = opts.method || 'GET';
  const J = (o, s = 200) => new Response(JSON.stringify(o), { status: s, headers: { 'content-type': 'application/json' } });

  if (u.includes('/auth/v1/user')) {
    const tok = (opts.headers?.Authorization || '').replace('Bearer ', '');
    const user = db.users[tok];
    return user ? J(user) : J({ error: 'bad' }, 401);
  }
  if (u.includes('/rest/v1/profiles')) {
    const id = u.match(/id=eq\.([^&]+)/)[1];
    return J(db.roles[id] ? [{ role: db.roles[id] }] : []);
  }
  if (u.includes('/rest/v1/organizations')) {
    if (m === 'PATCH') { db.patches.push(JSON.parse(opts.body)); return new Response(null, { status: 204 }); }
    return J(db.orgs);
  }
  if (u.includes('/rest/v1/org_checks')) {
    if (m === 'POST') { db.checks.push(...JSON.parse(opts.body)); return J({}, 201); }
    return J([...db.checks].reverse());
  }
  if (u.includes('/rest/v1/opportunities')) {
    if (m === 'PATCH') { db.patches.push(JSON.parse(opts.body)); return new Response(null, { status: 204 }); }
    return J(db.opps);
  }
  if (u.includes('/rest/v1/admin_audit')) {
    if (m === 'POST') { db.audit.push(...JSON.parse(opts.body)); return J({}, 201); }
    return J(db.audit);
  }
  return J({}, 404);
};

const env = { SUPABASE_URL: SUPA, SUPABASE_SERVICE_ROLE_KEY: SERVICE, ALLOW_ORIGIN: '*' };
const call = (body, token, ip = '1.1.1.1') => onRequestPost({
  request: new Request('https://x/api/admin', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'cf-connecting-ip': ip,
      ...(token ? { authorization: 'Bearer ' + token } : {})
    },
    body: JSON.stringify(body)
  }),
  env, waitUntil: p => p
});

const out = [];
const check = (name, pass, extra = '') => out.push(`${pass ? 'PASS' : 'FAIL'}  ${name}${extra ? '  — ' + extra : ''}`);

// --- 1. access control ------------------------------------------------
reset();
let r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified' }, null, '2.0.0.1');
check('no token is refused', r.status === 401, 'got ' + r.status);

r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified' }, 'tok-forged', '2.0.0.2');
check('forged/unknown token is refused', r.status === 401, 'got ' + r.status);

r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified' }, 'tok-vol', '2.0.0.3');
let b = await r.json();
check('VOLUNTEER token hitting /api/admin is refused', r.status === 403, 'got ' + r.status + ' ' + JSON.stringify(b));

r = await call({ action: 'publish-opportunity', opportunityId: 'opp-1' }, 'tok-vol', '2.0.0.4');
check('volunteer cannot publish', r.status === 403, 'got ' + r.status);

r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified' }, 'tok-org', '2.0.0.5');
check('ORGANIZATION token is refused', r.status === 403, 'got ' + r.status);

r = await call({ action: 'drop-tables', orgId: 'org-1' }, 'tok-admin', '2.0.0.6');
check('unknown action rejected by allowlist', r.status === 400, 'got ' + r.status);

// --- 2. the bar is enforced server-side --------------------------------
reset();
r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified',
                 confirmations: { real_entity: true, works_with_youth: true } }, 'tok-admin', '3.0.0.1');
b = await r.json();
check('admin cannot verify with checks not run', r.status === 400 && /Automated checks/.test(b.error || ''), b.error);

await call({ action: 'run-checks', orgId: 'org-1' }, 'tok-admin', '3.0.0.2');
r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified',
                 confirmations: { real_entity: true, works_with_youth: true } }, 'tok-admin', '3.0.0.3');
b = await r.json();
check('still blocked without the org attestation', r.status === 400 && /attested/i.test(b.error || ''), b.error);

db.orgs[0].screening_attested = true;
r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified',
                 confirmations: { real_entity: true } }, 'tok-admin', '3.0.0.4');
b = await r.json();
check('still blocked with a human box unticked', r.status === 400 && /youth/i.test(b.error || ''), b.error);

r = await call({ action: 'verify-org', orgId: 'org-1', decision: 'verified',
                 confirmations: { real_entity: true, works_with_youth: true } }, 'tok-admin', '3.0.0.5');
check('verify succeeds only when the whole bar is met', r.status === 200, 'got ' + r.status);
const vpatch = db.patches.find(p => p.verification_status === 'verified');
check('verified_by names the human', !!vpatch && vpatch.verified_by === 'u-admin');
check('action is audited', db.audit.length === 1 && db.audit[0].actor_id === 'u-admin' && db.audit[0].action === 'verify-org');

// --- 3. publishing cannot outrun verification --------------------------
reset();
r = await call({ action: 'publish-opportunity', opportunityId: 'opp-1' }, 'tok-admin', '4.0.0.1');
b = await r.json();
check('cannot publish for an unverified org', r.status === 400 && /not verified/i.test(b.error || ''), b.error);

db.opps[0].organizations.verification_status = 'verified';
r = await call({ action: 'publish-opportunity', opportunityId: 'opp-1' }, 'tok-admin', '4.0.0.2');
check('publish succeeds once the org is verified', r.status === 200, 'got ' + r.status);
check('publish is audited', db.audit.some(a => a.action === 'publish-opportunity'));

// --- 4. the key never leaks -------------------------------------------
reset();
const bodies = [];
for (const [body, tok, ip] of [
  [{ action: 'verify-org', orgId: 'nope', decision: 'verified' }, 'tok-admin', '5.0.0.1'],
  [{ action: 'publish-opportunity', opportunityId: 'nope' }, 'tok-admin', '5.0.0.2'],
  [{ action: 'verify-org', orgId: 'org-1', decision: 'verified' }, 'tok-vol', '5.0.0.3'],
  [{ action: 'run-checks' }, 'tok-admin', '5.0.0.4']
]) { bodies.push(await (await call(body, tok, ip)).text()); }
check('service key never appears in any response', !bodies.some(t => t.includes(SERVICE)));
check('get-bar exposes the checklist', (await (await call({ action: 'get-bar' }, null, '6.0.0.1')).json()).bar.length === 5);

console.log(out.join('\n'));
console.log('\n' + out.filter(l => l.startsWith('PASS')).length + '/' + out.length + ' passed');
