-- ═══════════════════════════════════════════════════════════════════════
-- RISE — Stage 2: opportunities, applications, and the public view
--
-- Run after 001. Idempotent.
--
-- WHAT THIS FILE GUARANTEES
--
--   Nothing an organization writes can reach a volunteer. Two independent
--   mechanisms, either of which would be sufficient:
--
--   1. `opportunities.status` is not client-writable. INSERT and UPDATE on
--      that column are revoked from anon and authenticated, exactly as
--      `verification_status` is in 001. An organization moves a draft to
--      'submitted' through a SECURITY DEFINER function that can only ever
--      write that one value — 'published' is unreachable from any client
--      path, in the same way 'verified' is.
--
--   2. Volunteers never touch this table. They read `public_opportunities`,
--      a view whose WHERE clause hard-codes "published AND the owning
--      organization is verified". SELECT on the base table is granted to
--      neither anon nor authenticated, so a volunteer session cannot query
--      unpublished rows even with a hand-written request. The filter is not
--      applied by the frontend and is not a policy that a later migration
--      could loosen by accident — it is the definition of the only object
--      they can read.
--
--   Stage 2 ships no volunteer-facing change. The view is created here and
--   nothing reads it until Stage 3.
-- ═══════════════════════════════════════════════════════════════════════


do $$ begin
  create type opportunity_status as enum ('draft', 'submitted', 'published', 'closed');
exception when duplicate_object then null; end $$;

do $$ begin
  create type application_status as enum ('sent', 'acknowledged', 'accepted', 'declined', 'withdrawn');
exception when duplicate_object then null; end $$;


-- ── opportunities ──────────────────────────────────────────────────────
create table if not exists public.opportunities (
  id                uuid primary key default gen_random_uuid(),
  org_id            uuid not null references public.organizations(id) on delete cascade,

  title             text not null,
  description       text,
  role_summary      text,
  requirements      text,

  is_remote         boolean not null default false,
  location_city     text,
  location_province text,

  time_commitment   text,
  min_age           int,
  starts_on         date,
  closes_on         date,

  -- Never client-writable. Default 'draft'; only the submit function and the
  -- service role can move it.
  status            opportunity_status not null default 'draft',
  submitted_at      timestamptz,
  published_at      timestamptz,
  published_by      uuid references auth.users(id),

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now()
);

create index if not exists opportunities_org_idx    on public.opportunities(org_id);
create index if not exists opportunities_status_idx on public.opportunities(status);

comment on column public.opportunities.status is
  'Service-role only, except draft->submitted via submit_opportunity(). '
  'INSERT and UPDATE on this column are revoked from anon and authenticated, '
  'so an organization cannot publish its own posting. Stage 3 publishes from '
  'a reviewed admin action holding the service_role key.';


-- ── applications ───────────────────────────────────────────────────────
-- Structured now; nothing writes it until Stage 4. Deliberately holds no
-- message body and no student contact details: when Stage 4 arrives the
-- organization receives a masked email and never the student's address, and
-- there is no in-app path for an adult to reach a minor.
create table if not exists public.applications (
  id              uuid primary key default gen_random_uuid(),
  opportunity_id  uuid not null references public.opportunities(id) on delete cascade,
  volunteer_id    uuid not null references auth.users(id) on delete cascade,
  status          application_status not null default 'sent',
  -- Stage 4 fills this: the per-application relay address the organization
  -- replies to. The student's real address is never stored on this row.
  masked_reply_to text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (opportunity_id, volunteer_id)
);

create index if not exists applications_opp_idx on public.applications(opportunity_id);
create index if not exists applications_vol_idx on public.applications(volunteer_id);

comment on table public.applications is
  'STAGE 4 GATE. Before any two-way contact between an organization and a '
  'student is enabled, the guardian-consent layer and masked messaging must '
  'exist. Until then applications are one-way: a masked email to the '
  'organization, no in-app minor contact, no student address stored here.';


