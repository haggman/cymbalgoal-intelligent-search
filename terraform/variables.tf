# Variables the Qwiklabs runtime injects at Start Lab time.
#
# ⚠️ RULE: every variable here must be one the platform actually supplies, under
# the exact name the platform uses. Nothing is present to answer a prompt, and a
# required variable the runtime does not know about fails the apply — for every
# student in the room, at once, with no partial success.
#
# Names verified by survey against the labs in gcp-ce-content that declare
# no-default variables and therefore depend on injection:
#   gcp_project_id   512 labs
#   gcp_region       508 labs
#   gcp_zone         479 labs
#   username         120 labs   ← NOT "gcp_username". See the note on it below.

variable "gcp_project_id" {
  description = "Project the lab platform provisions for the student."
  type        = string
}

variable "gcp_region" {
  description = <<-EOT
    Deployment region. Constrained to us-central1 or us-east1 for two independent reasons:
      1. QueryData context sets exist in only four regions; these are the two US ones.
      2. ai.embedding() calls Vertex from the cluster's own region, so the region
         must serve gemini-embedding-001.
    qwiklabs.yaml narrows allowed_locations to the same two — both gates, deliberately.
  EOT
  type        = string
  default     = "us-central1"

  validation {
    condition     = contains(["us-central1", "us-east1"], var.gcp_region)
    error_message = "Region must be us-central1 or us-east1 (QueryData + embedding model availability)."
  }
}

variable "gcp_zone" {
  description = <<-EOT
    Zone within gcp_region. Nothing uses it since the startup VM was removed, but
    Qwiklabs injects it and it costs nothing to declare, so it stays.
  EOT
  type        = string
  default     = "us-central1-a"
}

# -----------------------------------------------------------------------------
# ⚠️ THE VARIABLE MOST LIKELY TO KILL START LAB
# -----------------------------------------------------------------------------
# This is `username`, and it carries the LOCAL PART ONLY — "student-03-abc123",
# with no domain. Every lab in the content repo that needs a student identity
# appends the domain itself:
#
#   isv057/main.tf:35    "user:${var.username}@qwiklabs.net"
#   ce204/main.tf:33     "user:${var.username}@qwiklabs.net"
#   ce325/main.tf:37     "user:${var.username}@qwiklabs.net"
#   ce300/main.tf:111    runtime_user = "${var.username}@qwiklabs.net"
#
# Seventeen labs, no exceptions. main.tf builds local.student_email from it.
#
# Two ways the standalone dev version of this file got it wrong, both of which
# apply cleanly at a desk and fail at Start Lab:
#   1. It was named `gcp_username`. The platform does not inject that name, and
#      the variable had no default — "No value for required variable", room dead.
#   2. It validated that the value CONTAINED an "@". The platform's real value
#      never does, so even the correct name would have been rejected.
#
# Both were invisible to testing, because testing supplied a hand-written
# terraform.tfvars with a full email in it. A tfvars you wrote yourself proves
# your config parses; it proves nothing about what the platform hands you.
# -----------------------------------------------------------------------------
variable "username" {
  description = <<-EOT
    The student's lab username, LOCAL PART ONLY (e.g. "student-03-abc123").
    Injected by Qwiklabs. main.tf appends "@qwiklabs.net".

    Load-bearing, not cosmetic: it is how the student is granted alloydbsuperuser,
    which Task 3 needs for CREATE INDEX ... USING bm25 and Lab 3 needs for the
    Index Advisor. Do NOT use data.google_client_openid_userinfo — that returns
    the Terraform runner's identity, not the student's, which is why CymbalFlix
    declared it and then fell back to a variable.
  EOT
  type        = string

  # AlloyDB does NOT validate that an ALLOYDB_IAM_USER principal exists — it will
  # happily create a database user for an address nobody owns. The apply succeeds,
  # the output looks right, and the student has no alloydbsuperuser until they hit
  # Task 3 and can't build the index. Caught exactly that way on the first live apply.
  validation {
    condition     = !can(regex("@", var.username))
    error_message = "username must be the local part only (e.g. student-03-abc123), with no @domain — main.tf appends @qwiklabs.net."
  }

  validation {
    condition     = length(trimspace(var.username)) > 0
    error_message = "username is empty. Without it the student is never granted alloydbsuperuser, and Task 3 fails."
  }
}

# ---------------------------------------------------------------------------
# Tunables — not injected by the platform, defaults are the shipped values.
# ---------------------------------------------------------------------------

variable "cpu_count" {
  description = <<-EOT
    Primary instance vCPUs. Measured: cluster + instance creation is ~9 min at 8 vCPU
    and dominates provisioning (~85% of total wall clock), so this is the only real
    lever on how long an instructor must pre-warm ahead of an event. The student-facing
    notebook load is ~4.5 min regardless.
  EOT
  type        = number
  default     = 8
}

variable "student_email_domain" {
  description = <<-EOT
    Domain appended to var.username. Qwiklabs issues qwiklabs.net addresses; this is
    a variable only so the same config can be applied by hand in a personal project,
    where your identity is your own Google account domain.
  EOT
  type        = string
  default     = "qwiklabs.net"
}
