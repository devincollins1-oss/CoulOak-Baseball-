# Supabase schema

`schema.sql` is the database schema and Row Level Security policies for
the real-data pilot (replacing `localStorage`). It has no effect on the
app as it exists today - `index.html` is unchanged and still runs
entirely on `localStorage` until a follow-up migrates the data layer
over to this.

## Applying it

1. Open your Supabase project's dashboard.
2. Project > SQL Editor > New query.
3. Paste the entire contents of `schema.sql`.
4. Run. It should finish with no errors (9 tables, 2 functions, RLS
   enabled on all 9 tables, 22 policies).

Safe to run once on a fresh project. Re-running it on a project that
already has these tables will fail on the first `create table` (by
design - this isn't written to be idempotent).

## What this sets up

- `players`, `focus_signals`, `videos`, `video_comments`,
  `countdown_goals`, `plans`, `messages` - direct mapping of the data
  this app already tracks in `appState`.
- `profiles` - one row per signed-in user (coach or parent), created
  by app-side code right after Supabase Auth creates the account.
- `parent_access` - replaces the old shared-access-code model. A coach
  approves a parent's email against a specific player; a parent only
  gets read access to that player's data once their *signed-in* email
  matches an `approved` row here. Email is read from the verified
  auth token (`auth.jwt() ->> 'email'`), never something the client
  can claim on its own.
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
pending `parent_access` requests.

## Not done yet

- **App-side integration**: swapping `index.html`'s `localStorage`
  calls for Supabase client calls, and building the real email
  sign-in flow. This repo's sandbox can't reach `supabase.co`
  directly (blocked by the environment's network policy), so that
  phase needs to be tested by opening the deployed app in a real
  browser rather than purely from here.
- **Seasons/season history**: `appState` tracks these but they're not
  in this schema yet - lower priority than getting players, signals,
  video, and auth working first.
- **Cloudflare Stream wiring** for parent video uploads - separate
  piece, needs a Cloudflare account + API token (not created yet).
