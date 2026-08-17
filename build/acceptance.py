#!/usr/bin/env python3
# ============================================================================
#  CymbalGoal — Stage 3 acceptance check
#
#  Validates the ARTIFACTS, not any in-memory state. Reads only schema.sql,
#  indexes.sql, the gzipped CSVs, and manifest.json, so it can be run by the
#  pipeline notebook, by a provisioning script, or by hand months later.
#
#  Emitted by notebooks/cymbalgoal_de_pipeline_part1.ipynb. Do not hand-edit:
#  edit the notebook and re-emit, or the two will drift.
#
#  Exit code 0 = pass, 1 = fail. Safe to gate a shell script on.
#
#    python3 acceptance.py --base /content/cymbalgoal
#    python3 acceptance.py --base ./work --skip-bucket
# ============================================================================
import argparse
import csv
import gzip
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

csv.field_size_limit(10 * 1024 * 1024)   # profile_text is long

ap = argparse.ArgumentParser(description="CymbalGoal Stage 3 acceptance check")
ap.add_argument("--base", default="/content/cymbalgoal",
                help="working root containing csv/ and artifacts/")
ap.add_argument("--csv-dir", default=None, help="override <base>/csv")
ap.add_argument("--artifacts", default=None, help="override <base>/artifacts")
ap.add_argument("--gcs-prefix", default="gs://class-demo/alloydb-labs/cymbalgoal",
                help="bucket prefix to compare against")
ap.add_argument("--skip-bucket", action="store_true", help="skip the bucket comparison")
ap.add_argument("--report", default=None, help="override <artifacts>/stage3_acceptance.txt")
args = ap.parse_args()

BASE     = Path(args.base)
CSV_DIR  = Path(args.csv_dir) if args.csv_dir else BASE / "csv"
ARTIFACT = Path(args.artifacts) if args.artifacts else BASE / "artifacts"
SQL_PATH = ARTIFACT / "schema.sql"
IDX_PATH = ARTIFACT / "indexes.sql"
MF_PATH  = ARTIFACT / "manifest.json"
REPORT   = Path(args.report) if args.report else ARTIFACT / "stage3_acceptance.txt"

L, FAIL = [], []


def p(s=""):
    L.append(str(s))
    print(s)


def check(ok, msg):
    p(("  OK   " if ok else "  FAIL ") + msg)
    if not ok:
        FAIL.append(msg)


def statements_only(sql):
    "Strip -- comments so prose mentioning CREATE TABLE does not trip a check."
    return "\n".join(l for l in sql.splitlines() if not l.strip().startswith("--"))


for required in (SQL_PATH, MF_PATH):
    if not required.exists():
        sys.exit(f"FATAL: {required} not found. Wrong --base?")

sql = SQL_PATH.read_text()
mf = json.loads(MF_PATH.read_text())
ORDER = mf["load_order"]

# ---------------------------------------------------------------- parse DDL
cols, types, notnull, fks, pks = {}, {}, {}, [], {}
cur = None
for line in sql.splitlines():
    m = re.match(r"\s*CREATE TABLE (\w+)", line)
    if m:
        cur = m.group(1)
        cols[cur], types[cur], notnull[cur] = [], {}, set()
        continue
    if cur is None:
        continue
    if line.strip().startswith(")"):
        cur = None
        continue
    m = re.match(r"\s+PRIMARY KEY \(([^)]+)\)", line)
    if m:
        pks[cur] = [c.strip() for c in m.group(1).split(",")]
        continue
    m = re.match(r"\s+(\w+)\s+([A-Z]+(?:\(\d+(?:,\d+)?\))?)(.*)", line)
    if m and m.group(1).upper() not in ("PRIMARY", "FOREIGN", "CONSTRAINT", "UNIQUE"):
        name, typ, rest = m.group(1), m.group(2), m.group(3)
        cols[cur].append(name)
        types[cur][name] = typ
        if "NOT NULL" in rest:
            notnull[cur].add(name)
        if "PRIMARY KEY" in rest:
            pks[cur] = [name]
        r = re.search(r"REFERENCES (\w+) \((\w+)\)", rest)
        if r:
            fks.append((cur, name, r.group(1), r.group(2)))

