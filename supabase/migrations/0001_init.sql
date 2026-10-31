-- Keyholder v1 schema, logic, and policies.
-- All client writes go through security-definer RPCs so invariants hold.
-- Tested against Postgres 16 with a stubbed auth schema (see scripts/test_schema.sh).

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
create type public.invite_mode       as enum ('hold_mine', 'i_hold_yours', 'mutual');
create type public.key_status        as enum ('active', 'ended');
create type public.block_status      as enum ('active', 'ended');
create type public.block_end_reason  as enum ('holder_ended', 'break_glass', 'revoked', 'orphaned');
create type public.request_status    as enum ('pending', 'approved', 'denied', 'cancelled', 'expired');
create type public.request_decision  as enum ('approved_timed', 'approved_end', 'denied');

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------
create table public.profiles (
  id            uuid primary key references auth.users (id) on delete cascade,
  display_name  text not null,
  created_at    timestamptz not null default now()
);

create table public.streaks (
  user_id           uuid primary key references public.profiles (id) on delete cascade,
  started_at        timestamptz,                       -- null = no streak running
  paused_seconds    double precision not null default 0,
  pause_started_at  timestamptz,                       -- open pause window start
  pause_until       timestamptz,                       -- null while pause is open-ended (orphan grace)
  best_seconds      double precision not null default 0,
  grace_until       timestamptz,                       -- orphaned: re-lock before this to resume
  updated_at        timestamptz not null default now()
);

create table public.devices (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid not null references public.profiles (id) on delete cascade,
  apns_token         text,
  device_secret      text not null unique default encode(gen_random_bytes(32), 'hex'),
  last_heartbeat_at  timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);
create index devices_user_idx on public.devices (user_id);

create table public.invites (
  code         text primary key,
  inviter_id   uuid not null references public.profiles (id) on delete cascade,
  mode         public.invite_mode not null,
  created_at   timestamptz not null default now(),
  expires_at   timestamptz not null default now() + interval '7 days',
  accepted_by  uuid references public.profiles (id),
  accepted_at  timestamptz
);

create table public.keys (
  id            uuid primary key default gen_random_uuid(),
  holder_id     uuid not null references public.profiles (id) on delete cascade,
  locked_id     uuid not null references public.profiles (id) on delete cascade,
  status        public.key_status not null default 'active',
  created_at    timestamptz not null default now(),
  ended_at      timestamptz,
  ended_reason  text,
  check (holder_id <> locked_id)
);
-- v1: exactly one keyholder per locked person.
create unique index keys_one_active_per_locked on public.keys (locked_id) where status = 'active';
create index keys_holder_idx on public.keys (holder_id);

create table public.blocks (
  id                      uuid primary key default gen_random_uuid(),
  user_id                 uuid not null references public.profiles (id) on delete cascade,
  key_id                  uuid not null references public.keys (id),
  status                  public.block_status not null default 'active',
  cooling_off_hours       int not null check (cooling_off_hours between 12 and 72),
  app_count               int not null default 0,
  category_count          int not null default 0,
  started_at              timestamptz not null default now(),
  ended_at                timestamptz,
  ended_reason            public.block_end_reason,
  unlock_until            timestamptz,        -- current approved temporary unlock, if any
  break_glass_started_at  timestamptz,
  break_glass_ends_at     timestamptz,
  last_heartbeat_at       timestamptz not null default now(),
  verified                boolean not null default true,
  heartbeat_alerted       boolean not null default false
);
create unique index blocks_one_active_per_user on public.blocks (user_id) where status = 'active';
create index blocks_break_glass_due_idx on public.blocks (break_glass_ends_at) where status = 'active' and break_glass_ends_at is not null;

create table public.unlock_requests (
  id                 uuid primary key default gen_random_uuid(),
  block_id           uuid not null references public.blocks (id) on delete cascade,
  requester_id       uuid not null references public.profiles (id) on delete cascade,
  holder_id          uuid not null references public.profiles (id) on delete cascade,
  requested_minutes  int,
  status             public.request_status not null default 'pending',
  decision           public.request_decision,
  approved_minutes   int,
  unlock_until       timestamptz,
  created_at         timestamptz not null default now(),
  decided_at         timestamptz
);
create index unlock_requests_holder_pending_idx on public.unlock_requests (holder_id) where status = 'pending';
create index unlock_requests_block_idx on public.unlock_requests (block_id);

