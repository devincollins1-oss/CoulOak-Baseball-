# Supabase schema

`schema.sql` is the database schema and Row Level Security policies
behind the real-data pilot. **`index.html` now talks to this live** -
roster management and parent/athlete sign-in run through Supabase,
not `localStorage`. Everything else (focus signals, videos,
countdowns, plans, messages, season history) is still `localStorage`-only
for now - see "Not done yet" below.

## Applying it

1. Open your Supabase project's dashboard.
2. Project > SQL Editor > New query.
3. Paste the entire contents of `schema.sql`.
4. Run. It should finish with no errors (9 tables, 3 functions, RLS
   enabled on all 9 tables, 22 policies, 3 explicit grants).

Safe to run once on a fresh project. Re-running it on a project that
already has these tables will fail on the first `create table` (by
design - this isn't written to be idempotent). If you already ran an
earlier version of this file (before the `any_coach_profile_exists()`
bootstrap fix below existed), drop the `profiles` table's old insert
policy and re-run just that `create policy` statement, or drop and
recreate the whole schema if no real data has been entered yet.

## What this sets up

- `players`, `focus_signals`, `videos`, `video_comments`,
  `countdown_goals`, `plans`, `messages` - direct mapping of the data
  this app already tracks in `appState`.
- `profiles` - one row per signed-in user (coach or parent), created
  by app-side code right after Supabase Auth creates the account. The
  very first person to sign in and click "set me up as the coach"
  claims the coach role; RLS (`any_coach_profile_exists()`) closes
  that path permanently the moment one coach profile exists, so no one
  else can self-promote later.
- `parent_access` - replaces the old shared-access-code model. A coach
  grants a parent or athlete's email access to a specific player from
  Team Management; that person signs in with that exact email via a
  magic link, and RLS checks it against an `approved` row here. Email
  is read from the verified auth token (`auth.jwt() ->> 'email'`),
  never something the client can claim on its own.
- RLS policies giving coaches full read/write on everything, and
  parents/athletes read access scoped to their own linked player (plus
  team-wide videos and countdowns), with insert rights limited to
  their own check-ins and messages.

Verified locally against Postgres 16 with a stand-in `auth` schema
(not included here - Supabase provides the real one): confirmed a
parent sees only their own kid's players/signals/countdowns, cannot
insert a signal for another kid or forge a `coach`-sourced signal,
cannot update player stats directly, and an unapproved parent sees
nothing. Confirmed a coach sees and can write everything, including
pending `parent_access` requests. Confirmed the coach-role bootstrap
can only be claimed once, by the first person to do it.

The app-side integration (login flow, roster CRUD, parent invites) was
verified with Playwright using the *real* `@supabase/supabase-js`
client library with its network calls intercepted and replaced with
scripted responses - this sandbox can't reach `supabase.co` directly
(its network policy blocks it), so every sign-in branch, the roster
add/edit/delete paths, and the parent invite/revoke paths were
exercised against realistic mocked data rather than a live project.
**That's not the same as testing against your actual project** - see
the checklist below for what to verify by hand once this is deployed.

## Testing it for real

Once `schema.sql` is applied to your project and this code is live:

1. Open the app in a browser you haven't signed into before. Enter
   your email, click the link Supabase emails you.
2. You should land on "No coach account exists yet - is that you?" -
   confirm it. You're now the coach.
3. Add a player or two under Team Management.
4. Use "Invite Parent or Athlete" to grant a *different* email access
   to one of them (your own second email, or a friend's).
5. Open an incognito window (or a different browser), sign in with
   that second email. You should land directly in that player's
   parent/athlete view - no player picker, no access code.
6. In the Supabase dashboard's Table Editor, confirm the `players` and
   `parent_access` rows actually exist and match what you entered.
7. From Team Management, revoke that person's access, then try
   reloading their already-signed-in session - they should be bounced
   to "your coach hasn't granted you access yet."

If any of these don't match, something about the live project
(schema not applied, wrong URL/key, a typo in the email) is the likely
cause - check the browser console for the actual Supabase error first.

## Not done yet

- **focus_signals / videos / countdown_goals / plans / messages**:
  still `localStorage`-only, each per browser/device rather than
  shared. These tables exist in the schema and are ready for the same
  treatment players/parent_access just got.
- **Seasons/season history**: `appState` tracks these but they're not
  in this schema yet.
- **Cloudflare Stream wiring** for parent video uploads from their
  phones - separate piece, next up.
