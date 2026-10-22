-- Row Level Security proof for OneShot. Two users, A and B, each with a shop. Signed in as A, nothing of B's
-- can be read, added, changed or removed; insert-only tables refuse updates and deletes; anon reaches nothing.
--
-- Run against the linked project (everything is rolled back at the end):
--   supabase test db --linked
-- or with psql and the database connection string:
--   psql "$DATABASE_URL" -f supabase/tests/rls.sql
begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select no_plan();

-- ---------------------------------------------------------------------------------------------------------------
-- Fixtures, written as the table owner (bypasses RLS).
insert into auth.users (id, email, aud, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'rls-a@test.invalid', 'authenticated', 'authenticated'),
  ('bbbbbbbb-0000-0000-0000-000000000001', 'rls-b@test.invalid', 'authenticated', 'authenticated');

insert into shops (id, owner, name) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', 'Shop A'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'bbbbbbbb-0000-0000-0000-000000000001', 'Shop B');

insert into products (shop_id, id, name_en, name_th, price, edited_at) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'lays', 'Lays', 'เลย์', 20, now() - interval '1 day'),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'lays', 'Lays', 'เลย์', 20, now() - interval '1 day');
insert into barcodes (shop_id, code, sku) values ('bbbbbbbb-0000-0000-0000-00000000000b', '885000', 'lays');
insert into stock_levels (shop_id, sku, count) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'lays', 10);
insert into day_closes (shop_id, date, float, cash_sales, counted, sales, revenue)
  values ('bbbbbbbb-0000-0000-0000-00000000000b', '2026-10-21', 500, 100, 600, 3, 120);
insert into sales (id, shop_id, date, total, method) values
  ('aaaaaaaa-5a1e-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', now(), 20, 'cash'),
  ('bbbbbbbb-5a1e-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-00000000000b', now(), 20, 'cash');
insert into sale_lines (shop_id, sale_id, position, sku, name, quantity, amount) values
  ('aaaaaaaa-0000-0000-0000-00000000000a', 'aaaaaaaa-5a1e-0000-0000-000000000001', 0, 'lays', 'Lays', 1, 20),
  ('bbbbbbbb-0000-0000-0000-00000000000b', 'bbbbbbbb-5a1e-0000-0000-000000000001', 0, 'lays', 'Lays', 1, 20);
insert into stock_moves (id, shop_id, sku, delta, reason, at) values
  ('aaaaaaaa-30be-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', 'lays', 5, 'receive', now()),
  ('bbbbbbbb-30be-0000-0000-000000000001', 'bbbbbbbb-0000-0000-0000-00000000000b', 'lays', 5, 'receive', now());
insert into storage.objects (bucket_id, name, owner) values
  ('product-photos', 'bbbbbbbb-0000-0000-0000-00000000000b/lays/1.jpg', 'bbbbbbbb-0000-0000-0000-000000000001');
-- B opted in to training photos and sent one.
insert into training_consent (shop_id, policy_version) values ('bbbbbbbb-0000-0000-0000-00000000000b', '2026-10-22');
insert into storage.objects (bucket_id, name, owner) values
  ('training-frames', 'bbbbbbbb-0000-0000-0000-00000000000b/1.jpg', 'bbbbbbbb-0000-0000-0000-000000000001');

-- ---------------------------------------------------------------------------------------------------------------
-- Signed in as A.
set local role authenticated;
select set_config('request.jwt.claims',
  '{"sub": "aaaaaaaa-0000-0000-0000-000000000001", "role": "authenticated"}', true);

select is((select count(*)::int from shops), 1, 'A sees only its own shop');
select is((select id from shops), 'aaaaaaaa-0000-0000-0000-00000000000a'::uuid, 'the shop A sees is A''s');

