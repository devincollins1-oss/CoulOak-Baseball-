-- ============================================================
-- Couloak Baseball — initial Supabase schema
--
-- Run once in the Supabase dashboard: Project > SQL Editor > New
-- query > paste this whole file > Run. Safe to re-run from scratch
-- only on an empty project (every CREATE TABLE will fail if the
-- tables already exist).
--
-- Replaces the old shared-access-code model with real per-person
-- grants: a coach approves a parent's email against a specific
-- player in parent_access, and Row Level Security below uses that
-- table (matched against the signed-in user's own email - never
-- something the client can fake) to decide what each parent can see.
-- ============================================================

-- ------------------------------------------------------------
-- Tables
-- ------------------------------------------------------------

-- One row per signed-in user, created by the app right after
-- Supabase Auth creates the account (see app-side auth code).
create table profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text,
  role text not null default 'parent' check (role in ('coach', 'parent')),
  created_at timestamptz not null default now()
);

create table players (
  id uuid primary key default gen_random_uuid(),
  jersey_number int not null unique,
  first_name text not null,
  last_name text not null,
  pa int not null default 0,
  ab int not null default 0,
  avg numeric(4,3) not null default 0,
  k int not null default 0,
  bb int not null default 0,
  h int not null default 0,
  ip numeric(4,1) not null default 0,
  bf int not null default 0,
  er int not null default 0,
  pitch_k int not null default 0,
  pitch_bb int not null default 0,
  created_at timestamptz not null default now()
);

-- Coach-managed invite/approval list. A parent (or athlete, sharing
-- the same access model) only sees a player's data once their signed
-- -in email has an 'approved' row here for that player.
create table parent_access (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  parent_email text not null,
  parent_name text,
  relationship text not null default 'parent' check (relationship in ('parent', 'athlete')),
  status text not null default 'pending' check (status in ('pending', 'approved', 'denied')),
  requested_at timestamptz not null default now(),
  approved_at timestamptz
);

create table focus_signals (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  source text not null check (source in ('stat', 'coach', 'video', 'athlete', 'parent', 'countdown')),
  category text not null check (category in ('hitting', 'pitching', 'fielding', 'baserunning', 'mental', 'conditioning')),
  metric text,
  value numeric,
  priority text not null check (priority in ('good', 'watch', 'high')),
  insight text not null,
  tags text[] not null default '{}',
  flagged_by text,
  flagged_date timestamptz not null default now(),
  source_video_id uuid,
  source_video_name text,
  source_countdown_id uuid,
  source_countdown_name text,
  milestone_label text
);

create table videos (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  url text not null,
  description text,
  assigned_to_player_id uuid references players(id) on delete cascade,
  assigned_to_team boolean not null default false,
  uploaded_by uuid references profiles(id),
  upload_date timestamptz not null default now(),
  constraint videos_assignment_check check (
    (assigned_to_team = true and assigned_to_player_id is null)
    or (assigned_to_team = false and assigned_to_player_id is not null)
  )
);

create table video_comments (
  id uuid primary key default gen_random_uuid(),
  video_id uuid not null references videos(id) on delete cascade,
  author_id uuid references profiles(id),
  body text not null,
  promoted boolean not null default false,
  created_at timestamptz not null default now()
);

create table countdown_goals (
  id uuid primary key default gen_random_uuid(),
  event_name text not null,
  event_date date not null,
  scope_team boolean not null default false,
  scope_player_id uuid references players(id) on delete cascade,
  preparation_focus text,
  progress_state text not null default 'active' check (progress_state in ('active', 'completed', 'archived')),
  fired_milestones int[] not null default '{}',
  created_by uuid references profiles(id),
  created_at timestamptz not null default now(),
  constraint countdown_scope_check check (
    (scope_team = true and scope_player_id is null)
    or (scope_team = false and scope_player_id is not null)
  )
);

create table plans (
  player_id uuid primary key references players(id) on delete cascade,
  focus_tags text[] not null default '{}',
  insight text,
  drills jsonb not null default '[]',
  coach_cue text,
  parent_cue text,
  assigned_date timestamptz not null default now(),
  adherence jsonb not null default '[]'
);

create table messages (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references players(id) on delete cascade,
  sender_id uuid references profiles(id),
  sender_role text not null check (sender_role in ('coach', 'parent')),
  body text not null,
  created_at timestamptz not null default now()
);

-- ------------------------------------------------------------
-- Helper functions (security definer so they can read profiles /
-- parent_access without RLS on those tables blocking the check
-- itself - the standard Supabase pattern for this)
-- ------------------------------------------------------------

create or replace function is_coach()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from profiles where id = auth.uid() and role = 'coach'
  );
$$;