create table public.events (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  block_id    uuid references public.blocks (id) on delete set null,
  type        text not null,
  payload     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index events_user_idx on public.events (user_id, created_at desc);

-- Outbox. A Database Webhook on insert calls the send-push edge function.
create table public.notifications (
  id          bigserial primary key,
  user_id     uuid not null references public.profiles (id) on delete cascade,
  title       text not null,
  body        text not null,
  category    text not null,
  data        jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz
);

-- ---------------------------------------------------------------------------
-- Profile bootstrap on sign-up
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    coalesce(
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'name', ''),
      'Someone'
    )
  );
  insert into public.streaks (user_id) values (new.id);
  return new;
end $$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Internal helpers (not exposed)
-- ---------------------------------------------------------------------------
create or replace function public._require_user()
returns uuid language plpgsql stable as $$
declare v uuid := auth.uid();
begin
  if v is null then raise exception 'not authenticated' using errcode = '42501';
  end if;
  return v;
end $$;

create or replace function public._name(p_user uuid)
returns text language sql stable as $$
  select display_name from public.profiles where id = p_user
$$;

create or replace function public._event(p_user uuid, p_block uuid, p_type text, p_payload jsonb default '{}'::jsonb)
returns void language sql as $$
  insert into public.events (user_id, block_id, type, payload) values (p_user, p_block, p_type, p_payload)
$$;

create or replace function public._notify(p_user uuid, p_title text, p_body text, p_category text, p_data jsonb default '{}'::jsonb)
returns void language sql as $$
  insert into public.notifications (user_id, title, body, category, data) values (p_user, p_title, p_body, p_category, p_data)
$$;

-- Streak arithmetic -----------------------------------------------------------

create or replace function public.streak_seconds(s public.streaks, p_now timestamptz default now())
returns double precision language sql stable as $$
  select case
    when s.started_at is null then 0
    when s.grace_until is not null and s.grace_until <= p_now then 0
    else greatest(0,
      extract(epoch from (p_now - s.started_at))
      - s.paused_seconds
      - case when s.pause_started_at is not null
             then extract(epoch from (least(p_now, coalesce(s.pause_until, p_now)) - s.pause_started_at))
             else 0 end)
  end
$$;

-- Fold a finished pause window into paused_seconds; drop an expired grace.
create or replace function public._streak_settle(p_user uuid, p_now timestamptz default now())
returns void language plpgsql as $$
begin
  update public.streaks
     set paused_seconds   = paused_seconds + extract(epoch from (pause_until - pause_started_at)),
         pause_started_at = null,
         pause_until      = null,
         updated_at       = p_now
   where user_id = p_user and pause_until is not null and pause_until <= p_now;

  update public.streaks
     set started_at = null, paused_seconds = 0, pause_started_at = null, pause_until = null,
         grace_until = null, updated_at = p_now
   where user_id = p_user and grace_until is not null and grace_until <= p_now;
end $$;

create or replace function public._streak_pause(p_user uuid, p_until timestamptz, p_now timestamptz default now())
returns void language plpgsql as $$
begin
  perform public._streak_settle(p_user, p_now);
  update public.streaks
     set pause_started_at = coalesce(pause_started_at, p_now),
         pause_until      = greatest(coalesce(pause_until, p_until), p_until),
         updated_at       = p_now
   where user_id = p_user and started_at is not null;
end $$;

create or replace function public._streak_reset(p_user uuid, p_now timestamptz default now())
returns void language plpgsql as $$
declare s public.streaks;
begin
  perform public._streak_settle(p_user, p_now);
  select * into s from public.streaks where user_id = p_user;
  update public.streaks
     set best_seconds     = greatest(best_seconds, public.streak_seconds(s, p_now)),
         started_at       = null,
         paused_seconds   = 0,
         pause_started_at = null,
         pause_until      = null,
         grace_until      = null,
         updated_at       = p_now
   where user_id = p_user;
end $$;

