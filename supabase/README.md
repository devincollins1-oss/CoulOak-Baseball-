# Supabase schema

`schema.sql` is the database schema and Row Level Security policies
behind the real-data pilot. **`index.html` now talks to this live** -
roster management, parent/athlete sign-in, and video (both pasted
links and direct phone uploads via Cloudflare Stream) run through
Supabase, not `localStorage`. Everything else (focus signals,
countdowns, plans, messages, season history) is still
`localStorage`-only for now - see "Not done yet" below.

## Applying it

1. Open your Supabase project's dashboard.
2. Project > SQL Editor > New query.
3. Paste the entire contents of `schema.sql`.
4. Run. It should finish with no errors (10 tables, 5 functions, RLS
   enabled on all 10 tables, 25 policies, 5 explicit grants).

Safe to run once on a fresh project. Re-running it on a project that
already has these tables will fail on the first `create table` (by
design - this isn't written to be idempotent). If you already applied
an earlier version of this file, the pieces added since are additive -
re-run just the statements for whichever round(s) you're missing,
rather than the whole file.

**Round: videos uploaded from a phone (not just pasted links)**
```sql
alter table videos add column if not exists uploaded_by_name text;
alter table videos add column if not exists cloudflare_uid text;
alter table video_comments add column if not exists author_name text;
alter table video_comments add column if not exists author_role text;
alter table video_comments add column if not exists video_timestamp text;

create policy "Parents upload videos for their linked player"
  on videos for insert
  with check (
    assigned_to_team = false
    and assigned_to_player_id in (select linked_player_ids())
  );
```

(If you applied the schema before the `any_coach_profile_exists()`
bootstrap security fix landed, see the previous round's note in git
history for that patch too.)

**Round: admin role, which can invite other coaches**

This renames the one-time bootstrap role from "coach" to "admin" (an
admin has every coach permission, plus the ability to invite other
coaches) and adds a `coach_invites` table so an admin can grant someone
else the coach role, the same pre-approved way `parent_access` already
works for parents. Run this once:

```sql
alter table profiles drop constraint profiles_role_check;
alter table profiles add constraint profiles_role_check check (role in ('coach', 'parent', 'admin'));

create table coach_invites (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  full_name text,
  status text not null default 'approved' check (status in ('pending', 'approved', 'revoked')),
  invited_by uuid references profiles(id),
  invited_at timestamptz not null default now()
);
alter table coach_invites enable row level security;

create or replace function is_coach()
returns boolean language sql security definer set search_path = public stable
as $$
  select exists (select 1 from profiles where id = auth.uid() and role in ('coach', 'admin'));
$$;

create or replace function is_admin()
returns boolean language sql security definer set search_path = public stable
as $$
  select exists (select 1 from profiles where id = auth.uid() and role = 'admin');
$$;

create or replace function any_admin_profile_exists()
returns boolean language sql security definer set search_path = public stable
as $$
  select exists (select 1 from profiles where role = 'admin');
$$;

create or replace function has_approved_coach_invite()
returns boolean language sql security definer set search_path = public stable
as $$
  select exists (
    select 1 from coach_invites
    where status = 'approved' and lower(email) = lower(auth.jwt() ->> 'email')
  );
$$;

grant execute on function is_admin() to authenticated;
grant execute on function any_admin_profile_exists() to authenticated;
grant execute on function has_approved_coach_invite() to authenticated;

drop policy "Users create their own profile" on profiles;
create policy "Users create their own profile"
  on profiles for insert
  with check (
    id = auth.uid()
    and (
      role = 'parent'
      or (role = 'admin' and not any_admin_profile_exists())
      or (role = 'coach' and has_approved_coach_invite())
    )
  );

create policy "Admins manage coach invites"
  on coach_invites for all
  using (is_admin())
  with check (is_admin());

create policy "Invited users view their own coach invite"
  on coach_invites for select
  using (lower(email) = lower(auth.jwt() ->> 'email'));

-- One-time: promote your existing coach account (there should only
-- ever be one, since the old bootstrap only allowed one claim) to
-- admin, so you keep the ability to invite other coaches.
update profiles set role = 'admin' where role = 'coach';
```

## What this sets up

- `players`, `focus_signals`, `videos`, `video_comments`,
  `countdown_goals`, `plans`, `messages` - direct mapping of the data
  this app already tracks in `appState`.
- `profiles` - one row per signed-in user (admin, coach, or parent),
  created by app-side code right after Supabase Auth creates the
  account. The very first person to sign in and click "set me up as
  the admin" claims the admin role; RLS (`any_admin_profile_exists()`)
  closes that path permanently the moment one admin profile exists. An
  admin has every coach permission (`is_coach()` returns true for
  admins too) plus the ability to invite other coaches - the one thing
  a regular coach can't do.
- `coach_invites` - an admin grants another email the coach role from
  Team Management's "Invite Coach" button; that person signs in with
  that exact email and gets full coach access, same pre-approved
  pattern as `parent_access` below.
- `parent_access` - a coach (or admin) grants a parent or athlete's
  email access to a specific player from Team Management; that person
  signs in with that exact email via a magic link, and RLS checks it
  against an `approved` row here.
- `videos` / `video_comments` - coaches can post a video (link or
  phone upload) to the whole team or one player; a linked parent/
  athlete can only upload for their own player, never team-wide.
  Comments are open to whoever can see the video.

Verified locally against Postgres 16 with a stand-in `auth` schema:
confirmed a parent sees only their own kid's players/signals/
countdowns/videos, cannot insert data for another kid, cannot forge a
`coach`-sourced signal or a team-wide video, and an unapproved parent
sees nothing. Confirmed a coach sees and can write everything, that
the admin-role bootstrap can only be claimed once, that a coach can't
self-claim without an invite, that only an admin (not a regular coach)
can create one, and that an invited coach gets full coach access once
they sign in.

The app-side integration was verified with Playwright using the
*real* `@supabase/supabase-js` client library with its network calls
intercepted and replaced with scripted responses (including the
Cloudflare direct-upload flow) - this sandbox can't reach `supabase.co`
or `cloudflare.com` directly. **That's not the same as testing against
your actual project** - see the checklists below for what to verify by
hand.

## Deploying the video-upload Edge Function

Parents uploading video from their phone needs a Cloudflare API token
that must never reach the browser - `supabase/functions/create-video-upload`
is a small server-side function that mints a one-time Cloudflare
upload URL on request, using that token as a secret. This can't be
deployed from this environment (it needs your own Supabase login) -
here's how to do it:

Supabase doesn't support installing its CLI globally with
`npm install -g supabase` - it'll fail with `command not found` even
after the install reports success. Prefix every command below with
`npx` instead (run from inside your clone of this repo):

1. `npx supabase login` (opens a browser to authenticate)
2. Link this repo to your project: `npx supabase link --project-ref tfdgvkxykphpazmqpjpt`
3. Set the two secrets the function needs (find your Account ID in the
   Cloudflare dashboard sidebar; use the actual values for both -
   neither is shown here since this file is committed to a public repo):
   ```
   npx supabase secrets set CLOUDFLARE_ACCOUNT_ID=<your Cloudflare account ID>
   npx supabase secrets set CLOUDFLARE_API_TOKEN=<your Cloudflare API token>
   ```
4. Deploy: `npx supabase functions deploy create-video-upload`

## One more config value needed

`index.html` has a placeholder for your Cloudflare Stream **customer
code** (used to build playback URLs - not secret, every public video
link for your account contains it):

```js
const CLOUDFLARE_STREAM_CUSTOMER_CODE = 'REPLACE_WITH_CUSTOMER_CODE';
```

Find it in the Cloudflare dashboard: Stream > any video > "Code
snippets" / embed button (it's the `customer-XXXXXXXX` part of the
URL shown). Replace the placeholder with the real value before
uploaded videos will actually play.

