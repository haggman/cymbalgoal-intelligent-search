# Version pins.
#
# These are not conservative guesses — they were chosen by surveying every lab
# currently shipping in the content repo. Terraform 1.12.1 and google provider
# 7.x are both in active production use, so the old "<= 4.74" ceiling that
# earlier labs carry is an artifact of their age, not a platform limit.
#
# The floor matters: observability_config on google_alloydb_instance and the
# google_alloydb_user resource both need a provider far newer than 4.74.

terraform {
  required_version = ">= 1.12.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "7.35.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "3.7.2"
    }
  }
}
