-- =====================================================================
-- IATA 4U (Intelligent Academic Teaching Assistant)
-- Multi-agency database migration — v1
--
-- Paste into Supabase > SQL Editor and run once.
-- Additive: keeps your existing `applications` rows and `documents` bucket.
-- Existing submissions are assigned to a "Sky Touch Education" agency,
-- and the current live form keeps working (see trigger in section 4).
-- Safe to re-run: uses IF NOT EXISTS / DROP ... IF EXISTS throughout.
-- =====================================================================

begin;

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 0. Shared helper: keep updated_at fresh
-- ---------------------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger language plpgsql as $$
begin
  new.updated_at := now();
  return new;
end $$;

-- ---------------------------------------------------------------------
-- 1. AGENCIES — one row per education agent (each customer)
-- ---------------------------------------------------------------------
create table if not exists public.agencies (
  id             uuid primary key default gen_random_uuid(),
  name           text not null check (length(name) between 2 and 120),
  slug           text not null unique
                 check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$' and length(slug) between 3 and 50),
  logo_path      text,                       -- path inside the agency-logos bucket
  primary_colour text not null default '#1e3a8a' check (primary_colour ~ '^#[0-9a-fA-F]{6}$'),
  accent_colour  text not null default '#f59e0b' check (accent_colour  ~ '^#[0-9a-fA-F]{6}$'),
  contact_email  text,
  contact_phone  text,
  website        text,
  plan           text not null default 'trial' check (plan in ('trial', 'monthly', 'licence')),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

drop trigger if exists agencies_set_updated_at on public.agencies;
create trigger agencies_set_updated_at
  before update on public.agencies
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- 2. AGENCY MEMBERS — which logged-in users belong to which agency
-- ---------------------------------------------------------------------
create table if not exists public.agency_members (
  agency_id  uuid not null references public.agencies(id) on delete cascade,
  user_id    uuid not null references auth.users(id) on delete cascade,
  role       text not null default 'staff' check (role in ('owner', 'staff')),
  created_at timestamptz not null default now(),
  primary key (agency_id, user_id)
);
create index if not exists agency_members_user_id_idx on public.agency_members(user_id);

-- ---------------------------------------------------------------------
-- 3. Security helper functions (SECURITY DEFINER avoids RLS recursion)
-- ---------------------------------------------------------------------
create or replace function public.is_agency_member(p_agency uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.agency_members
    where agency_id = p_agency and user_id = auth.uid()
  );
$$;

create or replace function public.is_agency_owner(p_agency uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.agency_members
    where agency_id = p_agency and user_id = auth.uid() and role = 'owner'
  );
$$;

create or replace function public.agency_is_active(p_agency uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.agencies where id = p_agency and is_active);
$$;

-- Storage paths are text, so these take the first folder name as text
create or replace function public.agency_folder_is_active(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.agencies where id::text = p_folder and is_active);
$$;

create or replace function public.is_agency_member_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.agency_members
    where agency_id::text = p_folder and user_id = auth.uid()
  );
$$;

create or replace function public.is_agency_owner_folder(p_folder text)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.agency_members
    where agency_id::text = p_folder and user_id = auth.uid() and role = 'owner'
  );
$$;

-- ---------------------------------------------------------------------
-- 4. Seed Sky Touch + upgrade the existing APPLICATIONS table
-- ---------------------------------------------------------------------
insert into public.agencies (name, slug)
values ('Sky Touch Education', 'sky-touch')
on conflict (slug) do nothing;

-- New project: create the applications table (skipped if it already exists)
create table if not exists public.applications (
  id                uuid primary key default gen_random_uuid(),
  reference         text unique,
  first_name        text not null,
  last_name         text not null,
  email             text not null,
  phone             text,
  date_of_birth     date,
  nationality       text,
  address_line1     text,
  city              text,
  postcode          text,
  uk_entry_date     date,
  employment_status text,
  employer          text,
  job_title         text,
  education_level   text,
  institution       text,
  course_interest   text,
  documents         jsonb not null default '{}'::jsonb,
  consent           boolean not null default false,
  created_at        timestamptz not null default now()
);

alter table public.applications add column if not exists agency_id  uuid references public.agencies(id) on delete restrict;
alter table public.applications add column if not exists status     text not null default 'new';
alter table public.applications add column if not exists updated_at timestamptz not null default now();

do $$ begin
  alter table public.applications
    add constraint applications_status_check
    check (status in ('new', 'reviewing', 'more_info_needed', 'accepted', 'rejected', 'withdrawn'));
exception when duplicate_object then null;
end $$;

