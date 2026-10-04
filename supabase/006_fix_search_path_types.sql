-- ════════════════════════════════════════════════════════════════════════
-- 006 — Repair: 005 set an empty search path on functions that reference
--       custom types by bare name, which broke sign-in and applications.
--
-- RUN THIS NOW IF 005 HAS BEEN RUN. It is also safe to run if 005 has not.
-- ════════════════════════════════════════════════════════════════════════
--
-- What went wrong
--
-- 005 set search_path = '' on all eight functions. Before writing it I checked
-- that every SECURITY DEFINER function already qualified its TABLE names, and
-- it does. I did not check TYPE names, and five of them cast to custom enums
-- by bare name:
--
--   handle_new_user        'volunteer'::account_role
--   submit_opportunity     cur  opportunity_status
--   withdraw_opportunity   cur  opportunity_status
--   submit_application     v_role account_role, p_availability application_availability
--   withdraw_application   v_cur application_status
--
-- With an empty path those types cannot be resolved, so each function raises
-- "type does not exist" the moment it runs. For handle_new_user that happens
-- inside the signup trigger, which is why Google sign-in came back with
-- error=server_error&error_code=unexpected_failure: Supabase reports a failing
-- trigger as an unexpected failure, which gives no hint that the cause is a
-- search path.
--
-- The empty path is still right for the three functions that touch nothing but
-- built-ins, and those are left alone.
--
-- The fix for the other five
--
-- search_path = pg_catalog, public, pg_temp
--
-- This resolves the types again while keeping the security property that
-- mattered. pg_temp is searched FIRST for relation and type names when it is
-- not listed explicitly, and any signed-in user can create temporary objects,
-- so the original `= public` left a shadowing route open. Naming pg_temp last
-- closes it. This is the middle ground the review itself suggested, and it is
-- strictly better than where these functions started.
--
-- The alternative is to qualify every type inside each body as
-- public.account_role and keep the empty path. That is the stronger form and
-- it means rewriting five function bodies, which is not what you want to be
-- doing while sign-in is down. Worth doing later, deliberately, with a test
-- signup after each one.

alter function public.handle_new_user()          set search_path = pg_catalog, public, pg_temp;
alter function public.submit_opportunity(uuid)   set search_path = pg_catalog, public, pg_temp;
alter function public.withdraw_opportunity(uuid) set search_path = pg_catalog, public, pg_temp;
alter function public.withdraw_application(uuid) set search_path = pg_catalog, public, pg_temp;
alter function public.submit_application(
  uuid, public.application_availability, text, text, text, boolean, text[]
) set search_path = pg_catalog, public, pg_temp;


-- ── Check ───────────────────────────────────────────────────────────────
--
-- Expect eight rows. The five above show pg_catalog, public, pg_temp. The
-- three that reference nothing but built-ins keep the empty path:
--
--   enforce_named_verifier   search_path=
--   rise_display_name        search_path=
--   touch_updated_at         search_path=
--
-- Then sign in with Google. That is the real test; this query only says the
-- setting landed.

select
  p.proname                                                as function,
  p.prosecdef                                              as security_definer,
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
