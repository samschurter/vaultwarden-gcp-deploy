locals {
  backup_bucket_name = var.backup_bucket_name != "" ? var.backup_bucket_name : "${var.project_id}-${var.instance_name}-backups"
}

resource "google_service_account" "vaultwarden" {
  # Instance identity for Secret Manager and GCS backup access.
  account_id   = "${var.instance_name}-sa"
  display_name = "${var.instance_name} service account"
}

resource "google_project_iam_member" "secret_accessor" {
  # Allow the VM to read secrets at boot.
  project = var.project_id
  role   = "roles/secretmanager.secretAccessor"
  member = "serviceAccount:${google_service_account.vaultwarden.email}"
}

resource "google_storage_bucket_iam_member" "backup_object_admin" {
  # Limit backup access to the managed GCS bucket instead of the whole project.
  bucket = google_storage_bucket.backup.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.vaultwarden.email}"
}

resource "google_compute_firewall" "allow_http_https" {
  # Public HTTP/HTTPS for Caddy + Vaultwarden.
  name    = "${var.instance_name}-allow-http-https"
  network = "default"

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  target_tags = ["http-server", "https-server", var.instance_name]
}

resource "google_compute_firewall" "deny_ssh" {
  # Explicitly override default-network SSH exposure for this VM.
  name      = "${var.instance_name}-deny-ssh"
  network   = "default"
  priority  = 900
  direction = "INGRESS"

  deny {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.instance_name]
}

resource "google_compute_address" "vaultwarden" {
  # Optional static IP (paid) — default is ephemeral.
  count  = var.use_static_ip ? 1 : 0
  name   = "${var.instance_name}-ip"
  region = var.region
}

resource "google_storage_bucket" "backup" {
  # Managed bucket for backups (versioning enabled).
  name          = local.backup_bucket_name
  location      = var.region
  force_destroy = false

  uniform_bucket_level_access = true
  versioning {
    enabled = true
  }
}

resource "google_compute_instance" "vaultwarden" {
  # Single COS VM running Docker for the stack.
  name         = var.instance_name
  machine_type = var.machine_type
  zone         = var.zone

  tags = ["http-server", "https-server", var.instance_name]

  boot_disk {
    initialize_params {
      # COS image keeps the host lightweight and secure.
      image = "${var.image_project}/${var.image_family}"
      size  = var.boot_disk_gb
      type  = "pd-standard"
    }
  }

  network_interface {
    network = "default"

    dynamic "access_config" {
      # Static IP when requested.
      for_each = var.use_static_ip ? [1] : []
      content {
        nat_ip = google_compute_address.vaultwarden[0].address
      }
    }

    dynamic "access_config" {
      # Ephemeral IP (free tier friendly).
      for_each = var.use_static_ip ? [] : [1]
      content {}
    }
  }

  service_account {
    # Keep cloud-platform here: the startup flow fetches Secret Manager secrets
    # via gcloud on the VM, and Compute Engine still gates that through OAuth
    # scopes in addition to IAM roles.
    email  = google_service_account.vaultwarden.email
    scopes = ["cloud-platform"]
  }

  metadata = {
    # Make Cloud Logging the primary operator surface for COS system and
    # container logs, and retain serial console output for boot troubleshooting.
    google-logging-enabled     = "true"
    serial-port-logging-enable = "true"
  }

  metadata_startup_script = templatefile("${path.module}/startup.sh.tftpl", {
    # Bootstraps repo clone + secret fetch + docker compose.
    repo_url              = var.repo_url
    repo_ref              = var.repo_ref
    project_id            = var.project_id
    env_secret_name       = var.env_secret_name
    ddclient_secret_name  = var.ddclient_secret_name
    reboot_timezone       = var.reboot_timezone
    reboot_time           = var.reboot_time
  })
}