PASS2 = {"profile_text", "profile_embedding"}
INTS = {"INTEGER", "BIGINT", "SMALLINT"}
EXPECT = {t: [c for c in cs if c not in PASS2] for t, cs in cols.items()}
INT_RE = re.compile(r"^-?\d+$")
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")

p("=" * 78)
p("CYMBALGOAL STAGE 3 — ACCEPTANCE CHECK")
p("=" * 78)
p(f"base         {BASE}")
p(f"schema.sql   {len(sql):,} bytes")
p(f"manifest     snapshot {mf['snapshot']['date']}  {mf['snapshot']['sha256'][:16]}")
p(f"scope        {', '.join(mf['scope']['competitions'])}")

# ------------------------------------------------------- 0. DDL/index split
p("\n--- 0. DDL / INDEX SPLIT -------------------------------------------------")
check("CREATE INDEX" not in statements_only(sql),
      "schema.sql has no index statements (applies cleanly to an empty database)")
if IDX_PATH.exists():
    idx_sql = IDX_PATH.read_text()
    n_idx = statements_only(idx_sql).count("CREATE INDEX")
    check("CREATE TABLE" not in statements_only(idx_sql),
          "indexes.sql has no table statements")
    check(n_idx >= 2, f"indexes.sql carries the indexes ({n_idx} found)")
    check(idx_sql.lower().count("using scann") == 2, "both ScaNN indexes present")
    check("BM25 index is deliberately NOT created" in idx_sql,
          "BM25 note survived the split (building it is Lab 1 Task 3)")
else:
    check(False, "indexes.sql exists")

# ------------------------------------------- 1. structure, types, nullability
keys, fk_vals = {}, {}
p("\n--- 1. FILE STRUCTURE, TYPES, NULLABILITY -------------------------------")
for t in ORDER:
    path = CSV_DIR / f"{t}.csv.gz"
    if not path.exists():
        check(False, f"{t}: {path.name} missing")
        continue
    exp = EXPECT[t]
    idx = {c: i for i, c in enumerate(exp)}
    int_i = [idx[c] for c in exp if types[t][c] in INTS]
    date_i = [idx[c] for c in exp if types[t][c] == "DATE"]
    nn_i = [idx[c] for c in exp if c in notnull[t]]
    pk = pks.get(t, [])
    pk_i = [idx[c] for c in pk if c in idx]

    n = badlen = badint = baddate = badnull = 0
    seen, first = set(), None
    parents = {c: set() for c in pk}
    childvals = {cc: set() for (ct, cc, _, _) in fks if ct == t}
    for (_, _, pt, pc) in fks:
        if pt == t and pc in idx:
            parents.setdefault(pc, set())

    with gzip.open(path, "rt", encoding="utf-8", newline="") as fh:
        for row in csv.reader(fh):
            n += 1
            if first is None:
                first = row
            if len(row) != len(exp):
                badlen += 1
                continue
            for i in int_i:
                if row[i] and not INT_RE.match(row[i]):
                    badint += 1
            for i in date_i:
                if row[i] and not DATE_RE.match(row[i]):
                    baddate += 1
            for i in nn_i:
                if row[i] == "":
                    badnull += 1
            if pk_i:
                seen.add(tuple(row[i] for i in pk_i))
            for c in parents:
                if c in idx:
                    parents[c].add(row[idx[c]])
            for c in childvals:
                if c in idx and row[idx[c]]:
                    childvals[c].add(row[idx[c]])

    keys[t], fk_vals[t] = parents, childvals
    sf = mf["staged_files"][t]
    p(f"\n  {t}  ({n:,} rows x {len(exp)} cols)")
    check(exp == sf["column_order"], f"{t}: column order matches DDL and manifest")
    check(n == sf["rows"], f"{t}: row count {n:,} matches manifest")
    check(badlen == 0, f"{t}: every row has {len(exp)} fields")
    check(badint == 0, f"{t}: no float-formatted integers ({badint} bad)")
    check(baddate == 0, f"{t}: dates are YYYY-MM-DD ({baddate} bad)")
    check(badnull == 0, f"{t}: NOT NULL columns populated ({badnull} empty)")
    if pk_i:
        check(len(seen) == n, f"{t}: primary key {'+'.join(pk)} is unique")
    if first:
        check(first[0] != exp[0], f"{t}: no header row")

