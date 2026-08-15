-- ═══════════════════════════════════════════════════════════════════════
-- RISE — Stage 4.1: applications and the Level 1 form
--
-- Run after 003. Idempotent.
--
-- WHAT THIS FILE GUARANTEES
--
--   1. A volunteer can only apply to an opportunity that is published AND
--      whose organization is verified. Enforced inside submit_application()
--      by checking membership of public_opportunities, so it is a property of
--      the database rather than of the button that happens to be rendered.
--
--   2. A volunteer sees only their own applications. No policy on this table
--      grants any organization or any other volunteer a read.
--
--   3. `status` is not client-writable. Same column-level REVOKE pattern as
--      verification_status in 001 and opportunities.status in 002. The two
--      transitions a teen may make, submit and withdraw, go through
--      SECURITY DEFINER functions that can each write exactly one value.
--
--   4. There is no free-text column an organization can write. This table
--      records what a teen chose to say, and nothing an adult says back.
--      Organization to teen communication in later stages is a fixed
--      questionnaire or a structured meeting proposal, never prose.
--
-- WHAT IT DELIBERATELY DOES NOT STORE
--
--   No last name, school, home address, neighbourhood, photo, date of birth,
--   or phone number. Accessibility is a yes/no flag with no free-text field:
--   a teen who needs something should say so to a person at the Level 3
--   meeting, not type a medical detail into a database that an adult they
--   have never met can read. Collecting less is the point.
-- ═══════════════════════════════════════════════════════════════════════


-- ── Status ladder ──────────────────────────────────────────────────────
-- 002 shipped an enum for the old masked-email design (sent, acknowledged).
-- This spec replaces that flow, so the type is rebuilt rather than extended:
-- ADD VALUE cannot remove the dead states, and leaving them invites someone
-- to set one. Safe to swap because the table has never held a row — INSERT
-- has been revoked from `authenticated` since 002 and no client references it.
do $$
begin
  if exists (
    select 1 from pg_type t join pg_enum e on e.enumtypid = t.oid
    where t.typname = 'application_status' and e.enumlabel = 'sent'
  ) then
    alter table if exists public.applications alter column status drop default;
    alter type application_status rename to application_status_old;

    create type application_status as enum (
      'submitted', 'under_review', 'info_requested',
      'meeting_proposed', 'accepted', 'declined', 'withdrawn'
    );

    alter table if exists public.applications
      alter column status type application_status
      using (case status::text
               when 'sent'         then 'submitted'
               when 'acknowledged' then 'under_review'
               else status::text
             end)::application_status;

    alter table if exists public.applications
      alter column status set default 'submitted';

    drop type application_status_old;
  end if;
exception when undefined_object then null;
end $$;

-- Fresh installs that never had 002's enum.
do $$ begin
  create type application_status as enum (
    'submitted', 'under_review', 'info_requested',
    'meeting_proposed', 'accepted', 'declined', 'withdrawn'
  );
exception when duplicate_object then null; end $$;


-- ── Availability, as a fixed set ───────────────────────────────────────
-- An enum rather than free text so an organization filters on it later
-- without reading prose, and so a teen cannot accidentally write "Tuesdays
-- after school at the community centre on Elm Street" into a scheduling field.
do $$ begin
  create type application_availability as enum (
    'weekday_after_school', 'weekday_daytime', 'weekends', 'evenings', 'flexible'
  );
exception when duplicate_object then null; end $$;


-- ── applications ───────────────────────────────────────────────────────
create table if not exists public.applications (
  id              uuid primary key default gen_random_uuid(),
  opportunity_id  uuid not null references public.opportunities(id) on delete cascade,
  volunteer_id    uuid not null references auth.users(id) on delete cascade,
  status          application_status not null default 'submitted',
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (opportunity_id, volunteer_id)
);

-- The old design's relay column. This spec keeps applications inside RISE, so
-- there is no address to relay and nothing should be able to use it.
alter table public.applications drop column if exists masked_reply_to;

-- Renames the column if an earlier run of this file created it, so the file
-- stays safe to re-run either way.
do $$ begin
  alter table public.applications rename column applicant_first_name to applicant_display_name;
exception when undefined_column then null; when duplicate_column then null; end $$;

