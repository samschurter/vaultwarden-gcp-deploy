# ADMINISTRATOR.md

This guide covers normal administrative tasks for a running deployment.

The operating model is repo-managed and non-interactive: change configuration in this repo or in Secret Manager, apply Terraform, and let the VM re-converge on boot. Do not treat SSH access as part of the normal workflow.

## Keep the deployment current

There are multiple update paths:

1. Third-party containers are updated by Watchtower on the configured schedule.
2. When automatic COS updates are enabled, the OS downloads updates and the reboot watcher schedules the next configured window only after confirming a reboot is required.
3. Repo-built images and repo-managed configuration are updated when you change this repo and redeploy.

Watchtower only manages the named third-party containers in `docker-compose.yml`. It does not update the local `vwgc_backup:local` or `vwgc_countryblock:local` images, or the temporary ddclient image. The updater uses the locally cached `lscr.io/linuxserver/ddclient:latest` image, pulling it if absent; refresh that image explicitly when updating ddclient.

When you want to roll out repo changes:

1. Pull the latest repo changes into your working copy.
2. Review any changes to secrets or Terraform variables.
3. Run `terraform plan` from `infra/` and review the proposed changes before applying them. Startup content is managed through `metadata["startup-script"]`, so routine script changes update metadata in place. Other changes can still replace the VM and its auto-deleted boot disk; review every replacement separately.
4. Apply the reviewed plan, then stop/start the existing VM to run the new startup flow. Editing the repo or updating instance metadata alone does not execute startup. Ensure `repo_ref` resolves to the commit containing the change and clear any unwanted restore request before booting.

From `infra/`, after applying an in-place update:

```bash
project_id="$(terraform console <<< 'var.project_id' | jq -er .)"
instance_zone="$(terraform console <<< 'var.zone' | jq -er .)"
instance_name="$(terraform output -raw instance_name)"
gcloud compute instances stop "$instance_name" --project="$project_id" --zone="$instance_zone"
gcloud compute instances start "$instance_name" --project="$project_id" --zone="$instance_zone"
```

This uses the Compute API and requires no SSH. It preserves the existing boot
disk and application data, with downtime while the VM is stopped and startup
converges the stack. An ephemeral external IP can change; boot-time ddclient
updates DNS. Terraform apply finishing does not mean guest startup has finished;
check serial output and HTTPS readiness.



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
3. Review/apply Terraform, then stop/start the VM so startup fetches the new secret.

For Terraform-controlled settings such as region, zone, reboot schedule, backup bucket, or restore path, edit `infra/terraform.tfvars` and then apply Terraform.

## COS updates and scheduled reboots

