-- Taught-product photos (the app's Documents/Crops/<sku>/<millis>-<id>.jpg), stored at
-- product-photos/<shop_id>/<sku>/<file>.jpg. Private bucket: only the owning shop's signed-in user reaches it.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('product-photos', 'product-photos', false, 5242880, array['image/jpeg', 'image/png', 'image/heic'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
                               allowed_mime_types = excluded.allowed_mime_types;

-- The first path segment must be the caller's own shop id.
create policy "product-photos: own shop select" on storage.objects for select to authenticated
  using (bucket_id = 'product-photos'
         and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())));

create policy "product-photos: own shop insert" on storage.objects for insert to authenticated
  with check (bucket_id = 'product-photos'
              and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())));

create policy "product-photos: own shop update" on storage.objects for update to authenticated
  using (bucket_id = 'product-photos'
         and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())))
  with check (bucket_id = 'product-photos'
              and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())));

create policy "product-photos: own shop delete" on storage.objects for delete to authenticated
  using (bucket_id = 'product-photos'
         and (storage.foldername(name))[1] in (select id::text from public.shops where owner = (select auth.uid())));
