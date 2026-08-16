#!/usr/bin/env bash
#
# CymbalGoal — 05: full load, measured. The instructor-guide wall-clock number.
#
# WHERE: Cloud Shell, after 04.
# RUN:   bash 05-full-load-walltime.sh 2>&1 | tee ~/fullload.log
#
# Answers four things at once:
#
#   1. Does the vector query actually USE the ScaNN index, or is the planner
#      seq-scanning 13,439 rows? Same trap <@> had — assume nothing.
#   2. Total wall-clock for the real load: 8 relational tables (832,193
#      appearances) + pass 2 profiles + indexes. This is the number the
#      instructor guide's pre-warm timing is built on.
#   3. 🔴 The ScaNN ORDERING DELTA — the cost of schema.sql building its indexes
#      on empty tables versus building them after the load. That delta is the
#      number that justifies asking Stage 3 to re-emit schema.sql.
#   4. Whether load_profiles.sql runs clean and its assertions fire.
#
# Uses the documented no-restage fallback: run schema.sql whole, capture the
# index DDL verbatim, DROP the two ScaNN indexes, load, rebuild. NO regex
# splitting of the DDL — that is explicitly forbidden.

set -uo pipefail
source ~/cymbalgoal-conn.env

BUCKET="gs://class-demo/alloydb-labs/cymbalgoal"
WORK=~/cgload
mkdir -p "$WORK"

# ---------------------------------------------------------------------------
echo "################ 1. Is ScaNN actually being used? ################"
# ---------------------------------------------------------------------------
psql -X -c "\pset pager off" -c "
EXPLAIN (ANALYZE, BUFFERS)
SELECT player_id FROM pv
ORDER BY emb <=> ai.embedding('gemini-embedding-001','a striker who gives centre-backs nightmares')::vector
LIMIT 5;"
echo
echo ">>> Look for 'Index Scan using pv_scann'. A Seq Scan here means every"
echo ">>> vector timing we have is brute force, and Task 1's ScaNN aside is unearned."
echo
echo "--- and with enable_seqscan off, to see if it CAN use it ---"
psql -X -c "SET enable_seqscan=off;
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
        print(f'  {k:32s} rows={v.get("row_count")!s:>9s}  cols={len(co)}')
PY

echo
echo "--- the ScaNN index DDL schema.sql carries, captured VERBATIM ---"
grep -n -i -B2 -A4 'USING scann' "$WORK/schema.sql" | tee "$WORK/scann_ddl.txt"

# ---------------------------------------------------------------------------
echo
echo "################ 3. Fresh database, schema applied whole ################"
# ---------------------------------------------------------------------------
psql -X -c "DROP DATABASE IF EXISTS cymbalgoal;" -c "CREATE DATABASE cymbalgoal;"
export PGDATABASE=cymbalgoal

psql -X -c "CREATE EXTENSION IF NOT EXISTS vector;" \
        -c "CREATE EXTENSION IF NOT EXISTS alloydb_scann;" \
        -c "CREATE EXTENSION IF NOT EXISTS google_ml_integration;" \
        -c "CREATE EXTENSION IF NOT EXISTS pg_textsearch;"

echo "--- applying schema.sql WHOLE (this also builds ScaNN on empty tables) ---"
time psql -X -v ON_ERROR_STOP=1 -f "$WORK/schema.sql"

echo
echo "--- drop the two ScaNN indexes so the load takes the fast path (P-16) ---"
psql -X -c "DROP INDEX IF EXISTS players_profile_embedding_scann_idx;" \
        -c "DROP INDEX IF EXISTS clubs_profile_embedding_scann_idx;"

# ---------------------------------------------------------------------------
echo
echo "################ 4. PASS 1 — eight relational tables ################"
# ---------------------------------------------------------------------------
# Column list comes from the manifest, never from positional CSV order.
# Parents before children: competitions -> clubs -> players -> games ->
# appearances -> game_events -> player_valuations -> transfers.

python3 - <<'PY' > ~/cgload/collist.env
import json, os
m = json.load(open(os.path.expanduser('~/cgload/manifest.json')))
sf = m.get('staged_files')
items = sf.items() if isinstance(sf, dict) else [(f.get('name'), f) for f in sf]
cols = {}
for k, v in items:
    if not isinstance(v, dict): continue
    name = str(k)
    tbl = name.split('/')[-1].replace('.csv.gz','').replace('.csv','')
    co = v.get('column_order')
    if co: cols[tbl] = ','.join(co)
