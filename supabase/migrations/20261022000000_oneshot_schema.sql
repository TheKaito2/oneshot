-- OneShot cloud backup / sync schema. The device (SwiftData) is the source of truth; these tables mirror it.
--
-- Two timestamps on every row:
--   updated_at  set by the server (trigger) on every insert and applied update. It is the pull cursor:
--               a device asks for rows with updated_at > its last cursor. Clients never set it.
--   edited_at   only on last-writer-wins tables: when the device made the edit. An update whose edited_at is
--               older than the stored row's is skipped, so an old offline edit can't overwrite a newer one.
--               A device clock ahead of the server is clamped to now(), so it can't win every later edit.
-- Insert-only tables (sales, sale_lines, stock_moves) are never updated: authenticated gets no UPDATE/DELETE
-- grant and no policy for them. Push them with INSERT ... ON CONFLICT DO NOTHING (upsert, ignoreDuplicates).
-- Deletions are soft: set deleted_at (and a newer edited_at) so other devices pull the tombstone. No client
-- DELETE grant anywhere; rows go only with the shop (delete-account).

-- ---------------------------------------------------------------------------------------------------------------
-- Triggers

create function public.stamp_updated_at() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- BEFORE INSERT OR UPDATE on LWW tables, ahead of stamp_updated_at (triggers fire in name order).
create function public.keep_newer_edit() returns trigger
language plpgsql set search_path = '' as $$
begin
  new.edited_at := least(new.edited_at, now());
  if tg_op = 'UPDATE' and new.edited_at < old.edited_at then
    return null;  -- stored row is newer: skip this update silently
  end if;
  return new;
end $$;

revoke execute on function public.stamp_updated_at(), public.keep_newer_edit() from public, anon, authenticated;

-- ---------------------------------------------------------------------------------------------------------------
-- Tables

