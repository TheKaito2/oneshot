-- Hardening for training photos (security review, 22 Oct):
--   * consent times come from the server's clock, not the device's;
--   * uploads must be <shop uuid>/<uuid>.jpg|.json, at most 100 objects (50 photos + labels) per shop per day;
--   * the training-retention Edge Function removes anything older than 2 years, daily (pg_cron + pg_net).

-- Consent: the app only says whether it's withdrawing; the trigger stamps the times.
alter table public.training_consent add column withdrawing boolean not null default false;

create function public.training_consent_times() returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.withdrawing then
    new.withdrawn_at := now();
    new.granted_at := case when tg_op = 'UPDATE' then old.granted_at else now() end;
  else
    new.withdrawn_at := null;
    -- A fresh grant (first time, or after withdrawing) is stamped now; otherwise it stays as it was.
    new.granted_at := case when tg_op = 'INSERT' or old.withdrawing then now() else old.granted_at end;
  end if;
  return new;
end $$;

create trigger training_consent_times before insert or update on public.training_consent
  for each row execute function public.training_consent_times();

-- Photos a shop has added in the last day (security definer: counts regardless of the caller's own select policy).
create function public.training_frames_today(shop text) returns integer
language sql stable security definer set search_path = '' as $$
  select count(*)::integer from storage.objects
  where bucket_id = 'training-frames' and (storage.foldername(name))[1] = shop and created_at > now() - interval '1 day';
$$;
revoke all on function public.training_frames_today(text) from public, anon;
grant execute on function public.training_frames_today(text) to authenticated;

drop policy "training-frames: consenting shop insert" on storage.objects;
create policy "training-frames: consenting shop insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'training-frames'
              and name ~ '^[0-9a-f-]{36}/[0-9a-f-]{36}\.(jpg|json)$'
              and (storage.foldername(name))[1] in (
                select s.id::text from public.shops s
                join public.training_consent c on c.shop_id = s.id
                where s.owner = (select auth.uid()) and c.withdrawn_at is null)
              and public.training_frames_today((storage.foldername(name))[1]) < 100);

-- Retention: the names past 2 years, for the training-retention function (service role only).
create function public.training_frames_expired(max_rows integer default 1000) returns setof text
language sql stable security definer set search_path = '' as $$
  select name from storage.objects
  where bucket_id = 'training-frames' and created_at < now() - interval '2 years'
  order by created_at limit max_rows;
$$;
revoke all on function public.training_frames_expired(integer) from public, anon, authenticated;
grant execute on function public.training_frames_expired(integer) to service_role;

-- Daily at 03:00 Bangkok (20:00 UTC). The function URL and its shared secret live in Vault, not in this file:
--   select vault.create_secret('<https://<ref>.supabase.co/functions/v1/training-retention>', 'training_retention_url');
--   select vault.create_secret('<random secret, also set as CRON_SECRET for the function>', 'training_retention_secret');
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.schedule('training-retention', '0 20 * * *', $$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name = 'training_retention_url'),
    headers := jsonb_build_object('x-cron-secret',
      (select decrypted_secret from vault.decrypted_secrets where name = 'training_retention_secret')));
$$);
