# Build & Verification Scripts

**⚠️ NOT STUDENT-FACING. Internal build tooling.**

These provision a *throwaway* prototype cluster used to answer questions that can only be answered
on live infrastructure. They are not the lab's provisioning and must not be confused with it:

- the cluster gets a **public IP** and `--authorized-external-networks=0.0.0.0/0` so Cloud Shell
  can reach it with plain `psql`. That is acceptable only because the project is disposable and
  the data is a throwaway copy. The real lab provisions on the private network from a startup VM.
- `03` loads **only** `players.profile_text` — no relational tables, no embeddings, no explicit
  column list from the manifest. It is **not** a rehearsal of the Pass 1 / Pass 2 load contract.

## Order

```bash
bash 01-provision-test-rig.sh   2>&1 | tee ~/phaseA.log    # ~15-20 min
bash 02-tier1-tests.sh          2>&1 | tee ~/tier1.log
bash 03-tier1b-corpus.sh        2>&1 | tee ~/tier1b.log
```

`03` needs the running identity to have read on the staged corpus bucket. It checks first and
exits clean if not.

## What each answers

| Script | Question |
| :-- | :-- |
| `01` | — (provisions the rig) |
| `02` | **T1C** does `pg_textsearch` + a BM25 index work on PG 18? **T1A** does `ai.hybrid_search()` accept a BM25-backed text component? Plus free Tier 2/3 answers while the cluster is warm. |
| `03` | **T1B** does BM25 rank the row containing `€222,000,000` first, across all 13,439 real profiles? |

Every test prints a `VERDICT:` line so answers are greppable rather than buried in psql output.

## Before this repo goes public

Delete this folder, or keep the repo private until release. A public repo containing a script that
opens an AlloyDB instance to `0.0.0.0/0` is a bad look regardless of the surrounding comments.
