# syntax=docker/dockerfile:1@sha256:2780b5c3bab67f1f76c781860de469442999ed1a0d7992a5efdf2cffc0e3d769
# checkov:skip=CKV_DOCKER_3: s6-overlay requires root init so bundled services can prepare state before each service drops privileges
# checkov:skip=CKV_DOCKER_8: s6-overlay entrypoint must start as root so cont-init can initialize persistent state

ARG PENPOT_VERSION=2.19.3
ARG PENPOT_FRONTEND_DIGEST=sha256:d22ce9f6f4859adbc726f45965da0d4b083817b0c13ca4a49aa3e927901cccb9
ARG PENPOT_BACKEND_DIGEST=sha256:31ebb4dabd104c2ed3ae736dcf5a6043a0660ddaac7bcd8501c28036fb4b578c
ARG PENPOT_EXPORTER_DIGEST=sha256:1705d70e79f3530b3cee65d0cdbee3c5f44f26d62f5ad43bac7945dce4c7b653
ARG PENPOT_MCP_DIGEST=sha256:01ee7620262379c337a9f77e3149d860330d261ffc640d89af60dc8bd45aef94
ARG MAILPIT_VERSION=v1.34.0
ARG MAILPIT_IMAGE_DIGEST=sha256:23a2ef85bc50853ab3093645d1d64679afd8887e89da5e48a88940c172591a4e

FROM penpotapp/frontend:${PENPOT_VERSION}@${PENPOT_FRONTEND_DIGEST} AS frontend
FROM penpotapp/backend:${PENPOT_VERSION}@${PENPOT_BACKEND_DIGEST} AS backend
FROM penpotapp/mcp:${PENPOT_VERSION}@${PENPOT_MCP_DIGEST} AS mcp
FROM axllent/mailpit:${MAILPIT_VERSION}@${MAILPIT_IMAGE_DIGEST} AS mailpit
FROM penpotapp/exporter:${PENPOT_VERSION}@${PENPOT_EXPORTER_DIGEST}

ARG INTERNAL_POSTGRESQL_MAJOR=16
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG TARGETARCH

LABEL org.opencontainers.image.source="https://github.com/JSONbored/penpot-aio" \
      org.opencontainers.image.title="penpot-aio" \
      org.opencontainers.image.description="Penpot packaged as a single-container Unraid AIO image with bundled PostgreSQL, Redis-compatible cache, Mailpit, exporter, and MCP"

