#!/usr/bin/env bash
# Lab-only PKI. In production the bridge needs a publicly trusted cert for its FQDN
# (the voice platform validates it on calls it sends to you, and on BYE/REFER),
# and it validates the platform's cert against the system CA store.
set -euo pipefail
out="${1:?usage: certs.sh <outdir>}"
mkdir -p "$out"; cd "$out"
[ -f ca.crt ] && exit 0

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=lab-ca" -keyout ca.key -out ca.crt 2>/dev/null

issue() { # name, CN, SAN
  openssl req -newkey rsa:2048 -nodes -subj "/CN=$2" -keyout "$1.key" -out "$1.csr" 2>/dev/null
  printf 'subjectAltName=%s\nextendedKeyUsage=serverAuth,clientAuth\n' "$3" > "$1.ext"
  openssl x509 -req -in "$1.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile "$1.ext" -out "$1.crt" 2>/dev/null
  rm -f "$1.csr" "$1.ext"
}
issue sbc     bridge.lab   "DNS:bridge.lab,IP:203.0.113.1"
issue agent-a agent-a.lab  "DNS:agent-a.lab,IP:203.0.113.10"
issue agent-b agent-b.lab  "DNS:agent-b.lab,IP:203.0.113.11"