-- Reads: none of B's rows are visible.
select is((select count(*)::int from products     where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B products');
select is((select count(*)::int from barcodes     where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B barcodes');
select is((select count(*)::int from stock_levels where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B stock_levels');
select is((select count(*)::int from day_closes   where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B day_closes');
select is((select count(*)::int from sales        where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B sales');
select is((select count(*)::int from sale_lines   where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B sale_lines');
select is((select count(*)::int from stock_moves  where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0, 'A cannot select B stock_moves');
select is((select count(*)::int from products), 1, 'A still sees its own product');

-- Inserts into B's shop are refused (42501 = new row violates row-level security policy).
select throws_ok($$insert into shops (owner, name) values ('bbbbbbbb-0000-0000-0000-000000000001', 'x')$$,
  '42501', null, 'A cannot create a shop owned by B');
select throws_ok($$insert into shops (name) values ('second')$$, '23505', null, 'A cannot open a second shop');
select throws_ok($$insert into products (shop_id, id, name_en, name_th, price) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'x', 'x', 'x', 1)$$,
  '42501', null, 'A cannot insert B products');
select throws_ok($$insert into barcodes (shop_id, code, sku) values ('bbbbbbbb-0000-0000-0000-00000000000b', '1', 'x')$$,
  '42501', null, 'A cannot insert B barcodes');
select throws_ok($$insert into stock_levels (shop_id, sku, count) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'x', 1)$$,
  '42501', null, 'A cannot insert B stock_levels');
select throws_ok($$insert into day_closes (shop_id, date, float, cash_sales, counted, sales, revenue) values ('bbbbbbbb-0000-0000-0000-00000000000b', '2026-10-22', 0, 0, 0, 0, 0)$$,
  '42501', null, 'A cannot insert B day_closes');
select throws_ok($$insert into sales (id, shop_id, date, total) values (gen_random_uuid(), 'bbbbbbbb-0000-0000-0000-00000000000b', now(), 1)$$,
  '42501', null, 'A cannot insert B sales');
select throws_ok($$insert into sale_lines (shop_id, sale_id, position, sku, name, quantity, amount) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'bbbbbbbb-5a1e-0000-0000-000000000001', 1, 'x', 'x', 1, 1)$$,
  '42501', null, 'A cannot insert B sale_lines');
select throws_ok($$insert into sale_lines (shop_id, sale_id, position, sku, name, quantity, amount) values ('aaaaaaaa-0000-0000-0000-00000000000a', 'bbbbbbbb-5a1e-0000-0000-000000000001', 1, 'x', 'x', 1, 1)$$,
  '23503', null, 'A cannot hang a line on B''s sale under its own shop id');
select throws_ok($$insert into sales (id, shop_id, date, total, refund_of) values (gen_random_uuid(), 'aaaaaaaa-0000-0000-0000-00000000000a', now(), -20, 'bbbbbbbb-5a1e-0000-0000-000000000001')$$,
  '23503', null, 'A cannot refund B''s sale');
select throws_ok($$insert into stock_moves (id, shop_id, sku, delta, reason, at) values (gen_random_uuid(), 'bbbbbbbb-0000-0000-0000-00000000000b', 'x', 1, 'count', now())$$,
  '42501', null, 'A cannot insert B stock_moves');

-- Updates and deletes of B's rows touch nothing (RLS hides them), checked again as the owner below.
select results_eq($$with u as (update shops set name = 'pwned' where id = 'bbbbbbbb-0000-0000-0000-00000000000b' returning 1) select count(*)::int from u$$,
  $$values (0)$$, 'A cannot update B shop');
select throws_ok($$update shops set owner = 'bbbbbbbb-0000-0000-0000-000000000001'$$, '42501', null, 'A cannot hand its shop to B');
select results_eq($$with u as (update products set price = 0 where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b' returning 1) select count(*)::int from u$$,
  $$values (0)$$, 'A cannot update B products');
select throws_ok($$update products set shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b' where shop_id = 'aaaaaaaa-0000-0000-0000-00000000000a'$$,
  '42501', null, 'A cannot move its product into B''s shop');
select results_eq($$with u as (update barcodes set sku = 'x' where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b' returning 1) select count(*)::int from u$$,
  $$values (0)$$, 'A cannot update B barcodes');
select results_eq($$with u as (update stock_levels set count = 0 where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b' returning 1) select count(*)::int from u$$,
  $$values (0)$$, 'A cannot update B stock_levels');
select results_eq($$with u as (update day_closes set counted = 0 where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b' returning 1) select count(*)::int from u$$,
  $$values (0)$$, 'A cannot update B day_closes');
select throws_ok($$delete from products where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'$$, '42501', null, 'A cannot delete B products');
select throws_ok($$delete from barcodes where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'$$, '42501', null, 'A cannot delete B barcodes');
select throws_ok($$delete from stock_levels where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'$$, '42501', null, 'A cannot delete B stock_levels');
select throws_ok($$delete from day_closes where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'$$, '42501', null, 'A cannot delete B day_closes');
select throws_ok($$delete from shops$$, '42501', null, 'shops cannot be deleted directly (delete-account does it)');
select throws_ok($$delete from products$$, '42501', null, 'no hard delete even of A''s own product (soft delete via deleted_at)');

-- Insert-only tables refuse updates and deletes outright, even of A's own rows (42501 = permission denied).
select throws_ok($$update sales set total = 0$$, '42501', null, 'sales reject updates');
select throws_ok($$delete from sales$$, '42501', null, 'sales reject deletes');
select throws_ok($$update sale_lines set amount = 0$$, '42501', null, 'sale_lines reject updates');
select throws_ok($$delete from sale_lines$$, '42501', null, 'sale_lines reject deletes');
select throws_ok($$update stock_moves set delta = 0$$, '42501', null, 'stock_moves reject updates');
select throws_ok($$delete from stock_moves$$, '42501', null, 'stock_moves reject deletes');
select lives_ok($$insert into sales (id, shop_id, date, total) values ('aaaaaaaa-5a1e-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-00000000000a', now(), 999) on conflict do nothing$$,
  'a re-pushed sale is ignored (on conflict do nothing needs no update right)');
select is((select total from sales where id = 'aaaaaaaa-5a1e-0000-0000-000000000001'), 20::numeric, 'and the stored sale keeps its total');

-- A refund: own sale only, once.
select lives_ok($$insert into sales (id, shop_id, date, total, refund_of) values (gen_random_uuid(), 'aaaaaaaa-0000-0000-0000-00000000000a', now(), -20, 'aaaaaaaa-5a1e-0000-0000-000000000001')$$,
  'A refunds its own sale');
select throws_ok($$insert into sales (id, shop_id, date, total, refund_of) values (gen_random_uuid(), 'aaaaaaaa-0000-0000-0000-00000000000a', now(), -20, 'aaaaaaaa-5a1e-0000-0000-000000000001')$$,
  '23505', null, 'a sale is refunded at most once');

-- Last writer wins by edited_at: an older edit doesn't overwrite a newer one.
update products set price = 25, edited_at = now() - interval '1 hour' where id = 'lays';
update products set price = 99, edited_at = now() - interval '2 hours' where id = 'lays';
select is((select price from products where id = 'lays'), 25::numeric, 'an older edit is skipped');
update products set price = 30, edited_at = now() - interval '30 minutes' where id = 'lays';
select is((select price from products where id = 'lays'), 30::numeric, 'a newer edit is applied');
-- A device clock in the future is clamped, so it doesn't beat every later edit.
update products set price = 40, edited_at = now() + interval '1 year' where id = 'lays';
select is((select edited_at from products where id = 'lays'), now(), 'a future edited_at is clamped to now()');

-- Storage: only A's own folder.
select is((select count(*)::int from storage.objects where bucket_id = 'product-photos'), 0, 'A cannot list B photos');
select throws_ok($$insert into storage.objects (bucket_id, name, owner) values ('product-photos', 'bbbbbbbb-0000-0000-0000-00000000000b/lays/2.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  '42501', null, 'A cannot upload into B''s folder');
select throws_ok($$insert into storage.objects (bucket_id, name, owner) values ('product-photos', 'lays/2.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  '42501', null, 'A cannot upload outside a shop folder');
select lives_ok($$insert into storage.objects (bucket_id, name, owner) values ('product-photos', 'aaaaaaaa-0000-0000-0000-00000000000a/lays/1.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  'A uploads into its own folder');
-- Direct deletes from storage.objects may be blocked by Supabase's own trigger; either way B's photo must survive.
do $$ begin
  update storage.objects set name = 'aaaaaaaa-0000-0000-0000-00000000000a/stolen.jpg' where name like 'bbbbbbbb-%';
  delete from storage.objects where name like 'bbbbbbbb-%';
exception when others then null;
end $$;

-- Training photos: only with A's own consent, only in A's folder; never B's.
select throws_ok($$insert into storage.objects (bucket_id, name, owner) values ('training-frames', 'aaaaaaaa-0000-0000-0000-00000000000a/1.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  '42501', null, 'A cannot send a training photo before opting in');
select is((select count(*)::int from training_consent), 0, 'A cannot see B''s consent');
select throws_ok($$insert into training_consent (shop_id, policy_version) values ('bbbbbbbb-0000-0000-0000-00000000000b', 'x')$$,
  '42501', null, 'A cannot consent for B');
select lives_ok($$insert into training_consent (shop_id, policy_version) values ('aaaaaaaa-0000-0000-0000-00000000000a', '2026-10-22')$$,
  'A opts in for its own shop');
select lives_ok($$insert into storage.objects (bucket_id, name, owner) values ('training-frames', 'aaaaaaaa-0000-0000-0000-00000000000a/1.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  'A sends a training photo after opting in');
select throws_ok($$insert into storage.objects (bucket_id, name, owner) values ('training-frames', 'bbbbbbbb-0000-0000-0000-00000000000b/2.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  '42501', null, 'A cannot send into B''s training folder');
select is((select count(*)::int from storage.objects where bucket_id = 'training-frames' and name like 'bbbbbbbb-%'), 0,
  'A cannot list B''s training photos');
update training_consent set withdrawn_at = now() where shop_id = 'aaaaaaaa-0000-0000-0000-00000000000a';
select throws_ok($$insert into storage.objects (bucket_id, name, owner) values ('training-frames', 'aaaaaaaa-0000-0000-0000-00000000000a/2.jpg', 'aaaaaaaa-0000-0000-0000-000000000001')$$,
  '42501', null, 'after withdrawing, A cannot send training photos');

-- anon reaches nothing.
set local role anon;
select set_config('request.jwt.claims', '{"role": "anon"}', true);
select throws_ok($$select * from products$$, '42501', null, 'anon cannot select products');
select throws_ok($$select * from shops$$, '42501', null, 'anon cannot select shops');
select throws_ok($$insert into sales (id, shop_id, date, total) values (gen_random_uuid(), 'bbbbbbbb-0000-0000-0000-00000000000b', now(), 1)$$,
  '42501', null, 'anon cannot insert sales');
select is((select count(*)::int from storage.objects where bucket_id = 'product-photos'), 0, 'anon cannot list photos');
select is((select count(*)::int from storage.objects where bucket_id = 'training-frames'), 0, 'anon cannot list training photos');

-- ---------------------------------------------------------------------------------------------------------------
-- Back as the owner: B's rows are all still there, unchanged.
reset role;
select is((select name from shops where id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 'Shop B', 'B shop unchanged');
select is((select price from products where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 20::numeric, 'B product unchanged');
select is((select sku from barcodes where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 'lays', 'B barcode unchanged');
select is((select count from stock_levels where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 10, 'B stock unchanged');
select is((select counted from day_closes where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 600::numeric, 'B close unchanged');
select is((select count(*)::int from sales where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 1, 'B sales unchanged');
select is((select name from storage.objects where owner = 'bbbbbbbb-0000-0000-0000-000000000001' and bucket_id = 'product-photos'),
  'bbbbbbbb-0000-0000-0000-00000000000b/lays/1.jpg', 'B photo still there, same path');
select is((select count(*)::int from storage.objects where bucket_id = 'training-frames' and name like 'bbbbbbbb-%'), 1,
  'B training photo still there');

-- Deleting a user cascades to the shop and every row under it.
delete from auth.users where id = 'bbbbbbbb-0000-0000-0000-000000000001';
select is((select count(*)::int from products where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b')
        + (select count(*)::int from sales where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b')
        + (select count(*)::int from sale_lines where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b')
        + (select count(*)::int from stock_moves where shop_id = 'bbbbbbbb-0000-0000-0000-00000000000b'), 0,
  'deleting B''s user removes B''s rows');

select * from finish();
rollback;