-- Backfill: every existing submission belongs to Sky Touch
update public.applications
set agency_id = (select id from public.agencies where slug = 'sky-touch')
where agency_id is null;

alter table public.applications alter column agency_id set not null;
create index if not exists applications_agency_id_idx on public.applications(agency_id);
create index if not exists applications_status_idx    on public.applications(agency_id, status);

-- Keeps the current live form working: submissions with no agency_id go to Sky Touch
create or replace function public.applications_default_agency()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if new.agency_id is null then
    select id into new.agency_id from public.agencies where slug = 'sky-touch';
  end if;
  return new;
end $$;

drop trigger if exists applications_default_agency on public.applications;
create trigger applications_default_agency
  before insert on public.applications
  for each row execute function public.applications_default_agency();

drop trigger if exists applications_set_updated_at on public.applications;
create trigger applications_set_updated_at
  before update on public.applications
  for each row execute function public.set_updated_at();

-- ---------------------------------------------------------------------
-- 5. APPLICATION NOTES — agents track progress on each student
--    (built dynamically so it matches whatever type applications.id is)
-- ---------------------------------------------------------------------
do $$
declare id_type text;
begin
  select format_type(atttypid, atttypmod) into id_type
  from pg_attribute
  where attrelid = 'public.applications'::regclass and attname = 'id';

  execute format($f$
    create table if not exists public.application_notes (
      id             uuid primary key default gen_random_uuid(),
      application_id %s not null references public.applications(id) on delete cascade,
      agency_id      uuid not null references public.agencies(id) on delete cascade,
      author_id      uuid default auth.uid() references auth.users(id) on delete set null,
      body           text not null check (length(body) between 1 and 5000),
      created_at     timestamptz not null default now()
    )$f$, id_type);
end $$;

create index if not exists application_notes_app_idx on public.application_notes(application_id);

-- A note always inherits its application's agency (can't be spoofed)
create or replace function public.notes_set_agency()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  select agency_id into new.agency_id from public.applications where id = new.application_id;
  new.author_id := auth.uid();
  return new;
end $$;

drop trigger if exists notes_set_agency on public.application_notes;
create trigger notes_set_agency
  before insert on public.application_notes
  for each row execute function public.notes_set_agency();

-- ---------------------------------------------------------------------
-- 6. ROW LEVEL SECURITY — the isolation between agencies
-- ---------------------------------------------------------------------

-- AGENCIES
alter table public.agencies enable row level security;
revoke all on public.agencies from anon;
-- Owners may edit branding/contact only — never plan or is_active
revoke update on public.agencies from authenticated;
grant update (name, logo_path, primary_colour, accent_colour, contact_email, contact_phone, website)
  on public.agencies to authenticated;

drop policy if exists "v1 members read own agency"   on public.agencies;
drop policy if exists "v1 owners update own agency"  on public.agencies;
create policy "v1 members read own agency" on public.agencies
  for select to authenticated using (public.is_agency_member(id));
create policy "v1 owners update own agency" on public.agencies
  for update to authenticated
  using (public.is_agency_owner(id)) with check (public.is_agency_owner(id));

-- AGENCY MEMBERS
alter table public.agency_members enable row level security;
revoke all on public.agency_members from anon;

drop policy if exists "v1 members see their team" on public.agency_members;
drop policy if exists "v1 owners add members"     on public.agency_members;
drop policy if exists "v1 owners remove members"  on public.agency_members;
create policy "v1 members see their team" on public.agency_members
  for select to authenticated
  using (user_id = auth.uid() or public.is_agency_member(agency_id));
create policy "v1 owners add members" on public.agency_members
  for insert to authenticated with check (public.is_agency_owner(agency_id));
create policy "v1 owners remove members" on public.agency_members
  for delete to authenticated using (public.is_agency_owner(agency_id));

-- APPLICATIONS
alter table public.applications enable row level security;

drop policy if exists "v1 public can submit"         on public.applications;
drop policy if exists "v1 members read applications" on public.applications;
drop policy if exists "v1 members update applications" on public.applications;
drop policy if exists "v1 owners delete applications"   on public.applications;

-- Students (not logged in) can submit, but can never read anything back
create policy "v1 public can submit" on public.applications
  for insert to anon, authenticated
  with check (status = 'new' and public.agency_is_active(agency_id));
create policy "v1 members read applications" on public.applications
  for select to authenticated using (public.is_agency_member(agency_id));
create policy "v1 members update applications" on public.applications
  for update to authenticated
  using (public.is_agency_member(agency_id)) with check (public.is_agency_member(agency_id));
create policy "v1 owners delete applications" on public.applications
  for delete to authenticated using (public.is_agency_owner(agency_id));