-- Player ids the signed-in user is an approved parent/athlete for,
-- matched on their verified auth email - never a client-supplied value.
create or replace function linked_player_ids()
returns setof uuid
language sql
security definer
set search_path = public
stable
as $$
  select player_id from parent_access
  where status = 'approved'
    and lower(parent_email) = lower(auth.jwt() ->> 'email');
$$;

-- Used only to gate the one-time "claim the coach role" bootstrap
-- insert below - true once any coach profile exists, permanently
-- closing that path for everyone after the first one.
create or replace function any_coach_profile_exists()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (select 1 from profiles where role = 'coach');
$$;

-- Explicit rather than relying on default privileges: is_coach() and
-- linked_player_ids() are invoked implicitly from inside RLS policies,
-- and any_coach_profile_exists() is also called directly from the app
-- (via PostgREST's /rpc/ endpoint) during the sign-in bootstrap check.
grant execute on function is_coach() to authenticated;
grant execute on function linked_player_ids() to authenticated;
grant execute on function any_coach_profile_exists() to authenticated;

-- ------------------------------------------------------------
-- Row Level Security
-- ------------------------------------------------------------

alter table profiles enable row level security;
alter table players enable row level security;
alter table parent_access enable row level security;
alter table focus_signals enable row level security;
alter table videos enable row level security;
alter table video_comments enable row level security;
alter table countdown_goals enable row level security;
alter table plans enable row level security;
alter table messages enable row level security;

-- profiles: everyone can read their own row; coaches can read everyone's
create policy "Users read their own profile"
  on profiles for select
  using (id = auth.uid() or is_coach());

-- A user may only ever insert their own row, and may only claim the
-- 'coach' role while no coach exists yet (the one-time setup step -
-- see any_coach_profile_exists() above). Every sign-in after that
-- first one can only create a 'parent' profile.
create policy "Users create their own profile"
  on profiles for insert
  with check (
    id = auth.uid()
    and (role = 'parent' or (role = 'coach' and not any_coach_profile_exists()))
  );

create policy "Coaches manage all profiles"
  on profiles for update
  using (is_coach());

-- players: coaches manage; linked parents/athletes read their own kid
create policy "Coaches manage players"
  on players for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view their linked players"
  on players for select
  using (id in (select linked_player_ids()));

-- parent_access: coaches manage; a parent can see their own request rows
create policy "Coaches manage parent access"
  on parent_access for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view their own access rows"
  on parent_access for select
  using (lower(parent_email) = lower(auth.jwt() ->> 'email'));

-- focus_signals: coaches manage everything; linked parents/athletes
-- can read their kid's signals, and can submit their own check-ins
-- (source athlete/parent) but nothing else
create policy "Coaches manage focus signals"
  on focus_signals for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view their linked players' signals"
  on focus_signals for select
  using (player_id in (select linked_player_ids()));

create policy "Linked parents/athletes submit check-in signals"
  on focus_signals for insert
  with check (
    source in ('athlete', 'parent')
    and player_id in (select linked_player_ids())
  );

-- videos: coaches manage everything; linked parents/athletes see
-- team-wide videos and anything assigned to their own kid
create policy "Coaches manage videos"
  on videos for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view relevant videos"
  on videos for select
  using (
    assigned_to_team = true
    or assigned_to_player_id in (select linked_player_ids())
  );

-- video_comments: coaches manage everything; linked parents/athletes
-- can read and add comments on videos they can see
create policy "Coaches manage video comments"
  on video_comments for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view comments on relevant videos"
  on video_comments for select
  using (
    video_id in (
      select id from videos
      where assigned_to_team = true
         or assigned_to_player_id in (select linked_player_ids())
    )
  );

create policy "Parents comment on relevant videos"
  on video_comments for insert
  with check (
    video_id in (
      select id from videos
      where assigned_to_team = true
         or assigned_to_player_id in (select linked_player_ids())
    )
  );

-- countdown_goals: coaches manage everything; linked parents/athletes
-- see team-wide countdowns and anything scoped to their own kid
create policy "Coaches manage countdowns"
  on countdown_goals for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view relevant countdowns"
  on countdown_goals for select
  using (
    scope_team = true
    or scope_player_id in (select linked_player_ids())
  );

-- plans: coaches manage everything; linked parents/athletes read their kid's plan
create policy "Coaches manage plans"
  on plans for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view their linked player's plan"
  on plans for select
  using (player_id in (select linked_player_ids()));

-- messages: coaches manage everything; linked parents/athletes read
-- and send messages tied to their own kid
create policy "Coaches manage messages"
  on messages for all
  using (is_coach())
  with check (is_coach());

create policy "Parents view their linked player's messages"
  on messages for select
  using (player_id in (select linked_player_ids()));

create policy "Parents send messages for their linked player"
  on messages for insert
  with check (
    sender_role = 'parent'
    and player_id in (select linked_player_ids())
  );
