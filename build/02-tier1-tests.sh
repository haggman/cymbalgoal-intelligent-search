#!/usr/bin/env bash
#
# CymbalGoal — Tier 1 test rig, phase B: the questions that gate Lab 1.
#
# WHERE: Cloud Shell, same session (or re-source ~/cymbalgoal-conn.env).
# RUN:   bash 02-tier1-tests.sh 2>&1 | tee ~/tier1.log
#
# Then paste ~/tier1.log back. Every test prints a "VERDICT:" line so answers
# are greppable rather than buried in psql output.
#
# CHANGELOG
#   v2  Three corrections, all learned the hard way in phase A:
#
#   (a) PREFLIGHT added. google_ml.embedding() needs the AlloyDB service agent to
#       hold roles/aiplatform.user. v1 assumed it. If that grant is missing the
#       embedding UPDATE fails, every vector element fails with it, and ALL FOUR
#       hybrid_search probes error out — which reads exactly like "BM25 is not
#       supported" when the real cause is IAM. That would have been a wrong
#       answer to the most important question in the session.
#
#   (b) TEXT-ONLY probes added (A1a/A2a/A3a). ai.hybrid_search() is asked to
#       accept a BM25 text element with NO vector element present at all. This
#       isolates the actual question from the embedding pipeline entirely, so
#       T1A gets an answer even if Vertex access is broken.
#
#   (c) Model registration is now checked BEFORE it is relied on, not in the
#       bonus section afterwards.

set -uo pipefail
source ~/cymbalgoal-conn.env

PSQL="psql -X -v ON_ERROR_STOP=0"
banner() { echo; echo "################ $* ################"; echo; }

# ---------------------------------------------------------------------------
banner "PREFLIGHT — things that silently poison every downstream result"
# ---------------------------------------------------------------------------
echo "--- AlloyDB service agent must hold roles/aiplatform.user ---"
PROJNUM="$(gcloud projects describe "$CG_PROJECT" --format='value(projectNumber)')"
AGENT="serviceAccount:service-${PROJNUM}@gcp-sa-alloydb.iam.gserviceaccount.com"
if gcloud projects get-iam-policy "$CG_PROJECT" --flatten="bindings[].members" \
     --filter="bindings.role=roles/aiplatform.user AND bindings.members:${AGENT}" \
     --format="value(bindings.members)" | grep -q gcp-sa-alloydb; then
  echo "  ✓ granted"
else
  echo "  ✗ MISSING — google_ml.embedding() will fail and take the vector half of"
  echo "    every hybrid_search probe down with it. Grant it and re-run:"
  echo "    gcloud projects add-iam-policy-binding $CG_PROJECT \\"
  echo "      --member=\"$AGENT\" --role=\"roles/aiplatform.user\""
fi

# ---------------------------------------------------------------------------
banner "T1C — pg_textsearch + BM25 index on PG 18"
# ---------------------------------------------------------------------------
$PSQL <<'SQL'
\echo '--- server version ---'
SELECT version();

\echo '--- privileges: BM25 and the Index Advisor both need alloydbsuperuser ---'
SELECT current_user,
       pg_has_role(current_user,'alloydbsuperuser','member') AS is_alloydbsuperuser;

\echo '--- what is on offer? (BM25 went to Preview 2026-08-04 — 12 days ago) ---'
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_textsearch','rum','vector','alloydb_scann','google_ml_integration')
ORDER BY name;

\echo '--- create them ---'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS alloydb_scann;
CREATE EXTENSION IF NOT EXISTS google_ml_integration;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;
SELECT extname, extversion FROM pg_extension ORDER BY extname;

\echo '--- BM25 index on a plain TEXT column ---'
DROP TABLE IF EXISTS t1c CASCADE;
CREATE TABLE t1c (id int primary key, body text);
INSERT INTO t1c VALUES
 (1,'His €222,000,000 move to Paris Saint-Germain remains the world-record transfer.'),
 (2,'A journeyman defender who made 222 appearances in the second tier.'),
 (3,'He spent two seasons at Evian Grand Geneve FC before dropping down a division.');