alter table public.applications
  -- "Sarah M." — first name plus last initial, snapshotted at submit.
  --
  -- An organization does not need a minor's full legal name to decide whether
  -- to review an application, and handing an adult-run organization a child's
  -- complete identity before anyone has met is the over-exposure this whole
  -- stage exists to avoid. If they need the full name for their own records,
  -- that happens in person at the Level 3 meeting, from the teen, not from a
  -- database row.
  --
  -- Snapshotting it here is also what lets the organization dashboard read
  -- ONLY this table. It never needs a path to `profiles`, which holds the
  -- full name, so an org is not one careless join away from a surname.
  add column if not exists applicant_display_name text,

  add column if not exists availability application_availability,
  add column if not exists relevant_experience text,
  add column if not exists motivation text,
  add column if not exists prior_volunteering text,

  -- A FLAG, never a description. See the header. If a teen needs an
  -- adjustment, the org learns that a conversation is needed and has it in
  -- person at Level 3. RISE does not warehouse the detail.
  add column if not exists has_accessibility_needs boolean not null default false,

  -- Snapshot of the capability lines the teen already chose in the matcher.
  -- Copied rather than joined so the application stays a point-in-time record
  -- and, again, so nothing org-facing needs to read a volunteer's profile.
  add column if not exists skills_snapshot text[],

  add column if not exists submitted_at timestamptz,
  add column if not exists withdrawn_at timestamptz;

create index if not exists applications_opp_idx    on public.applications(opportunity_id);
create index if not exists applications_vol_idx    on public.applications(volunteer_id);
create index if not exists applications_status_idx on public.applications(status);

comment on table public.applications is
  'Stage 4. Holds what a teen chose to say and nothing an adult said back. '
  'No free-text column is writable by an organization, in any stage. '
  'Deliberately stores no surname, school, address, phone, DOB or photo, and '
  'accessibility is a boolean with no accompanying detail field.';

comment on column public.applications.has_accessibility_needs is
  'Flag only, by design. Specifics are raised with a person at the Level 3 '
  'meeting. Do not add a free-text accessibility column in a later migration.';


-- ── Display name ───────────────────────────────────────────────────────
-- "Sarah Mekouar" -> "Sarah M."   "Sarah Anne Mekouar" -> "Sarah M."
-- "Sarah" -> "Sarah"              ""/null -> null
--
-- Takes the initial of the LAST token rather than the second, so a middle
-- name does not leak a different letter than the family name. A single-token
-- name gets no initial rather than an awkward "Sarah S.".
create or replace function public.rise_display_name(p_full text)
returns text
language sql
immutable
as $$
  select case
    when p_full is null or btrim(p_full) = '' then null
    when array_length(string_to_array(btrim(p_full), ' '), 1) = 1
      then split_part(btrim(p_full), ' ', 1)
    else split_part(btrim(p_full), ' ', 1) || ' ' ||
         upper(left((string_to_array(btrim(p_full), ' '))[
           array_length(string_to_array(btrim(p_full), ' '), 1)], 1)) || '.'
  end
$$;