## Testing it for real

**Auth/roster** (once `schema.sql` is applied):
1. Open the app in a browser you haven't signed into before, sign in
   with your email via the magic link.
2. Land on "No admin account exists yet - is that you?" - confirm it.
3. Add a player or two under Team Management.
4. Invite a *different* email to one of them; sign in as that person
   in an incognito window - should land directly in their player's
   view, no picker, no code.
5. Confirm the rows actually exist in the Supabase Table Editor.
6. Revoke that access from Team Management; confirm their next reload
   gets bounced to "not granted access."
7. As the admin, use "Invite Coach" with a third email; sign in as
   that person - should land in the full coach view, but Team
   Management should *not* show them an "Invite Coach" button (only
   the admin gets that one).

**Video** (once the Edge Function is deployed and the customer code is set):
1. As coach, Video Analysis > "📤 Upload from Device" - pick a short
   clip, assign it to a player or the whole team, submit.
2. Confirm it appears in the library and actually plays.
3. Sign in as that player's linked parent; confirm they can see it (or
   can't, if it was assigned to someone else).
4. From the parent/athlete Videos tab, use their own "📤 Upload a
   video" button - confirm it uploads and the coach can see it too.
5. Post a comment from each role; confirm it's visible to the other.

If any of these don't match, check the browser console for the actual
Supabase/Cloudflare error first - most likely causes are the schema
not (fully) applied, the Edge Function not deployed, missing secrets,
or the customer code placeholder not yet replaced.

## Not done yet

- **focus_signals / countdown_goals / plans / messages**: still
  `localStorage`-only, each per browser/device rather than shared.
  These tables exist in the schema and are ready for the same
  treatment players/videos just got.
- **Seasons/season history**: `appState` tracks these but they're not
  in this schema yet.