-- Start fresh, or resume if inside an orphan grace window.
create or replace function public._streak_start(p_user uuid, p_now timestamptz default now())
returns void language plpgsql as $$
declare s public.streaks;
begin
  perform public._streak_settle(p_user, p_now);
  select * into s from public.streaks where user_id = p_user;
  if s.started_at is not null and s.grace_until is not null and s.grace_until > p_now
     and s.pause_started_at is not null and s.pause_until is null then
    update public.streaks
       set paused_seconds   = paused_seconds + extract(epoch from (p_now - pause_started_at)),
           pause_started_at = null,
           pause_until      = null,
           grace_until      = null,
           updated_at       = p_now
     where user_id = p_user;
  else
    update public.streaks
       set started_at = p_now, paused_seconds = 0, pause_started_at = null, pause_until = null,
           grace_until = null, updated_at = p_now
     where user_id = p_user;
  end if;
end $$;

-- Partner broke glass: keep the streak alive, open-ended pause, 24h to re-lock.
create or replace function public._streak_orphan(p_user uuid, p_now timestamptz default now())
returns void language plpgsql as $$
declare s public.streaks;
begin
  perform public._streak_settle(p_user, p_now);
  select * into s from public.streaks where user_id = p_user;
  if s.started_at is null then return; end if;
  update public.streaks
     set best_seconds     = greatest(best_seconds, public.streak_seconds(s, p_now)),
         pause_started_at = coalesce(pause_started_at, p_now),
         pause_until      = null,
         grace_until      = p_now + interval '24 hours',
         updated_at       = p_now
   where user_id = p_user;
end $$;

-- Block lifecycle ---------------------------------------------------------------

create or replace function public._active_block(p_user uuid)
returns public.blocks language sql stable as $$
  select * from public.blocks where user_id = p_user and status = 'active'
$$;

create or replace function public._holder_of_block(p_block public.blocks)
returns uuid language sql stable as $$
  select holder_id from public.keys where id = p_block.key_id
$$;

create or replace function public._end_block(p_block_id uuid, p_reason public.block_end_reason, p_now timestamptz default now())
returns public.blocks language plpgsql as $$
declare b public.blocks;
begin
  update public.blocks
     set status = 'ended', ended_at = p_now, ended_reason = p_reason,
         unlock_until = null, break_glass_started_at = null, break_glass_ends_at = null
   where id = p_block_id and status = 'active'
   returning * into b;
  if b.id is null then raise exception 'block not active'; end if;

  update public.unlock_requests set status = 'cancelled', decided_at = p_now
   where block_id = p_block_id and status = 'pending';

  perform public._event(b.user_id, b.id, 'block_ended', jsonb_build_object('reason', p_reason));
  return b;
end $$;

create or replace function public._request_unlock(p_user uuid, p_minutes int, p_source text default 'app')
returns public.unlock_requests language plpgsql as $$
declare b public.blocks; r public.unlock_requests; v_holder uuid;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if p_minutes is not null and (p_minutes < 15 or p_minutes > 1440) then
    raise exception 'minutes must be between 15 and 1440';
  end if;

  -- Idempotent: a pending request already exists, return it.
  select * into r from public.unlock_requests where block_id = b.id and status = 'pending' limit 1;
  if r.id is not null then return r; end if;

  v_holder := public._holder_of_block(b);
  insert into public.unlock_requests (block_id, requester_id, holder_id, requested_minutes)
  values (b.id, p_user, v_holder, p_minutes) returning * into r;

  perform public._event(p_user, b.id, 'unlock_requested', jsonb_build_object('minutes', p_minutes, 'source', p_source));
  perform public._notify(
    v_holder,
    public._name(p_user) || ' is asking for time',
    case when p_minutes is null then 'They want to be unlocked.'
         else 'They are asking for ' || p_minutes || ' minutes.' end,
    'UNLOCK_REQUEST',
    jsonb_build_object('request_id', r.id, 'requester_id', p_user, 'requested_minutes', p_minutes)
  );
  return r;
end $$;

