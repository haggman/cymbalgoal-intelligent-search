#!/usr/bin/env bash
#
# CymbalGoal — 04: the semantic-query hunt.
#
# WHERE: Cloud Shell, after 03.
# RUN:   bash 04-semantic-hunt.sh 2>&1 | tee ~/semantic-hunt.log
#
# WHY THIS EXISTS
# 03 proved BM25 answers "diminutive Argentine playmaker with a magical left
# foot" WELL — 12,996 hits with Messi at rank 2. That kills Task 4's motivation:
# if BM25 already handles meaning, nobody needs vector search or fusion.
#
# So we need a query where BM25 visibly FAILS and vector visibly WINS. This
# script measures candidates side by side and lets the evidence choose.
#
# THE HYPOTHESIS, in three families:
#
#   A. ADVERSARY FRAMING — the query names the OPPONENT, not the target.
#      "terrorises full-backs" should make BM25 retrieve full-backs (defenders)
#      while the intent is wingers. Predicted strongest: the failure is not
#      "worse ranking" but "wrong position", which an audience sees instantly.
#
#   B. IDIOM / FAN VOCABULARY — words a fan uses that a scouting profile never
#      does. Low lexical overlap, clear meaning.
#
#   C. CONTROL — the scouting-language query we know BM25 handles well, so the
#      comparison has a baseline and we do not fool ourselves.
#
# It also closes a Tier 2 item: ScaNN at VECTOR(3072) on PG 18, on the real
# 13,439-row corpus rather than a toy table.

set -uo pipefail
source ~/cymbalgoal-conn.env

BUCKET="gs://class-demo/alloydb-labs/cymbalgoal"
PSQL="psql -X -v ON_ERROR_STOP=0"

echo "### 1. Reload profiles WITH embeddings (03 dropped that column) ###"
$PSQL <<'SQL'
DROP TABLE IF EXISTS pv CASCADE;
CREATE TABLE pv (player_id text, profile_text text, emb_raw text);
SQL

time gcloud storage cat "$BUCKET/players_profiles.csv.gz" | gunzip -c \
  | psql -X -c "\copy pv (player_id, profile_text, emb_raw) FROM STDIN WITH (FORMAT csv)"

echo
echo "### 2. Cast to vector(3072) and index both ways ###"
$PSQL <<'SQL'
ALTER TABLE pv ADD COLUMN emb vector(3072);
SQL
time $PSQL -c "UPDATE pv SET emb = emb_raw::vector(3072); ALTER TABLE pv DROP COLUMN emb_raw;"

$PSQL -c "SELECT count(*) AS rows, count(emb) AS with_emb, vector_dims(min(emb)) AS dims FROM pv;" 2>/dev/null \
  || $PSQL -c "SELECT count(*) AS rows, count(emb) AS with_emb FROM pv;"

echo
echo "--- BM25 index ---"
time $PSQL -c "CREATE INDEX pv_bm25 ON pv USING bm25 (profile_text) WITH (text_config='english');"

echo
echo "--- ScaNN at 3072 on PG 18, real corpus (TIER 2 ANSWER) ---"
# num_leaves ~ sqrt(13439) = 116. CymbalFlix ships num_leaves=50 at ~9,700 rows.
time $PSQL -c "CREATE INDEX pv_scann ON pv USING scann (emb cosine) WITH (num_leaves=116, quantizer='sq8');"

echo
echo "################ 3. THE HUNT ################"

# Each candidate prints BM25 top-5 and VECTOR top-5 side by side.
# Profiles open with the subject's name, so the first 46 chars identify the row.
run_candidate () {
  local family="$1" q="$2"
  echo
  echo "=============================================================================="
  echo " [$family]  $q"
  echo "=============================================================================="
  $PSQL <<SQL
\pset pager off
WITH b AS (
  SELECT player_id, left(regexp_replace(profile_text,E'\\\\s+',' ','g'),46) AS who,
         row_number() OVER (ORDER BY profile_text <@> \$\$${q}\$\$ ASC) AS rk
  FROM pv WHERE profile_text <@> \$\$${q}\$\$ < 0
  ORDER BY profile_text <@> \$\$${q}\$\$ ASC LIMIT 5
), v AS (
  SELECT player_id, left(regexp_replace(profile_text,E'\\\\s+',' ','g'),46) AS who,
         row_number() OVER (ORDER BY emb <=> ai.embedding('gemini-embedding-001', \$\$${q}\$\$)::vector) AS rk
  FROM pv
  ORDER BY emb <=> ai.embedding('gemini-embedding-001', \$\$${q}\$\$)::vector LIMIT 5
)
SELECT COALESCE(b.rk,v.rk) AS rk,
       COALESCE(b.who,'—')  AS bm25_says,
       COALESCE(v.who,'—')  AS vector_says
FROM b FULL OUTER JOIN v ON b.rk = v.rk
ORDER BY 1;

SELECT count(*) AS bm25_total_matches FROM pv WHERE profile_text <@> \$\$${q}\$\$ < 0;
SQL
}

# --- Family A: adversary framing (query names the OPPONENT) -------------------
run_candidate "A-adversary" "a winger who terrorises full-backs"
run_candidate "A-adversary" "a striker who gives centre-backs nightmares"
run_candidate "A-adversary" "the player you assign your best defender to mark"

# --- Family B: idiom / fan vocabulary ----------------------------------------
run_candidate "B-idiom"     "someone who can unlock a parked bus"
run_candidate "B-idiom"     "an old head to steady a young dressing room"
run_candidate "B-idiom"     "a player who goes missing in big away games"
run_candidate "B-idiom"     "somebody to build a counter-attacking team around"

# --- Family C: control — we KNOW BM25 does well here -------------------------
run_candidate "C-control"   "diminutive Argentine playmaker with a magical left foot"

echo
echo "################ DONE ################"
echo "Looking for: a candidate where BM25's five are visibly the WRONG KIND of"
echo "player and vector's five are visibly right. Family A predicted strongest —"
echo "if BM25 returns actual full-backs for the winger query, that is the demo."
