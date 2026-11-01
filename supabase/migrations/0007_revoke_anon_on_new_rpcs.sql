-- Tightens who may call the functions added in 0004 and 0005. Kept apart from
-- them because Supabase may hold revokes for a confirmation prompt; the RPCs
-- already refuse callers who are not signed in (_require_user), so this is
-- belt and braces.
revoke execute on function public.start_block(int, int, int, text, int) from public, anon;

revoke execute on function
  public.request_app_change(int, int, int, int, int),
  public.decide_app_change(uuid, boolean),
  public.cancel_app_change(),
  public.update_block_apps(int, int, int),
  public._fmt_minutes(int),
  public._fmt_opened(text, int, int)
from public, anon;

revoke execute on function public._fmt_minutes(int), public._fmt_opened(text, int, int) from authenticated;
