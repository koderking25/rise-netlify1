-- ═══════════════════════════════════════════════════════════════════════
-- RISE — Stage 3: verification, publishing, and the audit trail
--
-- Run after 002. Idempotent.
--
-- WHAT THIS FILE GUARANTEES
--
--   'verified' cannot exist without naming a human. A trigger raises if
--   verification_status becomes 'verified' while verified_by is null. That
--   is a database constraint, not a UI convention, so it holds no matter how
--   the bar is set, who edits the frontend later, or what a future endpoint
--   forgets to check.
--
--   The automated pre-checks are advisory and structurally cannot approve
--   anything. They live in their own table with no write path to
--   verification_status, so no combination of passing checks approves an
--   organization — a person still has to.
--
--   The audit log is append-only. No UPDATE or DELETE grant exists for any
--   role, including service_role, so the record of who verified what cannot
--   be quietly rewritten afterwards.
-- ═══════════════════════════════════════════════════════════════════════


-- ── Screening attestation ──────────────────────────────────────────────
-- Point (d) of the bar: the organization's own written statement that anyone
-- who would contact minors is screened per their local requirements.
--
-- Legitimately client-writable by the owning organization, because it is
-- their statement to make — it is evidence for the review, not a grant of
-- verification. Recording who attested and when is the point: it is the
-- thing you can hold up later.
alter table public.organizations
  add column if not exists screening_attested    boolean not null default false,
  add column if not exists screening_attested_at timestamptz,
  add column if not exists screening_attested_by uuid references auth.users(id),
  add column if not exists screening_statement   text;

comment on column public.organizations.screening_attested is
  'The organization''s own attestation that anyone contacting minors is '
  'screened per local requirements. Written by the organization, never by '
  'RISE. Evidence for review, not a grant of verification.';


-- ── The human gate ─────────────────────────────────────────────────────
-- The structural guarantee. Nothing reaches 'verified' anonymously.
create or replace function public.enforce_named_verifier()
returns trigger
language plpgsql
as $$
begin
  if new.verification_status = 'verified'
     and (new.verified_by is null) then
    raise exception
      'verified requires a named human in verified_by (RISE Stage 3 gate)';
  end if;

  -- Stamp the time alongside the person, so the pair is always consistent.
  if new.verification_status = 'verified'
     and (old.verification_status is distinct from 'verified') then
    new.verified_at := coalesce(new.verified_at, now());
  end if;

  -- Leaving verified clears the attribution, so a stale name never implies a
  -- current approval.
  if new.verification_status <> 'verified'
     and old.verification_status = 'verified' then
    new.verified_by := null;
    new.verified_at := null;
  end if;

  return new;
end $$;

drop trigger if exists organizations_named_verifier on public.organizations;
create trigger organizations_named_verifier
  before insert or update on public.organizations
  for each row execute function public.enforce_named_verifier();


-- ── Advisory pre-checks ────────────────────────────────────────────────
-- Assists for the reviewer. Deliberately a separate table: there is no path
-- from a passing check to verification_status, so checks cannot approve.
create table if not exists public.org_checks (
  id          uuid primary key default gen_random_uuid(),
  org_id      uuid not null references public.organizations(id) on delete cascade,
  check_key   text not null,          -- 'business_number_format' | 'email_domain_match'
  passed      boolean not null,
  detail      text,
  checked_at  timestamptz not null default now()
);

create index if not exists org_checks_org_idx on public.org_checks(org_id, checked_at desc);

comment on table public.org_checks is
  'ADVISORY ONLY. Results shown to a reviewer. No trigger, policy or grant '
  'lets a passing check change verification_status. A person approves.';


-- ── Audit log ──────────────────────────────────────────────────────────
create table if not exists public.admin_audit (
  id           bigserial primary key,
  actor_id     uuid not null references auth.users(id),
  actor_email  text,
  action       text not null,
  target_type  text not null,          -- 'organization' | 'opportunity'
  target_id    uuid not null,
  detail       jsonb,
  created_at   timestamptz not null default now()
);

create index if not exists admin_audit_target_idx on public.admin_audit(target_type, target_id, created_at desc);
create index if not exists admin_audit_actor_idx  on public.admin_audit(actor_id, created_at desc);

comment on table public.admin_audit is
  'Append-only. No UPDATE or DELETE grant exists for any role, including '
  'service_role, so the record of who verified or published what cannot be '
  'rewritten. Inserted by the /api/admin Worker endpoint.';


-- ── Row-level security ─────────────────────────────────────────────────
alter table public.org_checks  enable row level security;
alter table public.admin_audit enable row level security;

-- Admins may read both. Nobody may write either from a browser: the endpoint
-- writes with the service_role key, which bypasses RLS.
drop policy if exists "checks: admin reads" on public.org_checks;
create policy "checks: admin reads" on public.org_checks
  for select using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "audit: admin reads" on public.admin_audit;
create policy "audit: admin reads" on public.admin_audit
  for select using (
    exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin')
  );

-- An organization may read its own check results — it should be able to see
-- why a review is stuck rather than guessing.
drop policy if exists "checks: org reads own" on public.org_checks;
create policy "checks: org reads own" on public.org_checks
  for select using (
    exists (select 1 from public.organizations g
            where g.id = org_id and g.owner_id = auth.uid())
  );


-- ── Grants ─────────────────────────────────────────────────────────────
grant select on public.org_checks  to authenticated;
grant select on public.admin_audit to authenticated;

grant select, insert on public.org_checks  to service_role;
-- INSERT and SELECT only. Deliberately no UPDATE or DELETE: append-only means
-- append-only, including for the key that can do everything else.
grant select, insert on public.admin_audit to service_role;


-- ═══════════════════════════════════════════════════════════════════════
-- REVOKES — the last word, as in 002.
-- Anything added to this file goes ABOVE this block.
-- ═══════════════════════════════════════════════════════════════════════

-- Nobody rewrites history.
revoke update, delete on public.admin_audit from anon, authenticated, service_role;
revoke insert, update, delete on public.admin_audit from anon, authenticated;

-- Checks are written by the endpoint only.
revoke insert, update, delete on public.org_checks from anon, authenticated;
revoke update, delete on public.org_checks from service_role;

-- The attestation is the organization's to make, but the verification
-- attribution is not theirs to write.
revoke insert (screening_attested_at, screening_attested_by)
  on public.organizations from anon, authenticated;

-- From 002.
revoke select on public.opportunities from anon;
revoke all    on public.opportunities from anon;
revoke all    on public.applications  from anon;
revoke insert (status, submitted_at, published_at, published_by)
  on public.opportunities from anon, authenticated;
revoke update (status, submitted_at, published_at, published_by)
  on public.opportunities from anon, authenticated;
revoke insert, update, delete on public.applications from anon, authenticated;

-- From 001.
revoke update (role) on public.profiles from anon, authenticated;
revoke insert (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;
revoke update (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;
