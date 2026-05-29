FROM caddy:builder-alpine AS builder

RUN xcaddy build --with github.com/mholt/caddy-ratelimit

FROM caddy:alpine

RUN apk add --no-cache bind-tools tzdata

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
COPY scripts/start-caddy.sh /usr/local/bin/start-caddy.sh

ENTRYPOINT ["/usr/local/bin/start-caddy.sh"]
CMD ["caddy", "docker-proxy", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
