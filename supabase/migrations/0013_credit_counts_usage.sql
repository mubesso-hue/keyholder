-- Given time starts on its own, and only counts while it's used.
--
-- Blocks of picked apps ("selected"): the moment the keyholder gives time, the
-- locked phone opens the apps and Screen Time counts the minutes spent in
-- them. The phone reports what it counted; the balance goes down by that, and
-- the shields come back when it's used up. 15 minutes at 3 pm and 15 at 5 pm,
-- with no buttons.
--
-- Everything-except blocks: Screen Time can't count minutes inside "all apps
-- except", so the clock starts by itself when time is given and runs until
-- the person locks again (what's left stays theirs) or it runs out.

alter table public.blocks
  add column if not exists credit_used_seconds int not null default 0 check (credit_used_seconds >= 0);

create or replace function public.give_credit(p_locked_id uuid, p_minutes int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; r public.unlock_requests;
        v_now timestamptz := now(); v_running boolean; v_until timestamptz; v_body text;
begin
  if p_minutes is null or p_minutes < 1 or p_minutes > 1440 then
    raise exception 'minutes must be between 1 and 1440';
  end if;
  select bl.* into b
    from public.blocks bl join public.keys k on k.id = bl.key_id
   where bl.user_id = p_locked_id and bl.status = 'active' and k.holder_id = me
   for update of bl;
  if b.id is null then raise exception 'you do not hold an active block for that person'; end if;

  -- Record it as an answer to their request, or as time given unasked.
  select * into r from public.unlock_requests
   where block_id = b.id and status = 'pending' and kind = 'time' limit 1 for update;
  if r.id is null then
    insert into public.unlock_requests (block_id, requester_id, holder_id, requested_minutes, kind,
                                        status, decision, approved_minutes, created_at, decided_at)
    values (b.id, p_locked_id, me, null, 'time', 'approved', 'approved_timed', p_minutes, v_now, v_now);
  else
    update public.unlock_requests
       set status = 'approved', decision = 'approved_timed', approved_minutes = p_minutes, decided_at = v_now
     where id = r.id;
  end if;

  v_running := b.unlock_until is not null and b.unlock_until > v_now;
  if b.mode = 'selected' then
    -- The phone opens the apps and counts the minutes spent in them.
    update public.blocks set credit_seconds = credit_seconds + p_minutes * 60
     where id = b.id returning * into b;
    v_body := 'Your apps are open. It only counts down while you''re using them.';
  elsif v_running then
    update public.blocks set unlock_until = unlock_until + make_interval(mins => p_minutes)
     where id = b.id returning * into b;
    perform public._streak_pause(p_locked_id, b.unlock_until, v_now);
    v_body := 'Added to the time you''re using now.';
  else
    -- Starts now, with anything saved from before.
    v_until := v_now + make_interval(secs => b.credit_seconds + p_minutes * 60);
    update public.blocks
       set unlock_until = v_until, credit_seconds = 0, credit_session_started_at = v_now
     where id = b.id returning * into b;
    perform public._streak_pause(p_locked_id, v_until, v_now);
    v_body := 'Your apps are open now. Lock again any time to keep the rest for later.';
  end if;

  perform public._event(p_locked_id, b.id, 'credit_given',
    jsonb_build_object('minutes', p_minutes, 'running', v_running, 'mode', b.mode));
  perform public._notify(p_locked_id,
    public._name(me) || ' gave you ' || public._fmt_minutes(p_minutes), v_body,
    'CREDIT_GIVEN', jsonb_build_object('block_id', b.id, 'minutes', p_minutes));
  return b;
end $$;

-- The locked phone reports how much given time it has counted for this block,
-- as a running total. Totals only grow, so a report sent twice or late does
-- no harm. Minutes used don't count toward the streak.
create or replace function public._credit_used(p_user uuid, p_block_id uuid, p_used_seconds int,
                                               p_now timestamptz default now())
returns public.blocks language plpgsql set search_path = public as $$
declare b public.blocks; v_delta int;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null or b.id is distinct from p_block_id then return b; end if;
  if p_used_seconds is null or p_used_seconds <= b.credit_used_seconds then return b; end if;

  v_delta := least(p_used_seconds - b.credit_used_seconds, b.credit_seconds);
  update public.blocks
     set credit_used_seconds = p_used_seconds, credit_seconds = credit_seconds - v_delta
   where id = b.id returning * into b;
  if v_delta > 0 then
    update public.streaks set paused_seconds = paused_seconds + v_delta, updated_at = p_now
     where user_id = p_user and started_at is not null;
    perform public._event(p_user, b.id, 'credit_used',
      jsonb_build_object('seconds', v_delta, 'left', b.credit_seconds));
  end if;
  return b;
end $$;

create or replace function public.report_credit_used(p_block_id uuid, p_used_seconds int)
returns public.blocks language plpgsql security definer set search_path = public as $$
begin
  return public._credit_used(public._require_user(), p_block_id, p_used_seconds);
end $$;

grant execute on function public.report_credit_used(uuid, int) to authenticated;

-- The monitor extension reports usage too, with the device secret.
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
  elsif p_type = 'credit_used' then
    perform public._credit_used(d.user_id, (p_payload ->> 'block_id')::uuid, (p_payload ->> 'used_seconds')::int);
    return jsonb_build_object('ok', true);
  end if;
  raise exception 'unknown event type %', p_type;
end $$;