-- ── The submit transition ──────────────────────────────────────────────
-- The only client-reachable way to change status, and it can write exactly
-- one value. Ownership is checked inside the function because SECURITY
-- DEFINER bypasses RLS.
create or replace function public.submit_opportunity(opp_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  owns boolean;
  cur  opportunity_status;
begin
  select o.status,
         exists (select 1 from public.organizations g
                 where g.id = o.org_id and g.owner_id = auth.uid())
    into cur, owns
  from public.opportunities o
  where o.id = opp_id;

  if cur is null then
    raise exception 'Opportunity not found';
  end if;
  if not owns then
    raise exception 'Not your opportunity';
  end if;
  -- Only ever draft -> submitted. Never publishes, never un-publishes.
  if cur <> 'draft' then
    raise exception 'Only a draft can be submitted';
  end if;

  update public.opportunities
     set status = 'submitted', submitted_at = now()
   where id = opp_id;
end $$;

revoke all on function public.submit_opportunity(uuid) from public, anon;
grant execute on function public.submit_opportunity(uuid) to authenticated;

-- Withdrawing a submission back to draft is safe: it can only move away from
-- volunteer visibility, never toward it.
create or replace function public.withdraw_opportunity(opp_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  owns boolean;
  cur  opportunity_status;
begin
  select o.status,
         exists (select 1 from public.organizations g
                 where g.id = o.org_id and g.owner_id = auth.uid())
    into cur, owns
  from public.opportunities o
  where o.id = opp_id;

  if not owns then raise exception 'Not your opportunity'; end if;
  if cur <> 'submitted' then raise exception 'Only a submitted posting can be withdrawn'; end if;

  update public.opportunities set status = 'draft', submitted_at = null where id = opp_id;
end $$;

revoke all on function public.withdraw_opportunity(uuid) from public, anon;
grant execute on function public.withdraw_opportunity(uuid) to authenticated;


-- ── Row-level security ─────────────────────────────────────────────────
alter table public.opportunities enable row level security;
alter table public.applications  enable row level security;

-- An organization sees and edits only its own postings.
drop policy if exists "opps: org reads own" on public.opportunities;
create policy "opps: org reads own" on public.opportunities
  for select using (
    exists (select 1 from public.organizations g
            where g.id = org_id and g.owner_id = auth.uid())
  );

drop policy if exists "opps: org creates own" on public.opportunities;
create policy "opps: org creates own" on public.opportunities
  for insert with check (
    exists (select 1 from public.organizations g
            where g.id = org_id and g.owner_id = auth.uid())
  );

-- Editing content is allowed; editing `status` is not, because the column
-- privilege below removes it regardless of what this policy permits.
drop policy if exists "opps: org edits own" on public.opportunities;
create policy "opps: org edits own" on public.opportunities
  for update using (
    exists (select 1 from public.organizations g
            where g.id = org_id and g.owner_id = auth.uid())
  ) with check (
    exists (select 1 from public.organizations g
            where g.id = org_id and g.owner_id = auth.uid())
  );

drop policy if exists "opps: org deletes own draft" on public.opportunities;
create policy "opps: org deletes own draft" on public.opportunities
  for delete using (
    status = 'draft'
    and exists (select 1 from public.organizations g
                where g.id = org_id and g.owner_id = auth.uid())
  );

-- Admin read access, for the review queue. Read-only in Stage 2: an admin
-- cannot verify or publish from the browser, because those columns are
-- revoked from `authenticated` and an admin is still `authenticated`.
-- Stage 3 performs those writes server-side with the service_role key.
drop policy if exists "orgs: admin reads all" on public.organizations;
create policy "orgs: admin reads all" on public.organizations
  for select using (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role = 'admin')
  );

drop policy if exists "opps: admin reads all" on public.opportunities;
create policy "opps: admin reads all" on public.opportunities
  for select using (
    exists (select 1 from public.profiles p
            where p.id = auth.uid() and p.role = 'admin')
  );

-- applications: a volunteer sees only their own. No organization-facing
-- policy exists yet — that arrives with Stage 4 alongside masking.
drop policy if exists "apps: volunteer reads own" on public.applications;
create policy "apps: volunteer reads own" on public.applications
  for select using (auth.uid() = volunteer_id);


-- ── The public view ────────────────────────────────────────────────────
-- The only opportunities object a volunteer can read.
--
-- Left as a non-security_invoker view on purpose: it runs with the owner's
-- rights, so the WHERE clause below — not the caller's RLS — is the security
-- boundary. That is what allows SELECT on the base table to be withheld
-- entirely from anon and authenticated while this view still resolves.
create or replace view public.public_opportunities as
  select
    o.id, o.title, o.description, o.role_summary, o.requirements,
    o.is_remote, o.location_city, o.location_province,
    o.time_commitment, o.min_age, o.starts_on, o.closes_on,
    o.published_at,
    g.id   as org_id,
    g.name as org_name,
    g.website_url as org_website,
    true   as rise_verified
  from public.opportunities o
  join public.organizations g on g.id = o.org_id
  where o.status = 'published'
    and g.verification_status = 'verified';

comment on view public.public_opportunities is
  'The ONLY opportunities object volunteers may read. Both conditions are '
  'part of the definition, not a filter the client applies: published, and '
  'the owning organization verified. Never grant SELECT on '
  'public.opportunities to anon or authenticated.';

grant select on public.public_opportunities to anon, authenticated;


-- ── Grants ─────────────────────────────────────────────────────────────
grant select, insert, update, delete on public.opportunities to authenticated;
grant select on public.applications to authenticated;

grant all on public.opportunities to service_role;
grant all on public.applications  to service_role;


-- ═══════════════════════════════════════════════════════════════════════
-- REVOKES — deliberately the last word in this file.
--
-- Re-asserted here, including the ones from 001, so that a GRANT added
-- carelessly above (now or in a future edit) cannot quietly widen the
-- surface. If you add anything to this file, add it ABOVE this block.
-- ═══════════════════════════════════════════════════════════════════════

-- Volunteers must never read the base table. The view is the only way in.
revoke select on public.opportunities from anon;
revoke all    on public.opportunities from anon;
revoke all    on public.applications  from anon;

-- Status is not client-writable; use submit_opportunity() / withdraw_opportunity().
revoke insert (status, submitted_at, published_at, published_by)
  on public.opportunities from anon, authenticated;
revoke update (status, submitted_at, published_at, published_by)
  on public.opportunities from anon, authenticated;

-- Applications are written only by the server, from Stage 4 onward.
revoke insert, update, delete on public.applications from anon, authenticated;

-- From 001 — restated so this file is self-sufficient as the last word.
revoke update (role) on public.profiles from anon, authenticated;
revoke insert (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;
revoke update (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;


-- ── updated_at ─────────────────────────────────────────────────────────
drop trigger if exists opportunities_touch on public.opportunities;
create trigger opportunities_touch before update on public.opportunities
  for each row execute function public.touch_updated_at();

drop trigger if exists applications_touch on public.applications;
create trigger applications_touch before update on public.applications
  for each row execute function public.touch_updated_at();
