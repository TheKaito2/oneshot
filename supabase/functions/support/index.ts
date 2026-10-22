// The support form (oneshot-pos.pages.dev/#contact): POST JSON {contact, message, lang, website}.
// `website` is a hidden honeypot: a bot that fills it gets a silent 200. One sender (by salted IP hash) may send
// 5 messages an hour. Messages land in public.support_messages, which only the service role can read.
import { createClient } from "npm:@supabase/supabase-js@2";

const ORIGIN = "https://oneshot-pos.pages.dev";
const cors = {
  "Access-Control-Allow-Origin": ORIGIN,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "content-type",
};

function secretKey(): string {
  const keys = Deno.env.get("SUPABASE_SECRET_KEYS");
  const key = keys ? JSON.parse(keys).default : Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!key) throw new Error("no secret key in the function's environment");
  return key;
}

async function sha256(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

const reply = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return reply(405, { error: "POST only" });
  try {
    const body = await req.json().catch(() => ({}));
    if (typeof body.website === "string" && body.website.length > 0) return reply(200, { sent: true });   // a bot
    const contact = String(body.contact ?? "").trim();
    const message = String(body.message ?? "").trim();
    const lang = String(body.lang ?? "").slice(0, 8);
    if (contact.length < 3 || contact.length > 200 || message.length < 5 || message.length > 4000) {
      return reply(400, { error: "Please add a way to reach you and a message (5 to 4000 characters)." });
    }
    const ip = req.headers.get("x-forwarded-for")?.split(",")[0].trim() ?? "unknown";
    const sender = await sha256(`${Deno.env.get("SUPPORT_SALT") ?? ""}:${ip}`);
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, secretKey(), {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const since = new Date(Date.now() - 3600_000).toISOString();
    const { count, error: countError } = await admin.from("support_messages").select("id", { count: "exact", head: true })
      .eq("sender_hash", sender).gte("created_at", since);
    if (countError) throw countError;
    if ((count ?? 0) >= 5) return reply(429, { error: "Too many messages. Please try again in an hour." });
    const { error } = await admin.from("support_messages").insert({ contact, message, lang, sender_hash: sender });
    if (error) throw error;
    return reply(200, { sent: true });
  } catch (error) {
    console.error(error);
    return reply(500, { error: "Couldn't send. Please try again later." });
  }
});
