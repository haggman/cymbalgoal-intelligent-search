#!/usr/bin/env bash
#
# CymbalGoal — 05: full load, measured. The instructor-guide wall-clock number.
#
# WHERE: Cloud Shell, after 04.
# RUN:   bash 05-full-load-walltime.sh 2>&1 | tee ~/fullload.log
#
# Answers four things at once:
#   1. Does the vector query actually USE the ScaNN index, or is the planner
#      seq-scanning 13,439 rows? Same trap <@> had — assume nothing.
#   2. Total wall-clock for the real load: 8 relational tables (832,193
#      appearances) + pass 2 profiles + indexes.
#   3. 🔴 The ScaNN ORDERING DELTA — the cost of schema.sql building its indexes
#      on empty tables versus after the load. This is the number that decides
#      whether Stage 3 must re-emit schema.sql.
#   4. Whether load_profiles.sql runs clean and its assertions fire.
#
# Uses the documented no-restage fallback: apply schema.sql whole, capture the
# index DDL verbatim, DROP the two ScaNN indexes, load, rebuild. NO regex
# splitting of DDL — explicitly forbidden.
#
# CHANGELOG
#   v2  (a) Kill the pager for real. `-c "\pset pager off"` does not reliably
#           stick, so EXPLAIN output opened `less` and hijacked the terminal.
#           Fixed with PAGER/PSQL_PAGER=cat AND -P pager=off on every call.
#       (b) Drop the /usr/bin/time dependency — GNU time is not guaranteed in
#           Cloud Shell. Uses bash's own $SECONDS instead.

set -uo pipefail
source ~/cymbalgoal-conn.env

# Belt and braces: env vars psql honours, plus the per-invocation flag.
export PAGER=cat
export PSQL_PAGER=cat
PSQL="psql -X -P pager=off"

BUCKET="gs://class-demo/alloydb-labs/cymbalgoal"
WORK=~/cgload
mkdir -p "$WORK"

# ---------------------------------------------------------------------------
echo "################ 1. Is ScaNN actually being used? ################"
# ---------------------------------------------------------------------------
$PSQL -c "
EXPLAIN (ANALYZE, BUFFERS)
SELECT player_id FROM pv
ORDER BY emb <=> ai.embedding('gemini-embedding-001','a striker who gives centre-backs nightmares')::vector
LIMIT 5;"
echo
echo ">>> Want 'Index Scan using pv_scann'. A Seq Scan means every vector timing"
echo ">>> we have is brute force and Task 1's ScaNN aside is unearned."
echo
echo "--- can it use the index if forced? ---"
$PSQL -c "SET enable_seqscan=off;
EXPLAIN SELECT player_id FROM pv
ORDER BY emb <=> ai.embedding('gemini-embedding-001','test')::vector LIMIT 5;"

# ---------------------------------------------------------------------------
echo
echo "################ 2. Fetch schema + manifest ################"
# ---------------------------------------------------------------------------
gcloud storage cp "$BUCKET/schema.sql"        "$WORK/schema.sql"
gcloud storage cp "$BUCKET/manifest.json"     "$WORK/manifest.json"
gcloud storage cp "$BUCKET/load_profiles.sql" "$WORK/load_profiles.sql"

echo
echo "--- manifest structure (03 assumed a list; it is a dict) ---"
python3 - <<'PY'
import json, os
m = json.load(open(os.path.expanduser('~/cgload/manifest.json')))
sf = m.get('staged_files')
print('staged_files type:', type(sf).__name__)
items = sf.items() if isinstance(sf, dict) else [(f.get('name'), f) for f in sf]
for k, v in items:
    if isinstance(v, dict):
        co = v.get('column_order') or []
        print(f'  {str(k):32s} rows={str(v.get("row_count")):>9s}  cols={len(co)}')
PY

echo
echo "--- ScaNN index DDL that schema.sql carries, captured VERBATIM ---"
grep -n -i -B2 -A4 'USING scann' "$WORK/schema.sql" | tee "$WORK/scann_ddl.txt"

# ---------------------------------------------------------------------------
echo
echo "################ 3. Fresh database, schema applied whole ################"
# ---------------------------------------------------------------------------
$PSQL -c "DROP DATABASE IF EXISTS cymbalgoal;"
$PSQL -c "CREATE DATABASE cymbalgoal;"
export PGDATABASE=cymbalgoal

$PSQL -c "CREATE EXTENSION IF NOT EXISTS vector;"
$PSQL -c "CREATE EXTENSION IF NOT EXISTS alloydb_scann;"
$PSQL -c "CREATE EXTENSION IF NOT EXISTS google_ml_integration;"
$PSQL -c "CREATE EXTENSION IF NOT EXISTS pg_textsearch;"

