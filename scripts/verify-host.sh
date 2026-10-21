#!/usr/bin/env bash
# Post-deploy smoke test for a running host.
# Usage: scripts/verify-host.sh <host> <ip> [admin]
set -euo pipefail

host="${1:?usage: $0 <host> <ip> [admin]}"
ip="${2:?usage: $0 <host> <ip> [admin]}"
admin="${3:-admin}"
cache_url="${CACHE_URL:-https://cache.int.esselius.dev/homelab}"

ssh_cmd=(ssh -o BatchMode=yes -o ConnectTimeout=5 "$admin@$ip")
fail=0

run() {
  "${ssh_cmd[@]}" "$1"
}

ok() {
  printf '  ok: %s\n' "$1"
}

bad() {
  printf '  FAIL: %s\n' "$1" >&2
  fail=1
}

warn() {
  printf '  warn: %s\n' "$1" >&2
}

if ! run true >/dev/null 2>&1; then
  echo "FAIL: cannot ssh to $admin@$ip ($host)" >&2
  exit 1
fi

state="$(run 'systemctl is-system-running 2>/dev/null || true' || true)"
case "$state" in
  running) ok "systemd is running" ;;
  *) bad "systemd state is '${state:-unknown}', expected running" ;;
esac

failed="$(run 'systemctl --failed --no-legend --plain' || true)"
if [ -z "$failed" ]; then
  ok "no failed systemd units"
else
  bad "failed systemd units:"
  printf '%s\n' "$failed" | sed 's/^/       /' >&2
fi

if run 'test -x /run/current-system/bin/switch-to-configuration'; then
  ok "current system is a complete NixOS closure"
else
  bad "/run/current-system is not a NixOS system"
fi

if run 'test -f /boot/extlinux/extlinux.conf'; then
  ok "extlinux boot entry present"
else
  bad "/boot/extlinux/extlinux.conf is missing"
fi

if run 'systemctl is-active --quiet incus.service'; then
  ok "incus active"
else
  bad "incus.service is not active"
fi

if run 'incus network show incusbr0 >/dev/null 2>&1'; then
  ok "incusbr0 present"
else
  bad "incus network incusbr0 is missing"
fi

if run "nix store info --store '$cache_url' >/dev/null 2>&1"; then
  ok "cache reachable ($cache_url)"
else
  warn "cache not reachable ($cache_url); deploys may fall back"
fi

printf '  host: %s\n' "$(run 'nixos-version' || echo unknown)"
printf '  current: %s\n' "$(run 'readlink /run/current-system' || echo unknown)"

if [ "$fail" -ne 0 ]; then
  echo "verify $host: FAILED" >&2
  exit 1
fi
echo "verify $host: OK"
