#!/usr/bin/env bash
#
# CymbalGoal — Tier 1 test rig, phase B: the four questions that gate Lab 1.
#
# WHERE: Cloud Shell, same session (or re-source ~/cymbalgoal-conn.env).
# RUN:   bash 02-tier1-tests.sh 2>&1 | tee ~/tier1.log
#
# Then paste ~/tier1.log back. Every test prints a "VERDICT:" line so the
# answers are greppable rather than buried.
#
# Ordering is deliberate: T1C and T1A need no lab data at all, so they answer
# even if the bucket turns out to be unreadable from a Qwiklabs project.

set -uo pipefail
source ~/cymbalgoal-conn.env

PSQL="psql -X -v ON_ERROR_STOP=0"

banner() { echo; echo "################ $* ################"; echo; }

# ---------------------------------------------------------------------------
banner "T1C — pg_textsearch + BM25 index on PG 18"
# ---------------------------------------------------------------------------
# Docs say pg_textsearch needs PG 17+ and the alloydbsuperuser role, and BM25
# went to Preview on 2026-08-04 — twelve days ago. "Preview" is the reason this
# is a Tier 1 item and not an assumption.

$PSQL <<'SQL'
\echo '--- server version ---'
SELECT version();
SHOW server_version_num;

\echo '--- am I alloydbsuperuser? ---'
SELECT current_user, rolsuper,
       pg_has_role(current_user,'alloydbsuperuser','member') AS is_alloydbsuperuser
FROM pg_roles WHERE rolname = current_user;

\echo '--- is pg_textsearch even offered on this instance? ---'
SELECT name, default_version, installed_version
FROM pg_available_extensions
WHERE name IN ('pg_textsearch','rum','vector','alloydb_scann','google_ml_integration')
ORDER BY name;

\echo '--- create the extensions ---'
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS alloydb_scann;
CREATE EXTENSION IF NOT EXISTS google_ml_integration;
CREATE EXTENSION IF NOT EXISTS pg_textsearch;

SELECT extname, extversion FROM pg_extension ORDER BY extname;

\echo '--- build a BM25 index on a plain TEXT column ---'
DROP TABLE IF EXISTS t1c CASCADE;
CREATE TABLE t1c (id int primary key, body text);
INSERT INTO t1c VALUES
 (1,'His 222,000,000 euro move to Paris Saint-Germain remains the world-record transfer.'),
 (2,'A journeyman defender who made 222 appearances in the second tier.'),
 (3,'He spent two seasons at Evian Grand Geneve FC before dropping down a division.');

CREATE INDEX t1c_bm25 ON t1c USING bm25 (body) WITH (text_config = 'english');

\echo '--- does the operator work, and are scores negative? ---'
SELECT id, body <@> 'world-record transfer' AS score
FROM t1c ORDER BY body <@> 'world-record transfer' ASC;
SQL

echo
echo "VERDICT T1C: read the block above — extension created + index created + <@> returned negative scores == PASS"

# ---------------------------------------------------------------------------
banner "T1B-i — tokenization, confirmed on the real engine"
# ---------------------------------------------------------------------------
# Already answered offline: pg_textsearch documents that it calls Postgres's
# own to_tsvector to tokenize, and the stock parser splits the currency string.
# This re-confirms it in situ and, more importantly, shows what the query
# string actually becomes and WHICH rows it can therefore reach.

$PSQL <<'SQL'
\echo '--- how the stock parser sees the two candidate examples ---'
SELECT '222' AS which, to_tsvector('english','His €222,000,000 move to Paris Saint-Germain.') AS tsv
UNION ALL
SELECT '117', to_tsvector('english','His €117,000,000 transfer from Real Madrid to Juventus.')
UNION ALL
SELECT 'evian', to_tsvector('english','He spent two seasons at Evian Grand Geneve FC.');

\echo '--- the euro sign: token or discarded? ---'
SELECT alias, token FROM ts_debug('english','€222,000,000') ;

\echo '--- and now the thing that actually matters: does BM25 rank the'
\echo '--- containing row first, when a decoy row owns the token "222"? ---'
SELECT id, left(body,60) AS body, body <@> '€222,000,000' AS score
FROM t1c ORDER BY body <@> '€222,000,000' ASC;
SQL

echo
echo "VERDICT T1B-i: if row 1 (the transfer fee) sorts above row 2 (222 appearances), the"
echo "               example survives tokenization. If row 2 wins or ties, use the Evian fallback."

# ---------------------------------------------------------------------------
banner "T1A — does ai.hybrid_search() accept a BM25-backed text component?"
# ---------------------------------------------------------------------------
# The documented parameter reference offers exactly two ranking_function values:
#   'ts_rank' for GIN indexes, '<=>' for RUM indexes.
# RUM does not exist on PG 18, and BM25 shipped four months AFTER hybrid_search.
# So the honest prior is "no". These four probes are ordered cheapest-first and
# any ONE of them passing changes Lab 1 Task 4's shape, so run them all even
# after the first failure — that is why ON_ERROR_STOP is off.

$PSQL <<'SQL'
\echo '=== A0: what does the function actually look like? ==='
SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'ai' AND p.proname IN ('hybrid_search','rank','g_to_tsquery')
ORDER BY p.proname;

