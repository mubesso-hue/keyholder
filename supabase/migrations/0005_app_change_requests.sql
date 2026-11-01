-- Changing blocked apps while locked.
--
-- Rule: anything that makes the block stricter applies instantly on the phone.
-- Anything that opens an app up is a request the keyholder approves or declines.
--
-- Apple keeps the actual app selection on the phone as opaque tokens, so the
-- server never knows which apps change. It records counts only: how many apps
-- or categories would open up, and the resulting block size. The phone holds
-- the proposed selection and applies it once the request is approved.

alter table public.unlock_requests
  add column if not exists kind text not null default 'time' check (kind in ('time', 'apps')),
  add column if not exists change jsonb not null default '{}'::jsonb;

create index if not exists unlock_requests_block_kind_pending_idx
  on public.unlock_requests (block_id, kind) where status = 'pending';

-- "45 min", "2 h", "1 h 20 min"
create or replace function public._fmt_minutes(p_minutes int)
returns text language sql immutable set search_path = public as $$
  select case
    when p_minutes < 60 then p_minutes || ' min'
    when p_minutes % 60 = 0 then (p_minutes / 60) || ' h'
    else (p_minutes / 60) || ' h ' || (p_minutes % 60) || ' min'
  end
$$;

-- Time requests: idempotency and folding are now scoped to kind = 'time',
-- so a pending app change never blocks or absorbs a request for time.
create or replace function public._request_unlock(p_user uuid, p_minutes int, p_source text default 'app')
returns public.unlock_requests language plpgsql set search_path = public as $$
declare b public.blocks; r public.unlock_requests; v_holder uuid;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if p_minutes is not null and (p_minutes < 15 or p_minutes > 1440) then
    raise exception 'minutes must be between 15 and 1440';
  end if;

  select * into r from public.unlock_requests
   where block_id = b.id and status = 'pending' and kind = 'time' limit 1;
  if r.id is not null then return r; end if;

  v_holder := public._holder_of_block(b);
  insert into public.unlock_requests (block_id, requester_id, holder_id, requested_minutes, kind)
  values (b.id, p_user, v_holder, p_minutes, 'time') returning * into r;

  perform public._event(p_user, b.id, 'unlock_requested', jsonb_build_object('minutes', p_minutes, 'source', p_source));
  perform public._notify(
    v_holder,
    public._name(p_user) || ' is asking for time',
    case when p_minutes is null then 'They want to be unlocked.'
         else 'They are asking for ' || public._fmt_minutes(p_minutes) || '.' end,
    'UNLOCK_REQUEST',
    jsonb_build_object('request_id', r.id, 'requester_id', p_user, 'requested_minutes', p_minutes)
  );
  return r;
end $$;

create or replace function public.holder_unlock(p_locked_id uuid, p_decision public.request_decision, p_minutes int default null)
returns public.unlock_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; r public.unlock_requests; v_now timestamptz := now();
begin
  if p_decision = 'denied' then raise exception 'nothing to deny'; end if;

  select bl.* into b
    from public.blocks bl join public.keys k on k.id = bl.key_id
   where bl.user_id = p_locked_id and bl.status = 'active' and k.holder_id = me
   for update of bl;
  if b.id is null then raise exception 'you do not hold an active block for that person'; end if;

  select * into r from public.unlock_requests
   where block_id = b.id and status = 'pending' and kind = 'time' limit 1;
  if r.id is null then
    insert into public.unlock_requests (block_id, requester_id, holder_id, requested_minutes, kind)
    values (b.id, p_locked_id, me, null, 'time') returning * into r;
    perform public._event(p_locked_id, b.id, 'holder_initiated_unlock', jsonb_build_object('request_id', r.id));
  end if;

  return public._apply_decision(r.id, p_decision, p_minutes, v_now);
end $$;

-- Same as 0001, with the approved time written as "1 h 20 min".
create or replace function public._apply_decision(p_request_id uuid, p_decision public.request_decision, p_minutes int, p_now timestamptz default now())
returns public.unlock_requests language plpgsql set search_path = public as $$
declare r public.unlock_requests; b public.blocks; v_until timestamptz; v_holder_name text;
begin
  select * into r from public.unlock_requests where id = p_request_id for update;
  select * into b from public.blocks where id = r.block_id for update;
  v_holder_name := public._name(r.holder_id);

  if p_decision = 'denied' then
    update public.unlock_requests set status = 'denied', decision = 'denied', decided_at = p_now
     where id = r.id returning * into r;
    perform public._event(r.requester_id, b.id, 'unlock_denied', jsonb_build_object('request_id', r.id));
    perform public._notify(r.requester_id, v_holder_name || ' said no', 'Your block stays on.',
      'UNLOCK_DECIDED', jsonb_build_object('request_id', r.id, 'decision', 'denied'));

  elsif p_decision = 'approved_timed' then
    if p_minutes is null or p_minutes < 15 or p_minutes > 1440 then
      raise exception 'minutes must be between 15 and 1440';
    end if;
    v_until := p_now + make_interval(mins => p_minutes);
    update public.unlock_requests
       set status = 'approved', decision = 'approved_timed', approved_minutes = p_minutes,
           unlock_until = v_until, decided_at = p_now
     where id = r.id returning * into r;
    update public.blocks set unlock_until = v_until where id = b.id;
    perform public._streak_pause(r.requester_id, v_until, p_now);
    perform public._event(r.requester_id, b.id, 'unlock_approved', jsonb_build_object('request_id', r.id, 'minutes', p_minutes, 'until', v_until));
    perform public._notify(r.requester_id, v_holder_name || ' unlocked you',
      'You have ' || public._fmt_minutes(p_minutes) || '. The block comes back on its own.',
      'UNLOCK_DECIDED', jsonb_build_object('request_id', r.id, 'decision', 'approved_timed', 'unlock_until', v_until, 'block_id', b.id));

  elsif p_decision = 'approved_end' then
    update public.unlock_requests
       set status = 'approved', decision = 'approved_end', decided_at = p_now
     where id = r.id returning * into r;
    perform public._end_block(b.id, 'holder_ended', p_now);
    perform public._streak_reset(r.requester_id, p_now);
    perform public._notify(r.requester_id, v_holder_name || ' ended your block', 'Your streak reset. Lock again whenever you want.',
      'BLOCK_ENDED', jsonb_build_object('reason', 'holder_ended', 'block_id', b.id));
  end if;

  return r;
