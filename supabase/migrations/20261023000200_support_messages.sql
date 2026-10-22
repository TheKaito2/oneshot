-- Messages from the support form on oneshot-pos.pages.dev (App Store 1.5: a way to contact the developer).
-- Written only by the `support` Edge Function (service role); nobody reads or writes them through the API.
-- Krist reads them in the Supabase dashboard (Table editor › support_messages).
create table public.support_messages (
  id          uuid primary key default gen_random_uuid(),
  created_at  timestamptz not null default now(),
  contact     text not null check (char_length(contact) between 3 and 200),
  message     text not null check (char_length(message) between 5 and 4000),
  lang        text check (char_length(lang) <= 8),
  sender_hash text not null   -- a salted hash of the sender's IP, only to limit how often one sender can write
);
alter table public.support_messages enable row level security;   -- no policies: closed to anon and users
create index support_messages_sender on public.support_messages (sender_hash, created_at);
