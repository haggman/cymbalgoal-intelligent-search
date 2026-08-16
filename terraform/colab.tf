# =============================================================================
# Colab Enterprise runtime — the student's notebook surface
# =============================================================================
# ⚠️ EXPERIMENTAL. Being evaluated as a replacement for the startup VM.
#
# Why this exists: the AlloyDB cluster has a private IP, so anything running SQL
# must be inside the VPC. That was the startup VM's only real justification. A
# VPC-attached Colab runtime satisfies the same constraint AND is a surface the
# student can see, which turns provisioning from hidden plumbing into Task 1
# content — including `CREATE INDEX ... USING scann`, a featured Google product
# currently buried in a shell script nobody reads.
#
# Verify with `terraform validate` before trusting any field name here. The
# reference docs are from the provider's main branch and may be ahead of 7.35.0.
# Today's lesson: an unverified field is not a field.
# =============================================================================

resource "google_colab_runtime_template" "lab" {
  name         = "cymbalgoal-runtime-template"
  display_name = "CymbalGoal Lab"
  location     = var.gcp_region
  description  = "VPC-attached runtime with line of sight to the AlloyDB private IP."

  machine_spec {
    # No accelerator. This notebook moves ~185 MB and runs SQL; there is nothing
    # for a GPU to do, and asking for one risks a quota denial on a lab project.
    machine_type = "e2-standard-4"
  }

  data_persistent_disk_spec {
    disk_type    = "pd-balanced"
    disk_size_gb = 100
  }

  # THE WHOLE POINT. Without network + subnetwork the runtime sits outside the
  # VPC and cannot reach 10.188.244.2 — same wall the Terraform runner hits.
  network_spec {
    enable_internet_access = true # pip install, and GCS if PGA misses
    network                = google_compute_network.main.id
    subnetwork             = google_compute_subnetwork.main.id
  }

  # euc_disabled = false keeps End User Credentials ON, so the notebook runs as
  # the STUDENT rather than as a service account. That is what makes IAM auth to
  # AlloyDB work — `gcloud auth print-access-token` returns the student's token,
  # and google_alloydb_user.student already grants them alloydbsuperuser.
  # Disabling EUC would break the auth model, not just change it.
  euc_config {
    euc_disabled = false
  }

  idle_shutdown_config {
    idle_timeout = "3600s" # one hour — longer than a 90-minute lab's idle gaps
  }

  software_config {
    colab_image {
      release_name = "py312"
    }
  }

  depends_on = [google_project_service.apis]
}

# -----------------------------------------------------------------------------
# Pre-created runtime — this is where the time saving lives
# -----------------------------------------------------------------------------
# Creating the runtime at Start Lab means cold start happens during the
# instructor's pre-warm window instead of eating the student's first ten
# minutes. That is the difference between this approach costing ~2.5 min of lab
# time and costing ~10.
#
# ⚠️ Least certain resource in this file. If `terraform validate` rejects it,
# comment it out — students can create a runtime from the template themselves,
# at the cost of cold start on the clock.
resource "google_colab_runtime" "lab" {
  name                     = "cymbalgoal-runtime"
  display_name             = "CymbalGoal Lab Runtime"
  location                 = var.gcp_region
  notebook_runtime_template_ref {
    notebook_runtime_template = google_colab_runtime_template.lab.id
  }

  # Start it now so it is warm when the student arrives.
  desired_state = "RUNNING"

  depends_on = [
    google_colab_runtime_template.lab,
    google_alloydb_instance.primary,
  ]
}
