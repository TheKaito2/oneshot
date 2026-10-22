// Deletes training photos older than 2 years (the retention the privacy policy promises). Called daily by pg_cron
// (migration 20261023000100) with the x-cron-secret header; anything else gets 401. Storage objects must be removed
// through the Storage API: Supabase blocks deleting them with SQL.
import { createClient } from "npm:@supabase/supabase-js@2";

function secretKey(): string {
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  const key = keys ? JSON.parse(keys).default : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key) throw new Error("no secret key in the function's environment");
  return key;
}

Deno.serve(async (req) => {
  const expected = Deno.env.get("CRON_SECRET");
  if (!expected || req.headers.get("x-cron-secret") !== expected) return new Response("unauthorized", { status: 401 });
  try {
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, secretKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    let removed = 0;
    for (let round = 0; round < 20; round++) {   // at most 20 000 a day; the rest go tomorrow
      const { data, error } = await admin.rpc("training_frames_expired", { max_rows: 1000 });
      if (error) throw error;
      const names = (data ?? []) as string[];
      if (names.length === 0) break;
      const { data: gone, error: removeError } = await admin.storage.from("training-frames").remove(names);
      if (removeError) throw removeError;
      removed += gone?.length ?? 0;
      if (!gone?.length) break;
    }
    return Response.json({ removed });
  } catch (error) {
    console.error(error);
    return new Response("failed", { status: 500 });
  }
});
