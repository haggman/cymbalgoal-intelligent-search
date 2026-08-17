# Data Preparation Notebook

`cymbalgoal_de_pipeline.ipynb` is the record of how the searchable corpus was built.

| | |
| :-- | :-- |
| Version | **v4.2** |
| sha256 | `865b46cb46afc872…` |
| Size | 293,379 bytes, 73 cells |
| Offline test suite | 15 suites, ~490 assertions, runs with no cloud access |

**Check the sha before assuming this is current.** A stale copy of this notebook shipped two
already-fixed SQL defects to the provisioning session, and the only reason it was caught is that
someone compared bytes rather than filenames.

- **Stage 4** — 14,235 profiles (13,439 players + 796 clubs), ~250 words each, generated with
  `gemini-3.7-flash` grounded in Google Search, prompt v1.6.0
- **Stage 5** — embedded with `gemini-embedding-001` at **3072 dimensions**
- **Stage 6** — exported as headerless gzipped CSV and staged to Cloud Storage

## Running it

Safe to Run All. Generation and embeddings both resume from checkpoints and will not re-bill;
`guard_cold_start()` refuses to start a full generation if the checkpoints failed to restore,
because a failed restore and a first run are otherwise the same code path with ~$157 between them.
Checkpoints mirror to `gs://class-demo/alloydb-labs/cymbalgoal/checkpoints/` and are restored
automatically, so a dead runtime costs nothing.

The final cell writes `artifacts/handback.txt` — twelve sections covering run state, QA screens,
the Lab 1 probes, final acceptance against the staged bytes, and the manifest repair.

## Why 3072 and not 768

This is the question everyone asks, and it is not a free choice.

Lab 1 embeds the fan's query text *inside PostgreSQL* with
`google_ml.embedding('gemini-embedding-001', query)`. That function takes exactly two arguments —
there is no `output_dimensionality`. So the query-side vector is whatever the model emits natively,
which is 3072. A stored column of any other width fails the distance operator with a dimension
mismatch, live, in front of the room.

Stored documents must match the query. 3072 it is.

Measured, not assumed: `cosine(RETRIEVAL_QUERY, model default) = 1.0`, so Vertex's default task
type **is** `RETRIEVAL_QUERY`, which pairs correctly with the `RETRIEVAL_DOCUMENT` documents this
notebook stores.

## Why the profiles are pre-built

Generating 14,235 grounded profiles costs real money and hours of wall clock. Doing it at lab time
would mean every student waits, every student gets slightly different text, and the lab's
verification steps could not assert anything. Generated once, staged, loaded as ordinary columns —
so the corpus is a pinned artifact and the lab is about search, not about generation.

⚠️ **Regenerating is a rebuild, not a refresh.** Grounded generation drifts, so a new corpus would
not match the labs — Lab 1 Task 2 depends on `€222,000,000` appearing in exactly one profile
(Neymar's). Regeneration also requires re-running the **Stage 3** notebook first, since the eight
relational CSVs, `schema.sql` and `manifest.json` are *inputs* to this one.

## What this notebook emits

- `players_profiles.csv.gz`, `clubs_profiles.csv.gz` — pass-2 files keyed on id, carrying
  `profile_text` and `profile_embedding`
- `load_profiles.sql` — the pass-2 `UPDATE`. The `\copy … FROM PROGRAM` lines are psql
  meta-commands; a non-psql loader may reimplement the transport but **must** reproduce both
  row-count assertions, which are the contract.
- `manifest.json` repairs — `column_order` describes the **file**, `table_column_order` describes
  the **table**. They differ by the two pass-2 columns, and any loader must preflight the field
  count against the column list before loading.

⚠️ The profile CSVs are **not line-oriented** — `profile_text` contains embedded newlines, so
13,439 records span ~51,693 physical lines. Use a real CSV parser or `COPY`; `head`, `tail`,
`split` and `wc -l` will corrupt records.