echo "--- applying schema.sql WHOLE (also builds ScaNN on empty tables) ---"
s=$SECONDS
$PSQL -v ON_ERROR_STOP=1 -f "$WORK/schema.sql"
echo ">>> schema.sql: $((SECONDS-s)) s"

echo
echo "--- drop the two ScaNN indexes so the load takes the fast path (P-16) ---"
$PSQL -c "DROP INDEX IF EXISTS players_profile_embedding_scann_idx;"
$PSQL -c "DROP INDEX IF EXISTS clubs_profile_embedding_scann_idx;"

# ---------------------------------------------------------------------------
echo
echo "################ 4. PASS 1 — eight relational tables ################"
# ---------------------------------------------------------------------------
# Column list from the manifest, never positional CSV order.
# Parents before children.
# 🔴 The manifest's column_order is DDL-derived: for players and clubs it lists
# profile_text and profile_embedding, which the pass-1 CSVs DO NOT CONTAIN.
# That is the two-pass contract working as intended — pass 2 fills them — but it
# means column_order describes the TABLE, not the FILE. Feeding it straight to
# \copy gives: ERROR: missing data for column "profile_text".
#
# So: take column_order as authoritative for ORDER, then subtract the pass-2
# columns. Still never positional, still never guessed.
python3 - <<'PY' > ~/cgload/collist.env
import json, os
PASS2 = {'profile_text', 'profile_embedding'}
m = json.load(open(os.path.expanduser('~/cgload/manifest.json')))
sf = m.get('staged_files')
items = sf.items() if isinstance(sf, dict) else [(f.get('name'), f) for f in sf]
for k, v in items:
    if not isinstance(v, dict): continue
    tbl = str(k).split('/')[-1].replace('.csv.gz','').replace('.csv','')
    co = v.get('column_order')
    if not co: continue
    kept = [c for c in co if c not in PASS2]
    if len(kept) != len(co):
        print(f'# {tbl}: dropped {len(co)-len(kept)} pass-2 column(s) from the load list',
              file=__import__('sys').stderr)
    print(f'COLS_{tbl}="{",".join(kept)}"')
PY
source ~/cgload/collist.env
cat ~/cgload/collist.env

echo
echo "--- PREFLIGHT: does each file's field count match its column list? ---"
echo "--- (this is the check that would have caught the profile_text bug) ---"
PREFLIGHT_OK=1
for t in competitions clubs players games appearances game_events player_valuations transfers; do
  var="COLS_$t"; cols="${!var:-}"
  [[ -z "$cols" ]] && { echo "  $t: NO COLUMN LIST"; PREFLIGHT_OK=0; continue; }
  n_cols=$(awk -F, '{print NF}' <<<"$cols")
  n_file=$(gcloud storage cat "$BUCKET/$t.csv.gz" 2>/dev/null | gunzip -c 2>/dev/null | head -1 \
           | python3 -c "import sys,csv
try: print(len(next(csv.reader(sys.stdin))))
except Exception: print(0)")
  if [[ "$n_cols" == "$n_file" ]]; then
    printf "  %-20s cols=%-3s file=%-3s ✓\n" "$t" "$n_cols" "$n_file"
  else
    printf "  %-20s cols=%-3s file=%-3s ✗ MISMATCH\n" "$t" "$n_cols" "$n_file"
    PREFLIGHT_OK=0
  fi
done
if [[ "$PREFLIGHT_OK" != "1" ]]; then
  echo
  echo "!! Preflight failed. Loading anyway would either error out or, worse,"
  echo "!! silently shift values into the wrong columns. Fix the list first."
  exit 1
fi

PASS1_START=$SECONDS
for t in competitions clubs players games appearances game_events player_valuations transfers; do
  var="COLS_$t"; cols="${!var:-}"
  if [[ -z "$cols" ]]; then
    echo "!! no column_order for $t in manifest — SKIPPING (never guess column order)"
    continue
  fi
  echo
  echo "--- $t ---"
  s=$SECONDS
  gcloud storage cat "$BUCKET/$t.csv.gz" | gunzip -c \
    | $PSQL -c "\copy $t ($cols) FROM STDIN WITH (FORMAT csv)"
  echo "    $((SECONDS-s)) s"
done
PASS1_TOTAL=$((SECONDS-PASS1_START))
echo
echo ">>> PASS 1 TOTAL: ${PASS1_TOTAL} s"

$PSQL -c "
SELECT 'competitions' t, count(*) FROM competitions UNION ALL
SELECT 'clubs', count(*) FROM clubs UNION ALL
SELECT 'players', count(*) FROM players UNION ALL
SELECT 'games', count(*) FROM games UNION ALL
SELECT 'appearances', count(*) FROM appearances UNION ALL
SELECT 'game_events', count(*) FROM game_events UNION ALL
SELECT 'player_valuations', count(*) FROM player_valuations UNION ALL
SELECT 'transfers', count(*) FROM transfers;"

# ---------------------------------------------------------------------------
echo
echo "################ 5. PASS 2 — profiles (no ScaNN index present) ################"
# ---------------------------------------------------------------------------
echo "--- what does load_profiles.sql expect? (first 40 lines) ---"
head -40 "$WORK/load_profiles.sql"

gcloud storage cp "$BUCKET/players_profiles.csv.gz" "$WORK/"
gcloud storage cp "$BUCKET/clubs_profiles.csv.gz"   "$WORK/"

PASS2_START=$SECONDS
( cd "$WORK" && psql -X -P pager=off -v ON_ERROR_STOP=0 -f load_profiles.sql )
PASS2_FAST=$((SECONDS-PASS2_START))
echo ">>> PASS 2 (fast path, index absent): ${PASS2_FAST} s"

$PSQL -c "
SELECT 'players' AS t, count(*) FILTER (WHERE profile_text IS NOT NULL) AS with_text,
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) AS with_emb FROM players
UNION ALL
SELECT 'clubs', count(*) FILTER (WHERE profile_text IS NOT NULL),
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) FROM clubs;"

