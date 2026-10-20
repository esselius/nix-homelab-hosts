# Maintenance notes

Scope: the NixOS host layer for a small incus VM-host pair (`rpi5-8gb`,
`rpi5-4gb`) plus a throwaway `rpi5-bootstrap` installer image. No application
workloads live here - those run as incus instances.

- Prefer small, explicit modules over framework abstractions. `modules/incus/`
  is split by concern; each file contributes to the internal `local.incus.spec`
  and `preseed.nix` is the only place that assembles the preseed value.
- Hosts (`hosts/*.nix`) tune only `local.incus.{network,guest,tls}`,
  `local.wireguard`, `local.dns`, plus `networking.hostName` / `stateVersion`;
  everything else belongs in `modules/`.
- This repo documents *why*, not just what: keep the README's decisions ledger,
  "Known risks", and verification status in sync with config changes.
- Run `nix fmt` and `nix flake check` before committing. Both are wired into the
  flake (`formatter`, `checks.eval-all`, `checks.fmt`).
- Never commit plaintext secrets. `secrets/rpi5.yaml` is sops-encrypted; edit it
  only inside `nix develop` (whose shellHook sets `SOPS_AGE_KEY_CMD`).
- Deploy with `--target-host` only; no `--build-host` needed (Nix builds via
  the configured aarch64-linux builder):
  `nixos-rebuild switch --flake .#rpi5-8gb --target-host admin@<ip> --sudo`