end $$;

-- decide_unlock answers time requests only.
create or replace function public.decide_unlock(p_request_id uuid, p_decision public.request_decision, p_minutes int default null)
returns public.unlock_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); r public.unlock_requests; b public.blocks; v_now timestamptz := now();
begin
  select * into r from public.unlock_requests where id = p_request_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  if r.holder_id <> me then raise exception 'not your key'; end if;
  if r.kind <> 'time' then raise exception 'not a request for time'; end if;
  if r.status <> 'pending' then raise exception 'request already decided'; end if;

  select * into b from public.blocks where id = r.block_id for update;
  if b.status <> 'active' then
    update public.unlock_requests set status = 'cancelled', decided_at = v_now where id = r.id;
    raise exception 'block already ended';
  end if;

  return public._apply_decision(r.id, p_decision, p_minutes, v_now);
end $$;

-- Locked person asks to open apps up. One pending app change per block: a new
-- one replaces the previous. p_* counts describe the block after the change.
create or replace function public.request_app_change(
  p_opened_apps int,
  p_opened_categories int,
  p_app_count int,
  p_category_count int,
  p_allowed_count int
)
returns public.unlock_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; r public.unlock_requests; v_holder uuid; v_what text;
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if coalesce(p_opened_apps, 0) + coalesce(p_opened_categories, 0) <= 0 then
    raise exception 'nothing to open up';
  end if;

  update public.unlock_requests set status = 'cancelled', decided_at = now()
   where block_id = b.id and kind = 'apps' and status = 'pending';

  v_holder := public._holder_of_block(b);
  insert into public.unlock_requests (block_id, requester_id, holder_id, kind, change)
  values (b.id, me, v_holder, 'apps', jsonb_build_object(
    'mode', b.mode,
    'opened_apps', greatest(coalesce(p_opened_apps, 0), 0),
    'opened_categories', greatest(coalesce(p_opened_categories, 0), 0),
    'app_count', greatest(coalesce(p_app_count, 0), 0),
    'category_count', greatest(coalesce(p_category_count, 0), 0),
    'allowed_count', greatest(coalesce(p_allowed_count, 0), 0)))
  returning * into r;

  v_what := public._fmt_opened(b.mode, coalesce(p_opened_apps, 0), coalesce(p_opened_categories, 0));
  perform public._event(me, b.id, 'app_change_requested', r.change);
  perform public._notify(v_holder, public._name(me) || ' wants to change their blocked apps',
    'They are asking to ' || v_what || '.',
    'APP_CHANGE_REQUEST', jsonb_build_object('request_id', r.id, 'requester_id', me));
  return r;
end $$;

-- "keep 2 more apps open", "unblock 1 app and 1 category". Matches AppChange.request in the app.
create or replace function public._fmt_opened(p_mode text, p_apps int, p_categories int)
returns text language sql immutable set search_path = public as $$
  select case
    when p_mode = 'all_except' then
      'keep ' || concat_ws(' and ',
        case when p_apps > 0 then p_apps || ' more ' || case when p_apps = 1 then 'app' else 'apps' end end,
        case when p_categories > 0 then p_categories || ' more ' || case when p_categories = 1 then 'category' else 'categories' end end)
      || ' open'
    else
      'unblock ' || concat_ws(' and ',
        case when p_apps > 0 then p_apps || ' ' || case when p_apps = 1 then 'app' else 'apps' end end,
        case when p_categories > 0 then p_categories || ' ' || case when p_categories = 1 then 'category' else 'categories' end end)
  end
$$;

