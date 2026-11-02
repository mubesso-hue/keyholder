-- 1. Nicknames: call the people you are tied to whatever you like.
--
-- A nickname is private to the person who set it. The app shows it in place of
-- the other person's Apple name, and push notifications use it too.
-- (Clearing a nickname stores null rather than deleting the row.)
create table if not exists public.nicknames (
  owner_id   uuid not null references public.profiles (id) on delete cascade,
  target_id  uuid not null references public.profiles (id) on delete cascade,
  name       text check (name is null or char_length(name) between 1 and 40),
  updated_at timestamptz not null default now(),
  primary key (owner_id, target_id)
);
alter table public.nicknames enable row level security;
create policy nicknames_own on public.nicknames for select to authenticated using (owner_id = auth.uid());
grant select on public.nicknames to authenticated;
grant all on public.nicknames to service_role;

create or replace function public.set_nickname(p_target uuid, p_name text)
returns void language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v text := nullif(btrim(coalesce(p_name, '')), '');
begin
  if p_target = me then raise exception 'change your own name in Settings'; end if;
  if not exists (select 1 from public.keys
                  where (holder_id = me and locked_id = p_target) or (holder_id = p_target and locked_id = me)) then
    raise exception 'you are not connected to that person';
  end if;
  v := left(v, 40);
  insert into public.nicknames (owner_id, target_id, name) values (me, p_target, v)
  on conflict (owner_id, target_id) do update set name = excluded.name, updated_at = now();
end $$;

-- A profile as one viewer sees it: display_name is their nickname for that
-- person if they set one; real_name is always the person's own name.
create or replace function public._profile_for(p_viewer uuid, p_profile public.profiles)
returns jsonb language sql stable set search_path = public as $$
  select to_jsonb(p_profile) || jsonb_build_object(
    'display_name', coalesce((select n.name from public.nicknames n
                               where n.owner_id = p_viewer and n.target_id = p_profile.id), p_profile.display_name),
    'real_name', p_profile.display_name)
$$;

-- Notifications name people the way the recipient does. Titles and bodies are
-- written with real names; swap in the recipient's nicknames, longest name first.
create or replace function public._notify(p_user uuid, p_title text, p_body text, p_category text, p_data jsonb default '{}'::jsonb)
returns void language plpgsql set search_path = public as $$
declare n record;
begin
  for n in select nk.name, p.display_name
             from public.nicknames nk join public.profiles p on p.id = nk.target_id
            where nk.owner_id = p_user and nk.name is not null
              and char_length(p.display_name) > 1 and p.display_name <> nk.name
            order by char_length(p.display_name) desc loop
    p_title := replace(p_title, n.display_name, n.name);
    p_body := replace(p_body, n.display_name, n.name);
  end loop;
  insert into public.notifications (user_id, title, body, category, data)
  values (p_user, p_title, p_body, p_category, p_data);
end $$;

-- 2. Daily allowance: a few minutes a day on chosen apps before they block.
--
-- The phone enforces it (Screen Time counts the minutes); the server records
-- the size so the keyholder can see it. It is chosen at Lock. After the first
-- few minutes of a block it can only go down: more time is the keyholder's call.
alter table public.blocks
  add column if not exists allowance_minutes int not null default 0
    check (allowance_minutes between 0 and 240);

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
  update public.blocks set allowance_minutes = p_minutes where id = b.id returning * into b;
  perform public._event(me, b.id, 'allowance_set', jsonb_build_object('minutes', p_minutes));
  return b;
end $$;

-- 3. Snapshot: profiles carry nicknames. Otherwise as in 0005.
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
    'held', held
  );
end $$;

grant execute on function public.set_nickname(uuid, text), public.set_block_allowance(int) to authenticated;
