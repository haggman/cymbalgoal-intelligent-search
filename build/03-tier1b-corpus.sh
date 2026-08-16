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
import json
m = json.load(open('/root/manifest.json')) if False else json.load(open(__import__('os').path.expanduser('~/manifest.json')))
for f in m.get('staged_files', []):
    if 'profile' in f.get('name',''):
        print(f.get('name'), '->', f.get('column_order'), '| rows:', f.get('row_count'))
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
time $PSQL -c "CREATE INDEX players_p_bm25 ON players_p USING bm25 (profile_text) WITH (text_config = 'english');"

echo
echo "### 4. THE QUESTION ###"
$PSQL <<'SQL'
\pset pager off

\echo '=== 4a. How crowded is the token space? ==='
\echo '=== "000" appears in nearly every profile that names a fee. "222" is'
\echo '=== the discriminating token, and these decoys are what can bury Neymar. ==='
SELECT
  count(*) FILTER (WHERE to_tsvector('english',profile_text) @@ to_tsquery('english','222')) AS docs_with_222,
  count(*) FILTER (WHERE to_tsvector('english',profile_text) @@ to_tsquery('english','117')) AS docs_with_117,
  count(*) FILTER (WHERE to_tsvector('english',profile_text) @@ to_tsquery('english','000')) AS docs_with_000,
  count(*) FILTER (WHERE profile_text ILIKE '%222,000,000%')                                  AS literal_222,
  count(*) FILTER (WHERE profile_text ILIKE '%117,000,000%')                                  AS literal_117,
  count(*) FILTER (WHERE profile_text ILIKE '%Evian%')                                        AS literal_evian,
  count(*)                                                                                    AS corpus
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
\echo '=== 4f. Sanity check on the OTHER half of Task 2 — the semantic miss.'
\echo '=== BM25 must return ZERO useful hits for this, or the story collapses. ==='
SELECT count(*) AS bm25_hits_for_semantic_query
FROM players_p
WHERE to_tsvector('english',profile_text)
      @@ plainto_tsquery('english','diminutive Argentine playmaker with a magical left foot');
SQL

echo
echo "VERDICT T1B: 4c returns rk=1  => €222,000,000 survives, Task 2 keeps its example."
echo "             4c returns rk>1  => how far down decides it; 4e is the replacement."
echo "             4a literal_222=1 but docs_with_222 large is the expected shape —"
echo "             the point is whether BM25's IDF is enough to beat the decoys."
