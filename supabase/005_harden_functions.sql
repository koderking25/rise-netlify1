-- ════════════════════════════════════════════════════════════════════════
-- 005: close the RPC on handle_new_user, and pin every function's search path
--
-- Two findings from the 20 September review, both database-side, neither of
-- which changes what the application can do. Safe to run on a live database.
-- ════════════════════════════════════════════════════════════════════════


-- ── 1. handle_new_user is a trigger, not an API ─────────────────────────
--
-- PostgREST publishes every function in the public schema as an RPC endpoint,
-- and Supabase grants EXECUTE to anon and authenticated by default. So the one
-- function that decides whether an account is a volunteer or an organization,
-- running as SECURITY DEFINER with the owner's full privileges, was reachable
-- at /rest/v1/rpc/handle_new_user by anyone on the internet, signed in or not.
--
-- Called directly it almost certainly just errors, because a trigger function
-- expects a NEW record that does not exist outside a trigger. But "it probably
-- errors" is not a control. Migration 001 calls this "the ONLY thing that
-- decides a role", and the whole point of these migrations is that guarantees
-- are structural rather than incidental.
--
-- This does not break signup. A trigger resolves its privileges through the
-- trigger's owner, not the session role, so revoking EXECUTE removes the REST
-- endpoint and leaves the trigger firing exactly as before.

revoke execute on function public.handle_new_user() from anon, authenticated;


-- ── 2. Pin the search path on all eight functions ───────────────────────
--
-- When a function names a table bare, Postgres resolves it by walking the
-- search path. Anything that can get an object to appear earlier in that list
-- than the real one gets its object used instead, which is a well known
-- privilege escalation route.
--
-- Five of the eight already set search_path = public, which means whoever
-- wrote them knew about this. That form is good but not the hardened one:
-- Postgres searches the temporary schema FIRST unless pg_temp is placed
-- explicitly, and any signed-in user can create temporary objects. So a temp
-- table could in principle shadow a real one inside a SECURITY DEFINER
-- function even with search_path = public set.
--
-- The hardened form is an empty path. Two things make that safe here, both
-- checked before writing this rather than assumed:
--
--   pg_catalog is searched implicitly even when the path is empty, so the
--   built-ins these functions use (now, btrim, split_part, string_to_array,
--   array_length, upper, left) all still resolve.
--
--   Every one of the five SECURITY DEFINER functions already writes its table
--   names fully qualified: public.profiles, public.opportunities,
--   public.applications, public.organizations. Nothing to break.
--
-- The three that set no path at all are ordinary helpers and triggers, and
-- reference no tables whatsoever.
--
-- enforce_named_verifier is worth naming on its own. It is the trigger that
-- enforces "nothing reaches verified without a named human in verified_by",
-- which is one of the strongest safeguarding guarantees in the schema, and it
-- was the least protected function in the file.

-- Previously unpinned
alter function public.touch_updated_at()        set search_path = '';
alter function public.enforce_named_verifier()  set search_path = '';
alter function public.rise_display_name(text)   set search_path = '';

-- Previously pinned to public; tightened so pg_temp cannot be searched first.
--
-- CORRECTED 4 October. These five first got search_path = '' like the three
-- above, which broke them: each casts to a custom enum by bare name
-- (account_role, opportunity_status, application_status,
-- application_availability) and an empty path cannot resolve a type any more
-- than it can resolve a table. handle_new_user fails inside the signup
-- trigger, so Google sign-in returned error_code=unexpected_failure with no
-- hint of the cause. I had checked these bodies for bare TABLE names, which
-- they do not have, and not for bare TYPE names, which they do.
--
-- pg_catalog, public, pg_temp keeps the types resolvable and still names
-- pg_temp last, which is the property that mattered: it is searched first for
-- relation and type names when unlisted, and any signed-in user can create
-- temporary objects there.
alter function public.handle_new_user()          set search_path = pg_catalog, public, pg_temp;
alter function public.submit_opportunity(uuid)   set search_path = pg_catalog, public, pg_temp;
alter function public.withdraw_opportunity(uuid) set search_path = pg_catalog, public, pg_temp;
-- Seven parameters, and the second is the enum rather than text. An alter
-- function call is matched by exact argument types, so a near-miss here fails
-- the migration rather than silently skipping; the signature is copied from
-- the declaration in 004 rather than remembered.
alter function public.submit_application(
  uuid, public.application_availability, text, text, text, boolean, text[]
) set search_path = pg_catalog, public, pg_temp;
alter function public.withdraw_application(uuid) set search_path = pg_catalog, public, pg_temp;


-- ── Check it worked ─────────────────────────────────────────────────────
--
-- Expect eight rows. The three helpers show search_path= (the empty path);
-- the five that cast to custom enums show pg_catalog, public, pg_temp. A row
-- showing just "public", or (NOT SET), means that function did not take.

select
  p.proname                                        as function,
  p.prosecdef                                      as security_definer,
  coalesce(array_to_string(p.proconfig, ', '), '(NOT SET)') as settings
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'handle_new_user', 'touch_updated_at', 'submit_opportunity',
    'withdraw_opportunity', 'enforce_named_verifier', 'rise_display_name',
    'submit_application', 'withdraw_application'
  )
order by p.prosecdef desc, p.proname;
