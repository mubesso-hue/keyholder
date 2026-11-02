-- History for the key detail page: what happened under my key this week.
--
-- Only the keyholder can read it, and only for blocks held under their own
-- key and requests sent to them.
create or replace function public.key_history(p_locked_id uuid)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := public._require_user(); v_since timestamptz := now() - interval '7 days';
begin
  if not exists (select 1 from public.keys where holder_id = me and locked_id = p_locked_id) then
    raise exception 'you do not hold that key';
  end if;

  return jsonb_build_object(
    'since', v_since,
    -- Requests they made. Time the keyholder gave unasked is created and
    -- decided in the same moment, so it isn't counted as a request.
    'requests', (select count(*) from public.unlock_requests u
                  where u.requester_id = p_locked_id and u.holder_id = me and u.kind = 'time'
                    and u.created_at > v_since
                    and (u.decided_at is null or u.decided_at <> u.created_at)),
    'given', (select count(*) from public.unlock_requests u
               where u.requester_id = p_locked_id and u.holder_id = me
                 and u.decision = 'approved_timed' and u.created_at > v_since),
    'unlocked_minutes', (select coalesce(sum(u.approved_minutes), 0) from public.unlock_requests u
                          where u.requester_id = p_locked_id and u.holder_id = me
                            and u.decision = 'approved_timed' and u.created_at > v_since),
    'requests_list', (select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at desc), '[]'::jsonb)
                        from (select * from public.unlock_requests u
                               where u.requester_id = p_locked_id and u.holder_id = me and u.created_at > v_since
                               order by u.created_at desc limit 20) x),
    'blocks', (select coalesce(jsonb_agg(jsonb_build_object(
                  'started_at', x.started_at, 'ended_at', x.ended_at, 'ended_reason', x.ended_reason,
                  'mode', x.mode, 'allowed_count', x.allowed_count,
                  'app_count', x.app_count, 'category_count', x.category_count) order by x.started_at desc), '[]'::jsonb)
                 from (select b.* from public.blocks b join public.keys k on k.id = b.key_id
                        where b.user_id = p_locked_id and k.holder_id = me
                          and (b.started_at > v_since or b.ended_at > v_since or b.status = 'active')
                        order by b.started_at desc limit 10) x),
    'last_block', (select jsonb_build_object('started_at', b.started_at, 'ended_at', b.ended_at,
                                             'ended_reason', b.ended_reason)
                     from public.blocks b join public.keys k on k.id = b.key_id
                    where b.user_id = p_locked_id and k.holder_id = me and b.status = 'ended'
                    order by b.ended_at desc limit 1)
  );
end $$;

grant execute on function public.key_history(uuid) to authenticated;