CREATE INDEX t1c_bm25 ON t1c USING bm25 (body) WITH (text_config = 'english');

\echo '--- operator works? scores negative? ---'
SELECT id, body <@> 'world-record transfer' AS score
FROM t1c ORDER BY body <@> 'world-record transfer' ASC;
SQL
echo
echo "VERDICT T1C: extension created + index created + negative scores == PASS"

# ---------------------------------------------------------------------------
banner "T1B-i — tokenization, on the real engine"
# ---------------------------------------------------------------------------
$PSQL <<'SQL'
\echo '--- how the stock parser tokenizes the candidates ---'
SELECT to_tsvector('english','His €222,000,000 move to Paris Saint-Germain.')   AS t222;
SELECT to_tsvector('english','He spent two seasons at Evian Grand Geneve FC.')  AS tevian;

\echo '--- the euro sign: token or discarded? ---'
SELECT alias, token FROM ts_debug('english','€222,000,000');

\echo '--- does BM25 beat the decoy that owns the token "222"? ---'
SELECT id, left(body,55) AS body, body <@> '€222,000,000' AS score
FROM t1c ORDER BY body <@> '€222,000,000' ASC;
SQL
echo
echo "VERDICT T1B-i: row 1 above row 2 => survives tokenization. Otherwise use Evian."

# ---------------------------------------------------------------------------
banner "T1A — does ai.hybrid_search() accept a BM25-backed text component?"
# ---------------------------------------------------------------------------
# Documented ranking_function values are 'ts_rank' (GIN) and '<=>' (RUM) only.
# RUM does not exist on PG 18, and BM25 shipped four months after hybrid_search.
# The honest prior is NO. Probes run cheapest-first; ON_ERROR_STOP is off so a
# failure does not hide the probes behind it.

$PSQL <<'SQL'
\echo '=== A0: does the function exist, and with what signature? ==='
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='ai' AND p.proname IN ('hybrid_search','rank','g_to_tsquery')
ORDER BY p.proname;

\echo ''
\echo '=== A0b: is gemini-embedding-001 registered, and with what task type? ==='
\echo '=== (§7.14 — if it carries an EXPLICIT task type we may need a re-embed) ==='
SELECT model_id, model_type, model_provider, model_qualified_name
FROM google_ml.model_info_view WHERE model_id ILIKE '%embed%';
SQL

$PSQL <<'SQL'
\echo ''
\echo '=== TEXT-ONLY PROBES — the real T1A answer, independent of embeddings ==='
\echo '=== If these work, BM25 feeds hybrid_search. No vector element involved. ==='
DROP TABLE IF EXISTS t1a CASCADE;
CREATE TABLE t1a (id int primary key, body text);
INSERT INTO t1a VALUES
 (1,'Neymar. His €222,000,000 move from Barcelona to Paris Saint-Germain remains the world-record transfer fee.'),
 (2,'A diminutive Argentine playmaker with a magical left foot who dictates tempo from the half-spaces.'),
 (3,'A towering Norwegian centre-forward whose game is built on penalty-box movement and raw pace.');
CREATE INDEX t1a_bm25 ON t1a USING bm25 (body) WITH (text_config = 'english');

\echo '--- A1a: ranking_function => the BM25 operator ---'
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY['{"data_type":"text","table_name":"t1a","key_column":"id",
    "text_column":"body","query_text_input":"world record transfer fee","limit":3,
    "weight":1.0,"ranking_function":"<@>"}'::jsonb],
  id_type => NULL::int);

\echo '--- A2a: ranking_function omitted, let it infer from the index ---'
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY['{"data_type":"text","table_name":"t1a","key_column":"id",
    "text_column":"body","query_text_input":"world record transfer fee","limit":3,
    "weight":1.0}'::jsonb],
  id_type => NULL::int);