# hadolint ignore=DL3002
USER root
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Keep the existing PostgreSQL 16 data directory on the Debian 13 exporter base.
# hadolint ignore=DL3003
RUN find /etc/apt -type f \( -name '*.list' -o -name '*.sources' \) -exec sed -i 's|http://|https://|g' {} + && \
    printf 'Acquire::Retries "5";\nAcquire::http::Timeout "30";\nAcquire::https::Timeout "30";\n' > /etc/apt/apt.conf.d/80-retries && \
    install -d /usr/share/keyrings && \
    curl -fsSLo /usr/share/keyrings/postgresql.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
    printf '%s  %s\n' '0144068502a1eddd2a0280ede10ef607d1ec592ce819940991203941564e8e76' /usr/share/keyrings/postgresql.asc | sha256sum --check - && \
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/postgresql.asc] https://apt.postgresql.org/pub/repos/apt trixie-pgdg main' > /etc/apt/sources.list.d/pgdg.list && \
    apt-get update && \
    apt-get -y dist-upgrade && \
    apt-get install -y --no-install-recommends \
      ca-certificates="$(apt-cache madison ca-certificates | awk 'NR==1 {print $3}')" \
      curl="$(apt-cache madison curl | awk 'NR==1 {print $3}')" \
      fontforge="$(apt-cache madison fontforge | awk 'NR==1 {print $3}')" \
      gettext-base="$(apt-cache madison gettext-base | awk 'NR==1 {print $3}')" \
      nginx="$(apt-cache madison nginx | awk 'NR==1 {print $3}')" \
      openssl="$(apt-cache madison openssl | awk 'NR==1 {print $3}')" \
      "postgresql-${INTERNAL_POSTGRESQL_MAJOR}=$(apt-cache madison postgresql-${INTERNAL_POSTGRESQL_MAJOR} | awk 'NR==1 {print $3}')" \
      "postgresql-client-${INTERNAL_POSTGRESQL_MAJOR}=$(apt-cache madison postgresql-client-${INTERNAL_POSTGRESQL_MAJOR} | awk 'NR==1 {print $3}')" \
      python3="$(apt-cache madison python3 | awk 'NR==1 {print $3}')" \
      python3-tabulate="$(apt-cache madison python3-tabulate | awk 'NR==1 {print $3}')" \
      redis-server="$(apt-cache madison redis-server | awk 'NR==1 {print $3}')" \
      redis-tools="$(apt-cache madison redis-tools | awk 'NR==1 {print $3}')" \
      woff-tools="$(apt-cache madison woff-tools | awk 'NR==1 {print $3}')" \
      woff2="$(apt-cache madison woff2 | awk 'NR==1 {print $3}')" \
      xz-utils="$(apt-cache madison xz-utils | awk 'NR==1 {print $3}')" && \
    useradd --system --home-dir /var/lib/mailpit --create-home --shell /usr/sbin/nologin mailpit && \
    mkdir -p /appdata/config /appdata/assets /appdata/logs /appdata/mailpit /appdata/postgres /appdata/redis /run/penpot-aio /run/postgresql /etc/nginx/overrides/http.d && \
    chown -R penpot:penpot /appdata/assets /appdata/logs && \
    chown -R postgres:postgres /appdata/postgres /run/postgresql && \
    chown -R redis:redis /appdata/redis && \
    chown -R mailpit:mailpit /appdata/mailpit && \
    chmod 700 /appdata/postgres /appdata/redis /appdata/mailpit && \
    rm -rf /tmp/* /var/lib/apt/lists/*

# The common archive provides the init scripts and the platform archive provides the binaries.
RUN set -eu; \
    case "${TARGETARCH}" in \
      amd64) s6_arch=x86_64; s6_arch_sha256=e6befcc96a437a3831386ecfc51808c5d3e939dc5fe3c02ae9284599e8aa2408 ;; \
      arm64) s6_arch=aarch64; s6_arch_sha256=b17f17a82e7a515c682a91edaf2ffdabb73f891981b6c1fd712115693a2f8b4c ;; \
      *) printf 'Unsupported TARGETARCH: %s\n' "${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    s6_tmp="$(mktemp -d)"; \
    trap 'rm -rf -- "${s6_tmp}"' EXIT; \
    s6_release="https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}"; \
    s6_noarch_archive="${s6_tmp}/s6-overlay-noarch.tar.xz"; \
    s6_arch_archive="${s6_tmp}/s6-overlay-${s6_arch}.tar.xz"; \
    curl -fsSL -o "${s6_noarch_archive}" "${s6_release}/s6-overlay-noarch.tar.xz"; \
    curl -fsSL -o "${s6_arch_archive}" "${s6_release}/s6-overlay-${s6_arch}.tar.xz"; \
    printf '%s  %s\n' \
      '5379750ed30a84bbd2e2dd74847ba6b5bd29cd0b2e3ea2ec58049b57eb2eda12' "${s6_noarch_archive}" \
      "${s6_arch_sha256}" "${s6_arch_archive}" | sha256sum --check -; \
    tar -C / -Jxpf "${s6_noarch_archive}"; \
    tar -C / -Jxpf "${s6_arch_archive}"

COPY --from=backend /opt/jre /opt/jre
COPY --from=backend /opt/penpot/backend /opt/penpot/backend
COPY --from=backend /opt/imagick/etc/ImageMagick-7/policy.xml /opt/imagick/etc/ImageMagick-7/policy.xml
COPY --from=frontend /var/www/app /var/www/app
COPY --from=frontend /entrypoint.sh /var/www/app/js/config.js /etc/nginx/overrides/location.d/external-locations.conf /opt/penpot/aio-frontend/
COPY --from=frontend /tmp/nginx.conf.template /tmp/nginx-mcp-locations.conf.template /tmp/resolvers.conf.template /tmp/nginx-security-headers.conf.template /tmp/
COPY --from=frontend /etc/nginx/mime.types /etc/nginx/mime.types
COPY --from=frontend /etc/nginx/overrides /etc/nginx/overrides
COPY --from=mcp /opt/penpot/mcp /opt/penpot/mcp
COPY --from=mailpit /mailpit /usr/local/bin/mailpit

RUN --mount=from=frontend,source=/etc/nginx,target=/tmp/penpot-nginx \
    if [ -r /tmp/penpot-nginx/csp-script-hashes.txt ]; then \
      install -m 644 /tmp/penpot-nginx/csp-script-hashes.txt /etc/nginx/csp-script-hashes.txt; \
    fi && \
    chown -R penpot:penpot /opt/penpot /var/www/app

COPY rootfs/ /
RUN find /etc/cont-init.d -type f -exec chmod +x {} \; && \
    find /etc/services.d -type f -name run -exec chmod +x {} \; && \
    find /usr/local/bin -type f -exec chmod +x {} \;

VOLUME ["/appdata"]
EXPOSE 8080 8025 4401 4402

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV JAVA_HOME=/opt/jre
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/penpot/browsers
ENV S6_CMD_WAIT_FOR_SERVICES_MAXTIME=420000
ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2

HEALTHCHECK --interval=30s --timeout=10s --start-period=180s --retries=5 \
  CMD curl -fsS http://127.0.0.1:8080/readyz >/dev/null || exit 1

ENTRYPOINT ["/init"]
