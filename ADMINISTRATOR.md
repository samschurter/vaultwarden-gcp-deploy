# ADMINISTRATOR.md

This guide covers normal administrative tasks for a running deployment.

The operating model is repo-managed and non-interactive: change configuration in this repo or in Secret Manager, apply Terraform, and let the VM re-converge on boot. Do not treat SSH access as part of the normal workflow.

## Keep the deployment current

There are multiple update paths:

1. Third-party containers are updated by Watchtower on the configured schedule.
2. The VM OS checks for updates and reboots daily if updates are available.
3. Repo-built images and repo-managed configuration are updated when you change this repo and redeploy.

Watchtower only manages the named third-party containers in `docker-compose.yml`. It does not update the local `vwgc_backup:local` or `vwgc_countryblock:local` images, or the temporary ddclient image. The updater uses the locally cached `lscr.io/linuxserver/ddclient:latest` image, pulling it if absent; refresh that image explicitly when updating ddclient.

When you want to roll out repo changes:

1. Pull the latest repo changes into your working copy.
2. Review any changes to secrets or Terraform variables.
3. Run `terraform plan` from `infra/` and review the proposed changes before applying them. A change to `metadata_startup_script` can require instance replacement, including its auto-deleted boot disk. Do not apply a replacement plan for a running vault without an explicit recovery/migration plan and verified backups.
4. Apply the reviewed plan, then arrange a boot to run the new startup flow. Editing the repo or updating instance metadata alone does not guarantee startup ran again. Ensure `repo_ref` resolves to the commit containing the change.

## Change application settings

Most runtime settings live in the `vwgc-env` secret created by `utilities/create-gcp-secrets.sh`.

Use this when you need to change values such as:

1. Vaultwarden domain or SMTP settings.
2. Signup policy.
3. Backup schedule or destination.
4. Country allowlist.
5. Watchtower schedule.

Update flow:

1. Run `bash utilities/create-gcp-secrets.sh`.
2. Update the prompted values.
3. Run `terraform apply`.

For Terraform-controlled settings such as region, zone, reboot schedule, backup bucket, or restore path, edit `infra/terraform.tfvars` and then apply Terraform.

## Check logs

