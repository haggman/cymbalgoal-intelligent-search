# Terraform — what built your lab cluster

You never ran this. It ran when you clicked **Start Lab**, and by the time you saw a command
prompt the cluster existed, the data was loaded, and the vector index was built.

It's here because "pre-built" is doing a lot of work in that sentence, and the parts it's hiding
are the parts worth stealing for your own systems.

## Status

⚠️ **Scaffolding.** `versions.tf`, `provider.tf` and `variables.tf` are final. `main.tf` is a
commented skeleton — the resources are still being validated against a live PostgreSQL 18 cluster.

## The three things worth your attention

**1. Indexes are built after the load, never before.**

The schema file that creates the tables also, if you let it, creates the vector indexes. Run it
straight through and you build an index on an empty table — then every single row you load has to
be inserted into that index one at a time. Load first, index second, with `maintenance_work_mem`
raised for the build. The same rule applies to any bulk load into any indexed table you'll ever
own.

**2. Some configuration can only be set at creation.**

Observability on an AlloyDB instance is one of these. Enable it later and you get a restart. In a
lab that's an annoyance; in production that's a maintenance window. It's also why the primary
instance has to be fully configured before a read pool exists — the setting can't be applied to
secondaries at all.

And `database_flags` are per-instance, not per-cluster. Add a read pool and you must repeat every
flag on it, or the pool quietly behaves differently from the primary and you debug it at 2am.

**3. Not everything has a Terraform resource.**

There is no resource for creating a database inside an AlloyDB cluster. There's no Terraform *or*
gcloud surface for the Data API setting — it's a raw REST call. So provisioning ends with a small
VM that runs the steps Terraform structurally can't, then goes away. That escape-hatch pattern is
worth knowing: infrastructure-as-code covers most of the surface, and you need a plan for the rest.

## What it deliberately does NOT do

It does not create the BM25 index. That's Task 3 — building it is the lab.

## Rebuilding in your own project

Terraform 1.12+, google provider 7.x, and a project with AlloyDB and Vertex AI enabled. Region must
be `us-central1` or `us-east1`: `google_ml.embedding()` calls Vertex from the cluster's own region,
and the embedding model is only served in some of them.

The staged corpus lives in a course-owned bucket you won't have access to. `../notebooks/` shows
how it was built from public CC0 data.