# ---------------------------------------------------------------------------
echo
echo "################ 6. Build ScaNN AFTER the load (correct order) ################"
# ---------------------------------------------------------------------------
echo "--- players ---"
s=$SECONDS
$PSQL -c "SET maintenance_work_mem='4GB';
CREATE INDEX players_profile_embedding_scann_idx ON players
USING scann (profile_embedding cosine) WITH (num_leaves=116, quantizer='sq8');"
SCANN_PLAYERS=$((SECONDS-s)); echo "    ${SCANN_PLAYERS} s"

echo "--- clubs ---"
s=$SECONDS
$PSQL -c "SET maintenance_work_mem='4GB';
CREATE INDEX clubs_profile_embedding_scann_idx ON clubs
USING scann (profile_embedding cosine) WITH (num_leaves=28, quantizer='sq8');"
SCANN_CLUBS=$((SECONDS-s)); echo "    ${SCANN_CLUBS} s"

# ---------------------------------------------------------------------------
echo
echo "################ 7. 🔴 THE ORDERING DELTA ################"
# ---------------------------------------------------------------------------
# Measure the WRONG order cheaply: wipe only the profile columns, leave the
# ScaNN indexes in place, re-run pass 2. Every vector then gets indexed
# incrementally on UPDATE — the slow path schema.sql currently forces.
echo "--- wiping profile columns only, ScaNN indexes left in place ---"
$PSQL -c "UPDATE players SET profile_text=NULL, profile_embedding=NULL;"
$PSQL -c "UPDATE clubs   SET profile_text=NULL, profile_embedding=NULL;"

SLOW_START=$SECONDS
( cd "$WORK" && psql -X -P pager=off -v ON_ERROR_STOP=0 -f load_profiles.sql )
PASS2_SLOW=$((SECONDS-SLOW_START))

echo
echo "=============================================================="
echo " RESULTS"
echo "--------------------------------------------------------------"
echo " Pass 1, eight relational tables      : ${PASS1_TOTAL} s"
echo " Pass 2, index built AFTER  (correct) : ${PASS2_FAST} s"
echo " Pass 2, index present DURING (wrong) : ${PASS2_SLOW} s"
echo " ScaNN build, players                 : ${SCANN_PLAYERS} s"
echo " ScaNN build, clubs                   : ${SCANN_CLUBS} s"
echo "--------------------------------------------------------------"
echo " CORRECT ORDER TOTAL : $((PASS1_TOTAL + PASS2_FAST + SCANN_PLAYERS + SCANN_CLUBS)) s"
echo " WRONG ORDER TOTAL   : $((PASS1_TOTAL + PASS2_SLOW)) s"
echo " DELTA PER STUDENT   : $((PASS2_SLOW - PASS2_FAST - SCANN_PLAYERS - SCANN_CLUBS)) s"
echo "=============================================================="
echo
echo "A large positive delta justifies asking Stage 3 to re-emit schema.sql."
echo "A small or negative one means the fallback (drop, load, recreate) is fine"
echo "and Stage 3 does not need to be disturbed."
