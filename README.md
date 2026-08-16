# CymbalGoal — Intelligent Search: From Keywords to Hybrid

Companion repository for the CymbalGoal AlloyDB workshop, **Lab 1 of 3**.

CymbalGoal is a global football fan and analytics platform. Fans follow clubs and players, rate
matches, and search across 13,439 players and 796 clubs drawn from the Big 5 European leagues plus
the Champions and Europa Leagues. In this lab you fix a search experience that fails in two
mirror-image ways, using a BM25 full-text index, vector similarity, and the fusion of the two.

You do **not** need this repository to complete the lab — everything you need is provisioned for you
when you click **Start Lab**. This repo exists so you can take the work home: re-read the notebook,
inspect the infrastructure that was built for you, and rebuild the whole thing in your own project.

---

## What's in here

| Folder | What it is | Do you need it during the lab? |
| :-- | :-- | :-- |
| `notebooks/` | The data-preparation notebook — how the profile text was generated and embedded | No. Reference and post-event study. |
| `terraform/` | The infrastructure that provisions your lab cluster | No. Runs automatically at Start Lab. |
| `build/` | Internal build and verification scripts | No. Not student-facing. |

### `notebooks/`

The profiles that make semantic search possible aren't in the source data. Transfermarkt gives you
numbers and categories — excellent for SQL, useless to embed. Every player and club profile in this
lab was generated once, offline, by the notebook in this folder, then embedded with
`gemini-embedding-001` at 3072 dimensions and staged to Cloud Storage.

This matters more than it sounds. **Nothing expensive happens at lab time.** Every student gets
byte-identical data, nobody waits on generation, and the corpus is a pinned artifact you can point
at and reproduce. If you want to run this pattern on your own data, the notebook is the recipe.

### `terraform/`

The cluster you'll use was built by this Terraform before you typed a single command. It is here so
you can see what "pre-built" actually meant — the PostgreSQL 18 cluster, the extensions, the load,
and the vector index that was constructed *after* the data landed rather than before it.

Read `terraform/README.md` for the parts worth your attention.

---

## Rebuilding this in your own project

You'll need a Google Cloud project with billing, the AlloyDB and Vertex AI APIs enabled, and
Terraform 1.12 or newer. Start with `terraform/README.md`.

The one thing you cannot copy is the data: the staged corpus lives in a bucket owned by the course.
The notebook shows you how it was made, and the source dataset is public and CC0.

---

## Source data

Football Data from Transfermarkt — <https://github.com/dcaribou/transfermarkt-datasets> — CC0 1.0.
Pinned snapshot, never downloaded live during a lab.

Scope: `GB1`, `ES1`, `IT1`, `L1`, `FR1`, `CL`, `EL`. 13,439 players · 796 clubs · 29,740 games ·
832,193 appearances · 417,617 game events · 297,822 valuations · 65,494 transfers · 65 competitions.
