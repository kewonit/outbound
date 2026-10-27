-- Outbound's tables in Supabase: the waitlist behind /api/waitlist, for one email when Outbound comes to Windows or
-- iPhone, and what people write on the feedback page, behind /api/feedback. Run once in the project's SQL editor.
--
-- They live in their own schema, which the Data API doesn't serve, so neither the project's public key nor its users
-- can read or write them. The only ways in are outbound_join_waitlist() and outbound_send_feedback(), and only with
-- SUPABASE_TOKEN, the Worker's secret. The database keeps that secret's SHA-256, never the secret itself. To make one:
--
--   openssl rand -hex 32                       the token: npx wrangler secret put SUPABASE_TOKEN
--   printf %s "$TOKEN" | shasum -a 256         its hash, for the insert below
--
-- Each waitlist address is for one email, then deleted:
--
--   select email, lang from outbound.waitlist where platform = 'windows';
--   delete from outbound.waitlist where platform = 'windows';
--
-- And the feedback, newest first:
--
--   select created_at, message, email, lang, app from outbound.feedback order by created_at desc;

create schema outbound;
revoke all on schema outbound from public, anon, authenticated;

create table outbound.waitlist (
  email text not null check (
    char_length(email) <= 254 and email = lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$'
  ),
  platform text not null check (platform in ('windows', 'ios')),
  lang text not null default 'en' check (lang ~ '^[a-z]{2}(-[a-z]{2,4})?$'),
  created_at timestamptz not null default now(),
  primary key (email, platform)
);
alter table outbound.waitlist enable row level security;
revoke all on outbound.waitlist from public, anon, authenticated;

create table outbound.keys (
  name text primary key,
  hash bytea not null check (length(hash) = 32)
);
alter table outbound.keys enable row level security;
revoke all on outbound.keys from public, anon, authenticated;
insert into outbound.keys (name, hash) values ('site', decode('<sha-256 of SUPABASE_TOKEN, in hex>', 'hex'));

-- Adds an address once per platform. It answers the same whether or not the address was already there.
create function public.outbound_join_waitlist(p_token text, p_email text, p_platform text, p_lang text default 'en')
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_token is null or not exists (
    select 1 from outbound.keys k
    where k.name = 'site' and k.hash = pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8'))
  ) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  insert into outbound.waitlist (email, platform, lang)
  values (pg_catalog.lower(pg_catalog.btrim(p_email)), p_platform, coalesce(p_lang, 'en'))
  on conflict do nothing;
end;
$$;
revoke all on function public.outbound_join_waitlist(text, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.outbound_join_waitlist(text, text, text, text) to anon;

-- What people write on the feedback page. Like the waitlist, it is out of the Data API's reach, and only
-- outbound_send_feedback() can add to it, with the site's secret.
create table outbound.feedback (
  id bigint generated always as identity primary key,
  message text not null check (char_length(message) between 1 and 2000 and message = btrim(message)),
  email text check (
    email is null
    or (char_length(email) <= 254 and email = lower(btrim(email)) and email ~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$')
  ),
  lang text not null default 'en' check (lang ~ '^[a-z]{2}(-[a-z]{2,4})?$'),
  app text check (app is null or app ~ '^[0-9]{1,3}(\.[0-9]{1,3}){0,2}$'),
  created_at timestamptz not null default now()
);
alter table outbound.feedback enable row level security;
revoke all on outbound.feedback from public, anon, authenticated;

-- Keeps one message: the email only when given, and the app's version only when the app opened the page.
create function public.outbound_send_feedback(p_token text, p_message text, p_email text, p_lang text, p_app text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_token is null or not exists (
    select 1 from outbound.keys k
    where k.name = 'site' and k.hash = pg_catalog.sha256(pg_catalog.convert_to(p_token, 'UTF8'))
  ) then
    raise exception 'not allowed' using errcode = '42501';
  end if;
  insert into outbound.feedback (message, email, lang, app)
  values (pg_catalog.btrim(p_message), nullif(pg_catalog.lower(pg_catalog.btrim(p_email)), ''),
          coalesce(p_lang, 'en'), nullif(p_app, ''));
end;
$$;
revoke all on function public.outbound_send_feedback(text, text, text, text, text) from public, anon, authenticated, service_role;
grant execute on function public.outbound_send_feedback(text, text, text, text, text) to anon;

notify pgrst, 'reload schema';
