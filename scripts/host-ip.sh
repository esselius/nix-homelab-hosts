#!/usr/bin/env bash
# Resolve a host name to its LAN address, optionally asserting an explicit IP.
# Usage: scripts/host-ip.sh <host> [expected-ip]
# Set ALLOW_IP_OVERRIDE=1 to let an explicit IP override the inventory (needed
# for a freshly flashed bootstrap host with a temporary address).
set -euo pipefail

host="${1:?usage: $0 <host> [expected-ip]}"
expected="${2:-}"

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo"

# shellcheck disable=SC2016 # ${name} is a Nix variable, not shell.
ip="$(
  HOST_NAME="$host" nix eval --raw --impure --expr '
    let
      i = import ./inventory.nix;
      name = builtins.getEnv "HOST_NAME";
      h = i.${name} or (throw "unknown host: ${name}");
    in
    h.ip
  '
)"

if [ -n "$expected" ] && [ "$expected" != "$ip" ]; then
  if [ "${ALLOW_IP_OVERRIDE:-0}" = 1 ]; then
    ip="$expected"
  else
    echo "error: IP=$expected does not match inventory: $host -> $ip" >&2
    echo "       set ALLOW_IP_OVERRIDE=1 only for a temporary/bootstrap address" >&2
    exit 1
  fi
fi

printf '%s\n' "$ip"
