# bukka-api-1 for BUK-45: the API server, still using its own local database
# file. The apprentice moves its data to a private PostgreSQL server.
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      iproute2 dnsutils curl procps sudo less nano vim-tiny ca-certificates postgresql-client \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash oncall \
 && echo "oncall ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/oncall \
 && echo 'PS1="oncall@bukka-api-1:\w\$ "' >> /home/oncall/.bashrc \
 && echo 'cat /etc/motd' >> /home/oncall/.bashrc

COPY api /opt/bukka/api
RUN pip install --no-cache-dir /opt/bukka/api \
 && mkdir -p /var/lib/bukka \
 && cd /opt/bukka/api \
 && DATABASE_URL=sqlite:////var/lib/bukka/bukka.db alembic upgrade head \
 && DATABASE_URL=sqlite:////var/lib/bukka/bukka.db python -m bukka_api.seed \
 && chown -R oncall /var/lib/bukka

COPY labs/buk-45/rootfs/ /
RUN chmod +x /usr/local/bin/* && chmod 600 /etc/bukka/api.env

EXPOSE 8080
CMD ["/usr/local/bin/boot.sh"]
