# The three variables the lab platform injects at Start Lab time.
# Do not add required variables without a default — nothing is there to answer a prompt.

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
