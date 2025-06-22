terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

# Configure the Google Provider
provider "google" {
  project = "encoded-alpha-457108-e8"
  region  = "us-central1"
}
