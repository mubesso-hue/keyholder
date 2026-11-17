-- Heartbeats only write when something changes.
--
-- Every heartbeat updated the block row, every update reached both phones over
-- realtime, and each phone refreshed and sent another heartbeat: a loop of
-- several requests a second. Now a heartbeat writes only when the block's state
-- changes or the last one is over 5 minutes old, which is plenty for the
-- 12-hour "phone gone quiet" check.
create or replace function public._heartbeat(p_user uuid, p_authorized boolean, p_shielded boolean, p_now timestamptz default now())
returns void language plpgsql set search_path = public as $$
declare b public.blocks;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then return; end if;
  if not p_authorized then
    if b.verified or b.last_heartbeat_at < p_now - interval '5 minutes' then
      update public.blocks set last_heartbeat_at = p_now, verified = false where id = b.id;
      perform public._event(p_user, b.id, 'heartbeat_unauthorized');
    end if;
    return;
  end if;
  if b.verified and not b.heartbeat_alerted and b.last_heartbeat_at >= p_now - interval '5 minutes' then
    return;
  end if;
  update public.blocks
     set last_heartbeat_at = p_now, verified = true, heartbeat_alerted = false
   where id = b.id;
end $$;
