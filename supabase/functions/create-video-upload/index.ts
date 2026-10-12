// Mints a one-time Cloudflare Stream direct-upload URL on behalf of a
// signed-in user, so the browser can upload a video straight to
// Cloudflare without ever seeing the Cloudflare API token (which stays
// here, as a server-side secret - see supabase/README.md for how to
// set CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN).
//
// This function does NOT write anything to the videos table - that
// happens client-side, after the upload itself succeeds, via a normal
// insert that goes through the same Row Level Security policies as
// everything else (see supabase/schema.sql). This function only needs
// to decide whether to hand out an upload URL at all, using the exact
// same authorization rules (is_coach / linked_player_ids) by querying
// through a client scoped to the caller's own JWT - never a service
// role key, so it can't do anything the caller themselves couldn't.
//
// Supabase verifies the caller is signed in at all before this code
// ever runs (the default verify_jwt behavior) - the checks below are
// about WHICH player/scope they're allowed to upload for.
//
// Also handles a second request shape, { checkUid }: confirms with
// Cloudflare directly whether a given upload actually landed. Needed
// because Cloudflare's basic-POST direct-upload endpoint has been
// observed returning a non-2xx (confirmed: a 500 with an empty body)
// even when the file was received and encoded successfully - trusting
// that response status alone produces false "upload failed" errors for
// uploads that actually worked. The client calls this after the upload
// POST, regardless of what status that POST reported, and only treats
// the upload as failed if Cloudflare itself says the video doesn't exist.

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response(null, { headers: CORS_HEADERS });
  }

  if (req.method !== 'POST') {
    return jsonResponse({ error: 'Method not allowed' }, 405);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return jsonResponse({ error: 'Missing Authorization header' }, 401);
  }

  let body: { scope?: 'team' | string; maxDurationSeconds?: number; checkUid?: string };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400);
  }

  const accountId = Deno.env.get('CLOUDFLARE_ACCOUNT_ID');
  const apiToken = Deno.env.get('CLOUDFLARE_API_TOKEN');
  if (!accountId || !apiToken) {
    console.error('CLOUDFLARE_ACCOUNT_ID / CLOUDFLARE_API_TOKEN not set');
    return jsonResponse({ error: 'Video upload is not configured on the server yet' }, 500);
  }

  // Status-check mode: just confirming the caller is signed in (above) is
  // enough here - a Cloudflare video uid alone doesn't expose anything
  // meaningful, so this doesn't need the same per-scope authorization as
  // minting a new upload URL does.
  if (body.checkUid) {
    const statusResp = await fetch(
      `https://api.cloudflare.com/client/v4/accounts/${accountId}/stream/${body.checkUid}`,
      { headers: { Authorization: `Bearer ${apiToken}` } }
    );
    if (statusResp.status === 404) {
      return jsonResponse({ exists: false });
    }
    const statusData = await statusResp.json();
    if (!statusResp.ok || !statusData.success) {
      console.error('Cloudflare status check error:', JSON.stringify(statusData));
      return jsonResponse({ error: 'Could not check upload status' }, 502);
    }
    return jsonResponse({ exists: true, readyToStream: !!statusData.result?.readyToStream });
  }

  const { scope, maxDurationSeconds } = body;
  if (!scope || (scope !== 'team' && typeof scope !== 'string')) {
    return jsonResponse({ error: 'scope must be "team" or a player id' }, 400);
  }

  const { createClient } = await import('https://esm.sh/@supabase/supabase-js@2.117.3');
  // Scoped to the caller's own JWT, so every query below runs under
  // their Row Level Security - the same rules as the rest of the app.
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  if (scope === 'team') {
    const { data: isCoach, error } = await supabase.rpc('is_coach');
    if (error || !isCoach) {
      return jsonResponse({ error: 'Only the coach can upload a team-wide video' }, 403);
    }
  } else {
    const { data: player, error } = await supabase
      .from('players')
      .select('id')
      .eq('id', scope)
      .maybeSingle();
    // players SELECT is itself RLS-gated to the coach or that player's
    // linked parents/athletes - finding nothing means "not authorized
    // for this player," not necessarily "player doesn't exist."
    if (error || !player) {
      return jsonResponse({ error: 'Not authorized to upload for this player' }, 403);
    }
  }

  const cfResponse = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${accountId}/stream/direct_upload`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${apiToken}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        // Phone clips are short; cap well above any realistic practice/
        // game clip while still bounding worst-case storage per upload.
        maxDurationSeconds: Math.min(Math.max(maxDurationSeconds ?? 600, 1), 3600),
      }),
    }
  );

  const cfData = await cfResponse.json();
  if (!cfResponse.ok || !cfData.success) {
    console.error('Cloudflare direct_upload error:', JSON.stringify(cfData));
    return jsonResponse({ error: 'Could not start the video upload' }, 502);
  }

  return jsonResponse({ uploadURL: cfData.result.uploadURL, uid: cfData.result.uid });
});