# ------------------------------------------------------- 2. FK integrity
p("\n--- 2. FOREIGN KEY INTEGRITY (across the actual files) ------------------")
for ct, cc, pt, pc in fks:
    child = fk_vals.get(ct, {}).get(cc)
    parent = keys.get(pt, {}).get(pc)
    if child is None or parent is None:
        p(f"  ..   {ct}.{cc} -> {pt}.{pc}  (not captured)")
        continue
    orph = child - parent
    check(not orph, f"{ct}.{cc} -> {pt}.{pc}  ({len(orph):,} unresolvable)")

# ------------------------------------------------------------- 3. checksums
p("\n--- 3. CHECKSUMS vs MANIFEST -------------------------------------------")
for t in ORDER:
    path = CSV_DIR / f"{t}.csv.gz"
    if not path.exists():
        continue
    h = hashlib.sha256(path.read_bytes()).hexdigest()
    check(h == mf["staged_files"][t]["sha256"], f"{t}: sha256 matches manifest")

# ----------------------------------------------------------- 4. Lab 1 canary
p("\n--- 4. LAB 1 CANARY ------------------------------------------------------")
pidx = {c: i for i, c in enumerate(EXPECT["players"])}
hits = []
with gzip.open(CSV_DIR / "players.csv.gz", "rt", encoding="utf-8", newline="") as fh:
    for row in csv.reader(fh):
        if "messi" in row[pidx["player_name"]].lower():
            hits.append((row[pidx["player_id"]], row[pidx["player_name"]]))
for i, nm in hits:
    p(f"       {i:<10} {nm}")
check(any(nm.strip().lower() == "lionel messi" for _, nm in hits),
      "Lionel Messi present in players.csv.gz")
check(len(hits) >= 2, f"at least one BM25 decoy present ({len(hits)} 'messi' matches)")

# --------------------------------------------------------------- 5. bucket
p("\n--- 5. BUCKET vs LOCAL ---------------------------------------------------")
if args.skip_bucket:
    p("  ..   skipped by --skip-bucket")
else:
    dest = args.gcs_prefix.rstrip("/") + "/"
    try:
        ls = subprocess.run(["gcloud", "storage", "ls", "-l", dest],
                            capture_output=True, text=True)
        ls_out, ls_err = ls.stdout, ls.stderr
    except FileNotFoundError:
        ls_out, ls_err = "", "gcloud not on PATH"
    remote = {}
    for line in (ls_out or "").splitlines():
        m = re.match(r"\s*(\d+)\s+\S+\s+(gs://\S+)", line)
        if m:
            remote[m.group(2).rsplit("/", 1)[-1]] = int(m.group(1))
    if not remote:
        p("  ..   bucket not listed — SKIPPED, not failed. Local checks stand.")
        p(f"       {(ls_err or '').strip()[:200]}")
    else:
        for t in ORDER:
            f = f"{t}.csv.gz"
            check(remote.get(f) == mf["staged_files"][t]["gz_bytes"],
                  f"{f}: bucket size matches local")
        for f, local in (("schema.sql", SQL_PATH), ("indexes.sql", IDX_PATH)):
            check(f in remote, f"{f} present in bucket")
            if local.exists() and f in remote:
                check(remote[f] == local.stat().st_size, f"{f} in bucket matches local")

# --------------------------------------------------------------- verdict
p("\n" + "=" * 78)
if FAIL:
    p(f"ACCEPTANCE FAILED — {len(FAIL)} check(s). Do not hand these files to the loader.")
    for f in FAIL:
        p(f"     - {f}")
else:
    p("ACCEPTANCE PASSED — the staged artifacts are safe to load.")
p("=" * 78)

REPORT.parent.mkdir(parents=True, exist_ok=True)
REPORT.write_text("\n".join(L))
print(f"\n[written to {REPORT}]")
sys.exit(1 if FAIL else 0)
