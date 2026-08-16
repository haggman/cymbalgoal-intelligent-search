#!/usr/bin/env bash
#
# CymbalGoal — 06: ScaNN diagnostics + recall. Small, fast, self-logging.
#
# WHERE: Cloud Shell. Needs the `pv` table from 04.
# RUN:   bash 06-scann-diagnostics.sh
#
# No `| tee` needed — it logs itself, and writes a short paste-sized summary.
#   Full log : ~/cg-06-full.log
#   SUMMARY  : ~/cg-06-summary.txt   <-- this is the one to send back
#
# Answers two things:
#   1. Do vector queries actually USE the ScaNN index, or does the planner
#      seq-scan 13,439 rows? Task 1's ScaNN aside is unearned until we know.
#   2. RECALL — does ScaNN return the SAME neighbours brute force does? This is
#      the question the ordering-delta test could not answer. An approximate
#      index can be fast and quietly wrong, which in Lab 1 means the semantic
#      search demo returns worse players with no error to notice.

set -uo pipefail
source ~/cymbalgoal-conn.env
export PGDATABASE=postgres          # `pv` lives here, built by 04
export PAGER=cat PSQL_PAGER=cat

FULL=~/cg-06-full.log
SUMMARY=~/cg-06-summary.txt
exec > >(tee "$FULL") 2>&1

PSQL="psql -X -P pager=off"
Q1='a striker who gives centre-backs nightmares'
Q2='diminutive Argentine playmaker with a magical left foot'

echo "################ 1. Is the ScaNN index used? ################"
$PSQL -c "EXPLAIN (ANALYZE, BUFFERS)
SELECT player_id FROM pv
ORDER BY emb <=> ai.embedding('gemini-embedding-001','$Q1')::vector LIMIT 10;"

echo
echo "################ 2. ScaNN tuning knobs ################"
$PSQL -c "SELECT name, setting FROM pg_settings WHERE name LIKE '%scann%' ORDER BY name;"

echo
echo "################ 3. RECALL — ScaNN vs brute force ################"
# Brute force = planner forced off every index type, so the seq scan computes
# exact nearest neighbours. Overlap of the two top-10 lists IS the recall.
$PSQL <<SQL
\pset pager off
CREATE TEMP TABLE q AS
  SELECT ai.embedding('gemini-embedding-001','$Q1')::vector AS e1,
         ai.embedding('gemini-embedding-001','$Q2')::vector AS e2;

SET enable_indexscan=off; SET enable_bitmapscan=off; SET enable_indexonlyscan=off;
CREATE TEMP TABLE exact1 AS SELECT player_id FROM pv, q ORDER BY emb <=> q.e1 LIMIT 10;
CREATE TEMP TABLE exact2 AS SELECT player_id FROM pv, q ORDER BY emb <=> q.e2 LIMIT 10;

RESET enable_indexscan; RESET enable_bitmapscan; RESET enable_indexonlyscan;
CREATE TEMP TABLE approx1 AS SELECT player_id FROM pv, q ORDER BY emb <=> q.e1 LIMIT 10;
CREATE TEMP TABLE approx2 AS SELECT player_id FROM pv, q ORDER BY emb <=> q.e2 LIMIT 10;

\echo '--- recall@10: how many of brute force top-10 did ScaNN also return? ---'
SELECT 'striker query' AS q,
       (SELECT count(*) FROM exact1 JOIN approx1 USING (player_id)) AS overlap_of_10
UNION ALL
SELECT 'playmaker query',
       (SELECT count(*) FROM exact2 JOIN approx2 USING (player_id));

\echo ''
\echo '--- where they disagree (striker query) ---'
SELECT 'exact only' AS side, player_id FROM exact1 WHERE player_id NOT IN (SELECT player_id FROM approx1)
UNION ALL
SELECT 'scann only', player_id FROM approx1 WHERE player_id NOT IN (SELECT player_id FROM exact1);
SQL

echo
echo "################ 4. Timing: indexed vs brute force ################"
$PSQL <<SQL
\timing on
\pset pager off
SELECT player_id FROM pv
ORDER BY emb <=> ai.embedding('gemini-embedding-001','$Q1')::vector LIMIT 10;
SET enable_indexscan=off; SET enable_bitmapscan=off;
SELECT player_id FROM pv
ORDER BY emb <=> ai.embedding('gemini-embedding-001','$Q1')::vector LIMIT 10;
SQL

# ---------------------------------------------------------------------------
# Compact summary — the only thing that needs pasting back.
# ---------------------------------------------------------------------------
{
  echo "===== CymbalGoal 06 — ScaNN diagnostics SUMMARY ====="
  echo
  echo "-- scan type chosen (want: Index Scan using pv_scann) --"
  grep -iE 'Index Scan|Seq Scan|Execution Time|Planning Time' "$FULL" | head -8
  echo
  echo "-- scann settings --"
  grep -iE '^ *scann\.' "$FULL" | head -20
  echo
  echo "-- recall@10 (10 = perfect) --"
  sed -n '/recall@10/,/^$/p' "$FULL" | head -12
  echo
  echo "-- disagreements --"
  sed -n '/where they disagree/,/^$/p' "$FULL" | head -14
  echo
  echo "-- query timings (first = indexed, second = brute force) --"
  grep -iE '^Time:' "$FULL" | head -6
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
