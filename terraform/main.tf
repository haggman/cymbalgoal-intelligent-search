# CymbalGoal Lab 1 — provisioning skeleton.
#
# ⚠️ SCAFFOLDING ONLY. Nothing below is applied yet.
#
# The version pins in versions.tf are settled and measured. Everything in this
# file is still gated on live results from the prototype rig (see ../build/).
# It is written out as commented structure rather than working HCL on purpose:
# a plausible-looking main.tf that has never been applied is worse than an
# obviously unfinished one, because someone eventually trusts it.
#
# Open decisions that change the shape of this file:
#
#   D-09  Does Lab 1 Task 5 use the semantic-reranker form of ai.rank()?
#         If yes, discoveryengine.googleapis.com MUST be enabled below — that
#         form draws its models from Discovery Engine. If no, drop it.
#
#   D-31  Load method: `gcloud alloydb clusters import` vs `psql \copy` from
#         the startup VM. Decide with real file sizes. Note the import API is
#         one table per call and permits one operation at a time, which matters
#         with eight relational tables plus two profile files in play.
#
#   D-32  Does the read pool earn its keep? No lab task currently requires one.
#         It was inherited from mkt007's cluster shape and costs wall-clock on
#         every student cluster. Measure with and without before committing.
#
#   T1A   If BM25 does not feed ai.hybrid_search(), Lab 1 Task 4 changes shape
#         but NOT this file — provisioning is unaffected either way.

# ---------------------------------------------------------------------------
# APIs
# ---------------------------------------------------------------------------
# resource "google_project_service" "apis" {
#   for_each = toset([
#     "alloydb.googleapis.com",
#     "compute.googleapis.com",
#     "servicenetworking.googleapis.com",
#     "aiplatform.googleapis.com",
#     # "discoveryengine.googleapis.com",   # ← gated on D-09
#   ])
#   service            = each.value
#   disable_on_destroy = false
# }

# ---------------------------------------------------------------------------
# Cluster
# ---------------------------------------------------------------------------
# POSTGRES_18 is pinned explicitly and must never be left to the default.
# RUM does not exist on PG 18, which is why this lab teaches BM25 —
# the version choice and the curriculum are the same decision.
#
# resource "google_alloydb_cluster" "cymbalgoal" {
#   cluster_id       = "cymbalgoal-cluster"
#   location         = var.gcp_region
#   database_version = "POSTGRES_18"
#   network_config { network = ... }
#   initial_user { user = "postgres", password = ... }
# }

# ---------------------------------------------------------------------------
# Primary instance
# ---------------------------------------------------------------------------
# Two ordering constraints that are easy to get wrong and expensive to discover:
#
#   1. observability_config MUST be set at creation. Enabling it later forces a
#      restart in the middle of provisioning.
#   2. It cannot be enabled on secondaries, so the primary must exist and be
#      configured BEFORE any read pool is created.
#
#   3. database_flags are instance-level, not cluster-level. Every flag set here
#      must be repeated verbatim on any read pool, or the pool silently behaves
#      differently from the primary.
#
# resource "google_alloydb_instance" "primary" {
#   instance_type = "PRIMARY"
#   observability_config { enabled = true, track_active_queries = true, track_wait_events = true }
#   database_flags = { "google_ml_integration.enable_model_endpoint_management" = "on" }
# }

# ---------------------------------------------------------------------------
# Read pool — gated on D-32
# ---------------------------------------------------------------------------
# resource "google_alloydb_instance" "readpool" { ... }

# ---------------------------------------------------------------------------
# Database user
# ---------------------------------------------------------------------------
# resource "google_alloydb_user" "lab_user" { ... }

# ---------------------------------------------------------------------------
# Startup VM — the escape hatch
# ---------------------------------------------------------------------------
# Everything Terraform structurally cannot do, in this order:
#
#   1. CREATE DATABASE cymbalgoal          — no google_alloydb_database resource exists
#   2. PATCH the Data API setting          — no Terraform surface, no gcloud surface;
#                                            raw v1alpha REST from the VM
#   3. CREATE EXTENSION vector, alloydb_scann, google_ml_integration, pg_textsearch
#                                          — granting alloydbsuperuser where required;
#                                            BM25 and the Index Advisor both need it
#   4. Assert the google_ml_integration extension version meets the floor, and FAIL
#      LOUDLY if it doesn't. A silent version mismatch surfaces as a broken lab task
#      in front of the room.
#   5. Apply the schema — TABLES ONLY.
#      ⚠️ schema.sql as staged also creates the two ScaNN indexes. Running it
#      wholesale builds them on empty tables, so every one of 14,235 vectors is
#      then indexed incrementally during the pass-2 UPDATE — the slow path, on
#      every student cluster. See ../build/README.md.
#   6. Pass 1 — the eight relational tables, ALWAYS with an explicit column list
#      taken from the manifest. Never positional CSV order. Parents before children.
#   7. Pass 2 — load_profiles.sql, which updates only profile_text and
#      profile_embedding and asserts row counts.
#   8. Build the ScaNN indexes NOW, after both loads, with maintenance_work_mem
#      and shared_buffers tuned below total machine memory.
#   9. Do NOT create the BM25 index. That is Lab 1 Task 3 — it's the lab.
#
# resource "google_compute_instance" "startup" {
#   metadata_startup_script = templatefile("${path.module}/startup_script.tftpl", { ... })
# }
