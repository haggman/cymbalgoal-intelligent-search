# =============================================================================
# CymbalGoal Lab 1 — Intelligent Search. Provisioning.
# =============================================================================
# Runs from the Start Lab button. This provisions the CLUSTER ONLY. The database,
# schema, data load and indexes are done by the student's notebook in Task 1 —
# which is deliberate, not a shortcut:
#
#   * Nothing here can run SQL. The Terraform runner sits outside the VPC, and
#     there is no google_alloydb_database resource. A startup VM used to bridge
#     that gap; the AlloyDB Python Connector removes the need, since it reaches
#     the cluster from anywhere with IAM auth.
#   * A database created by provisioning is owned by `postgres`, and
#     alloydbsuperuser is NOT a real superuser — so the student could not drop or
#     fully manage their own database. Measured, not theorised.
#   * The load teaches something. CREATE INDEX ... USING scann is a featured
#     product; burying it in a shell script nobody reads wastes it.
#
# Measured: cluster + instance ~12-15 min (85% of total). Notebook load ~4.4 min.
#
# Provenance for every value here:
#   cymbalgoal-database-flags.md          flag names, verified against the API
#   cymbalgoal-notebook-provisioning.md   why the VM is gone
#   cymbalgoal-qwiklabs-runtime-facts.md  which variables the platform injects
#   cymbalgoal-terraform-baseline.md      what CymbalFlix got right
# =============================================================================

locals {
  cluster_id  = "cymbalgoal-cluster"
  instance_id = "cymbalgoal-primary"
  network     = "cymbalgoal-network"
}

data "google_project" "current" {
  project_id = var.gcp_project_id
}

