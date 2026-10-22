-- Opt-in training photos ("Help improve OneShot"): a checked-out counter photo (faces blurred on the device) and a
-- JSON of its confirmed item boxes, stored at training-frames/<shop_id>/<uuid>.jpg|.json.
-- Only a shop that has opted in (training_consent, not withdrawn) can add photos; only that shop can see or delete
-- its own; the developer reads them for training with the service role, which bypasses RLS and never ships.

create table public.training_consent (
  shop_id        uuid primary key references public.shops (id) on delete cascade,
  granted_at     timestamptz not null default now(),
  policy_version text not null,
  withdrawn_at   timestamptz
);

alter table public.training_consent enable row level security;

create policy "own shop: select" on public.training_consent for select to authenticated
  using (shop_id in (select id from public.shops where owner = (select auth.uid())));
create policy "own shop: insert" on public.training_consent for insert to authenticated
  with check (shop_id in (select id from public.shops where owner = (select auth.uid())));
create policy "own shop: update" on public.training_consent for update to authenticated
  using (shop_id in (select id from public.shops where owner = (select auth.uid())))
  with check (shop_id in (select id from public.shops where owner = (select auth.uid())));

grant select, insert, update on public.training_consent to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('training-frames', 'training-frames', false, 3145728, array['image/jpeg', 'application/json'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

-- Adding needs the caller's own shop as the first folder AND consent that hasn't been withdrawn.
create policy "training-frames: consenting shop insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'training-frames'
              and (storage.foldername(name))[1] in (
                select s.id::text from public.shops s
                join public.training_consent c on c.shop_id = s.id
                where s.owner = (select auth.uid()) and c.withdrawn_at is null));

-- Seeing and deleting: the shop's own photos, so turning it off can remove what was sent.
create policy "training-frames: own shop select" on storage.objects for select to authenticated
  using (bucket_id = 'training-frames'
         and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())));

create policy "training-frames: own shop delete" on storage.objects for delete to authenticated
  using (bucket_id = 'training-frames'
         and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())));