-- ── Submit ─────────────────────────────────────────────────────────────
-- The only way a row is created. Every rule that matters lives here because
-- SECURITY DEFINER bypasses RLS, so the checks have to be explicit.
create or replace function public.submit_application(
  p_opportunity_id  uuid,
  p_availability    application_availability,
  p_experience      text default null,
  p_motivation      text default null,
  p_prior           text default null,
  p_accessibility   boolean default false,
  p_skills          text[] default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_role  account_role;
  v_first text;
  v_id    uuid;
begin
  if v_uid is null then
    raise exception 'Sign in to apply';
  end if;

  -- Volunteers only. An organization or admin account applying to a posting
  -- would be nonsense, and anonymous applications are a spam vector with no
  -- safe way to follow up.
  select role into v_role from public.profiles where id = v_uid;
  if v_role is distinct from 'volunteer' then
    raise exception 'Only volunteer accounts can apply';
  end if;

  -- THE GATE: the opportunity must be visible in public_opportunities, whose
  -- definition already requires published AND organization verified. Checking
  -- membership of the view rather than re-deriving the condition means this
  -- can never drift from what a volunteer is allowed to see.
  if not exists (select 1 from public.public_opportunities where id = p_opportunity_id) then
    raise exception 'That opportunity is not open for applications';
  end if;

  -- First name plus last initial. The surname itself is never copied across.
  select public.rise_display_name(full_name)
    into v_first from public.profiles where id = v_uid;

  insert into public.applications (
    opportunity_id, volunteer_id, applicant_display_name, availability,
    relevant_experience, motivation, prior_volunteering,
    has_accessibility_needs, skills_snapshot, status, submitted_at
  ) values (
    p_opportunity_id, v_uid, v_first, p_availability,
    nullif(btrim(coalesce(p_experience, '')), ''),
    nullif(btrim(coalesce(p_motivation, '')), ''),
    nullif(btrim(coalesce(p_prior, '')), ''),
    coalesce(p_accessibility, false), p_skills, 'submitted', now()
  )
  returning id into v_id;

  return v_id;
exception
  when unique_violation then
    raise exception 'You have already applied to this opportunity';
end $$;

revoke all on function public.submit_application(uuid, application_availability, text, text, text, boolean, text[]) from public, anon;
grant execute on function public.submit_application(uuid, application_availability, text, text, text, boolean, text[]) to authenticated;


-- ── Withdraw ───────────────────────────────────────────────────────────
-- Always available to the teen, and only ever moves away from organization
-- visibility, which is why it is safe to expose directly.
create or replace function public.withdraw_application(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_owner uuid;
  v_cur   application_status;
begin
  select volunteer_id, status into v_owner, v_cur
    from public.applications where id = p_id;

  if v_owner is null then raise exception 'Application not found'; end if;
  if v_owner <> auth.uid() then raise exception 'Not your application'; end if;
  if v_cur = 'withdrawn' then return; end if;

  update public.applications
     set status = 'withdrawn', withdrawn_at = now()
   where id = p_id;
end $$;

revoke all on function public.withdraw_application(uuid) from public, anon;
grant execute on function public.withdraw_application(uuid) to authenticated;


-- ── Row-level security ─────────────────────────────────────────────────
alter table public.applications enable row level security;

-- A volunteer sees only their own. There is deliberately NO organization
-- policy in this stage: applications go nowhere an org can see until the
-- review dashboard is built and reviewed.
drop policy if exists "apps: volunteer reads own" on public.applications;
create policy "apps: volunteer reads own" on public.applications
  for select using (auth.uid() = volunteer_id);


-- ── Grants ─────────────────────────────────────────────────────────────
grant select on public.applications to authenticated;
grant all    on public.applications to service_role;


-- ═══════════════════════════════════════════════════════════════════════
-- REVOKES — the last word, as in 002 and 003.
-- Anything added to this file goes ABOVE this block.
-- ═══════════════════════════════════════════════════════════════════════

-- Applications are created and moved only through the functions above.
revoke insert, update, delete on public.applications from anon, authenticated;
revoke all on public.applications from anon;

-- Belt and braces: even if a future migration grants UPDATE on this table,
-- the status column stays out of reach of a client.
revoke insert (status, submitted_at, withdrawn_at, applicant_display_name)
  on public.applications from anon, authenticated;
revoke update (status, submitted_at, withdrawn_at, applicant_display_name)
  on public.applications from anon, authenticated;

-- From 003.
revoke update, delete on public.admin_audit from anon, authenticated, service_role;
revoke insert, update, delete on public.admin_audit from anon, authenticated;
revoke insert, update, delete on public.org_checks from anon, authenticated;
revoke update, delete on public.org_checks from service_role;

-- From 002.
revoke select on public.opportunities from anon;
revoke all    on public.opportunities from anon;
revoke insert (status, submitted_at, published_at, published_by)
  on public.opportunities from anon, authenticated;
revoke update (status, submitted_at, published_at, published_by)
  on public.opportunities from anon, authenticated;

-- From 001.
revoke update (role) on public.profiles from anon, authenticated;
revoke insert (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;
revoke update (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;


-- ── updated_at ─────────────────────────────────────────────────────────
drop trigger if exists applications_touch on public.applications;
create trigger applications_touch before update on public.applications
  for each row execute function public.touch_updated_at();
