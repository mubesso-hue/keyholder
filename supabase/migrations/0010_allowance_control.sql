-- The keyholder controls the daily allowance.
--
-- The keyholder can set it to any size at any time. The locked person can turn
-- it down or off themselves, and can ask for more, which the keyholder approves
-- or declines (like asking for time). Changes reach the phone through the
-- block's allowance_minutes; allowance_set_at says which change is newest.

alter table public.blocks add column if not exists allowance_set_at timestamptz;

create table if not exists public.allowance_requests (
  id           uuid primary key default gen_random_uuid(),
  block_id     uuid not null references public.blocks (id) on delete cascade,
  requester_id uuid not null references public.profiles (id) on delete cascade,
  holder_id    uuid not null references public.profiles (id) on delete cascade,
  minutes      int not null check (minutes between 1 and 240),
  status       public.request_status not null default 'pending',
  created_at   timestamptz not null default now(),
  decided_at   timestamptz
);
create index if not exists allowance_requests_block_pending_idx
  on public.allowance_requests (block_id) where status = 'pending';
alter table public.allowance_requests enable row level security;
create policy allowance_requests_select on public.allowance_requests for select to authenticated
  using (requester_id = auth.uid() or holder_id = auth.uid());
grant select on public.allowance_requests to authenticated;
grant all on public.allowance_requests to service_role;

