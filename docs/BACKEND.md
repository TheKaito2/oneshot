# OneShot backend (Supabase)

Accounts are optional. The app works offline. A signed-in owner gets cloud backup and sync across their own
devices. The device's SwiftData store stays the source of truth, and Supabase mirrors it. The sync engine pushes
and pulls rows.

- Project region: Singapore (`ap-southeast-1`).
- v1 model: one owner, one shop, many devices. No staff roles yet.
- All backend code lives in `supabase/`:

| Path | What it is |
|---|---|
| `migrations/20261022000000_oneshot_schema.sql` | Tables, triggers, grants, Row Level Security |
| `migrations/20261022000100_product_photos.sql` | Private Storage bucket `product-photos` and its policies |
| `functions/delete-account/index.ts` | In-app account deletion (App Store guideline 5.1.1(v)) |
| `tests/rls.sql` | pgTAP proof of the RLS rules (63 checks) |
| `local-check/` | Runs the migrations and `tests/rls.sql` in PGlite. No Docker or project needed. |
| `config.toml` | Supabase CLI config. `delete-account` has `verify_jwt = false` because it checks the token itself. |

## Tables

All money columns are `numeric`, matching the app's `Decimal`. Send money as JSON strings or numbers. Never
pass it through `Double`.

| Table | Key | Mirrors | Write rule |
|---|---|---|---|
| `shops` | `id`, `owner` unique → `auth.users` | shop settings (`name`, `promptpay_id`) | last writer wins |
| `products` | `(shop_id, id)` | `ProductRecord` (+ `archived`, `deleted_at`) | last writer wins |
| `barcodes` | `(shop_id, code)` | `BarcodeRecord` | last writer wins |
| `stock_levels` | `(shop_id, sku)` | `StockRecord` (`count`, `reorder_at`) | last writer wins |
| `day_closes` | `(shop_id, date)` | `CloseRecord` | last writer wins |
| `sales` | `(shop_id, id)` | `SaleRecord` (`ring_up` seconds, `auto_units`, `refund_of`) | insert-only |
| `sale_lines` | `(shop_id, sale_id, position)` | `LineRecord` | insert-only |
| `stock_moves` | `(shop_id, id)` | `StockMoveRecord` (`reason` is `receive` or `count`) | insert-only |

Every child table has `shop_id → shops(id) on delete cascade`. Deleting the auth user deletes the shop, and the
shop's deletion removes everything under it. `sale_lines` and refunds reference `sales` by `(shop_id, id)`, so
a line or a refund can only point at a sale of the same shop.

Other constraints:

- `sales.refund_of` is unique per shop, so a sale is refunded at most once.
- `sales.method` is `promptPay`, `cash` or null, matching `PaymentMethod.rawValue`.
- `day_closes.date` is a calendar `date`. The client converts the close's `Date` to the day in `Asia/Bangkok`.

### Timestamps the sync engine relies on

- **`updated_at`** is set by a trigger to the server's `now()` on every insert and on every update that is
  applied. It is the pull cursor: ask for `updated_at > cursor`, ordered by `updated_at`, and save the largest
  value you received as the new cursor. The server overwrites anything a client sends here.
  - Rows written by transactions that commit out of order can carry an `updated_at` slightly behind a row
    you already pulled. To catch them, pull from `cursor - 1 minute` and apply rows idempotently, since every
    key is stable.
- **`edited_at`** exists only on the last-writer-wins tables. The device sets it to the moment of the edit
  (`updatedAt` in SwiftData). If an incoming update has an `edited_at` older than the stored row's, a trigger
  skips the update without an error. An offline edit that arrives late therefore cannot overwrite a newer
  edit from another device. An `edited_at` in the future (a device clock set ahead) is clamped to the
  server's `now()`, so that device can't win every later edit.
- **Deleting** a product, barcode or stock level means an upsert with `deleted_at` set and a fresh
  `edited_at`. This is how a `TombstoneRecord` is pushed. Clients have no `DELETE` right on any table, because
  other devices would never learn of a hard delete. Rows go away only with the shop.

### How to push

- **Last-writer-wins tables:** `upsert` (`INSERT … ON CONFLICT DO UPDATE`).
- **Insert-only tables:** `upsert(…, ignoreDuplicates: true)` (`ON CONFLICT DO NOTHING`). A row that is
  already there is skipped, and this needs no update right.
- **Order:** push `sales` in `date` order, then their `sale_lines`. A refund must land after its original
  sale, or in the same request. Otherwise the foreign key rejects it (`23503`). Retry it on the next push.

## Row Level Security

