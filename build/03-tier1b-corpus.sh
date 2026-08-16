#!/usr/bin/env bash
#
# CymbalGoal — Tier 1B against the REAL corpus.
#
# WHERE: Cloud Shell, after 01 and 02.
# RUN:   bash 03-tier1b-corpus.sh 2>&1 | tee ~/tier1b.log
#
# PREREQ: the Qwiklabs identity must be able to read
#         gs://class-demo/alloydb-labs/cymbalgoal/
#         Check with:  gcloud storage ls gs://class-demo/alloydb-labs/cymbalgoal/
#
# This loads ONLY players.profile_text. It is deliberately not the real Pass 1 /
# Pass 2 load contract — no relational tables, no embeddings, no explicit column
# list from the manifest. The question on the table is "does BM25 rank the
# containing row first across 13,439 real documents", and text alone answers it.
# The real load contract gets built and measured in the Tier 2 pass.

set -uo pipefail
source ~/cymbalgoal-conn.env

BUCKET="gs://class-demo/alloydb-labs/cymbalgoal"
PSQL="psql -X -v ON_ERROR_STOP=0"

echo "### 0. Can we even read the bucket? ###"
gcloud storage ls "$BUCKET/" || {
  echo "FATAL: cannot read $BUCKET from this project's identity."
  echo "Either grant roles/storage.objectViewer to $(gcloud config get-value account),"
  echo "or copy the two profile files into a bucket in this project and edit BUCKET above."
  exit 1
}

echo
echo "### 1. The manifest — column order is authoritative, not the CSV's shape ###"
gcloud storage cat "$BUCKET/manifest.json" > ~/manifest.json
python3 - <<'PY'
import json, os
m = json.load(open(os.path.expanduser('~/manifest.json')))
for f in m.get('staged_files', []):
    if 'profile' in str(f.get('name','')):
        print(' ', f.get('name'), '->', f.get('column_order'), '| rows:', f.get('row_count'))
PY

echo
echo "### 2. Stream the player profiles in (no raw file ever hits disk) ###"
$PSQL <<'SQL'
DROP TABLE IF EXISTS players_p CASCADE;
CREATE TABLE players_p (player_id text, profile_text text, profile_embedding text);
SQL

# 175 MB gz, most of it embeddings we are about to throw away. ~3-5 min.
time gcloud storage cat "$BUCKET/players_profiles.csv.gz" \
  | gunzip -c \
  | psql -X -c "\copy players_p (player_id, profile_text, profile_embedding) FROM STDIN WITH (FORMAT csv)"

$PSQL <<'SQL'
ALTER TABLE players_p DROP COLUMN profile_embedding;
SELECT count(*) AS rows_loaded,
       count(*) FILTER (WHERE profile_text IS NULL) AS null_text
FROM players_p;
SQL

echo
echo "### 3. Build the BM25 index — exactly the DDL Lab 1 Task 3 will teach ###"
# TIME THIS. Task 3 budgets ~15 minutes total, and the student watches this
# build. 13,439 documents of ~250 words is the real shape of that wait, and if
# it runs long the task needs a "this takes a minute, here's why" beat rather
# than silence. This number goes straight into the instructor guide.
time $PSQL -c "CREATE INDEX players_p_bm25 ON players_p USING bm25 (profile_text) WITH (text_config = 'english');"

echo
echo "### 4. THE QUESTION ###"
$PSQL <<'SQL'
\pset pager off

\echo '=== 4a-0. IS THE INDEX ACTUALLY BEING USED? ==='
\echo '=== <@> has TWO overloads: (text,bm25query) uses the index, (text,text) does'
\echo '=== not and computes by sequential scan. Same answer, no index. On 3 rows'
\echo '=== nobody notices; on 13,439 it is the difference between a demo and a'
\echo '=== stall. Task 4 will teach this EXPLAIN step, so verify it here first. ==='
EXPLAIN (ANALYZE, BUFFERS)
SELECT player_id FROM players_p
ORDER BY profile_text <@> '€222,000,000' ASC LIMIT 10;

\echo ''
\echo '=== 4a. How many rows does BM25 ACTUALLY match? ==='
\echo '=== <@> returns 0 for no-overlap rows, so a real hit is score < 0. Counting'
\echo '=== negative scores is the only honest match count — tsquery counts describe'
\echo '=== GIN semantics, not BM25 bag-of-words semantics. ==='
SELECT
  count(*) FILTER (WHERE profile_text <@> '€222,000,000' < 0) AS bm25_hits_222,
  count(*) FILTER (WHERE profile_text <@> '€117,000,000' < 0) AS bm25_hits_117,
  count(*) FILTER (WHERE profile_text <@> 'Evian Grand Geneve FC' < 0) AS bm25_hits_evian,
  count(*) FILTER (WHERE profile_text ILIKE '%222,000,000%')  AS literal_222,
  count(*) FILTER (WHERE profile_text ILIKE '%117,000,000%')  AS literal_117,
  count(*) FILTER (WHERE profile_text ILIKE '%Evian%')        AS literal_evian,
  count(*)                                                    AS corpus
FROM players_p;

