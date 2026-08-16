#!/usr/bin/env bash
#
# CymbalGoal — 07: does load_profiles.sql actually fail loudly when starved?
#
# WHERE: Cloud Shell. Needs the cymbalgoal database built by 05.
# RUN:   bash 07-load-profiles-assertions.sh
#
# Self-logging:
#   Full log : ~/cg-07-full.log
#   SUMMARY  : ~/cg-07-summary.txt   <-- send this one back
#
# WHY THIS MATTERS
# The contract says load_profiles.sql "asserts row counts and fails loudly
# rather than half-loading." That claim has never been tested against a starved
# input. It is the difference between a student cluster that fails provisioning
# visibly and one that comes up with 9,000 of 13,439 profiles and looks fine
# until Task 2 returns nothing for Neymar.
#
# A half-load is the worst outcome available: no error, no signal, and the lab
# breaks in front of the room rather than at provision time.

set -uo pipefail
source ~/cymbalgoal-conn.env
export PGDATABASE=cymbalgoal
export PAGER=cat PSQL_PAGER=cat

FULL=~/cg-07-full.log
SUMMARY=~/cg-07-summary.txt
exec > >(tee "$FULL") 2>&1

PSQL="psql -X -P pager=off"
BUCKET="gs://class-demo/alloydb-labs/cymbalgoal"
WORK=~/cgload
STARVE=~/cgstarve
mkdir -p "$STARVE"

echo "################ 0. The artifact under test ################"
echo "--- load_profiles.sql, in full ---"
cat "$WORK/load_profiles.sql"

echo
echo "################ 1. Baseline — clean run should SUCCEED ################"
$PSQL -c "UPDATE players SET profile_text=NULL, profile_embedding=NULL;"
$PSQL -c "UPDATE clubs   SET profile_text=NULL, profile_embedding=NULL;"

( cd "$WORK" && psql -X -P pager=off -v ON_ERROR_STOP=0 -f load_profiles.sql )
BASELINE_RC=$?
echo ">>> baseline exit code: $BASELINE_RC  (0 = clean)"

$PSQL -c "
SELECT 'players' AS t, count(*) FILTER (WHERE profile_text IS NOT NULL) AS with_text,
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) AS with_emb FROM players
UNION ALL
SELECT 'clubs', count(*) FILTER (WHERE profile_text IS NOT NULL),
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) FROM clubs;"

echo
echo "################ 2. Starve it — remove 500 player profiles ################"
# Same filename, fewer rows. If the assertions are real they must notice.
cp "$WORK/load_profiles.sql" "$STARVE/"
cp "$WORK/clubs_profiles.csv.gz" "$STARVE/"

ORIG=$(gcloud storage cat "$BUCKET/players_profiles.csv.gz" | gunzip -c | wc -l)
gcloud storage cat "$BUCKET/players_profiles.csv.gz" | gunzip -c \
  | head -n $((ORIG - 500)) | gzip -c > "$STARVE/players_profiles.csv.gz"
SHORT=$(gunzip -c "$STARVE/players_profiles.csv.gz" | wc -l)
echo "  original rows : $ORIG"
echo "  starved rows  : $SHORT   (expect $((ORIG-500)))"

echo
echo "--- wiping, then running against the STARVED file ---"
$PSQL -c "UPDATE players SET profile_text=NULL, profile_embedding=NULL;"
$PSQL -c "UPDATE clubs   SET profile_text=NULL, profile_embedding=NULL;"

set +e
( cd "$STARVE" && psql -X -P pager=off -v ON_ERROR_STOP=1 -f load_profiles.sql )
STARVED_RC=$?
set -e
echo ">>> STARVED exit code: $STARVED_RC   (NON-ZERO is the PASS condition)"

echo
echo "################ 3. What state did the failure leave behind? ################"
# The critical question. A loud failure that still commits 12,939 profiles is
# still a half-load — the assertion has to roll back, not just complain.
$PSQL -c "
SELECT 'players' AS t, count(*) FILTER (WHERE profile_text IS NOT NULL) AS with_text,
       count(*) FILTER (WHERE profile_embedding IS NOT NULL) AS with_emb,
       count(*) AS total FROM players
UNION ALL
SELECT 'clubs', count(*) FILTER (WHERE profile_text IS NOT NULL),
       count(*) FILTER (WHERE profile_embedding IS NOT NULL), count(*) FROM clubs;"

echo
echo "################ 4. Restore the database to a good state ################"
$PSQL -c "UPDATE players SET profile_text=NULL, profile_embedding=NULL;"
$PSQL -c "UPDATE clubs   SET profile_text=NULL, profile_embedding=NULL;"
( cd "$WORK" && psql -X -P pager=off -f load_profiles.sql ) >/dev/null 2>&1
$PSQL -c "SELECT count(*) FILTER (WHERE profile_text IS NOT NULL) AS players_restored FROM players;"

# ---------------------------------------------------------------------------
{
  echo "===== CymbalGoal 07 — load_profiles.sql assertions SUMMARY ====="
  echo
  echo "-- does the file contain assertions at all? --"
  grep -inE 'assert|raise|exception|count\(\*\)|EXPECTED|<>|!=' "$WORK/load_profiles.sql" | head -20
  echo
  echo "-- baseline (clean input) --"
  grep -E 'baseline exit code' "$FULL"
  echo
  echo "-- starved run (500 rows removed) --"
  grep -E 'original rows|starved rows|STARVED exit code' "$FULL"
  echo
  echo "-- error text raised, if any --"
  grep -iE 'ERROR|FATAL|EXCEPTION|mismatch|expected' "$FULL" | tail -15
  echo
  echo "-- post-failure state: 0 = rolled back cleanly, partial = HALF LOAD --"
  sed -n '/What state did the failure leave/,/^####/p' "$FULL" | head -12
  echo
  echo "===== end ====="
} > "$SUMMARY"

echo
echo "=============================================================="
cat "$SUMMARY"
echo "=============================================================="
echo
echo "Full log : $FULL"
echo "SUMMARY  : $SUMMARY   <-- send this one back"