-- APPLICATION NOTES
alter table public.application_notes enable row level security;
revoke all on public.application_notes from anon;

drop policy if exists "v1 members read notes"   on public.application_notes;
drop policy if exists "v1 members add notes"    on public.application_notes;
drop policy if exists "v1 authors delete notes" on public.application_notes;
create policy "v1 members read notes" on public.application_notes
  for select to authenticated using (public.is_agency_member(agency_id));
create policy "v1 members add notes" on public.application_notes
  for insert to authenticated with check (public.is_agency_member(agency_id));
create policy "v1 authors delete notes" on public.application_notes
  for delete to authenticated using (author_id = auth.uid());

-- ---------------------------------------------------------------------
-- 7. Functions the front end calls
-- ---------------------------------------------------------------------

-- Public form: load an agency's branding from its link, e.g. iata4u.com/a/sky-touch
-- JS: supabase.rpc('get_agency_by_slug', { p_slug: 'sky-touch' })
create or replace function public.get_agency_by_slug(p_slug text)
returns table (id uuid, name text, slug text, logo_path text,
               primary_colour text, accent_colour text,
               contact_email text, contact_phone text, website text)
language sql stable security definer set search_path = public as $$
  select id, name, slug, logo_path, primary_colour, accent_colour,
         contact_email, contact_phone, website
  from public.agencies
  where slug = lower(p_slug) and is_active;
$$;
grant execute on function public.get_agency_by_slug(text) to anon, authenticated;

-- Agent sign-up: creates the agency and makes the caller its owner
-- JS: supabase.rpc('create_agency', { p_name: 'Bright Path', p_slug: 'bright-path' })
create or replace function public.create_agency(p_name text, p_slug text)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then
    raise exception 'You must be signed in to create an agency';
  end if;
  insert into public.agencies (name, slug)
  values (trim(p_name), lower(trim(p_slug)))
  returning id into v_id;
  insert into public.agency_members (agency_id, user_id, role)
  values (v_id, auth.uid(), 'owner');
  return v_id;
end $$;
revoke execute on function public.create_agency(text, text) from public, anon;
grant  execute on function public.create_agency(text, text) to authenticated;

-- ---------------------------------------------------------------------
-- 8. STORAGE
--    documents bucket: files go under  <agency_id>/<application ref>/<file>
--    agency-logos bucket (public):    <agency_id>/logo.png
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('agency-logos', 'agency-logos', true, 2097152,
        array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "v1 public upload to agency folder" on storage.objects;
drop policy if exists "v1 members read agency documents"  on storage.objects;
drop policy if exists "v1 owners delete agency documents" on storage.objects;
drop policy if exists "v1 owners manage logo insert"      on storage.objects;
drop policy if exists "v1 owners manage logo update"      on storage.objects;
drop policy if exists "v1 owners manage logo delete"      on storage.objects;

-- Students upload only into an active agency's folder; they can't read back
create policy "v1 public upload to agency folder" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'documents'
              and public.agency_folder_is_active((storage.foldername(name))[1]));

create policy "v1 members read agency documents" on storage.objects
  for select to authenticated
  using (bucket_id = 'documents'
         and public.is_agency_member_folder((storage.foldername(name))[1]));

create policy "v1 owners delete agency documents" on storage.objects
  for delete to authenticated
  using (bucket_id = 'documents'
         and public.is_agency_owner_folder((storage.foldername(name))[1]));

create policy "v1 owners manage logo insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'agency-logos'
              and public.is_agency_owner_folder((storage.foldername(name))[1]));
create policy "v1 owners manage logo update" on storage.objects
  for update to authenticated
  using (bucket_id = 'agency-logos'
         and public.is_agency_owner_folder((storage.foldername(name))[1]));
create policy "v1 owners manage logo delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'agency-logos'
         and public.is_agency_owner_folder((storage.foldername(name))[1]));

commit;

-- =====================================================================
-- AFTER RUNNING: check for OLD policies that could leak data.
-- Policies combine with OR, so an older "anon can read" policy would
-- override the isolation above. Run this and review anything NOT
-- starting with "v1":
--
--   select schemaname, tablename, policyname, roles, cmd
--   from pg_policies
--   where tablename in ('applications', 'agencies', 'agency_members',
--                       'application_notes', 'objects')
--   order by tablename, policyname;
--
-- Then make yourself owner of Sky Touch (swap in your email):
--
--   insert into public.agency_members (agency_id, user_id, role)
--   select a.id, u.id, 'owner'
--   from public.agencies a, auth.users u
--   where a.slug = 'sky-touch' and u.email = 'you@example.com';
-- =====================================================================