-- The locked person: choose it at Lock, then only down or off.
create or replace function public.set_block_allowance(p_minutes int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks;
begin
  if p_minutes is null or p_minutes < 0 or p_minutes > 240 then
    raise exception 'allowance must be between 0 and 240 minutes';
  end if;
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if p_minutes > b.allowance_minutes and now() - b.started_at > interval '5 minutes' then
    raise exception 'only your keyholder can give you more time';
  end if;
  update public.blocks set allowance_minutes = p_minutes, allowance_set_at = now()
   where id = b.id returning * into b;
  perform public._event(me, b.id, 'allowance_set', jsonb_build_object('minutes', p_minutes));
  return b;
end $$;

-- The keyholder sets it to any size.
create or replace function public.holder_set_allowance(p_locked_id uuid, p_minutes int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks;
begin
  if p_minutes is null or p_minutes < 0 or p_minutes > 240 then
    raise exception 'allowance must be between 0 and 240 minutes';
  end if;
  select bl.* into b
    from public.blocks bl join public.keys k on k.id = bl.key_id
   where bl.user_id = p_locked_id and bl.status = 'active' and k.holder_id = me
   for update of bl;
  if b.id is null then raise exception 'you do not hold an active block for that person'; end if;

  update public.blocks set allowance_minutes = p_minutes, allowance_set_at = now()
   where id = b.id returning * into b;
  -- A setting from the keyholder answers any open request.
  update public.allowance_requests
     set status = case when p_minutes >= minutes then 'approved'::public.request_status
                       else 'cancelled'::public.request_status end,
         decided_at = now()
   where block_id = b.id and status = 'pending';

  perform public._event(p_locked_id, b.id, 'allowance_set_by_holder', jsonb_build_object('minutes', p_minutes));
  perform public._notify(p_locked_id,
    public._name(me) || ' changed your daily allowance',
    case when p_minutes = 0 then 'Your daily allowance is off.'
         else 'It''s now ' || public._fmt_minutes(p_minutes) || ' a day.' end,
    'ALLOWANCE_CHANGED', jsonb_build_object('block_id', b.id, 'minutes', p_minutes));
  return b;
end $$;

-- The locked person asks for more. One open request at a time.
create or replace function public.request_allowance(p_minutes int)
returns public.allowance_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; r public.allowance_requests; v_holder uuid;
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if p_minutes is null or p_minutes < 1 or p_minutes > 240 then
    raise exception 'allowance must be between 1 and 240 minutes';
  end if;
  if p_minutes <= b.allowance_minutes then
    raise exception 'ask for more than you have now';
  end if;

  update public.allowance_requests set status = 'cancelled', decided_at = now()
   where block_id = b.id and status = 'pending';

  v_holder := public._holder_of_block(b);
  insert into public.allowance_requests (block_id, requester_id, holder_id, minutes)
  values (b.id, me, v_holder, p_minutes) returning * into r;

  perform public._event(me, b.id, 'allowance_requested',
    jsonb_build_object('minutes', p_minutes, 'from', b.allowance_minutes));
  perform public._notify(v_holder,
    public._name(me) || ' wants a bigger daily allowance',
    case when b.allowance_minutes = 0 then 'They are asking for ' || public._fmt_minutes(p_minutes) || ' a day.'
         else 'From ' || public._fmt_minutes(b.allowance_minutes) || ' to ' || public._fmt_minutes(p_minutes) || ' a day.' end,
    'ALLOWANCE_REQUEST', jsonb_build_object('request_id', r.id, 'requester_id', me));
  return r;
end $$;

create or replace function public.decide_allowance(p_request_id uuid, p_approve boolean)
returns public.allowance_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); r public.allowance_requests; b public.blocks; v_now timestamptz := now();
begin
  select * into r from public.allowance_requests where id = p_request_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  if r.holder_id <> me then raise exception 'not your key'; end if;
  if r.status <> 'pending' then raise exception 'request already decided'; end if;

  select * into b from public.blocks where id = r.block_id for update;
  if b.status <> 'active' then
    update public.allowance_requests set status = 'cancelled', decided_at = v_now where id = r.id;
    raise exception 'block already ended';
  end if;

  update public.allowance_requests
     set status = case when p_approve then 'approved'::public.request_status else 'denied'::public.request_status end,
         decided_at = v_now
   where id = r.id returning * into r;

  if p_approve then
    update public.blocks set allowance_minutes = r.minutes, allowance_set_at = v_now where id = b.id;
    perform public._event(r.requester_id, b.id, 'allowance_approved', jsonb_build_object('minutes', r.minutes));
    perform public._notify(r.requester_id, public._name(me) || ' approved your allowance',
      'It''s now ' || public._fmt_minutes(r.minutes) || ' a day.',
      'ALLOWANCE_CHANGED', jsonb_build_object('block_id', b.id, 'minutes', r.minutes));
  else
    perform public._event(r.requester_id, b.id, 'allowance_denied', jsonb_build_object('minutes', r.minutes));
    perform public._notify(r.requester_id, public._name(me) || ' said no to more allowance',
      case when b.allowance_minutes = 0 then 'You have no daily allowance.'
           else 'It stays at ' || public._fmt_minutes(b.allowance_minutes) || ' a day.' end,
      'ALLOWANCE_DECIDED', jsonb_build_object('request_id', r.id, 'approved', false));
  end if;
  return r;
end $$;

create or replace function public.cancel_allowance_request()
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user();
begin
  update public.allowance_requests set status = 'cancelled', decided_at = now()
   where requester_id = me and status = 'pending';
end $$;

-- Snapshot: open allowance requests on both sides. Otherwise as in 0008.
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
      'profile', public._profile_for(me, p),
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
      'pending_allowance', (select to_jsonb(a) from public.allowance_requests a
                              join public.blocks b on b.id = a.block_id and b.status = 'active'
                             where a.holder_id = me and a.requester_id = k.locked_id and a.status = 'pending'
                             order by a.created_at desc limit 1),
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
    'keyholder', (select jsonb_build_object('key', to_jsonb(k), 'profile', public._profile_for(me, p))
                    from public.keys k join public.profiles p on p.id = k.holder_id
                   where k.locked_id = me and k.status = 'active'),
    'my_pending_request', (select to_jsonb(u) from public.unlock_requests u
                             where u.requester_id = me and u.status = 'pending' and u.kind = 'time'
                             order by u.created_at desc limit 1),
    'my_app_change', (select to_jsonb(u) from public.unlock_requests u
                        where u.requester_id = me and u.kind = 'apps' and u.block_id = v_block_id
                        order by u.created_at desc limit 1),
    'my_allowance_request', (select to_jsonb(a) from public.allowance_requests a
                               where a.requester_id = me and a.status = 'pending' and a.block_id = v_block_id
                               order by a.created_at desc limit 1),
    'held', held
  );
end $$;

grant execute on function
  public.holder_set_allowance(uuid, int),
  public.request_allowance(int),
  public.decide_allowance(uuid, boolean),
  public.cancel_allowance_request()
to authenticated;
