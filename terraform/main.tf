# =============================================================================
# CymbalGoal Lab 1 — Intelligent Search. Provisioning.
# =============================================================================
# Runs from the Start Lab button. The student never sees it and never runs it;
# from their point of view the cluster simply exists.
#
# Every value here is measured, not assumed. Provenance:
#   cymbalgoal-database-flags.md          flag names, verified against the API
#   cymbalgoal-provisioning-walltime.md   timings and the load ordering
#   cymbalgoal-qwiklabs-runtime-facts.md  which variables the platform injects
#   cymbalgoal-terraform-baseline.md      what to inherit from CymbalFlix
#
# Measured total: ~15-18 min. Cluster + instance is ~85% of that.
# =============================================================================

locals {
  cluster_id  = "cymbalgoal-cluster"
  instance_id = "cymbalgoal-primary"
  network     = "cymbalgoal-network"
  database    = "cymbalgoal"
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
    "aiplatform.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",

    # REQUIRED by D-09. Lab 1 Task 5 uses the semantic-reranker form of
    # ai.rank() — signature confirmed live as
    #   (model_id, search_string, documents text[], top_n)
    # and that form draws its models from Discovery Engine. Without this API
    # Task 5 fails at the last step of the lab, which is the worst possible
    # place to discover it.
    "discoveryengine.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# -----------------------------------------------------------------------------
# Network — dedicated VPC, not default
# -----------------------------------------------------------------------------
resource "google_compute_network" "main" {
  name                    = local.network
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name          = "${local.network}-subnet"
  ip_cidr_range = "10.0.0.0/24"
  network       = google_compute_network.main.id
  region        = var.gcp_region

  # The startup VM has no external IP. This lets it reach Google APIs — GCS for
  # the corpus, the AlloyDB Admin API for the Data API PATCH — directly rather
  # than hairpinning through Cloud NAT. NAT still covers apt.debian.org, which
  # is not a Google endpoint.
  private_ip_google_access = true
}

# A custom VPC starts with NO firewall rules — not even the default-allow-ssh
# that the `default` network ships with. Without this, there is no way to reach
# the startup VM at all when provisioning fails, and the serial console is the
# only window. IAP's fixed range is the safe way in: no public IP required, and
# access is governed by IAM rather than by source address.
resource "google_compute_firewall" "iap_ssh" {
  name          = "cymbalgoal-allow-iap-ssh"
  network       = google_compute_network.main.name
  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"] # IAP TCP forwarding, documented and fixed

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# AlloyDB is VPC-native and reaches the managed service over Private Service
# Access. The peering must exist before the instance, or instance creation
# races it — hence the explicit depends_on further down.
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

# NAT, so the startup VM can reach GCS and the AlloyDB Admin API without a
# public IP of its own.
resource "google_compute_router" "main" {
  name    = "cymbalgoal-router"
  region  = var.gcp_region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name                               = "cymbalgoal-nat"
  router                             = google_compute_router.main.name
  region                             = var.gcp_region
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# -----------------------------------------------------------------------------
# Cluster
# -----------------------------------------------------------------------------
# AlloyDB requires an initial password even in an IAM-only setup. We generate
# one, hand it to the startup VM, and otherwise ignore it.
resource "random_password" "initial" {
  length           = 24
  special          = true
  override_special = "-_=+"
}

resource "google_alloydb_cluster" "main" {
  cluster_id = local.cluster_id
  location   = var.gcp_region

  # POSTGRES_18 is pinned explicitly and must never be left to the default.
  # RUM does not exist on PG 18, which is *why* this lab teaches BM25 — the
  # version choice and the curriculum are the same decision.
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

  # ⚠️ observability_config is NOT in the GA google provider — verified against
  # the installed schema at the newest 7.x, which offers only:
  #   client_connection_config, connection_pool_config, machine_config,
  #   network_config, psc_instance_config, query_insights_config,
  #   read_pool_config, timeouts
  # The registry docs describing it are ahead of the released GA provider.
  #
  # That turned out to be the right prompt to ask a better question: LAB 1 DOES
  # NOT NEED IT. Observability powers wait events and active queries, which is
  # Lab 3's story. Each lab provisions its own cluster, so P-14's "set it at
  # creation" applies to Lab 3's cluster, not this one. Carrying it here was
  # inheriting a requirement that does not belong to this lab.
  #
  # 🔴 FOR LAB 3: resolve before writing its Terraform. Either use google-beta
  # for the instance resource (mkt004 and ce436 both already declare it), or set
  # it from the startup VM with `gcloud alloydb instances update` — which works
  # but costs a restart mid-provision, the exact thing P-14 warns against.
  #
  # query_insights_config IS GA and is the Query Insights surface Lab 3 Task 2
  # uses. Harmless here, and it means Labs 2 and 3 extend a base that already
  # has it rather than adding it later and forcing a restart.
  query_insights_config {
    query_string_length     = 4500
    record_application_tags = true
    record_client_address   = true
    query_plans_per_minute  = 5
  }

  # ⚠️ EVERY NAME HERE IS VERIFIED against
  #   GET .../locations/{r}/supportedDatabaseFlags
  # AlloyDB rejects the ENTIRE instance create if one flag name is unknown —
  # no warning, no partial apply. At Start Lab that means every student in the
  # room gets a cluster with no instance. Never add a name you have not checked.
  #
  # Deliberately NOT set, because they already default to on:
  #   google_ml_integration.enable_model_support
  #   google_ml_integration.enable_ai_query_engine
  # Deliberately NOT set, because it does not exist on AlloyDB at any version:
  #   google_ml_integration.enable_model_endpoint_management  (Cloud SQL vocabulary)
  # Deliberately NOT set, because we use private IP:
  #   password.enforce_complexity  (mandatory ONLY when public IP is enabled)
  database_flags = {
    "google_ml_integration.enable_preview_ai_functions" = "on"
    "google_columnar_engine.enabled"                    = "on"
  }

  depends_on = [google_service_networking_connection.psa]
}

# -----------------------------------------------------------------------------
# ⚠️ THE BINDING EVERYTHING DEPENDS ON
# -----------------------------------------------------------------------------
# Without this, google_ml.embedding() / ai.embedding() fail — which means every
# vector search in the lab fails, from Task 2 onward. The cluster builds fine,
# the data loads fine, and the lab dies at the first semantic query.
#
# The AlloyDB service agent does not exist until the cluster does, so binding
# the role earlier fails. This depends_on is not decoration.
resource "google_project_iam_member" "alloydb_vertex" {
  project    = var.gcp_project_id
  role       = "roles/aiplatform.user"
  member     = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-alloydb.iam.gserviceaccount.com"
  depends_on = [google_alloydb_cluster.main]
}

# -----------------------------------------------------------------------------
# Student database user
# -----------------------------------------------------------------------------
# Lab 1 Task 3 runs CREATE INDEX ... USING bm25, and Lab 3 queries the Index
# Advisor. Both require alloydbsuperuser. var.gcp_username carries the student's
# real lab email — see variables.tf for why the openid data source is wrong here.
resource "google_alloydb_user" "student" {
  cluster        = google_alloydb_cluster.main.id
  user_id        = var.gcp_username
  user_type      = "ALLOYDB_IAM_USER"
  database_roles = ["alloydbsuperuser"]
  depends_on     = [google_alloydb_instance.primary]
}

# -----------------------------------------------------------------------------
# D-32 — read pool: DELIBERATELY ABSENT
# -----------------------------------------------------------------------------
# CymbalFlix shipped a READ_POOL at 2 vCPU / 1 node and CymbalGoal inherited the
# shape without inheriting a reason. No task in any of the three labs requires
# one; Lab 3's System Insights story is the only plausible consumer and it does
# not need a pool to tell its story. A pool costs provisioning wall-clock on
# every student cluster.
#
# If one is ever added: database_flags are INSTANCE-level, so every flag above
# must be repeated on it verbatim, or the pool silently behaves differently.

# -----------------------------------------------------------------------------
# Startup VM — the escape hatch for what Terraform structurally cannot do
# -----------------------------------------------------------------------------
resource "google_service_account" "startup" {
  account_id   = "cymbalgoal-startup"
  display_name = "CymbalGoal provisioning VM"
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "startup_roles" {
  for_each = toset([
    "roles/alloydb.admin",          # create the database, PATCH the Data API setting
    "roles/storage.objectViewer",   # read the staged corpus
    "roles/serviceusage.serviceUsageConsumer",
  ])
  project = var.gcp_project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.startup.email}"
}

resource "google_compute_instance" "startup" {
  name         = "cymbalgoal-startup"
  machine_type = "e2-standard-4"
  zone         = var.gcp_zone

  boot_disk {
    initialize_params {
      image = "debian-12"
      size  = 50 # the profile corpus is 185 MB gzipped; leave room
    }
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id
    # No access_config — no public IP. Egress via Cloud NAT.
  }

  service_account {
    email  = google_service_account.startup.email
    scopes = ["cloud-platform"]
  }

  metadata_startup_script = templatefile("${path.module}/startup_script.tftpl", {
    project_id  = var.gcp_project_id
    region      = var.gcp_region
    cluster_id  = local.cluster_id
    instance_id = local.instance_id
    db_name     = local.database
    db_host     = google_alloydb_instance.primary.ip_address
    db_password = random_password.initial.result
    gcs_prefix  = var.gcs_data_prefix
    student     = var.gcp_username
  })

  # ⚠️ Terraform considers this resource complete when the VM BOOTS, not when
  # the startup script finishes. It does not and cannot wait for the load.
  # That is accepted: provisioning is pre-warmed ~1 hour ahead, against ~15-18
  # min of work. See cymbalgoal-qwiklabs-runtime-facts.md. Task 1 opens with a
  # row-count query so a student who jumps the gun sees 0 instead of 13,439.
  depends_on = [
    google_alloydb_instance.primary,
    google_project_iam_member.alloydb_vertex,
    google_project_iam_member.startup_roles,
    google_compute_router_nat.main,
  ]
}
