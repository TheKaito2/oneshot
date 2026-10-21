// Deletes the caller's account and everything it owns (App Store Review Guideline 5.1.1(v)).
//
// POST with the user's access token: `Authorization: Bearer <access_token>`. Steps, each safe to repeat,
// so a failed call can simply be retried:
//   1. verify the JWT with the Auth server
//   2. remove the shop's Storage objects (product-photos/<shop_id>/...)
//   3. delete the shop row; every table cascades from it
//   4. delete the auth user (would cascade the shop too; step 3 makes the order explicit)
// Responds 200 {"deleted": true}, 401 for a missing or bad token, 405 for other methods, 500 on failure.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const BUCKET = "product-photos";

function secretKey(): string {
  // New API keys: SUPABASE_SECRET_KEYS = {"default": "sb_secret_..."}; legacy projects: SUPABASE_SERVICE_ROLE_KEY.
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  const key = keys ? JSON.parse(keys).default : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key) throw new Error("no secret key in the function's environment");
  return key;
}

function reply(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });
}

// Every object path under `prefix`, walking folders (Storage lists one level at a time).
async function listAll(admin: SupabaseClient, prefix: string): Promise<string[]> {
  const paths: string[] = [];
  for (let offset = 0; ; offset += 1000) {
    const { data, error } = await admin.storage.from(BUCKET).list(prefix, { limit: 1000, offset });
    if (error) throw error;
    for (const item of data) {
      const path = `${prefix}/${item.name}`;
      if (item.id === null) paths.push(...await listAll(admin, path)); // a folder
      else paths.push(path);
    }
    if (data.length < 1000) return paths;
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return reply(405, { error: "POST only" });

  const jwt = req.headers.get("Authorization")?.replace(/^Bearer\s+/i, "");
  if (!jwt) return reply(401, { error: "missing bearer token" });

  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, secretKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const { data: { user }, error: authError } = await admin.auth.getUser(jwt);
    if (authError || !user) return reply(401, { error: "invalid token" });

    const { data: shops, error: shopError } = await admin.from("shops").select("id").eq("owner", user.id);
    if (shopError) throw shopError;

    for (const { id } of shops) {
      const paths = await listAll(admin, id);
      for (let i = 0; i < paths.length; i += 1000) {
        const { error } = await admin.storage.from(BUCKET).remove(paths.slice(i, i + 1000));
        if (error) throw error;
      }
      const { error } = await admin.from("shops").delete().eq("id", id);
      if (error) throw error;
    }

    // TODO(sign-in-with-apple): once Apple sign-in is enabled, revoke the user's Apple token here, before the
    // user is deleted: POST https://appleid.apple.com/auth/revoke with client_id, a client_secret JWT signed by
    // the Sign in with Apple key (secret APPLE_PRIVATE_KEY etc. in this function's env), and the refresh token
    // from the authorization code the app sends. Apple requires this for apps offering Sign in with Apple.

    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) throw deleteError;

    return reply(200, { deleted: true });
  } catch (error) {
    console.error("delete-account failed", error); // details stay in the function logs
    return reply(500, { error: "could not delete the account; try again" });
  }
});