-- One shop per owner (v1). Shop settings live here.
create table public.shops (
  id           uuid primary key default gen_random_uuid(),
  owner        uuid not null unique default auth.uid() references auth.users (id) on delete cascade,
  name         text not null default '',
  promptpay_id text,
  created_at   timestamptz not null default now(),
  edited_at    timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- StoreV3.ProductRecord. id = detector class label, or "qa-…" for taught products.
create table public.products (
  shop_id    uuid not null references public.shops (id) on delete cascade,
  id         text not null,
  name_en    text not null,
  name_th    text not null,
  price      numeric not null check (price >= 0),
  cost       numeric check (cost >= 0),
  size       text,
  category   text,
  barcode    text,
  archived   boolean not null default false,
  deleted_at timestamptz,
  edited_at  timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (shop_id, id)
);

-- StoreV3.BarcodeRecord: a barcode scanned in the app and tied to a product.
create table public.barcodes (
  shop_id    uuid not null references public.shops (id) on delete cascade,
  code       text not null,
  sku        text not null,
  deleted_at timestamptz,
  edited_at  timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (shop_id, code)
);

-- StoreV3.StockRecord: a tracked product's count and reorder point.
create table public.stock_levels (
  shop_id    uuid not null references public.shops (id) on delete cascade,
  sku        text not null,
  count      integer not null,
  reorder_at integer not null default 5,
  deleted_at timestamptz,
  edited_at  timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (shop_id, sku)
);

-- StoreV3.SaleRecord. Insert-only. A refund has refund_of = the sale it reverses, negative lines and total.
create table public.sales (
  id         uuid not null,
  shop_id    uuid not null references public.shops (id) on delete cascade,
  date       timestamptz not null,
  total      numeric not null,
  method     text check (method in ('promptPay', 'cash')),
  received   numeric,
  ring_up    double precision,  -- seconds from first item to paid
  auto_units integer,
  refund_of  uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (shop_id, id),  -- per shop, so another shop's ids can't collide with (and silently drop) these
  unique (shop_id, refund_of),  -- a sale is refunded at most once; NULLs don't collide
  -- Same shop only. Push sales in date order so an original lands before (or in the same request as) its refund.
  foreign key (shop_id, refund_of) references public.sales (shop_id, id) on delete cascade
);

-- StoreV3.LineRecord. Insert-only.
create table public.sale_lines (
  shop_id    uuid not null references public.shops (id) on delete cascade,
  sale_id    uuid not null,
  position   integer not null,
  sku        text not null,
  name       text not null,
  quantity   integer not null,
  amount     numeric not null,
  updated_at timestamptz not null default now(),
  primary key (shop_id, sale_id, position),
  foreign key (shop_id, sale_id) references public.sales (shop_id, id) on delete cascade
);

-- StoreV3.CloseRecord: one end-of-day close per shop per calendar day (Asia/Bangkok). Last writer wins.
create table public.day_closes (
  shop_id    uuid not null references public.shops (id) on delete cascade,
  date       date not null,
  float      numeric not null,
  cash_sales numeric not null,
  counted    numeric not null,
  sales      integer not null,
  revenue    numeric not null,
  edited_at  timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (shop_id, date)
);

-- StoreV3.StockMoveRecord: a delivery or a recount (stored as the difference it made). Insert-only.
create table public.stock_moves (
  id         uuid not null,
  shop_id    uuid not null references public.shops (id) on delete cascade,
  sku        text not null,
  delta      integer not null,
  reason     text not null check (reason in ('receive', 'count')),
  at         timestamptz not null,
  updated_at timestamptz not null default now(),
  primary key (shop_id, id)
);

-- Pull cursor indexes. The PKs above already lead with shop_id for the LWW tables' point lookups.
create index on public.shops (owner, updated_at);
create index on public.products (shop_id, updated_at);
create index on public.barcodes (shop_id, updated_at);
create index on public.stock_levels (shop_id, updated_at);
create index on public.sales (shop_id, updated_at);
create index on public.sale_lines (shop_id, updated_at);
create index on public.day_closes (shop_id, updated_at);
create index on public.stock_moves (shop_id, updated_at);

-- Triggers: every table stamps updated_at; LWW tables also keep the newer edit.
do $$
declare t text;
begin
  foreach t in array array['shops', 'products', 'barcodes', 'stock_levels', 'day_closes'] loop
    execute format('create trigger a_keep_newer_edit before insert or update on public.%I
                    for each row execute function public.keep_newer_edit()', t);
    execute format('create trigger b_stamp_updated_at before insert or update on public.%I
                    for each row execute function public.stamp_updated_at()', t);
  end loop;
  foreach t in array array['sales', 'sale_lines', 'stock_moves'] loop
    execute format('create trigger b_stamp_updated_at before insert on public.%I
                    for each row execute function public.stamp_updated_at()', t);
  end loop;
end $$;

-- ---------------------------------------------------------------------------------------------------------------
-- Privileges and Row Level Security. anon gets nothing; authenticated only reaches its own shop's rows.

alter table public.shops        enable row level security;
alter table public.products     enable row level security;
alter table public.barcodes     enable row level security;
alter table public.stock_levels enable row level security;
alter table public.sales        enable row level security;
alter table public.sale_lines   enable row level security;
alter table public.day_closes   enable row level security;
alter table public.stock_moves  enable row level security;

revoke all on public.shops, public.products, public.barcodes, public.stock_levels,
              public.sales, public.sale_lines, public.day_closes, public.stock_moves
  from anon, authenticated;

-- Shop deletion goes through the delete-account function (service role), so no DELETE here.
grant select, insert, update on public.shops to authenticated;
grant select, insert, update on public.products, public.barcodes, public.stock_levels, public.day_closes
  to authenticated;
grant select, insert on public.sales, public.sale_lines, public.stock_moves to authenticated;

create policy "own shop: select" on public.shops for select to authenticated
  using (owner = (select auth.uid()));
create policy "own shop: insert" on public.shops for insert to authenticated
  with check (owner = (select auth.uid()));
create policy "own shop: update" on public.shops for update to authenticated
  using (owner = (select auth.uid())) with check (owner = (select auth.uid()));

-- Child tables: shop_id must be a shop the caller owns. (select auth.uid()) is evaluated once per statement.
do $$
declare
  t text;
  mine constant text := 'shop_id in (select id from public.shops where owner = (select auth.uid()))';
begin
  foreach t in array array['products', 'barcodes', 'stock_levels', 'day_closes'] loop
    execute format('create policy "own shop: select" on public.%I for select to authenticated using (%s)', t, mine);
    execute format('create policy "own shop: insert" on public.%I for insert to authenticated with check (%s)', t, mine);
    execute format('create policy "own shop: update" on public.%I for update to authenticated using (%s) with check (%s)', t, mine, mine);
  end loop;
  -- Insert-only: no update or delete policy.
  foreach t in array array['sales', 'sale_lines', 'stock_moves'] loop
    execute format('create policy "own shop: select" on public.%I for select to authenticated using (%s)', t, mine);
    execute format('create policy "own shop: insert" on public.%I for insert to authenticated with check (%s)', t, mine);
  end loop;
end $$;
