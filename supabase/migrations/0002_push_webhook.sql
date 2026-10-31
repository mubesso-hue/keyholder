-- Deliver the notifications outbox: on insert, ask the send-push edge function
-- to deliver that row. Equivalent to a Database Webhook, expressed as SQL so it
-- lives in version control. pg_net performs the HTTP call asynchronously.
--
-- The function re-reads the row with the service role and only sends unsent
-- rows, so the body carries nothing but the id and no secret is required.

create schema if not exists extensions;

do $$
begin
  create extension if not exists pg_net with schema extensions;
exception when others then
  raise notice 'pg_net not available here (%). The push trigger will be a no-op.', sqlerrm;
end $$;

create or replace function public.notify_send_push()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  -- Outside Supabase (local tests) pg_net is absent; deliver nothing.
  if not exists (select 1 from pg_extension where extname = 'pg_net') then
    return new;
  end if;
  perform net.http_post(
    url := 'https://apatxdwaozoozkigrgbt.supabase.co/functions/v1/send-push',
    headers := '{"Content-Type": "application/json"}'::jsonb,
    body := jsonb_build_object('type', 'INSERT', 'table', 'notifications',
                               'record', jsonb_build_object('id', new.id)),
    timeout_milliseconds := 5000
  );
  return new;
end $$;

-- Only the trigger may run it; never the REST API.
revoke execute on function public.notify_send_push() from public, anon, authenticated;

drop trigger if exists notifications_send_push on public.notifications;
create trigger notifications_send_push
after insert on public.notifications
for each row execute function public.notify_send_push();