Serial boot output is available in Cloud Logging. COS log shipping is disabled by
default using instance metadata `google-logging-enabled=false`, which stops uploads
at the source rather than excluding them after ingestion. This disables all
`cos_*` streams, including `cos_system`, `cos_containers`, audit, and journal logs.
This uses the [documented COS logging metadata switch](https://docs.cloud.google.com/container-optimized-os/docs/how-to/logging).

Use either of these entry points:

1. Google Cloud Console -> Compute Engine -> VM instances -> your instance -> Logs
2. Google Cloud Console -> Logging -> Logs Explorer, filtered to the VM

To restore full COS log shipping for troubleshooting, set this in
`infra/terraform.tfvars`, review/apply the plan, and boot the VM with the new metadata:

```hcl
enable_cos_logging = true
```

Set it back to `false` and repeat the apply/boot flow when finished. With it enabled,
Cloud Logging includes application container stdout/stderr and COS system logs.
In either mode, boot logs report DNS update attempts and the final result; raw
ddclient/provider output is suppressed to keep credentials out of logs.

Important local paths, if you ever need them for deeper inspection:

1. Vaultwarden file log: `/mnt/stateful_partition/vaultwarden-gcp-deploy/vaultwarden/vaultwarden.log`
2. Docker container logs: `/var/lib/docker/containers/<container-id>/<container-id>-json.log`

Docker keeps its existing bounded rotation policy. COS logging configuration does
not disable local Docker logs or the system journal. Routine backup output is
visible in Cloud Logging only while COS logging is enabled; otherwise check the
backup objects in GCS and local logs when diagnostic access is available.

## DNS operations

`utilities/update-dns.sh` runs on every VM boot after secrets are fetched and before
Compose starts the stack. It discovers IPv4 through GCP metadata, runs ddclient
directly without LinuxServer's `/init`/s6 supervisor, and discards the container
and cache when done. Each of three attempts has a 15-second metadata timeout and a
120-second ddclient timeout, with 10 seconds between attempts. Image acquisition
time is additional. A failed update exits nonzero and prevents Compose startup.
Caddy retains its separate DNS propagation check before requesting certificates.

Both Cloudflare and DuckDNS secrets remain supported. ddclient's own config parser
preserves provider settings and credentials. The wrapper overrides each parsed
host's IP discovery and removes the daemon setting on every config read. This also
avoids ddclient 4.0.0 treating `daemon=0` as its minimum polling interval. `daemon=300`, web/ipify discovery,
or old `PUID`, `PGID`, and `VWGC_DDCLIENT_CONF` env entries can remain in existing
secrets; no secret rewrite or full secret-creation wizard is needed for migration.
New templates omit web discovery and polling.
The wrapper also checks every host's resulting IPv4 and success status, since some
ddclient releases report provider errors while returning exit code zero.

Container restarts do not change the VM's address and do not run the updater. If
you explicitly replace the external IP while the VM stays running, rerun the
updater on the VM through approved diagnostic access:

```bash
sudo bash /mnt/stateful_partition/vaultwarden-gcp-deploy/utilities/update-dns.sh
```

Alternatively, reboot through the normal operational workflow to run startup
again. The command above must run on the VM, where metadata and the fetched secret
exist; running it in Cloud Shell will not update the intended VM's address.

For a different fetched config path, set `DDCLIENT_CONF_FILE` when invoking the
script. `DDCLIENT_IMAGE` can select a tested LinuxServer ddclient image; the wrapper
uses ddclient 4.x's native parser and update entry point. To refresh the default
image during approved VM maintenance, run `sudo docker pull lscr.io/linuxserver/ddclient:latest`.

After deploying this change:

1. Confirm serial boot output reports `dns-update: completed` and the hostname resolves to the metadata external IPv4, directly or via the DuckDNS CNAME.
2. Confirm Caddy starts and HTTPS works. Compose's `--remove-orphans` removes the old `ddns` container after the successful DNS update; no supervised ddclient process should remain.
3. Repeat a boot with existing Docker state and confirm the DNS update runs again.
4. With COS logging disabled, confirm new `cos_*` ingestion subsides while serial boot output remains available. Historical logs remain stored.
5. Compare external network and Logging request-byte metrics over comparable periods to confirm the ipify loop and ongoing COS uploads have disappeared. Allow for boot activity and metric reporting delay.

## Manage backups

The managed deployment stores backups in GCS by default.

Routine checks:

1. Confirm backup jobs succeed using local logs, or Cloud Logging when COS logging is enabled.
2. Confirm recent backup objects exist in the configured GCS bucket.
3. Confirm the current env secret still contains the expected backup destination and encryption settings.

If you change the backup bucket name, update `infra/terraform.tfvars` and apply Terraform.

If you change backup behavior such as schedule, retention, or notification settings, update the env secret and apply Terraform.

## Restore from backup

Restore is handled at boot, using `restore_backup_path` in Terraform.

Procedure:

1. Identify the object path in the managed backup bucket.
2. Set `restore_backup_path` in `infra/terraform.tfvars` to that object path.
3. Run `terraform apply`.
4. Wait for the VM to boot and the restore to complete.
5. Validate the site and logs.
6. Clear `restore_backup_path` back to `""`.
7. Run `terraform apply` again.

The restore uses the current backup encryption key from the env secret when the archive is encrypted.

## Reattach Terraform state in a new environment

If you need to administer the deployment from a new Cloud Shell session or another machine:

1. Authenticate `gcloud` to the same project.
2. Run `bash utilities/create-gcp-secrets.sh --prepare-terraform`.
3. Change into `infra/`.
4. Run `terraform init -reconfigure -backend-config=backend.hcl`.

That recreates the local backend config and reconnects Terraform to the existing remote state.
