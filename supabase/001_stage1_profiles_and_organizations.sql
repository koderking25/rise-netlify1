-- ═══════════════════════════════════════════════════════════════════════
-- RISE — Stage 1: account roles and organization records
--
-- Run this once in the Supabase SQL editor (Dashboard → SQL Editor → New
-- query → paste → Run). It is idempotent: running it twice is harmless.
--
-- THE CENTRAL GUARANTEE OF THIS FILE
--
--   `organizations.verification_status` and `profiles.role` cannot be set or
--   changed by any client, ever — including a signed-in organization editing
--   its own row, which RLS would otherwise permit.
--
--   That is enforced with Postgres COLUMN-LEVEL privileges, not with RLS.
--   The distinction matters. RLS decides WHICH ROWS you may touch; column
--   grants decide WHICH COLUMNS you may write. A policy like
--   "orgs may update their own row" is row-level, so it would happily let an
--   org set its own verification_status to 'verified'. Revoking the column
--   privilege closes that off underneath RLS, so no future policy — however
--   carelessly written — can reopen it.
--
--   Net effect: "RISE Verified" can only ever be granted by something holding
--   the service_role key, which lives on the server and never in the browser.
-- ═══════════════════════════════════════════════════════════════════════


-- ── Enums ──────────────────────────────────────────────────────────────
do $$ begin
  create type account_role as enum ('volunteer', 'organization', 'admin');
exception when duplicate_object then null; end $$;

do $$ begin
  create type org_verification as enum ('unverified', 'in_review', 'verified', 'suspended');
exception when duplicate_object then null; end $$;


-- ── profiles ───────────────────────────────────────────────────────────
-- One row per auth user. Keyed to auth.users.id per Supabase convention.
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  role        account_role not null default 'volunteer',
  full_name   text,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

comment on column public.profiles.role is
  'Set by the on-signup trigger from signup metadata, never by the client. '
  'UPDATE on this column is revoked from anon and authenticated, so a user '
  'cannot promote themselves to admin.';


-- ── organizations ──────────────────────────────────────────────────────
create table if not exists public.organizations (
  id                    uuid primary key default gen_random_uuid(),
  owner_id              uuid not null references auth.users(id) on delete cascade,

  name                  text not null,
  org_type              text,
  registration_number   text,
  website_url           text,
  address_line1         text,
  address_line2         text,
  city                  text,
  province              text,
  postal_code           text,

  contact_name          text,
  contact_position      text,
  contact_email         text,
  contact_phone         text,

  -- Never client-writable. See the note at the top of this file.
  verification_status   org_verification not null default 'unverified',
  verified_at           timestamptz,
  verified_by           uuid references auth.users(id),
  review_notes          text,

  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create index if not exists organizations_owner_idx  on public.organizations(owner_id);
create index if not exists organizations_status_idx on public.organizations(verification_status);

comment on column public.organizations.verification_status is
  'Service-role only. INSERT and UPDATE on this column are revoked from anon '
  'and authenticated, so an organization can never mark itself verified. '
  'Stage 3 flips this from a reviewed admin action.';


-- ── Signup trigger ─────────────────────────────────────────────────────
-- Creates the profile row automatically, and is the ONLY thing that decides a
-- role. It reads the account type the signup form put in user metadata and
-- accepts exactly two values. Anything else — including someone hand-crafting
-- a signup payload with account_type='admin' — falls through to 'volunteer'.
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  requested text := coalesce(new.raw_user_meta_data->>'account_type', 'volunteer');
begin
  insert into public.profiles (id, role, full_name)
  values (
    new.id,
    case when requested = 'organization' then 'organization'::account_role
         else 'volunteer'::account_role end,
    coalesce(new.raw_user_meta_data->>'full_name', new.raw_user_meta_data->>'username')
  )
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- Backfill: every existing account is a volunteer. This is what keeps the
-- current volunteer experience unchanged — they all already have the role the
-- app will now look for.
insert into public.profiles (id, role)
select u.id, 'volunteer'::account_role
from auth.users u
left join public.profiles p on p.id = u.id
where p.id is null;


-- ── Row-level security ─────────────────────────────────────────────────
alter table public.profiles      enable row level security;
alter table public.organizations enable row level security;

-- profiles: you can read and update only your own row.
drop policy if exists "profiles: read own" on public.profiles;
create policy "profiles: read own" on public.profiles
  for select using (auth.uid() = id);

drop policy if exists "profiles: update own" on public.profiles;
create policy "profiles: update own" on public.profiles
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- organizations: an owner sees and edits only their own organization.
-- Note there is deliberately NO policy letting organizations read profiles,
-- user_data, or anything belonging to a volunteer. Organization accounts are
-- adults; volunteer accounts are minors. Nothing in Stage 1 gives an
-- organization any read path to a student's data at all.
drop policy if exists "orgs: read own" on public.organizations;
create policy "orgs: read own" on public.organizations
  for select using (auth.uid() = owner_id);

drop policy if exists "orgs: create own" on public.organizations;
create policy "orgs: create own" on public.organizations
  for insert with check (auth.uid() = owner_id);

drop policy if exists "orgs: update own" on public.organizations;
create policy "orgs: update own" on public.organizations
  for update using (auth.uid() = owner_id) with check (auth.uid() = owner_id);

-- Deliberately no DELETE policy. An organization that has interacted with
-- students should be suspended and audited, not erased.


-- ── Column privileges — the actual guarantee ───────────────────────────
grant usage on schema public to anon, authenticated;

grant select, update on public.profiles to authenticated;
grant select, insert, update on public.organizations to authenticated;

-- ...then take back the two columns that must never be client-writable.
revoke update (role) on public.profiles from anon, authenticated;

revoke insert (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;
revoke update (verification_status, verified_at, verified_by, review_notes)
  on public.organizations from anon, authenticated;

-- service_role bypasses RLS and column grants; that key stays server-side.
grant all on public.profiles      to service_role;
grant all on public.organizations to service_role;


-- ── updated_at ─────────────────────────────────────────────────────────
create or replace function public.touch_updated_at()
returns trigger language plpgsql as $$
begin new.updated_at = now(); return new; end $$;

drop trigger if exists profiles_touch on public.profiles;
create trigger profiles_touch before update on public.profiles
  for each row execute function public.touch_updated_at();

drop trigger if exists organizations_touch on public.organizations;
create trigger organizations_touch before update on public.organizations
  for each row execute function public.touch_updated_at();
