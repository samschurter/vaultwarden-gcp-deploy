# Vaultwarden on Google Cloud Docker Image - Countryblock

Docker container that allowlists inbound traffic by country using `iptables`. Used in the [Vaultwarden on Google Cloud](https://github.com/samschurter/vaultwarden-gcp-deploy) project, however this image may be used stand-alone.

In this repository's managed Google Compute Engine deployment, the VM bootstrap writes Docker daemon config with `"userland-proxy": false` before the stack starts. That keeps published container ports on Docker's kernel NAT and forwarding path instead of a host-side proxy listener. The countryblock container runs with `network_mode: "host"` and firewall capabilities so it can program the VM's host firewall directly. On startup it creates a dedicated `iptables` chain, inserts a scoped jump near the top of `DOCKER-USER` for public `80/443` ingress on the primary VM interface, then returns only when the source IP matches an `ipset` for one of the configured countries. Any other public source that reaches the chain is dropped. A cron job refreshes the country `ipset` contents from ipdeny on the configured schedule.

This allowlist is intended as defense in depth around the public ingress surface, not as the primary security boundary for Vaultwarden. Authentication, TLS, secret handling, and service hardening remain the primary controls.

# Container Requirements

* Capabilities (`cap_add`):
  * `NET_ADMIN`
  * `NET_RAW`
* `network_mode: "host"`


# Environmental Variables

| Environmental Variable | Description                                                                 |
| ---------------------- | --------------------------------------------------------------------------- |
| COUNTRIES              | Space separated list of allowed ISO 3166-1 alpha-2 country codes; defaults to `US` |
| COUNTRYBLOCK_SCHEDULE  | Cron expression for when to update the IP block list (e.g., 0 0 \* \* \*)   |
| TZ                     | Timezone, optional                                                          |

Only listed countries are allowed from the public internet. If `COUNTRIES` is unset or empty, the container falls back to `US`. The managed deployment expects public ingress on `eth0` and published TCP ports `80,443`; `PUBLIC_IFACE` and `PUBLISHED_TCP_PORTS` may be overridden if that appliance assumption changes.

The refresh job uses ipdeny's published MD5 manifest to catch accidental corruption or incomplete downloads from that feed. It does not provide an independent authenticity guarantee because the manifest and the zone files are both fetched from ipdeny.
