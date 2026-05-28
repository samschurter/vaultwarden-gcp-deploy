# Vaultwarden on Google Cloud Docker Image - Caddy

This is the proxy container repository for the [Vaultwarden on Google Cloud](https://github.com/samschurter/vaultwarden-gcp-deploy) project.

## Changes

Base Image: `caddy:alpine`

Changes to Base Image: Add tzdata package so timezone is set using `TZ` env variable, and build Caddy with the `github.com/mholt/caddy-ratelimit` module used by the bundled Caddyfile