create or replace function public._heartbeat(p_user uuid, p_authorized boolean, p_shielded boolean, p_now timestamptz default now())
returns void language plpgsql as $$
declare b public.blocks;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then return; end if;
  if not p_authorized then
    perform public._report_revocation(p_user, p_now);
    return;
  end if;
  update public.blocks
     set last_heartbeat_at = p_now, verified = true, heartbeat_alerted = false
   where id = b.id;
end $$;

create or replace function public._report_revocation(p_user uuid, p_now timestamptz default now())
returns void language plpgsql as $$
declare b public.blocks; v_holder uuid;
begin
  select * into b from public.blocks where user_id = p_user and status = 'active' for update;
  if b.id is null then return; end if;
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

create or replace function public._complete_break_glass(p_block_id uuid, p_now timestamptz default now())
returns public.blocks language plpgsql as $$
declare b public.blocks; v_holder uuid; partner_block public.blocks; v_name text;
begin
  select * into b from public.blocks where id = p_block_id and status = 'active' for update;
  if b.id is null then raise exception 'block not active'; end if;
  if b.break_glass_ends_at is null or b.break_glass_ends_at > p_now then
    raise exception 'break glass not due';
  end if;

  v_holder := public._holder_of_block(b);
  v_name := public._name(b.user_id);

  b := public._end_block(b.id, 'break_glass', p_now);
  perform public._streak_reset(b.user_id, p_now);
  perform public._event(b.user_id, b.id, 'break_glass_completed');

  -- Dissolve the relationship in both directions.
  update public.keys
     set status = 'ended', ended_at = p_now, ended_reason = 'break_glass'
   where status = 'active'
     and ((holder_id = v_holder and locked_id = b.user_id) or (holder_id = b.user_id and locked_id = v_holder));

  -- Mutual pact: the partner is left without a keyholder. Lift their block, keep their streak on grace.
  select bl.* into partner_block
    from public.blocks bl join public.keys k on k.id = bl.key_id
   where bl.user_id = v_holder and bl.status = 'active' and k.holder_id = b.user_id
   for update;
  if partner_block.id is not null then
    perform public._end_block(partner_block.id, 'orphaned', p_now);
    perform public._streak_orphan(v_holder, p_now);
    perform public._notify(v_holder, 'Your block was lifted',
      v_name || ' broke glass, so nobody holds your key. Re-lock with a new keyholder within 24 hours to keep your streak.',
      'BLOCK_ENDED', jsonb_build_object('reason', 'orphaned'));
  end if;

  perform public._notify(v_holder, v_name || '''s block ended', 'Break Glass completed. You no longer hold their key.',
    'BREAK_GLASS_COMPLETED', jsonb_build_object('user_id', b.user_id));
  perform public._notify(b.user_id, 'Your block has ended', 'Break Glass completed. Your streak reset.',
    'BLOCK_ENDED', jsonb_build_object('reason', 'break_glass'));
  return b;
end $$;

-- ---------------------------------------------------------------------------
-- Public RPCs (authenticated users)
-- ---------------------------------------------------------------------------

create or replace function public.create_invite(p_mode public.invite_mode)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v_code text; i int := 0;
begin
  loop
    select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', (floor(random() * 32))::int + 1, 1), '')
      into v_code from generate_series(1, 8);
    begin
      insert into public.invites (code, inviter_id, mode) values (v_code, me, p_mode);
      return v_code;
    exception when unique_violation then
      i := i + 1;
      if i > 10 then raise exception 'could not allocate invite code'; end if;
    end;
  end loop;
end $$;

-- Preview for the accept screen.
create or replace function public.get_invite(p_code text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v public.invites;
begin
  select * into v from public.invites where code = upper(trim(p_code));
  if v.code is null then raise exception 'invalid code'; end if;
  return jsonb_build_object(
    'code', v.code,
    'mode', v.mode,
    'inviter_id', v.inviter_id,
    'inviter_name', public._name(v.inviter_id),
    'usable', v.accepted_at is null and v.expires_at > now() and v.inviter_id <> me
  );
end $$;

create or replace function public.accept_invite(p_code text)
returns setof public.keys language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v public.invites; k public.keys;
begin
  select * into v from public.invites where code = upper(trim(p_code)) for update;
  if v.code is null then raise exception 'invalid code'; end if;
  if v.accepted_at is not null then raise exception 'invite already used'; end if;
  if v.expires_at <= now() then raise exception 'invite expired'; end if;
  if v.inviter_id = me then raise exception 'cannot accept your own invite'; end if;

  begin
    if v.mode in ('hold_mine', 'mutual') then
      insert into public.keys (holder_id, locked_id) values (me, v.inviter_id) returning * into k;
      return next k;
    end if;
    if v.mode in ('i_hold_yours', 'mutual') then
      insert into public.keys (holder_id, locked_id) values (v.inviter_id, me) returning * into k;
      return next k;
    end if;
  exception when unique_violation then
    raise exception 'someone already holds that key';
  end;

  update public.invites set accepted_by = me, accepted_at = now() where code = v.code;
  perform public._event(me, null, 'invite_accepted', jsonb_build_object('inviter_id', v.inviter_id, 'mode', v.mode));
  perform public._notify(v.inviter_id, public._name(me) || ' accepted your invite',
    case v.mode
      when 'hold_mine' then 'They now hold your key.'
      when 'i_hold_yours' then 'You now hold their key.'
      else 'You are in a mutual pact.' end,
    'INVITE_ACCEPTED', jsonb_build_object('user_id', me, 'mode', v.mode));
  return;
end $$;

create or replace function public.end_key(p_key_id uuid)
returns public.keys language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); k public.keys; other uuid;
begin
  select * into k from public.keys where id = p_key_id and status = 'active' for update;
  if k.id is null then raise exception 'key not active'; end if;
  if me <> k.holder_id and me <> k.locked_id then raise exception 'not your key'; end if;
  if exists (select 1 from public.blocks where key_id = k.id and status = 'active') then
    raise exception 'cannot end a key while a block is active';
  end if;
  update public.keys
     set status = 'ended', ended_at = now(),
         ended_reason = case when me = k.holder_id then 'holder_resigned' else 'locked_removed' end
   where id = k.id returning * into k;
  other := case when me = k.holder_id then k.locked_id else k.holder_id end;
  perform public._notify(other, public._name(me) ||
    case when me = k.holder_id then ' no longer holds your key' else ' removed you as keyholder' end,
    'Nothing is blocked right now.', 'KEY_ENDED', jsonb_build_object('key_id', k.id));
  return k;
end $$;

create or replace function public.start_block(p_cooling_off_hours int, p_app_count int, p_category_count int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); k public.keys; b public.blocks;
begin
  select * into k from public.keys where locked_id = me and status = 'active';
  if k.id is null then raise exception 'nobody holds your key'; end if;
  if exists (select 1 from public.blocks where user_id = me and status = 'active') then
    raise exception 'already locked';
  end if;
  if coalesce(p_app_count, 0) + coalesce(p_category_count, 0) <= 0 then
    raise exception 'nothing selected';
  end if;
  if p_cooling_off_hours not between 12 and 72 then
    raise exception 'cooling off must be between 12 and 72 hours';
  end if;

  insert into public.blocks (user_id, key_id, cooling_off_hours, app_count, category_count)
  values (me, k.id, p_cooling_off_hours, coalesce(p_app_count, 0), coalesce(p_category_count, 0))
  returning * into b;

  perform public._streak_start(me);
  perform public._event(me, b.id, 'block_started', jsonb_build_object(
    'cooling_off_hours', p_cooling_off_hours, 'app_count', p_app_count, 'category_count', p_category_count));
  perform public._notify(k.holder_id, public._name(me) || ' locked their phone',
    'You hold the key. ' || coalesce(p_app_count, 0) || ' apps, ' || coalesce(p_category_count, 0) || ' categories.',
    'BLOCK_STARTED', jsonb_build_object('user_id', me, 'block_id', b.id));
  return b;
end $$;

create or replace function public.lengthen_cooling_off(p_hours int)
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks;
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if p_hours <= b.cooling_off_hours then raise exception 'can only lengthen cooling off'; end if;
  if p_hours > 72 then raise exception 'maximum is 72 hours'; end if;
  update public.blocks set cooling_off_hours = p_hours where id = b.id returning * into b;
  perform public._event(me, b.id, 'cooling_off_lengthened', jsonb_build_object('hours', p_hours));
  return b;
end $$;

create or replace function public.request_unlock(p_minutes int default null)
returns public.unlock_requests language plpgsql security definer set search_path = public as $$
begin
  return public._request_unlock(public._require_user(), p_minutes, 'app');
end $$;

-- Shared by decide_unlock (answering a request) and holder_unlock (keyholder acts first).
create or replace function public._apply_decision(p_request_id uuid, p_decision public.request_decision, p_minutes int, p_now timestamptz default now())
returns public.unlock_requests language plpgsql as $$
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
      'You have ' || p_minutes || ' minutes. The block comes back on its own.',
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

create or replace function public.decide_unlock(p_request_id uuid, p_decision public.request_decision, p_minutes int default null)
returns public.unlock_requests language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); r public.unlock_requests; b public.blocks; v_now timestamptz := now();
begin
  select * into r from public.unlock_requests where id = p_request_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  if r.holder_id <> me then raise exception 'not your key'; end if;
  if r.status <> 'pending' then raise exception 'request already decided'; end if;

  select * into b from public.blocks where id = r.block_id for update;
  if b.status <> 'active' then
    update public.unlock_requests set status = 'cancelled', decided_at = v_now where id = r.id;
    raise exception 'block already ended';
  end if;

  return public._apply_decision(r.id, p_decision, p_minutes, v_now);
end $$;

-- Keyholder gives time without being asked (e.g. to cut a Break Glass wait short).
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

  -- Fold a pending request into this decision rather than leaving it dangling.
  select * into r from public.unlock_requests where block_id = b.id and status = 'pending' limit 1;
  if r.id is null then
    insert into public.unlock_requests (block_id, requester_id, holder_id, requested_minutes)
    values (b.id, p_locked_id, me, null) returning * into r;
    perform public._event(p_locked_id, b.id, 'holder_initiated_unlock', jsonb_build_object('request_id', r.id));
  end if;

  return public._apply_decision(r.id, p_decision, p_minutes, v_now);
end $$;

create or replace function public.start_break_glass()
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; v_holder uuid; v_now timestamptz := now();
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if b.break_glass_ends_at is not null then return b; end if;  -- idempotent

  update public.blocks
     set break_glass_started_at = v_now,
         break_glass_ends_at = v_now + make_interval(hours => b.cooling_off_hours)
   where id = b.id returning * into b;

  v_holder := public._holder_of_block(b);
  perform public._event(me, b.id, 'break_glass_started', jsonb_build_object('ends_at', b.break_glass_ends_at));
  perform public._notify(v_holder, public._name(me) || ' broke the glass',
    'Their block ends in ' || b.cooling_off_hours || ' hours unless you unlock them sooner.',
    'BREAK_GLASS_STARTED', jsonb_build_object('user_id', me, 'block_id', b.id, 'ends_at', b.break_glass_ends_at));
  return b;
end $$;

create or replace function public.cancel_break_glass()
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks; v_holder uuid;
begin
  select * into b from public.blocks where user_id = me and status = 'active' for update;
  if b.id is null then raise exception 'not locked'; end if;
  if b.break_glass_ends_at is null then return b; end if;
  update public.blocks set break_glass_started_at = null, break_glass_ends_at = null
   where id = b.id returning * into b;
  v_holder := public._holder_of_block(b);
  perform public._event(me, b.id, 'break_glass_cancelled');
  perform public._notify(v_holder, public._name(me) || ' cancelled Break Glass', 'Their block continues. Streak intact.',
    'BREAK_GLASS_CANCELLED', jsonb_build_object('user_id', me, 'block_id', b.id));
  return b;
end $$;

-- The device calls this when its local timer fires; cron also completes it.
create or replace function public.complete_break_glass()
returns public.blocks language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); b public.blocks;
begin
  select * into b from public.blocks where user_id = me and status = 'active';
  if b.id is null then raise exception 'not locked'; end if;
  return public._complete_break_glass(b.id);
end $$;

create or replace function public.report_revocation()
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._report_revocation(public._require_user());
end $$;

create or replace function public.heartbeat(p_authorized boolean, p_shielded boolean default true)
returns void language plpgsql security definer set search_path = public as $$
begin
  perform public._heartbeat(public._require_user(), p_authorized, p_shielded);
end $$;

-- Registers (or refreshes) this device and returns its row including device_secret.
create or replace function public.register_device(p_apns_token text default null, p_device_id uuid default null)
returns public.devices language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); d public.devices;
begin
  if p_device_id is not null then
    update public.devices
       set apns_token = coalesce(p_apns_token, apns_token), updated_at = now()
     where id = p_device_id and user_id = me returning * into d;
    if d.id is not null then return d; end if;
  end if;
  insert into public.devices (user_id, apns_token) values (me, p_apns_token) returning * into d;
  return d;
end $$;

create or replace function public.update_display_name(p_name text)
returns public.profiles language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); p public.profiles;
begin
  if length(trim(p_name)) < 1 or length(trim(p_name)) > 40 then raise exception 'name must be 1 to 40 characters'; end if;
  update public.profiles set display_name = trim(p_name) where id = me returning * into p;
  return p;
end $$;

-- Everything the home screen needs in one round trip.
create or replace function public.me_snapshot()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v_now timestamptz := now(); held jsonb; r record;
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
                            where u.holder_id = me and u.requester_id = k.locked_id and u.status = 'pending'
                            order by u.created_at desc limit 1),
      'requests_this_week', (select count(*) from public.unlock_requests u
                               where u.requester_id = k.locked_id and u.created_at > v_now - interval '7 days')
    ) order by k.created_at), '[]'::jsonb)
    into held
    from public.keys k join public.profiles p on p.id = k.locked_id
   where k.holder_id = me and k.status = 'active';

  return jsonb_build_object(
    'server_time', v_now,
    'me', (select to_jsonb(p) from public.profiles p where p.id = me),
    'streak', (select to_jsonb(s) from public.streaks s where s.user_id = me),
    'block', (select to_jsonb(b) from public.blocks b where b.user_id = me and b.status = 'active'),
    'keyholder', (select jsonb_build_object('key', to_jsonb(k), 'profile', to_jsonb(p))
                    from public.keys k join public.profiles p on p.id = k.holder_id
                   where k.locked_id = me and k.status = 'active'),
    'my_pending_request', (select to_jsonb(u) from public.unlock_requests u
                             where u.requester_id = me and u.status = 'pending' order by u.created_at desc limit 1),
    'held', held
  );
end $$;

-- ---------------------------------------------------------------------------
-- Service-role RPCs (edge functions, cron)
-- ---------------------------------------------------------------------------

-- Extensions have no user JWT; they authenticate with the per-device secret via the device-event edge function.
create or replace function public.device_event(p_secret text, p_type text, p_payload jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare d public.devices; r public.unlock_requests;
begin
  select * into d from public.devices where device_secret = p_secret;
  if d.id is null then raise exception 'unknown device' using errcode = '42501'; end if;
  update public.devices set last_heartbeat_at = now(), updated_at = now() where id = d.id;

  if p_type = 'heartbeat' then
    perform public._heartbeat(d.user_id,
      coalesce((p_payload ->> 'authorized')::boolean, true),
      coalesce((p_payload ->> 'shielded')::boolean, true));
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

create or replace function public.cron_tick()
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_now timestamptz := now(); r record; completed int := 0; flagged int := 0; expired int := 0;
begin
  for r in select id from public.blocks where status = 'active' and break_glass_ends_at is not null and break_glass_ends_at <= v_now loop
    begin
      perform public._complete_break_glass(r.id, v_now);
      completed := completed + 1;
    exception when others then
      perform public._event((select user_id from public.blocks where id = r.id), r.id, 'cron_error', jsonb_build_object('message', sqlerrm));
    end;
  end loop;

  -- Missed heartbeat: mark unverified and tell the keyholder once.
  for r in select b.*, public._holder_of_block(b) as holder_id
             from public.blocks b
            where b.status = 'active' and b.last_heartbeat_at < v_now - interval '12 hours' and not b.heartbeat_alerted loop
    update public.blocks set verified = false, heartbeat_alerted = true where id = r.id;
    perform public._notify(r.holder_id, public._name(r.user_id) || '''s phone has gone quiet',
      'No check-in for 12 hours. Their streak is unverified until the app opens again.',
      'HEARTBEAT_MISSED', jsonb_build_object('user_id', r.user_id, 'block_id', r.id));
    flagged := flagged + 1;
  end loop;

  update public.unlock_requests set status = 'expired', decided_at = v_now
   where status = 'pending' and created_at < v_now - interval '24 hours';
  get diagnostics expired = row_count;

  return jsonb_build_object('completed_break_glass', completed, 'flagged_heartbeats', flagged, 'expired_requests', expired);