\echo ''
\echo '=== 4a-2. The decoy population: how many profiles own the token "222"? ==='
SELECT
  count(*) FILTER (WHERE to_tsvector('english',profile_text) @@ to_tsquery('english','222')) AS docs_with_222,
  count(*) FILTER (WHERE to_tsvector('english',profile_text) @@ to_tsquery('english','117')) AS docs_with_117,
  count(*) FILTER (WHERE to_tsvector('english',profile_text) @@ to_tsquery('english','000')) AS docs_with_000
FROM players_p;

\echo ''
\echo '=== 4b. BM25 top 10 for the primary example ==='
SELECT player_id,
       left(regexp_replace(profile_text, E'\\s+', ' ', 'g'), 90) AS snippet,
       round((profile_text <@> '€222,000,000')::numeric, 4) AS score,
       profile_text ILIKE '%222,000,000%' AS is_the_row
FROM players_p
ORDER BY profile_text <@> '€222,000,000' ASC
LIMIT 10;

\echo ''
\echo '=== 4c. Where does the TRUE row actually land? (rank 1 or bust) ==='
WITH ranked AS (
  SELECT player_id, profile_text,
         row_number() OVER (ORDER BY profile_text <@> '€222,000,000' ASC) AS rk
  FROM players_p
)
SELECT rk, player_id, left(regexp_replace(profile_text, E'\\s+',' ','g'),100) AS snippet
FROM ranked WHERE profile_text ILIKE '%222,000,000%';

\echo ''
\echo '=== 4d. Same for the designated second example, €117,000,000 ==='
WITH ranked AS (
  SELECT player_id, profile_text,
         row_number() OVER (ORDER BY profile_text <@> '€117,000,000' ASC) AS rk
  FROM players_p
)
SELECT rk, player_id, left(regexp_replace(profile_text, E'\\s+',' ','g'),100) AS snippet
FROM ranked WHERE profile_text ILIKE '%117,000,000%';

\echo ''
\echo '=== 4e. The fallback: ordinary word tokens, no punctuation to fragment ==='
SELECT player_id,
       left(regexp_replace(profile_text, E'\\s+',' ','g'),90) AS snippet,
       round((profile_text <@> 'Evian Grand Geneve FC')::numeric,4) AS score,
       profile_text ILIKE '%Evian%' AS is_the_row
FROM players_p
ORDER BY profile_text <@> 'Evian Grand Geneve FC' ASC
LIMIT 10;

\echo ''
\echo '=== 4f. The OTHER half of Task 2 — the semantic miss.'
\echo '=== BM25 must return ~nothing useful here, or the story collapses. Measured'
\echo '=== with BM25 semantics (score < 0), not tsquery semantics. ==='
SELECT count(*) AS bm25_hits_semantic
FROM players_p
WHERE profile_text <@> 'diminutive Argentine playmaker with a magical left foot' < 0;

\echo '--- and what does BM25 put on top for it? (should be unconvincing) ---'
SELECT player_id, left(regexp_replace(profile_text,E'\\s+',' ','g'),80) AS snippet,
       round((profile_text <@> 'diminutive Argentine playmaker with a magical left foot')::numeric,3) AS score
FROM players_p
WHERE profile_text <@> 'diminutive Argentine playmaker with a magical left foot' < 0
ORDER BY 3 ASC LIMIT 5;
SQL

echo
echo "VERDICT T1B: 4c returns rk=1  => €222,000,000 survives, Task 2 keeps its example."
echo "             4c returns rk>1  => how far down decides it; 4e is the replacement."
echo "             4a bm25_hits_222 is the number that matters — if it is in the"
echo "             hundreds, the 'exact match' framing is weak even if rank is 1."

# ---------------------------------------------------------------------------
echo
echo "################ TIER 2/3 — leftovers from 02's bonus block ################"
# ---------------------------------------------------------------------------
$PSQL <<'SQL'
\echo '--- P-12: google_ml_integration version vs the 1.5.2/1.5.7/1.5.8 floor ---'
SELECT extname, extversion FROM pg_extension ORDER BY extname;

\echo ''
\echo '--- which google_ml flags does the SERVER expose, and what are they set to? ---'
SELECT name, setting FROM pg_settings WHERE name LIKE 'google_ml_integration%' ORDER BY name;

\echo ''
\echo '--- D-09: ai.rank() signatures. Lab 1 Task 5 needs the SEMANTIC-RERANKER form ---'
\echo '--- (model_id, search_string, documents, top_n) — not the row-wise scorer. ---'
SELECT pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='ai' AND p.proname='rank';

\echo ''
\echo '--- the full ai.* inventory — settles ai.embedding vs google_ml.embedding ---'
SELECT p.proname, pg_get_function_result(p.oid) AS returns
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='ai' ORDER BY 1;

\echo ''
\echo '--- do ai.embedding() and google_ml.embedding() agree? If ai.* returns vector'
\echo '--- natively, every lab query drops a ::vector cast. ---'
SELECT pg_typeof(ai.embedding('gemini-embedding-001','test')) AS ai_type,
       pg_typeof(google_ml.embedding('gemini-embedding-001','test')) AS google_ml_type;

\echo ''
\echo '--- ScaNN at 3072 on PG 18, on the REAL corpus size (Tier 2) ---'
\echo '--- skipped here: players_p carries no embedding column. Run against the'
\echo '--- full load in the Terraform pass, where the number actually means something.'
SQL
