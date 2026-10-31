-- Hardening after running Supabase's security advisor on the live project.
--
-- 1. Pin search_path on the internal helpers. They are only reachable through
--    the security-definer RPCs, but pinning costs nothing and silences the lint.
alter function public._require_user() set search_path = public;
alter function public._name(uuid) set search_path = public;
alter function public._event(uuid, uuid, text, jsonb) set search_path = public;
alter function public._notify(uuid, text, text, text, jsonb) set search_path = public;
alter function public.streak_seconds(public.streaks, timestamptz) set search_path = public;
alter function public._streak_settle(uuid, timestamptz) set search_path = public;
alter function public._streak_pause(uuid, timestamptz, timestamptz) set search_path = public;
alter function public._streak_reset(uuid, timestamptz) set search_path = public;
alter function public._streak_start(uuid, timestamptz) set search_path = public;
alter function public._streak_orphan(uuid, timestamptz) set search_path = public;
alter function public._active_block(uuid) set search_path = public;
alter function public._holder_of_block(public.blocks) set search_path = public;
alter function public._end_block(uuid, public.block_end_reason, timestamptz) set search_path = public;
alter function public._request_unlock(uuid, int, text) set search_path = public;
alter function public._heartbeat(uuid, boolean, boolean, timestamptz) set search_path = public;
alter function public._report_revocation(uuid, timestamptz) set search_path = public;
alter function public._complete_break_glass(uuid, timestamptz) set search_path = public;
alter function public._apply_decision(uuid, public.request_decision, int, timestamptz) set search_path = public;

-- 2. The remaining advisor warnings are intentional: the public RPCs are
--    SECURITY DEFINER on purpose and every one of them starts by requiring
--    auth.uid(), so signed-in users can only act as themselves.
