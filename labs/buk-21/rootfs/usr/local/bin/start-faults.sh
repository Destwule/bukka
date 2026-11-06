#!/usr/bin/env bash
# What went wrong in last night's change. Students must not read this file;
# it's here because the lab needs it. (Reading it is like reading the answer
# key: you'll learn nothing.)
set -u
# Fault 1: DNS points at a resolver that doesn't exist.
cp /etc/resolv.conf /etc/resolv.conf.docker 2>/dev/null || true
echo "nameserver 192.0.2.53   # internal resolver (dns-1.bukka.internal)" > /etc/resolv.conf
# Fault 2: the firewall default-denies inbound, and the rule for the API port was lost.
iptables -P INPUT DROP
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
# Fault 3 is in /etc/bukka/api.env (BUKKA_HOST=127.0.0.1).
exit 0