# -----------------------------------------------------------------------------
# APIs
# -----------------------------------------------------------------------------
resource "google_project_service" "apis" {
  for_each = toset([
    "alloydb.googleapis.com",
    "compute.googleapis.com",
    "servicenetworking.googleapis.com",
    "aiplatform.googleapis.com", # Vertex, and Colab Enterprise runtimes
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",

    # REQUIRED by D-09. Lab 1 Task 5 uses the semantic-reranker form of
    # ai.rank(), confirmed live as
    #   (model_id, search_string, documents text[], top_n)
    # and that form draws its models from Discovery Engine. Without this, Task 5
    # fails at the last step of the lab — the worst place to find out.
    "discoveryengine.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Network
# -----------------------------------------------------------------------------
# AlloyDB is VPC-native and requires Private Service Access even when reached
# over its public IP. No subnet, NAT, router or firewall rules — those all
# existed to serve the startup VM and went with it.
resource "google_compute_network" "main" {
  name                    = local.network
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_global_address" "psa" {
  name          = "cymbalgoal-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
  depends_on    = [google_project_service.apis]
}

resource "google_service_networking_connection" "psa" {
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa.name]
  depends_on              = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
# AlloyDB requires an initial user with a password even in an IAM-only setup.
# We generate one and never use it — no consumer, and it appears in no output.
resource "random_password" "initial" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

resource "google_alloydb_cluster" "main" {
  cluster_id = local.cluster_id
  location   = var.gcp_region

  # Pinned explicitly, never left to the default. RUM does not exist on PG 18,
  # which is *why* this lab teaches BM25 — the version choice and the curriculum
  # are the same decision.
  database_version = "POSTGRES_18"

  network_config {
    network = google_compute_network.main.id
  }

  initial_user {
    user     = "postgres"
    password = random_password.initial.result
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# Primary instance
# -----------------------------------------------------------------------------
resource "google_alloydb_instance" "primary" {
  cluster       = google_alloydb_cluster.main.name
  instance_id   = local.instance_id
  instance_type = "PRIMARY"

  machine_config {
    cpu_count = var.cpu_count
  }

  # Public IP, reached by the AlloyDB Python Connector with enable_iam_auth.
  #
  # This is NOT the "public IP + raw psql" shape that was rejected earlier — that
  # forces 0.0.0.0/0 authorized networks because Cloud Shell's egress IP is
  # dynamic. Here IAM gates access and the Connector carries mTLS with certs from
  # the Admin API. Measured: connects in 0.5 s with NO authorized networks
  # configured at all, so nothing is opened to the internet.
  #
  # It also means students can use ANY Colab runtime. VPC attachment would force
  # one pre-created runtime per student (google_colab_runtime requires
  # runtime_user), which is cost and provisioning time multiplied by room size.
  #
  # ⚠️ Deliberately no authorized_external_networks. If one is ever needed, use
  # the narrowest range that works — never 0.0.0.0/0 in a shipped lab.
  network_config {
    enable_public_ip = true
  }

  # ⚠️ EVERY NAME VERIFIED against
  #   GET .../locations/{region}/supportedDatabaseFlags
  # AlloyDB rejects the ENTIRE instance create or update if one flag name is
  # unknown — no warning, no partial apply. At Start Lab that means every student
  # in the room gets a cluster with no instance. Never add an unchecked name.
  database_flags = {
    # MANDATORY with public IP. AlloyDB refuses the request without it.
    "password.enforce_complexity" = "on"

    # Required for enable_iam_auth to work. google_alloydb_user creates the
    # principal; this flag is what lets it authenticate. Without it the IAM user
    # exists but cannot log in.
    "alloydb.iam_authentication" = "on"

    # Preview ai.* functions — PG 17/18 only. Lab 1 Task 5 needs ai.rank().
    "google_ml_integration.enable_preview_ai_functions" = "on"

    # Task 1's columnar-engine aside.
    "google_columnar_engine.enabled" = "on"

    # NOT set, because they already default to on:
    #   google_ml_integration.enable_model_support
    #   google_ml_integration.enable_ai_query_engine
    #   google_ml_integration.enable_faster_embedding_generation
    # NOT set, because it does not exist on AlloyDB at any version:
    #   google_ml_integration.enable_model_endpoint_management  (Cloud SQL term)
    # NOT set, because it is Lab 2's:
    #   google_ml_integration.enable_cost_optimized_ai_functions
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# ⚠️ THE BINDING EVERYTHING DEPENDS ON
# -----------------------------------------------------------------------------
# Without this, ai.embedding() / google_ml.embedding() fail — so every vector
# search in the lab fails, from Task 2 onward. The cluster builds fine, the load
# succeeds, and the lab dies at the first semantic query.
#
# The AlloyDB service agent does not exist until the cluster does, so binding
# earlier fails. This depends_on is load-bearing.
resource "google_project_iam_member" "alloydb_vertex" {
  project    = var.gcp_project_id
  role       = "roles/aiplatform.user"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
  depends_on = [google_alloydb_cluster.main]
}

# -----------------------------------------------------------------------------
# Student database user
# -----------------------------------------------------------------------------
# Task 1 creates the database, Task 3 runs CREATE INDEX ... USING bm25, and Lab 3
# uses the Index Advisor. All need alloydbsuperuser.
#
# var.gcp_username carries the student's real lab email. Do NOT use
# data.google_client_openid_userinfo — it returns the Terraform runner's
# identity, which is why CymbalFlix declared it and then fell back to a variable.
resource "google_alloydb_user" "student" {
  cluster   = google_alloydb_cluster.main.id
  user_id   = var.gcp_username
  user_type = "ALLOYDB_IAM_USER"

  # ⚠️ alloydbiamuser is NOT optional. AlloyDB grants it automatically on
  # creation, and database_roles declares the COMPLETE set — so listing only
  # alloydbsuperuser reads as "revoke alloydbiamuser" on the NEXT apply:
  #   Error 400: cannot revoke IAM roles [alloydbiamuser ...]
  # The first apply succeeds and every one after it fails. CymbalFlix carries the
  # same latent bug; it never re-applies, so it never surfaces there.
  database_roles = ["alloydbsuperuser", "alloydbiamuser"]

  depends_on = [google_alloydb_instance.primary]
}

# -----------------------------------------------------------------------------
# D-32 — read pool: DELIBERATELY ABSENT
# -----------------------------------------------------------------------------
# Inherited from CymbalFlix's cluster shape (READ_POOL, 2 vCPU, 1 node) without
# inheriting a reason. No task in any of the three labs requires one, and it
# costs provisioning wall-clock on every student cluster.
#
# If one is ever added: database_flags are INSTANCE-level, so every flag above
# must be repeated on it verbatim, or the pool silently behaves differently.
