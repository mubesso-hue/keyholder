-- Heartbeats from the app's background extension are liveness pings only.
--
-- The extension can't reliably read Screen Time authorization. At midnight the
-- daily heartbeat read "not authorized" while access was fine, and the server
-- ended the block as revoked, reset the streak and told the keyholder.
--
-- The extension only runs while Screen Time access stands, so a heartbeat from
-- it counts as authorized whatever it says. Revocation is reported only by the
-- app itself, after repeated checks (report_revocation). Builds already
-- installed keep sending "authorized": false at midnight; it is ignored.
create or replace function public.device_event(p_secret text, p_type text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.devices; r public.unlock_requests;
begin
  select * into d from public.devices where device_secret = p_secret;
  if d.id is null then raise exception 'unknown device' using errcode = '42501'; end if;
  update public.devices set last_heartbeat_at = now(), updated_at = now() where id = d.id;

  if p_type = 'heartbeat' then
    perform public._event(d.user_id, (select id from public.blocks where user_id = d.user_id and status = 'active'),
      'extension_heartbeat', p_payload);
    perform public._heartbeat(d.user_id, true, coalesce((p_payload ->> 'shielded')::boolean, true));
    return jsonb_build_object('ok', true);
  elsif p_type = 'request_unlock' then
    r := public._request_unlock(d.user_id, (p_payload ->> 'minutes')::int, 'shield');
    return jsonb_build_object('ok', true, 'request_id', r.id);
  elsif p_type = 'revoked' then
    perform public._report_revocation(d.user_id);
    return jsonb_build_object('ok', true);
  elsif p_type = 'break_glass_done' then
    perform public._complete_break_glass((select id from public.blocks where user_id = d.user_id and status = 'active'));
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'unknown event type %', p_type;
end $$;