RLS is on for every table.

- **`anon`:** has no grants on any OneShot table and is refused with `42501`. In the bucket, it matches no
  policy and sees nothing.
- **`authenticated`:**
  - `shops`: can select, insert and update only the row where `owner = auth.uid()`. `owner` defaults to
    `auth.uid()`, and it cannot be changed to someone else. A second shop fails on the unique `owner`. There is
    no delete; account deletion goes through the function.
  - Last-writer-wins tables: can select, insert and update rows only when `shop_id` is a shop the caller
    owns. Updates are also checked on the new row, so a row cannot be moved into another shop. There is no
    DELETE (see soft deletes above).
  - Insert-only tables: can select and insert under the same `shop_id` rule. There is no UPDATE or DELETE grant
    and no policy, so those statements fail with `permission denied` (`42501`), even on the caller's own rows.
- **`service_role` / secret key:** bypasses RLS. It is used only inside the `delete-account` function.

### Storage

- Bucket `product-photos`: private, 5 MB per file, JPEG/PNG/HEIC only. Uploads must set `contentType`
  (for example `image/jpeg`), or the allow-list rejects them.
- Object path: `<shop_id>/<sku>/<file>.jpg`, which mirrors the app's `Documents/Crops/<sku>/`.
- Policies: select, insert, update and delete only when the first path segment is the caller's own shop id.
  Read photos with signed URLs or an authenticated download, since the bucket is not public.
- FeaturePrint vectors are not synced. Each device rebuilds them from the photos.

## Account deletion

`POST https://<project-ref>.supabase.co/functions/v1/delete-account` with
`Authorization: Bearer <user access token>` (and the `apikey` header that supabase-swift adds).

1. Verifies the token with the Auth server (`auth.getUser`). A missing or invalid token gets `401`.
2. Removes every object under `product-photos/<shop_id>/`.
3. Deletes the shop row, and every table cascades from it.
4. Deletes the auth user.

Success returns `200 {"deleted": true}`. Every step is safe to repeat, so on a `500` the app retries.

After a success the app signs out. What happens to the books on the device is the app's decision.

**TODO:** Sign in with Apple token revocation is not built yet. A `TODO(sign-in-with-apple)` in the function
marks where it goes: call Apple's `/auth/revoke` before the user is deleted. Build it when Apple sign-in is
enabled, because Apple requires it for apps that offer Sign in with Apple.

## Linking and deploying

Run these from the repo root after creating the project (region Singapore) in the dashboard.

1. Sign in and link the project:
   ```bash
   supabase login
   ```
   ```bash
   supabase link --project-ref <project-ref>
   ```
   `link` asks for the database password. Type it at the prompt. Never put it in a file or a command line.
2. Check, then apply, the migrations:
   ```bash
   supabase db push --dry-run
   ```
   ```bash
   supabase db push
   ```
3. Run the RLS proof against the linked project. It runs inside a transaction and rolls back, so it leaves
   nothing behind.
   ```bash
   supabase test db --linked
   ```
4. Lint the schema:
   ```bash
   supabase db lint --linked
   ```
5. Deploy the function:
   ```bash
   supabase functions deploy delete-account
   ```
   `SUPABASE_URL` and the secret key (`SUPABASE_SECRET_KEYS`, or `SUPABASE_SERVICE_ROLE_KEY` on legacy keys)
   are injected into the function's environment by the platform. There is nothing to set by hand.
6. In the dashboard, under Authentication → Providers, enable the sign-in methods the app uses.

Offline check, with no project and no Docker. It applies the migrations to PGlite and runs `tests/rls.sql`, and
the last line should be `1..63`:

```bash
deno run -A --no-lock supabase/local-check/run.ts
```

`local-check/stub.sql` only imitates Supabase's `auth` and `storage` schemas. The run against the real project in
step 3 is the one that counts.

## Which key goes where

| Key | Where | Never |
|---|---|---|
| Project URL + publishable key (`sb_publishable_…`, or the legacy `anon` key) | The app's `Config.xcconfig`, read through Info.plist. | — |
| Secret key (`sb_secret_…`) / legacy `service_role` key | Only the function's environment, where the platform injects it. | In the app, in the repo, in `Config.xcconfig`, in chat. |
| Database password | Typed at the `supabase link` prompt, or kept in your password manager. | In any file. |

`Config.xcconfig` is not in the repo yet. Add it to `.gitignore` when it is created, and commit a
`Config.example.xcconfig` with placeholder values. The publishable key is safe in a shipped app, because RLS is
what protects the data. It stays out of git anyway, so keys can be rotated without a commit.