`enable_cos_auto_updates=true` (the default) publishes
`cos-update-strategy=update_enabled`. This makes the repo's intended OS-update
policy explicit: [COS milestone 117 and later disable automatic updates by default](https://docs.cloud.google.com/container-optimized-os/docs/concepts/auto-update).
Set the variable to `false` to publish `update_disabled` and skip the reboot watcher
when managing OS updates separately. Review/apply the change and boot the VM with
the new metadata to converge the updater and watcher.

Startup starts `update-engine.service` and checks `update_engine_client --status`
in the foreground. Failure makes startup return nonzero instead of claiming that
the updater is ready. The long-lived wait runs separately as
`vaultwarden-update-reboot.service`; later failures are recorded by systemd and
do not retroactively change an already completed startup script's exit status.
Watcher diagnostics go to the system journal and serial console.

The helper requires both a successful wait and a confirmed
`CURRENT_OP=UPDATE_STATUS_UPDATED_NEED_REBOOT` before calling `shutdown`. A D-Bus
error, missing service, or unconfirmed status never schedules a reboot. The reboot
window is calculated after the wait, using `reboot_timezone` and `reboot_time`.
If today's window has passed, it uses the next local date; relative minutes avoid
interpreting that time in a different host timezone and round up by less than one
minute.

With diagnostic access to the VM, inspect the watcher using:

```bash
sudo systemctl status vaultwarden-update-reboot.service
sudo journalctl -u vaultwarden-update-reboot.service
```

Otherwise, inspect recent serial output with the Compute API as described below.
The old helper could schedule a reboot even after a failed update-engine call;
changing the repo does not cancel an existing shutdown request. `sudo shutdown -c`
inside the running VM cancels a pending scheduled shutdown. A subsequent normal
stop/start clears that old runtime request and runs the deployed startup flow.

## Check logs

COS agent uploads and serial-console uploads are separate paths, both disabled
by default. `enable_cos_logging=false` sets `google-logging-enabled=false` and
disables `cos_*` streams, including `cos_system`, `cos_containers`, audit, and
journal logs. `enable_serial_logging=false` sets `serial-port-logging-enable=false`
and disables serial-console forwarding, which otherwise includes kernel and
systemd network-interface chatter even when the COS agent is off. These settings
disable the upload paths rather than excluding entries after ingestion.
See the [COS logging switch](https://docs.cloud.google.com/container-optimized-os/docs/how-to/logging)
and [serial-port logging documentation](https://docs.cloud.google.com/compute/docs/troubleshooting/viewing-serial-port-output).

Read recent boot output from a running VM without enabling log shipping or SSH:

```bash
gcloud compute instances get-serial-port-output vaultwarden \
  --project=YOUR_PROJECT_ID --zone=YOUR_ZONE --port=1
```

Use your configured instance name if different. The Compute API retains only the
most recent 1 MB per serial port for running instances; enable serial uploads when
you need longer history or output from stopped instances. Cloud Logging entries
already stored remain available after disabling uploads.

When uploads are enabled, use either of these Cloud Logging entry points:

1. Google Cloud Console -> Compute Engine -> VM instances -> your instance -> Logs
2. Google Cloud Console -> Logging -> Logs Explorer, filtered to the VM

To enable persistent log collection for troubleshooting, select the streams in
`infra/terraform.tfvars` and review/apply the plan:

```hcl
enable_cos_logging = true
enable_serial_logging = true
```

The flags are independent. Boot the VM with the new metadata when changing COS
agent collection; changing serial forwarding itself requires no guest-script
change or reboot. Set the flags back to `false` and apply when finished; boot again
if changing the COS agent setting. COS collection includes application container
stdout/stderr and COS system logs. Serial output includes startup messages such
as DNS update attempts and their final result. Raw ddclient/provider output is
suppressed to keep credentials out of logs.

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
4. Confirm new `cos_*` ingestion subsides with COS logging disabled. With serial logging disabled, confirm new `serialconsole.googleapis.com` entries also subside; recent boot output remains readable through the Compute API. Historical Cloud Logging entries remain stored.
5. Compare external network and Logging request-byte metrics over comparable periods to confirm the ipify loop and ongoing COS uploads have disappeared. Allow for boot activity and metric reporting delay.

## Manage backups

The managed deployment stores backups in GCS by default.

Routine checks:

1. Confirm backup jobs succeed using local logs, or Cloud Logging when COS logging is enabled.
2. Confirm recent backup objects exist in the configured GCS bucket.
3. Confirm the current env secret still contains the expected backup destination and encryption settings.

If you change the backup bucket name, update `infra/terraform.tfvars` and apply Terraform.

If you change backup behavior such as schedule, retention, or notification settings,
update the env secret, review/apply Terraform, and stop/start the VM to fetch the new settings.

## Restore from backup

Restore is handled at boot, using `restore_backup_path` in Terraform. Terraform
stores this as the instance metadata key `vwgc-restore-backup-path`, separately
from `metadata["startup-script"]`. Setting or clearing it updates metadata in place;
it does not execute a restore, reboot, or replace the VM by itself. Complete the
legacy startup-script migration above first if applicable.

Procedure:

1. Identify the object path in the managed backup bucket.
2. Set `restore_backup_path` in `infra/terraform.tfvars` to that object path.
3. Review the plan and run `terraform apply` to publish the request.
4. Stop/start the VM using the commands above (or let first boot handle a newly created VM). Wait for serial output reporting `Restore completed` and successful application startup.
5. Validate the restored vault contents and HTTPS, not just Terraform's exit status.
6. Clear `restore_backup_path` back to `""`.
7. Review the plan and run `terraform apply` again. This removes the request in place; no reboot is needed for cleanup.

The restore uses the current backup encryption key from the env secret when the archive is encrypted.
Only instance metadata is consulted. An absent or empty request skips restoration;
a metadata transport/server failure aborts startup instead of silently ignoring a
possible restore. A successful restore is stamped on the persistent disk, so the
same archive path is skipped on subsequent boots of that disk. Failure leaves no
success stamp and is retried on a later boot. Clearing the request does not erase
the stamp or undo restored data; restoring the same archive again on the same disk
would require a deliberate separate operation.

## Reattach Terraform state in a new environment

If you need to administer the deployment from a new Cloud Shell session or another machine:

1. Authenticate `gcloud` to the same project.
2. Run `bash utilities/create-gcp-secrets.sh --prepare-terraform`.
3. Change into `infra/`.
4. Run `terraform init -reconfigure -backend-config=backend.hcl`.

That recreates the local backend config and reconnects Terraform to the existing remote state.
