#!/usr/bin/env bash
# Resolve a hostname's real address over DNS-over-HTTPS.
#
# The local resolver answers every name with an address from 198.18.0.0/15, the
# RFC 2544 benchmarking range, so a tool that refuses non-public addresses sees
# a private target and declines to fetch. Querying Cloudflare over HTTPS returns
# the address the proxy routes on.
#
# Prints one IPv4 address per line; exits non-zero when the name has none.
set -euo pipefail

name="${1:?usage: realip.sh <hostname>}"
answer=$(curl -fsS --max-time 15 -H 'accept: application/dns-json' \
  "https://cloudflare-dns.com/dns-query?name=${name}&type=A")

python3 - "$answer" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
addrs = [a["data"] for a in data.get("Answer", []) if a.get("type") == 1]
if not addrs:
    sys.exit(1)
print("\n".join(addrs))
PY