create or replace function public.decide_app_change(p_request_id uuid, p_approve boolean)
returns public.unlock_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); r public.unlock_requests; b public.blocks; v_now timestamptz := now();
begin
  select * into r from public.unlock_requests where id = p_request_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  if r.holder_id <> me then raise exception 'not your key'; end if;
  if r.kind <> 'apps' then raise exception 'not an app change'; end if;
  if r.status <> 'pending' then raise exception 'request already decided'; end if;

  select * into b from public.blocks where id = r.block_id for update;
  if b.status <> 'active' then
    update public.unlock_requests set status = 'cancelled', decided_at = v_now where id = r.id;
    raise exception 'block already ended';
  end if;

  update public.unlock_requests
     set status = case when p_approve then 'approved'::public.request_status else 'denied'::public.request_status end,
         decided_at = v_now
   where id = r.id returning * into r;

  perform public._event(r.requester_id, b.id,
    case when p_approve then 'app_change_approved' else 'app_change_denied' end,
    jsonb_build_object('request_id', r.id));
  perform public._notify(r.requester_id,
    public._name(me) || case when p_approve then ' approved your app change' else ' said no to your app change' end,
    case when p_approve then 'Your apps are updated.' else 'Your blocked apps stay as they were.' end,
    'APP_CHANGE_DECIDED', jsonb_build_object('request_id', r.id, 'approved', p_approve));
  return r;
end $$;

create or replace function public.cancel_app_change()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user();
begin
  update public.unlock_requests set status = 'cancelled', decided_at = now()
   where requester_id = me and kind = 'apps' and status = 'pending';
end $$;

-- The phone reports the block's new size after applying a stricter change
-- right away, or an approved one. Counts are informational: Apple keeps the
-- apps themselves on the phone.
create or replace function public.update_block_apps(p_app_count int, p_category_count int, p_allowed_count int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks;
begin
  update public.blocks
     set app_count = greatest(coalesce(p_app_count, 0), 0),
         category_count = greatest(coalesce(p_category_count, 0), 0),
         allowed_count = greatest(coalesce(p_allowed_count, 0), 0)
   where user_id = me and status = 'active'
   returning * into b;
  if b.id is null then raise exception 'not locked'; end if;
  perform public._event(me, b.id, 'apps_changed', jsonb_build_object(
    'app_count', b.app_count, 'category_count', b.category_count, 'allowed_count', b.allowed_count));
  return b;
end $$;

-- Snapshot: time requests and app changes are reported separately.
create or replace function public.me_snapshot()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v_now timestamptz := now(); held jsonb; r record; v_block_id uuid;
begin
  perform public._streak_settle(me, v_now);
  for r in select locked_id from public.keys where holder_id = me and status = 'active' loop
    perform public._streak_settle(r.locked_id, v_now);
  end loop;

  select coalesce(jsonb_agg(jsonb_build_object(
      'key', to_jsonb(k),
      'profile', to_jsonb(p),
      'block', (select to_jsonb(b) from public.blocks b where b.user_id = k.locked_id and b.status = 'active'),
      'streak', (select to_jsonb(s) from public.streaks s where s.user_id = k.locked_id),
      'pending_request', (select to_jsonb(u) from public.unlock_requests u
                            where u.holder_id = me and u.requester_id = k.locked_id
                              and u.status = 'pending' and u.kind = 'time'
                            order by u.created_at desc limit 1),
      'pending_app_change', (select to_jsonb(u) from public.unlock_requests u
                               where u.holder_id = me and u.requester_id = k.locked_id
                                 and u.status = 'pending' and u.kind = 'apps'
                               order by u.created_at desc limit 1),
      'requests_this_week', (select count(*) from public.unlock_requests u
                               where u.requester_id = k.locked_id and u.kind = 'time'
                                 and u.created_at > v_now - interval '7 days')
    ) order by k.created_at), '[]'::jsonb)
    into held
    from public.keys k join public.profiles p on p.id = k.locked_id
   where k.holder_id = me and k.status = 'active';

  select id into v_block_id from public.blocks where user_id = me and status = 'active';

  return jsonb_build_object(
    'server_time', v_now,
    'me', (select to_jsonb(p) from public.profiles p where p.id = me),
    'streak', (select to_jsonb(s) from public.streaks s where s.user_id = me),
    'block', (select to_jsonb(b) from public.blocks b where b.id = v_block_id),
    'keyholder', (select jsonb_build_object('key', to_jsonb(k), 'profile', to_jsonb(p))
                    from public.keys k join public.profiles p on p.id = k.holder_id
                   where k.locked_id = me and k.status = 'active'),
    'my_pending_request', (select to_jsonb(u) from public.unlock_requests u
                             where u.requester_id = me and u.status = 'pending' and u.kind = 'time'
                             order by u.created_at desc limit 1),
    -- Latest app change for the current block, whatever its status, so the
    -- phone can apply an approval or drop a declined change.
    'my_app_change', (select to_jsonb(u) from public.unlock_requests u
                        where u.requester_id = me and u.kind = 'apps' and u.block_id = v_block_id
                        order by u.created_at desc limit 1),
    'held', held
  );
end $$;

-- Revoking anon access lives in 0007, applied separately.
grant execute on function
  public.request_app_change(int, int, int, int, int),
  public.decide_app_change(uuid, boolean),
  public.cancel_app_change(),
  public.update_block_apps(int, int, int)
to authenticated;
