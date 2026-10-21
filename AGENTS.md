# Maintenance notes

Scope: the NixOS host layer for a small incus VM-host pair (`rpi5-8gb`,
`rpi5-4gb`) plus a throwaway `rpi5-bootstrap` installer image. No application
workloads live here - those run as incus instances.

- Prefer small, explicit modules over framework abstractions. `modules/incus/`
  is split by concern; each file contributes to the internal `local.incus.spec`
  and `preseed.nix` is the only place that assembles the preseed value.
  Settings that must be applied without an incus restart go through
  `modules/incus/runtime.nix` (`incus config set`) instead of the preseed.
- Values shared by both permanent hosts (VPN server identity, DNS zone and
  bootstrap records, TLS/monitoring toggles) live in `modules/site.nix` as
  `local.site`, wired in with `mkDefault`.
- Hosts (`hosts/*.nix`) tune only `local.incus.{network,guest,tls,dnsAddress,metrics}`,
  `local.wireguard`, `local.dns`, plus `networking.hostName` / `stateVersion`;
  everything else belongs in `modules/`.
- This repo documents *why*, not just what: keep the README's decisions ledger,
  "Known risks", and verification status in sync with config changes.
- Run `task fmt` and `nix flake check` before committing. `nix fmt` (and
  `task fmt`) formats the tree via the flake formatter; `nix flake check` covers
  `checks.eval-all`, `checks.fmt`, and `checks.shellcheck`.
- Never commit plaintext secrets. `secrets/rpi5.yaml` is sops-encrypted; edit it
  only inside `nix develop` (whose shellHook sets `SOPS_AGE_KEY_CMD`).
- Deploy with `--target-host` only; no `--build-host` needed on the normal path
  (Nix builds via the configured aarch64-linux builder):
  `nixos-rebuild switch --flake .#rpi5-8gb --target-host admin@<ip> --sudo`.
  `task deploy` adds `--build-host <target>` only in its Cachix-unreachable
  fallback, to build on the host itself.
- Host addresses live in `inventory.nix`; resolve them with
  `scripts/host-ip.sh <host>` (the Taskfile does). Never add another independent
  IP default. `task deploy` refuses a dirty worktree (`ALLOW_DIRTY=1` overrides),
  runs `nix flake check`, and then `scripts/verify-host.sh`; a failed verify
  fails the deploy (`AUTO_ROLLBACK=1` reverts, or use `task rollback`).
  Destructive tasks require `CONFIRM=WIPE|MOUNT|FLASH`.
