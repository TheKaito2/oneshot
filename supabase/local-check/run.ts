import { PGlite } from "npm:@electric-sql/pglite@0.3.14";
import { pgtap } from "npm:@electric-sql/pglite@0.3.14/pgtap";
// Runs the migrations and tests/rls.sql in PGlite (Postgres 17 in WASM) on a stand-in for Supabase's auth
// and storage schemas (stub.sql). No Docker, no project. Usage: deno run -A --no-lock supabase/local-check/run.ts
const root = decodeURIComponent(new URL("..", import.meta.url).pathname);
const db = new PGlite({ extensions: { pgtap } });
await db.exec(await Deno.readTextFile(new URL("./stub.sql", import.meta.url)));
for (const f of [...Deno.readDirSync(`${root}/migrations`)].map((e) => e.name).sort()) {
  await db.exec(await Deno.readTextFile(`${root}/migrations/${f}`));
  console.log("migrated", f);
}
const results = await db.exec(await Deno.readTextFile(`${root}/tests/rls.sql`));
let fail = 0;
for (const r of results) for (const row of r.rows) for (const v of Object.values(row)) {
  if (typeof v === "string" && /^(ok|not ok|#|1\.\.)/.test(v)) { console.log(v); if (v.startsWith("not ok")) fail++; }
}
Deno.exit(fail ? 1 : 0);
