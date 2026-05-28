terraform {
  # Pin Terraform and provider versions for repeatable builds.
  required_version = ">= 1.6.0"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  # Single project/region/zone for this small deployment.
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
