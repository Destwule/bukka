# BUK-27 lab: a fresh Debian server, "bukka-web-1", with systemd.
# The Bukka code is already deployed to /opt/bukka; nothing runs it yet.

# Build the web app once, so the server only needs the static files.
FROM node:20-bookworm-slim AS web
WORKDIR /src/web
COPY web/package.json web/package-lock.json ./
RUN npm ci --silent
COPY web/ ./
RUN npm run build

FROM debian:bookworm
ENV container=docker
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      systemd systemd-sysv python3 python3-venv curl iproute2 procps sudo less nano vim-tiny ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && rm -f /lib/systemd/system/multi-user.target.wants/getty* \
          /etc/systemd/system/*.wants/getty* /lib/systemd/system/sysinit.target.wants/systemd-firstboot*

# The engineer logs in as "oncall" and uses sudo. The service account
# "bukka" exists for running the API; nobody logs in as it.
RUN useradd -m -s /bin/bash oncall \
 && echo "oncall ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/oncall \
 && echo 'PS1="oncall@bukka-web-1:\w\$ "' >> /home/oncall/.bashrc \
 && useradd --system --home /var/lib/bukka --shell /usr/sbin/nologin bukka

# The deployed code: API in a virtualenv, web app as static files.
COPY api /opt/bukka/api
RUN python3 -m venv /opt/bukka/venv \
 && /opt/bukka/venv/bin/pip install --no-cache-dir /opt/bukka/api \
 && mkdir -p /var/lib/bukka /etc/bukka \
 && cd /opt/bukka/api \
 && DATABASE_URL=sqlite:////var/lib/bukka/bukka.db /opt/bukka/venv/bin/alembic upgrade head \
 && DATABASE_URL=sqlite:////var/lib/bukka/bukka.db /opt/bukka/venv/bin/python -m bukka_api.seed \
 && chown -R bukka:bukka /var/lib/bukka
COPY --from=web /src/web/dist /opt/bukka/web/dist
COPY labs/buk-27/rootfs/ /

STOPSIGNAL SIGRTMIN+3
CMD ["/lib/systemd/systemd"]
