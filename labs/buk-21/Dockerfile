# A small "production server" for BUK-21: Debian with the Bukka API installed
# and managed like a service. start-faults.sh breaks three things on boot.
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      iptables iproute2 dnsutils curl procps sudo less nano vim-tiny ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# The engineer on call logs in as "oncall" (not root) and uses sudo.
RUN useradd -m -s /bin/bash oncall
 && echo "oncall ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/oncall
 && echo 'PS1="oncall@bukka-prod-1:\w\$ "' >> /home/oncall/.bashrc

COPY api /opt/bukka/api
RUN pip install --no-cache-dir /opt/bukka/api
 && cd /opt/bukka/api
 && DATABASE_URL=sqlite:////var/lib/bukka/bukka.db sh -c 'mkdir -p /var/lib/bukka && alembic upgrade head && python -m bukka_api.seed'
 && chown -R oncall /var/lib/bukka

COPY labs/buk-21/rootfs/ /
RUN chmod +x /usr/local/bin/*

EXPOSE 8080
CMD ["/usr/local/bin/boot.sh"]
