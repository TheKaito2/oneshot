# Runs tests/rls.sql on the linked project without Docker (`supabase test db --linked` needs Docker for pg_prove).
# Each TAP line goes into a temp table; a closing RAISE returns them in the error text and aborts the transaction,
# so nothing is left behind. Usage, from the repo root: python3 supabase/local-check/remote.py
import pathlib, re, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parent.parent
lines = []
for line in (root / "tests/rls.sql").read_text().split("\n"):
    if line.startswith("select ") and not line.startswith(("select no_plan", "select set_config")):
        line = "insert into tap (line) " + line
    lines.append(line)
sql = "\n".join(lines).replace(
    "select no_plan();",
    "select no_plan();\ncreate temp table tap (n serial, line text);\n"
    "grant all on tap to public;\ngrant all on sequence tap_n_seq to public;", 1)
end = "insert into tap (line) select * from finish();\nrollback;"
assert end in sql, "tests/rls.sql no longer ends with finish(); rollback;"
sql = sql.replace(end, "insert into tap (line) select * from finish();\n"
                       "do $$ begin raise exception E'TAP\\n%', "
                       "(select string_agg(line, E'\\n' order by n) from tap); end $$;")

with tempfile.NamedTemporaryFile("w", suffix=".sql") as f:
    f.write(sql)
    f.flush()
    out = subprocess.run(["supabase", "db", "query", "--linked", "-f", f.name],
                         capture_output=True, text=True, stdin=subprocess.DEVNULL).stdout
text = out.replace("\\\\n", "\n").replace("\\n", "\n")
tap = [l for l in text.split("\n") if re.match(r"(not ok|ok) \d+|1\.\.\d+|#", l)]
if not tap:
    sys.exit("no TAP output; the SQL failed before finishing:\n" + out[-2000:])
print("\n".join(tap))
sys.exit(1 if any(l.startswith("not ok") for l in tap) else 0)