\echo ''
\echo '=== build a tiny table with BOTH a BM25 index and a real 3072-dim vector ==='
DROP TABLE IF EXISTS t1a CASCADE;
CREATE TABLE t1a (id int primary key, body text, emb vector(3072));
INSERT INTO t1a VALUES
 (1,'Neymar. His €222,000,000 move from Barcelona to Paris Saint-Germain remains the world-record transfer fee.'),
 (2,'A diminutive Argentine playmaker with a magical left foot who dictates tempo from the half-spaces.'),
 (3,'A towering Norwegian centre-forward whose game is built on penalty-box movement and raw pace.');

-- This also silently answers a Tier 3 question: does google_ml.embedding()
-- work on PG 18, and does it emit 3072 dimensions natively?
UPDATE t1a SET emb = google_ml.embedding('gemini-embedding-001', body)::vector;
SELECT id, vector_dims(emb) AS dims FROM t1a ORDER BY id;

CREATE INDEX t1a_bm25 ON t1a USING bm25 (body) WITH (text_config = 'english');

\echo ''
\echo '=== A1: ranking_function => the BM25 operator ==='
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY[
    '{"data_type":"text","table_name":"t1a","key_column":"id","text_column":"body",
      "query_text_input":"world record transfer fee","limit":3,"weight":0.5,
      "ranking_function":"<@>"}'::jsonb,
    '{"data_type":"vector","table_name":"t1a","key_column":"id","embedding_column":"emb",
      "query_text_input":"most expensive signing ever","limit":3,"weight":0.5,
      "model_id":"gemini-embedding-001","distance_function":"cosine"}'::jsonb
  ],
  id_type => NULL::int
);

\echo ''
\echo '=== A2: same, but ranking_function omitted entirely (let it infer the index) ==='
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY[
    '{"data_type":"text","table_name":"t1a","key_column":"id","text_column":"body",
      "query_text_input":"world record transfer fee","limit":3,"weight":0.5}'::jsonb,
    '{"data_type":"vector","table_name":"t1a","key_column":"id","embedding_column":"emb",
      "query_text_input":"most expensive signing ever","limit":3,"weight":0.5,
      "model_id":"gemini-embedding-001","distance_function":"cosine"}'::jsonb
  ],
  id_type => NULL::int
);

\echo ''
\echo '=== A3: the literal string "bm25" as the ranking function ==='
SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY[
    '{"data_type":"text","table_name":"t1a","key_column":"id","text_column":"body",
      "query_text_input":"world record transfer fee","limit":3,"weight":0.5,
      "ranking_function":"bm25"}'::jsonb,
    '{"data_type":"vector","table_name":"t1a","key_column":"id","embedding_column":"emb",
      "query_text_input":"most expensive signing ever","limit":3,"weight":0.5,
      "model_id":"gemini-embedding-001","distance_function":"cosine"}'::jsonb
  ],
  id_type => NULL::int
);

\echo ''
\echo '=== A4: control — the DOCUMENTED GIN/ts_rank path, to prove the rig is sane ==='
\echo '=== (if this also fails, the failures above are my harness, not BM25)  ==='
ALTER TABLE t1a ADD COLUMN body_tsv tsvector
  GENERATED ALWAYS AS (to_tsvector('english', body)) STORED;
CREATE INDEX t1a_gin ON t1a USING gin (body_tsv);

SELECT * FROM ai.hybrid_search(
  search_inputs => ARRAY[
    '{"data_type":"text","table_name":"t1a","key_column":"id","text_column":"body_tsv",
      "query_text_input":"world record transfer fee","limit":3,"weight":0.5,
      "ranking_function":"ts_rank"}'::jsonb,
    '{"data_type":"vector","table_name":"t1a","key_column":"id","embedding_column":"emb",
      "query_text_input":"most expensive signing ever","limit":3,"weight":0.5,
      "model_id":"gemini-embedding-001","distance_function":"cosine"}'::jsonb
  ],
  id_type => NULL::int
);
SQL

echo
echo "VERDICT T1A: A1/A2/A3 all error + A4 succeeds  => BM25 does NOT feed ai.hybrid_search();"
echo "             Lab 1 Task 4 becomes a hand-written CTE + RRF."
echo "             Any of A1/A2/A3 returning rows    => it DOES; Task 4 keeps its planned shape."
echo "             A4 also failing                   => my harness is wrong, ignore A1-A3."

# ---------------------------------------------------------------------------
banner "BONUS — free Tier 2/3 answers while the cluster is warm"
# ---------------------------------------------------------------------------
$PSQL <<'SQL'
\echo '--- google_ml_integration version vs the 1.5.2/1.5.7/1.5.8 floor (P-12) ---'
SELECT extversion FROM pg_extension WHERE extname='google_ml_integration';

\echo '--- does the preview-AI-functions flag exist under that exact name? (P-10) ---'
SELECT name, setting, context FROM pg_settings WHERE name LIKE 'google_ml_integration%';

\echo '--- ai.rank() signatures — which form do we teach? (D-09) ---'
SELECT pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='ai' AND p.proname='rank';

\echo '--- ScaNN at 3072 on PG 18 (Tier 2) ---'
CREATE INDEX t1a_scann ON t1a USING scann (emb cosine) WITH (num_leaves=1, quantizer='sq8');
\echo '    (num_leaves=1 only because this table has 3 rows; the real one uses 50)'

\echo '--- how is gemini-embedding-001 registered? explicit task type or default? (§7.14) ---'
SELECT model_id, model_type, model_provider, model_qualified_name, model_request_url
FROM google_ml.model_info_view WHERE model_id LIKE '%embedding%';
SQL

echo
echo "################ DONE — paste ~/tier1.log back ################"
