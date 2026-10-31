-- 1. Block modes.
--    'selected'   : the user picked the apps and categories to block (v1 behaviour).
--    'all_except' : everything is blocked except the apps the user keeps open
--                   (Phone, Messages, Maps, banking...). New apps are blocked too.
alter table public.blocks
  add column if not exists mode text not null default 'selected'
    check (mode in ('selected', 'all_except')),
  add column if not exists allowed_count int not null default 0;

-- start_block gains two optional arguments. Older app builds call it with the
-- first three named arguments only, and keep working through the defaults.
drop function if exists public.start_block(int, int, int);

create or replace function public.start_block(
  p_cooling_off_hours int,
  p_app_count int,
  p_category_count int,
  p_mode text default 'selected',
  p_allowed_count int default 0
)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); k public.keys; b public.blocks; v_summary text;
begin
  select * into k from public.keys where locked_id = me and status = 'active';
  if k.id is null then raise exception 'nobody holds your key'; end if;
  if p_mode not in ('selected', 'all_except') then
    raise exception 'unknown block mode';
  end if;
  if exists (select 1 from public.blocks where user_id = me and status = 'active') then
    raise exception 'already locked';
  end if;
  if p_mode = 'selected' and coalesce(p_app_count, 0) + coalesce(p_category_count, 0) <= 0 then
    raise exception 'nothing selected';
  end if;
  if p_cooling_off_hours not between 12 and 72 then
    raise exception 'cooling off must be between 12 and 72 hours';
  end if;

  insert into public.blocks (user_id, key_id, cooling_off_hours, app_count, category_count, mode, allowed_count)
  values (me, k.id, p_cooling_off_hours, coalesce(p_app_count, 0), coalesce(p_category_count, 0),
          p_mode, greatest(coalesce(p_allowed_count, 0), 0))
  returning * into b;

  v_summary := case
    when p_mode = 'all_except' then
      'Everything is blocked except ' || b.allowed_count || case when b.allowed_count = 1 then ' app.' else ' apps.' end
    else
      coalesce(p_app_count, 0) || ' apps, ' || coalesce(p_category_count, 0) || ' categories.'
  end;

  perform public._streak_start(me);
  perform public._event(me, b.id, 'block_started', jsonb_build_object(
    'cooling_off_hours', p_cooling_off_hours, 'mode', p_mode,
    'app_count', p_app_count, 'category_count', p_category_count, 'allowed_count', b.allowed_count));
  perform public._notify(k.holder_id, public._name(me) || ' locked their phone',
    'You hold the key. ' || v_summary,
    'BLOCK_STARTED', jsonb_build_object('user_id', me, 'block_id', b.id));
  return b;
end $$;

revoke execute on function public.start_block(int, int, int, text, int) from public, anon;
grant execute on function public.start_block(int, int, int, text, int) to authenticated;

-- 2. Safer revocation.
--    Screen Time can briefly report "not authorized" right after access is
--    granted, and the app's background extensions cannot always read the
--    status at all. A heartbeat saying "not authorized" therefore no longer
--    ends the block: it is logged and the block is marked unverified.
--    Revocation is reported only by the app itself after repeated checks
--    (report_revocation) or explicitly by an extension (device_event 'revoked').
create or replace function public._heartbeat(p_user uuid, p_authorized boolean, p_shielded boolean, p_now timestamptz default now())
returns void language plpgsql set search_path = public as $$
declare b public.blocks;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then return; end if;
  if not p_authorized then
    update public.blocks set last_heartbeat_at = p_now, verified = false where id = b.id;
    perform public._event(p_user, b.id, 'heartbeat_unauthorized');
    return;
  end if;
  update public.blocks
     set last_heartbeat_at = p_now, verified = true, heartbeat_alerted = false
   where id = b.id;
end $$;

-- 3. Server-side guard for app builds that predate the debounced check: a
--    revocation report in the first two minutes of a block is logged and
--    ignored. That is exactly when iOS can still report stale authorization.
create or replace function public._report_revocation(p_user uuid, p_now timestamptz default now())
returns void language plpgsql set search_path = public as $$
declare b public.blocks; v_holder uuid;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then return; end if;
  if p_now - b.started_at < interval '2 minutes' then
    perform public._event(p_user, b.id, 'revocation_ignored_new_block');
    return;
  end if;
  v_holder := public._holder_of_block(b);
  perform public._end_block(b.id, 'revoked', p_now);
  perform public._streak_reset(p_user, p_now);
  perform public._event(p_user, b.id, 'revoked');
  perform public._notify(
    v_holder,
    public._name(p_user) || ' turned off Screen Time access',
    'Their block is gone and their streak reset. You held their key.',
    'REVOKED',
    jsonb_build_object('user_id', p_user)
  );
  perform public._notify(p_user, 'Your block ended', 'Screen Time access was turned off, so the block was removed and your streak reset.',
    'BLOCK_ENDED', jsonb_build_object('reason', 'revoked'));
end $$;
