-- End-to-end scenario against the schema. Runs as a superuser; auth.uid() is
-- driven by a session setting so we can "be" different users.
\set ON_ERROR_STOP on
\set QUIET on
\pset tuples_only on
\pset format unaligned

create or replace function pg_temp.as_user(u uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', u::text, false)
$$;
create or replace function pg_temp.as_nobody() returns void language sql as $$
  select set_config('request.jwt.claim.sub', '', false)
$$;
create or replace function pg_temp.ok(cond boolean, msg text) returns text language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'ASSERTION FAILED: %', msg; end if;
  return 'ok: ' || msg;
end $$;
create or replace function pg_temp.assert_raises(sql text, expected text) returns text language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(expected in sqlerrm) = 0 then
      raise exception 'expected error containing "%" but got "%"', expected, sqlerrm;
    end if;
    return 'ok: raises "' || expected || '"';
  end;
  raise exception 'expected error containing "%" but statement succeeded: %', expected, sql;
end $$;

\set marc  '11111111-1111-1111-1111-111111111111'
\set sarah '22222222-2222-2222-2222-222222222222'
\set tom   '33333333-3333-3333-3333-333333333333'

-- Users -----------------------------------------------------------------------
insert into auth.users (id, raw_user_meta_data) values
  (:'marc',  '{"full_name":"Marc"}'),
  (:'sarah', '{"full_name":"Sarah"}'),
  (:'tom',   '{}');

select pg_temp.ok((select count(*) from public.profiles) = 3, 'profiles auto-created');
select pg_temp.ok((select display_name from public.profiles where id = :'tom') = 'Someone', 'fallback name');
select pg_temp.ok((select count(*) from public.streaks) = 3, 'streak rows auto-created');

-- Mutual pact via invite ------------------------------------------------------
select pg_temp.as_user(:'marc');
select public.create_invite('mutual') as code \gset
select pg_temp.assert_raises($$select public.accept_invite('$$ || :'code' || $$')$$, 'own invite');

select pg_temp.as_user(:'sarah');
select count(*) as accepted_keys from public.accept_invite(:'code') \gset
select pg_temp.ok(:accepted_keys = 2, 'mutual invite creates two keys');
select pg_temp.ok((select count(*) from public.keys where status = 'active') = 2, 'two active keys');
select pg_temp.ok((select count(*) from public.notifications where category = 'INVITE_ACCEPTED') = 1, 'inviter notified');
select pg_temp.assert_raises($$select public.accept_invite('$$ || :'code' || $$')$$, 'already used');

-- A third person cannot also hold Marc's key.
select pg_temp.as_user(:'marc');
select public.create_invite('hold_mine') as code2 \gset
select pg_temp.as_user(:'tom');
select pg_temp.assert_raises($$select public.accept_invite('$$ || :'code2' || $$')$$, 'already holds');

-- Lock --------------------------------------------------------------------------
select pg_temp.as_user(:'tom');
select pg_temp.assert_raises('select public.start_block(24, 3, 0)', 'nobody holds your key');

select pg_temp.as_user(:'marc');
select pg_temp.assert_raises('select public.start_block(24, 0, 0)', 'nothing selected');
select pg_temp.assert_raises('select public.start_block(6, 3, 0)', 'between 12 and 72');
select id as marc_block from public.start_block(24, 5, 1) \gset
select pg_temp.assert_raises('select public.start_block(24, 5, 1)', 'already locked');

select pg_temp.as_user(:'sarah');
select id as sarah_block from public.start_block(48, 3, 0) \gset

select pg_temp.ok((select count(*) from public.blocks where status = 'active') = 2, 'two active blocks');
select pg_temp.ok((select started_at is not null from public.streaks where user_id = :'marc'), 'marc streak started');
select pg_temp.ok((select count(*) from public.notifications where category = 'BLOCK_STARTED') = 2, 'holders notified');

-- Cannot end a key while locked.
select pg_temp.as_user(:'marc');
select pg_temp.assert_raises(
  $$select public.end_key((select key_id from public.blocks where id = '$$ || :'marc_block' || $$'))$$,
  'while a block is active');

-- Request + decide ---------------------------------------------------------------
select pg_temp.assert_raises('select public.request_unlock(5)', 'between 15 and 1440');
select id as req1 from public.request_unlock(30) \gset
select id as req1_again from public.request_unlock(60) \gset
select pg_temp.ok(:'req1' = :'req1_again', 'second request while pending is idempotent');
select pg_temp.ok((select count(*) from public.notifications where category = 'UNLOCK_REQUEST') = 1, 'one push to holder');

-- Sarah's phone sees the pending request in her snapshot.
select pg_temp.as_user(:'sarah');
select public.me_snapshot() as snap \gset
select pg_temp.ok((:'snap'::jsonb) -> 'block' ->> 'id' = :'sarah_block', 'snapshot: own block');
select pg_temp.ok(jsonb_array_length((:'snap'::jsonb) -> 'held') = 1, 'snapshot: holds one key');
select pg_temp.ok((:'snap'::jsonb) -> 'held' -> 0 -> 'pending_request' ->> 'id' = :'req1', 'snapshot: pending request visible');
select pg_temp.ok((:'snap'::jsonb) -> 'held' -> 0 -> 'profile' ->> 'display_name' = 'Marc', 'snapshot: held profile');
select pg_temp.ok((:'snap'::jsonb) -> 'keyholder' -> 'profile' ->> 'display_name' = 'Marc', 'snapshot: my keyholder');
select pg_temp.ok(((:'snap'::jsonb) -> 'held' -> 0 ->> 'requests_this_week')::int = 1, 'snapshot: weekly request count');

-- Wrong holder cannot decide.
select pg_temp.as_user(:'tom');
select pg_temp.assert_raises($$select public.decide_unlock('$$ || :'req1' || $$', 'approved_timed', 15)$$, 'not your key');

select pg_temp.as_user(:'sarah');
select pg_temp.assert_raises($$select public.decide_unlock('$$ || :'req1' || $$', 'approved_timed', 5)$$, 'between 15 and 1440');
select status as req1_status from public.decide_unlock(:'req1', 'approved_timed', 15) \gset
select pg_temp.ok(:'req1_status' = 'approved', 'approved');
select pg_temp.ok((select unlock_until is not null from public.blocks where id = :'marc_block'), 'block carries unlock window');
select pg_temp.ok((select pause_until is not null from public.streaks where user_id = :'marc'), 'streak paused');
select pg_temp.ok((select count(*) from public.notifications where category = 'UNLOCK_DECIDED') = 1, 'requester notified');
select pg_temp.assert_raises($$select public.decide_unlock('$$ || :'req1' || $$', 'denied')$$, 'already decided');

-- Keyholder gives time without a request --------------------------------------------
select pg_temp.as_user(:'tom');
select pg_temp.assert_raises($$select public.holder_unlock('$$ || :'marc' || $$', 'approved_timed', 30)$$, 'do not hold');
select pg_temp.as_user(:'sarah');
select pg_temp.assert_raises($$select public.holder_unlock('$$ || :'marc' || $$', 'denied')$$, 'nothing to deny');
select unlock_until as hu_until from public.blocks where id = :'marc_block' \gset
select status as hu_status, coalesce(requested_minutes::text, 'null') as hu_requested from public.holder_unlock(:'marc', 'approved_timed', 60) \gset
select pg_temp.ok(:'hu_status' = 'approved' and :'hu_requested' = 'null', 'holder-initiated unlock is auto-approved with no requested minutes');
select pg_temp.ok((select unlock_until > :'hu_until'::timestamptz from public.blocks where id = :'marc_block'), 'unlock window extended');
select pg_temp.ok((select pause_until = unlock_until from public.streaks s, public.blocks b where s.user_id = :'marc' and b.id = :'marc_block'), 'streak pause follows the longer window');
select pg_temp.ok((select count(*) from public.unlock_requests where block_id = :'marc_block') = 2, 'two request rows');

-- Streak arithmetic with explicit clocks ------------------------------------------
do $$
declare u uuid := '44444444-4444-4444-4444-444444444444'; s public.streaks; t0 timestamptz := '2026-01-01 00:00+00';
begin
  insert into auth.users (id, raw_user_meta_data) values (u, '{"full_name":"Clock"}');
  perform public._streak_start(u, t0);
  select * into s from public.streaks where user_id = u;
  assert public.streak_seconds(s, t0 + interval '10 hours') = 36000, 'ten hours in';

  -- a 1h approved unlock at hour 10
  perform public._streak_pause(u, t0 + interval '11 hours', t0 + interval '10 hours');
  select * into s from public.streaks where user_id = u;
  assert public.streak_seconds(s, t0 + interval '10 hours 30 minutes') = 36000, 'clock frozen mid-pause';
  assert public.streak_seconds(s, t0 + interval '12 hours') = 39600, 'eleven hours counted after a one hour pause';

  -- settle folds the finished pause
  perform public._streak_settle(u, t0 + interval '12 hours');
  select * into s from public.streaks where user_id = u;
  assert s.pause_until is null and s.paused_seconds = 3600, 'pause folded';

  -- orphan at hour 20, re-lock inside grace => resume minus gap
  perform public._streak_orphan(u, t0 + interval '20 hours');
  select * into s from public.streaks where user_id = u;
  assert s.best_seconds = 68400, 'best recorded at orphan time (19h)';
  assert public.streak_seconds(s, t0 + interval '30 hours') = 68400, 'frozen during grace';
  perform public._streak_start(u, t0 + interval '28 hours');
  select * into s from public.streaks where user_id = u;
  assert s.grace_until is null and s.started_at = t0, 'resumed same streak';
  assert public.streak_seconds(s, t0 + interval '30 hours') = 68400 + 7200, 'resumed, gap excluded';

  -- orphan again and let grace lapse => zero on read, reset on next settle
  perform public._streak_orphan(u, t0 + interval '40 hours');
  select * into s from public.streaks where user_id = u;
  assert public.streak_seconds(s, t0 + interval '70 hours') = 0, 'expired grace reads as zero';
  perform public._streak_settle(u, t0 + interval '70 hours');
  select * into s from public.streaks where user_id = u;
  assert s.started_at is null and s.best_seconds > 0, 'reset after grace, record kept';

  -- reset records the best
  perform public._streak_start(u, t0 + interval '100 hours');
  perform public._streak_reset(u, t0 + interval '300 hours');
  select * into s from public.streaks where user_id = u;
  assert s.best_seconds = 720000, 'new record 200h';
end $$;
select 'ok: streak arithmetic';

-- Break Glass ------------------------------------------------------------------
select pg_temp.as_user(:'marc');
select break_glass_ends_at as bg_ends from public.start_break_glass() \gset
select pg_temp.ok((:'bg_ends'::timestamptz - now()) between interval '23 hours 59 minutes' and interval '24 hours 1 minute', 'ends in 24h');
select pg_temp.ok((select count(*) from public.notifications where category = 'BREAK_GLASS_STARTED') = 1, 'holder pushed');
select break_glass_ends_at as bg_ends2 from public.start_break_glass() \gset
select pg_temp.ok(:'bg_ends' = :'bg_ends2', 'starting twice is idempotent');

select public.cancel_break_glass();
select pg_temp.ok((select break_glass_ends_at is null from public.blocks where id = :'marc_block'), 'cancelled');
select pg_temp.ok((select started_at is not null from public.streaks where user_id = :'marc'), 'streak intact after cancel');

select pg_temp.assert_raises('select public.complete_break_glass()', 'not due');
select public.start_break_glass();
select pg_temp.assert_raises('select public.complete_break_glass()', 'not due');

-- Lengthen only.
select pg_temp.assert_raises('select public.lengthen_cooling_off(12)', 'only lengthen');
select cooling_off_hours as coh from public.lengthen_cooling_off(48) \gset
select pg_temp.ok(:coh = 48, 'lengthened to 48');

-- Simulate the clock: make it due, then let cron complete it.
update public.blocks set break_glass_ends_at = now() - interval '1 minute' where id = :'marc_block';
select pg_temp.as_nobody();
select public.cron_tick() as tick \gset
select pg_temp.ok(((:'tick'::jsonb) ->> 'completed_break_glass')::int = 1, 'cron completed one break glass');
select pg_temp.ok((select status = 'ended' and ended_reason = 'break_glass' from public.blocks where id = :'marc_block'), 'marc block ended by break glass');
select pg_temp.ok((select started_at is null from public.streaks where user_id = :'marc'), 'marc streak reset');
select pg_temp.ok((select count(*) from public.keys where status = 'active') = 0, 'pact dissolved both ways');
select pg_temp.ok((select status = 'ended' and ended_reason = 'orphaned' from public.blocks where id = :'sarah_block'), 'sarah orphaned');
select pg_temp.ok((select grace_until is not null and started_at is not null from public.streaks where user_id = :'sarah'), 'sarah on grace');
select pg_temp.ok((select count(*) from public.notifications where category = 'BREAK_GLASS_COMPLETED') = 1, 'holder told of completion');
select pg_temp.ok((select count(*) from public.notifications where category = 'BLOCK_ENDED' and data ->> 'reason' = 'orphaned') = 1, 'sarah told she is orphaned');

-- Sarah re-locks inside grace with a new keyholder and keeps her streak ------------
select pg_temp.as_user(:'sarah');
select public.create_invite('hold_mine') as code3 \gset
select pg_temp.as_user(:'tom');
select count(*) from public.accept_invite(:'code3');
select pg_temp.as_user(:'sarah');
select started_at as sarah_started_before from public.streaks where user_id = :'sarah' \gset
select id as sarah_block2 from public.start_block(24, 2, 0) \gset
select pg_temp.ok((select started_at = :'sarah_started_before'::timestamptz and grace_until is null and pause_started_at is null
                     from public.streaks where user_id = :'sarah'), 'streak resumed after re-lock');

-- Heartbeat + revocation --------------------------------------------------------
select public.heartbeat(true, true);
select pg_temp.ok((select verified from public.blocks where id = :'sarah_block2'), 'verified after heartbeat');

-- Cron flags a quiet phone once.
update public.blocks set last_heartbeat_at = now() - interval '13 hours' where id = :'sarah_block2';
select pg_temp.as_nobody();
select public.cron_tick() as tick2 \gset
select public.cron_tick() as tick3 \gset
select pg_temp.ok(((:'tick2'::jsonb) ->> 'flagged_heartbeats')::int = 1, 'quiet phone flagged');
select pg_temp.ok(((:'tick3'::jsonb) ->> 'flagged_heartbeats')::int = 0, 'alerted only once');
select pg_temp.ok((select not verified from public.blocks where id = :'sarah_block2'), 'block unverified');

-- Device secret path (extensions) ----------------------------------------------
select pg_temp.as_user(:'sarah');
select id as dev_id, device_secret as dev_secret from public.register_device('abc123') \gset
select id as dev_id2 from public.register_device('def456', :'dev_id') \gset
select pg_temp.ok(:'dev_id' = :'dev_id2', 'register_device updates in place');

select pg_temp.as_nobody();
select public.device_event(:'dev_secret', 'heartbeat', '{"authorized": true, "shielded": true}');
select pg_temp.ok((select verified from public.blocks where id = :'sarah_block2'), 'device heartbeat re-verifies');
select pg_temp.assert_raises($$select public.device_event('nope', 'heartbeat', '{}')$$, 'unknown device');

select public.device_event(:'dev_secret', 'request_unlock', '{"minutes": 15}');
select pg_temp.ok((select count(*) from public.unlock_requests where block_id = :'sarah_block2' and status = 'pending') = 1, 'shield button creates a request');

-- Revocation ends the block, resets the streak, keeps the key.
select public.device_event(:'dev_secret', 'revoked', '{}');
select pg_temp.ok((select status = 'ended' and ended_reason = 'revoked' from public.blocks where id = :'sarah_block2'), 'revoked block ended');
select pg_temp.ok((select started_at is null from public.streaks where user_id = :'sarah'), 'revoked streak reset');
select pg_temp.ok((select count(*) from public.keys where status = 'active' and locked_id = :'sarah') = 1, 'key survives revocation');
select pg_temp.ok((select count(*) from public.unlock_requests where block_id = :'sarah_block2' and status = 'cancelled') = 1, 'pending request cancelled');
select pg_temp.ok((select count(*) from public.notifications where category = 'REVOKED') = 1, 'holder told of revocation');

-- Keyholder may resign once nothing is locked.
select pg_temp.as_user(:'tom');
select ended_reason as resign_reason from public.end_key((select id from public.keys where status = 'active' and holder_id = :'tom')) \gset
select pg_temp.ok(:'resign_reason' = 'holder_resigned', 'holder resigned');

-- Unauthenticated callers are rejected.
select pg_temp.as_nobody();
select pg_temp.assert_raises('select public.me_snapshot()', 'not authenticated');
select pg_temp.assert_raises('select public.start_break_glass()', 'not authenticated');

-- RLS: a stranger sees nothing, a holder sees their person --------------------------
set role authenticated;
select pg_temp.as_user(:'tom');
select pg_temp.ok((select count(*) from public.blocks where user_id = :'marc') = 0, 'rls: stranger cannot read marc');
select pg_temp.ok((select count(*) from public.blocks where user_id = :'sarah') = 2, 'rls: former holder still sees sarah history');
select pg_temp.ok((select count(*) from public.profiles) = 2, 'rls: self plus related only');
select pg_temp.assert_raises('select public.cron_tick()', 'permission denied');
select pg_temp.assert_raises($$select public.device_event('x', 'heartbeat', '{}')$$, 'permission denied');
reset role;

select 'scenario ok';