\echo '--- A3a: the literal string "bm25" ---'
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY['{"data_type":"text","table_name":"t1a","key_column":"id",
    "text_column":"body","query_text_input":"world record transfer fee","limit":3,
    "weight":1.0,"ranking_function":"bm25"}'::jsonb],
  id_type => NULL::int);

\echo '--- A4a: CONTROL — documented GIN + ts_rank path. If THIS fails too, my ---'
\echo '--- harness is wrong and A1a-A3a prove nothing. ---'
ALTER TABLE t1a ADD COLUMN body_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', body)) STORED;
CREATE INDEX t1a_gin ON t1a USING gin (body_tsv);
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY['{"data_type":"text","table_name":"t1a","key_column":"id",
    "text_column":"body_tsv","query_text_input":"world record transfer fee","limit":3,
    "weight":1.0,"ranking_function":"ts_rank"}'::jsonb],
  id_type => NULL::int);
SQL

echo
echo "VERDICT T1A (text-only): any of A1a/A2a/A3a returning rows => BM25 DOES feed"
echo "  ai.hybrid_search(); Task 4 keeps its planned shape."
echo "  All three erroring while A4a succeeds => it does NOT; Task 4 becomes a"
echo "  hand-written CTE + RRF (~30-35 min, Lab 1 to ~95) or drops to GIN."
echo "  A4a also failing => harness problem, ignore A1a-A3a entirely."

# ---------------------------------------------------------------------------
banner "T1A-vector — the full two-element fusion (needs Vertex access)"
# ---------------------------------------------------------------------------
# Only meaningful if PREFLIGHT passed. If the embedding UPDATE fails here, that
# is an IAM/model-registration problem and says NOTHING about BM25.
$PSQL <<'SQL'
ALTER TABLE t1a ADD COLUMN emb vector(3072);
\echo '--- this also answers: does google_ml.embedding() emit 3072 natively on PG 18? ---'
UPDATE t1a SET emb = google_ml.embedding('gemini-embedding-001', body)::vector;
SELECT id, vector_dims(emb) AS dims FROM t1a ORDER BY id;

\echo '--- full fusion: BM25 text element + vector element ---'
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY[
    '{"data_type":"text","table_name":"t1a","key_column":"id","text_column":"body",
      "query_text_input":"world record transfer fee","limit":3,"weight":0.5,
      "ranking_function":"<@>"}'::jsonb,
    '{"data_type":"vector","table_name":"t1a","key_column":"id","embedding_column":"emb",
      "query_text_input":"most expensive signing ever","limit":3,"weight":0.5,
      "model_id":"gemini-embedding-001","distance_function":"cosine"}'::jsonb],
  id_type => NULL::int);
SQL

# ---------------------------------------------------------------------------
banner "BONUS — Tier 2/3 answers while the cluster is warm"
# ---------------------------------------------------------------------------
$PSQL <<'SQL'
\echo '--- google_ml_integration version vs the 1.5.2/1.5.7/1.5.8 floor (P-12) ---'
SELECT extversion FROM pg_extension WHERE extname='google_ml_integration';

\echo '--- which google_ml flags does the SERVER actually expose? ---'
SELECT name, setting FROM pg_settings WHERE name LIKE 'google_ml_integration%' ORDER BY name;

\echo '--- ai.rank() signatures — which form do we teach? (D-09) ---'
SELECT pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='ai' AND p.proname='rank';

\echo '--- every ai.* function available, for Lab 2 planning ---'
SELECT p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='ai' ORDER BY 1;

\echo '--- ScaNN at 3072 on PG 18 (num_leaves=1 only because this table has 3 rows) ---'
CREATE INDEX t1a_scann ON t1a USING scann (emb cosine) WITH (num_leaves=1, quantizer='sq8');
SQL

echo
echo "################ DONE — paste ~/tier1.log back ################"
