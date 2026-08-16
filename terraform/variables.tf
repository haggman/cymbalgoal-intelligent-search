# Variables the Qwiklabs runtime injects at Start Lab time.
#
# ⚠️ RULE: every variable here must be one the platform actually supplies.
# Nothing is present to answer a prompt, and a variable the runtime does not
# know about fails the apply. Verified against labs in gcp-ce-content that
# declare no-default variables — see cymbalgoal-qwiklabs-runtime-facts.md.
#
# When testing manually, terraform.tfvars must contain ONLY these. If you need
# to add one to make the apply succeed, that is a Start Lab failure you just
# papered over.

variable "gcp_project_id" {
  description = "Project the lab platform provisions for the student."
  type        = string
}

variable "gcp_region" {
  description = <<-EOT
    Deployment region. Constrained to us-central1 or us-east1 for two independent reasons:
      1. QueryData context sets exist in only four regions; these are the two US ones.
      2. google_ml.embedding() calls Vertex from the cluster's own region, so the region
         must serve gemini-embedding-001.
  EOT
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1"], var.gcp_region)
    error_message = "Region must be us-central1 or us-east1 (QueryData + embedding model availability)."
  }
}

variable "gcp_zone" {
  description = "Zone within gcp_region, used by the startup VM."
  type        = string
  default     = "us-central1-a"
}

variable "gcp_username" {
  description = <<-EOT
    The student's full lab email (e.g. student-03-xxxx@qwiklabs.net), injected by Qwiklabs.

    This is load-bearing, not cosmetic: it is how the student is granted alloydbsuperuser,
    which Lab 1 Task 3 needs to CREATE INDEX ... USING bm25 and Lab 3 needs for the Index
    Advisor. Do NOT use data.google_client_openid_userinfo — that returns the Terraform
    runner's identity, not the student's, which is why CymbalFlix declared it and then
    fell back to a variable.
  EOT
  type        = string

  # AlloyDB does NOT validate that an ALLOYDB_IAM_USER principal exists — it will
  # happily create a database user for an address nobody owns. A typo, or the
  # placeholder from terraform.tfvars.example, produces a silently useless grant:
  # the apply succeeds, the output looks right, and the human doing the testing
  # has no alloydbsuperuser. Caught exactly that way on the first live apply.
  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.gcp_username))
    error_message = "gcp_username must be a full email address (e.g. student-03-abc123@qwiklabs.net)."
  }

  validation {
    condition     = !can(regex("(?i)(XX-xxxxxxxx|example\\.com|CHANGEME)", var.gcp_username))
    error_message = "gcp_username is still the placeholder from terraform.tfvars.example. Put your real lab email in terraform.tfvars."
  }
}

# ---------------------------------------------------------------------------
# Tunables — not injected by the platform, defaults are the shipped values.
# ---------------------------------------------------------------------------

variable "cpu_count" {
  description = <<-EOT
    Primary instance vCPUs. Measured: instance creation is ~7 min at 8 vCPU and dominates
    provisioning (~85% of total wall clock), so this is the only real lever on how long a
    student waits. The load itself is ~2.5 min regardless.
  EOT
  type        = number
  default     = 8
}

variable "gcs_data_prefix" {
  description = "Staged corpus location. Pinned snapshot 2026-08-14; never fetched from Kaggle at lab time."
  type        = string
  default     = "gs://class-demo/alloydb-labs/cymbalgoal"
}