end $$;

-- ---------------------------------------------------------------------------
-- Row level security (reads only; writes go through RPCs)
-- ---------------------------------------------------------------------------
create or replace function public.is_holder_of(p_locked uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.keys where holder_id = auth.uid() and locked_id = p_locked)
$$;

create or replace function public.is_related_to(p_user uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select p_user = auth.uid() or exists (
    select 1 from public.keys
     where (holder_id = auth.uid() and locked_id = p_user) or (locked_id = auth.uid() and holder_id = p_user))
$$;

alter table public.profiles        enable row level security;
alter table public.streaks         enable row level security;
alter table public.devices         enable row level security;
alter table public.invites         enable row level security;
alter table public.keys            enable row level security;
alter table public.blocks          enable row level security;
alter table public.unlock_requests enable row level security;
alter table public.events          enable row level security;
alter table public.notifications   enable row level security;

create policy profiles_select on public.profiles for select to authenticated using (public.is_related_to(id));
create policy streaks_select  on public.streaks  for select to authenticated using (user_id = auth.uid() or public.is_holder_of(user_id));
create policy devices_own     on public.devices  for all    to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy invites_select  on public.invites  for select to authenticated using (inviter_id = auth.uid());
create policy keys_select     on public.keys     for select to authenticated using (holder_id = auth.uid() or locked_id = auth.uid());
create policy blocks_select   on public.blocks   for select to authenticated using (user_id = auth.uid() or public.is_holder_of(user_id));
create policy requests_select on public.unlock_requests for select to authenticated using (requester_id = auth.uid() or holder_id = auth.uid());
create policy events_select   on public.events   for select to authenticated using (user_id = auth.uid() or public.is_holder_of(user_id));
create policy notifs_select   on public.notifications for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Grants: lock internal helpers down, expose RPCs to the right roles
-- ---------------------------------------------------------------------------
-- Supabase grants these by default; stated explicitly so behaviour does not
-- depend on platform defaults. RLS still gates every row.
grant usage on schema public to anon, authenticated, service_role;
grant select on all tables in schema public to authenticated;
grant all on public.devices to authenticated;
grant all on all tables in schema public to service_role;
grant usage, select on all sequences in schema public to service_role;

revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function
  public.create_invite(public.invite_mode),
  public.get_invite(text),
  public.accept_invite(text),
  public.end_key(uuid),
  public.start_block(int, int, int),
  public.lengthen_cooling_off(int),
  public.request_unlock(int),
  public.decide_unlock(uuid, public.request_decision, int),
  public.holder_unlock(uuid, public.request_decision, int),
  public.start_break_glass(),
  public.cancel_break_glass(),
  public.complete_break_glass(),
  public.report_revocation(),
  public.heartbeat(boolean, boolean),
  public.register_device(text, uuid),
  public.update_display_name(text),
  public.me_snapshot(),
  public.streak_seconds(public.streaks, timestamptz),
  public.is_holder_of(uuid),
  public.is_related_to(uuid)
to authenticated;

grant execute on function public.device_event(text, text, jsonb), public.cron_tick() to service_role;

-- ---------------------------------------------------------------------------
-- Realtime + cron (no-ops outside Supabase)
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.unlock_requests, public.blocks, public.keys, public.streaks;
  end if;
end $$;

do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('keyholder_tick', '* * * * *', 'select public.cron_tick()');
exception when others then
  raise notice 'pg_cron not available here (%). Enable it on Supabase and run: select cron.schedule(''keyholder_tick'', ''* * * * *'', ''select public.cron_tick()'');', sqlerrm;
end $$;