for t, c in cols.items():
    print(f'COLS_{t}="{c}"')
PY
source ~/cgload/collist.env
cat ~/cgload/collist.env

PASS1_START=$(date +%s)
for t in competitions clubs players games appearances game_events player_valuations transfers; do
  var="COLS_$t"; cols="${!var:-}"
  if [[ -z "$cols" ]]; then
    echo "!! no column_order for $t in manifest — SKIPPING (do not guess)"; continue
  fi
  echo
  echo "--- $t ---"
  /usr/bin/time -f "    %e s" bash -c \
    "gcloud storage cat '$BUCKET/$t.csv.gz' | gunzip -c | psql -X -c \"\\copy $t ($cols) FROM STDIN WITH (FORMAT csv)\""
done
PASS1_END=$(date +%s)
echo
echo ">>> PASS 1 TOTAL: $((PASS1_END-PASS1_START)) s"

psql -X -c "
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
echo "################ 5. PASS 2 — profiles (indexes still absent) ################"
# ---------------------------------------------------------------------------
echo "--- what does load_profiles.sql expect? ---"
head -40 "$WORK/load_profiles.sql"
echo "  … (showing first 40 lines)"

gcloud storage cp "$BUCKET/players_profiles.csv.gz" "$WORK/"
gcloud storage cp "$BUCKET/clubs_profiles.csv.gz"   "$WORK/"

PASS2_START=$(date +%s)
( cd "$WORK" && psql -X -v ON_ERROR_STOP=0 -f load_profiles.sql )
PASS2_END=$(date +%s)
echo ">>> PASS 2 TOTAL (fast path, no ScaNN index present): $((PASS2_END-PASS2_START)) s"

psql -X -c "
SELECT 'players'  AS t, count(*) FILTER (WHERE profile_text IS NOT NULL) AS with_text,
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) AS with_emb FROM players
UNION ALL
SELECT 'clubs', count(*) FILTER (WHERE profile_text IS NOT NULL),
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) FROM clubs;"

# ---------------------------------------------------------------------------
echo
echo "################ 6. Build ScaNN AFTER the load (the correct order) ################"
# ---------------------------------------------------------------------------
psql -X -c "SET maintenance_work_mem='4GB'; SHOW maintenance_work_mem;"

echo "--- players ---"
time psql -X -c "SET maintenance_work_mem='4GB';
CREATE INDEX players_profile_embedding_scann_idx ON players
USING scann (profile_embedding cosine) WITH (num_leaves=116, quantizer='sq8');"

echo "--- clubs ---"
time psql -X -c "SET maintenance_work_mem='4GB';
CREATE INDEX clubs_profile_embedding_scann_idx ON clubs
USING scann (profile_embedding cosine) WITH (num_leaves=28, quantizer='sq8');"

# ---------------------------------------------------------------------------
echo
echo "################ 7. 🔴 THE ORDERING DELTA ################"
# ---------------------------------------------------------------------------
# Now measure the WRONG order cheaply: wipe only the profile columns, leave the
# ScaNN index in place, and re-run pass 2. Every vector then gets indexed
# incrementally on UPDATE. Difference vs. section 5 is the per-student cost of
# leaving schema.sql as it is.
echo "--- wiping profile columns only, keeping the ScaNN indexes ---"
psql -X -c "UPDATE players SET profile_text=NULL, profile_embedding=NULL;" \
        -c "UPDATE clubs   SET profile_text=NULL, profile_embedding=NULL;"

SLOW_START=$(date +%s)
( cd "$WORK" && psql -X -v ON_ERROR_STOP=0 -f load_profiles.sql )
SLOW_END=$(date +%s)

echo
echo "=============================================================="
echo " PASS 2, index built AFTER  (correct) : $((PASS2_END-PASS2_START)) s"
echo " PASS 2, index present DURING (wrong) : $((SLOW_END-SLOW_START)) s"
echo " DELTA — the cost of not re-emitting schema.sql, PER STUDENT"
echo "=============================================================="
echo
echo "TOTAL LOAD (pass1 + pass2 + indexes), correct ordering:"
echo "  pass 1: $((PASS1_END-PASS1_START)) s"
echo "  pass 2: $((PASS2_END-PASS2_START)) s"
echo "  + ScaNN build times printed in section 6"
