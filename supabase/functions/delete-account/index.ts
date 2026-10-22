// Deletes the caller's account and everything it owns (App Store Review Guideline 5.1.1(v)).
//
// POST with the user's access token: `Authorization: Bearer <access_token>`, and for an account that signed in with
// Apple, JSON {"apple_authorization_code": "<fresh code>"} so its Apple token can be revoked. Steps, each safe to repeat,
// so a failed call can simply be retried:
//   1. verify the JWT with the Auth server
//   2. remove the shop's Storage objects (product-photos/<shop_id>/...)
//   3. delete the shop row; every table cascades from it
//   4. delete the auth user (would cascade the shop too; step 3 makes the order explicit)
// Responds 200 {"deleted": true}, 401 for a missing or bad token, 405 for other methods, 500 on failure.
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";
import { importPKCS8, SignJWT } from "npm:jose@5";

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

// Sign in with Apple: Apple requires an app to revoke the user's Apple token when the account is deleted. The app sends
// a fresh authorization code (the user confirms with Apple once); it is exchanged for a token, which is revoked.
// The client secret is a 5-minute ES256 JWT signed with the Sign in with Apple key (function secrets APPLE_*).
async function revokeApple(code: string): Promise<void> {
  const env = (name: string) => {
    const value = Deno.env.get(name);
    if (!value) throw new Error(`missing ${name}`);
    return value;
  };
  const clientId = env("APPLE_CLIENT_ID");
  const key = await importPKCS8(env("APPLE_PRIVATE_KEY").replace(/\\+n/g, "\n"), "ES256");
  const now = Math.floor(Date.now() / 1000);
  const clientSecret = await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: env("APPLE_KEY_ID") })
    .setIssuer(env("APPLE_TEAM_ID")).setSubject(clientId).setAudience("https://appleid.apple.com")
    .setIssuedAt(now).setExpirationTime(now + 300)
    .sign(key);
  const form = (fields: Record<string, string>) => ({
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields),
  });
  const exchanged = await fetch("https://appleid.apple.com/auth/token",
    form({ client_id: clientId, client_secret: clientSecret, code, grant_type: "authorization_code" }));
  if (!exchanged.ok) throw new Error(`apple token exchange ${exchanged.status}`);
  const tokens = await exchanged.json();
  const token = tokens.refresh_token ?? tokens.access_token;
  const revoked = await fetch("https://appleid.apple.com/auth/revoke", form({
    client_id: clientId, client_secret: clientSecret, token,
    token_type_hint: tokens.refresh_token ? "refresh_token" : "access_token",
  }));
  if (!revoked.ok) throw new Error(`apple revoke ${revoked.status}`);
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

    // An Apple account: revoke its Apple token first. A failure is logged and the deletion goes on (the user asked
    // for it; the Apple link then shows in their Apple ID settings, where they can remove it themselves).
    const body = await req.json().catch(() => ({}));
    const appleCode = typeof body?.apple_authorization_code === "string" ? body.apple_authorization_code : null;
    if (user.identities?.some((identity) => identity.provider === "apple")) {
      if (appleCode) {
        await revokeApple(appleCode).catch((error) => console.error("apple revoke failed", error));
      } else {
        console.error("apple user deleted without an authorization code; token not revoked");
      }
    }

    const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
    if (deleteError) throw deleteError;

    return reply(200, { deleted: true });
  } catch (error) {
    console.error("delete-account failed", error); // details stay in the function logs
    return reply(500, { error: "could not delete the account; try again" });
  }
});
