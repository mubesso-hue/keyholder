-- Time is a balance, not a window.
--
-- When the keyholder gives 30 minutes, those minutes go into the locked
-- person's balance. They spend it when they choose: "Use my time" opens their
-- apps while the balance counts down, and "Lock again" stops the clock and keeps
-- what's left. Use 15 minutes at 3 pm and the other 15 at 5 pm.
--
-- Screen Time can't count the minutes spent inside "everything except" apps,
-- so the clock runs while the person has their apps unlocked, which they
-- control. Older app builds keep using holder_unlock / decide_unlock, which
-- still open a fixed window.

alter table public.blocks
  add column if not exists credit_seconds int not null default 0 check (credit_seconds >= 0),
  add column if not exists credit_session_started_at timestamptz;

-- The keyholder gives time. It answers any pending request for time, goes
-- into the balance, or, while the person is using their time, extends it.
create or replace function public.give_credit(p_locked_id uuid, p_minutes int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; r public.unlock_requests;
        v_now timestamptz := now(); v_running boolean;
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
  if v_running then
    update public.blocks set unlock_until = unlock_until + make_interval(mins => p_minutes)
     where id = b.id returning * into b;
    perform public._streak_pause(p_locked_id, b.unlock_until, v_now);
  else
    update public.blocks set credit_seconds = credit_seconds + p_minutes * 60
     where id = b.id returning * into b;
  end if;

  perform public._event(p_locked_id, b.id, 'credit_given', jsonb_build_object('minutes', p_minutes, 'running', v_running));
  perform public._notify(p_locked_id,
    public._name(me) || ' gave you ' || public._fmt_minutes(p_minutes),
    case when v_running then 'Added to the time you''re using now.'
         else 'Use it whenever you like: open Keyholder and tap Use my time.' end,
    'CREDIT_GIVEN', jsonb_build_object('block_id', b.id, 'minutes', p_minutes));
  return b;
end $$;

-- The locked person starts using their balance: apps open until it runs out.
create or replace function public.use_credit()
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; v_now timestamptz := now(); v_until timestamptz;
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if b.unlock_until is not null and b.unlock_until > v_now then raise exception 'already using time'; end if;
  if b.credit_seconds <= 0 then raise exception 'no time to use'; end if;

  v_until := v_now + make_interval(secs => b.credit_seconds);
  update public.blocks
     set unlock_until = v_until, credit_seconds = 0, credit_session_started_at = v_now
   where id = b.id returning * into b;
  perform public._streak_pause(me, v_until, v_now);
  perform public._event(me, b.id, 'credit_started', jsonb_build_object('until', v_until));
  return b;
end $$;

-- The locked person locks again early: what's left goes back into the balance.
create or replace function public.stop_credit()
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; v_now timestamptz := now(); v_left int;
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if b.unlock_until is null or b.unlock_until <= v_now then return b; end if;

  v_left := floor(extract(epoch from (b.unlock_until - v_now)))::int;
  update public.blocks
     set credit_seconds = credit_seconds + greatest(v_left, 0), unlock_until = null, credit_session_started_at = null
   where id = b.id returning * into b;
  -- The streak pause ends now instead of at the old end time.
  update public.streaks set pause_until = v_now, updated_at = v_now
   where user_id = me and pause_started_at is not null and pause_until > v_now;
  perform public._streak_settle(me, v_now);
  perform public._event(me, b.id, 'credit_stopped', jsonb_build_object('seconds_left', v_left));
  return b;
end $$;

grant execute on function public.give_credit(uuid, int), public.use_credit(), public.stop_credit() to authenticated;
