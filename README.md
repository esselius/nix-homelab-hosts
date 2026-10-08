# NixOS Raspberry Pi 5 incus VM-host pair (`rpi5-8gb`, `rpi5-4gb`)

Two standalone NixOS incus servers on Raspberry Pi 5 boards (8 GB and 4 GB), declared from this
repo, built from a macOS (Apple Silicon) host, installed via nixos-anywhere without kexec, root on
NVMe, ephemeral root state (impermanence), microSD as permanent boot + rescue device.

## Hosts

| Host | Board | Role | incus workloads |
|------|-------|------|-----------------|
| `rpi5-8gb` | Pi 5 8 GB | primary | VMs (KVM/QEMU) + LXC containers |
| `rpi5-4gb` | Pi 5 4 GB | secondary | LXC containers only (no VMs, no ZFS) |
| `rpi5-rescue` | either | rescue/installer OS living on each SD card (p2) | none |

`rpi5-rescue` is a first-class flake host, not a frozen image: it is rebuilt with the same
nixos-rebuild mechanics as the main hosts (see `docs/ownership.md`, summarized in the SD table
below). It carries `VARIANT_ID=installer` plus baked-in SSH keys, which is what makes plain
`nixos-anywhere` skip its kexec phase on these boards.

## Architecture

Boot chain (both hosts, identical):

```
Pi 5 EEPROM (SPI) -> stock firmware (SD p1 FAT) -> u-boot.bin -> extlinux.conf (SD p3 ext4)
-> mainline kernel + initrd -> /
```

- No U-Boot fork, no EEPROM configuration, no ACPI/EDK2 detour.
- `hardware.raspberry-pi.firmware = { enable = true; uboot.enable = true; }` stages firmware,
  DTBs, overlays, `config.txt`, and `u-boot.bin` onto the FAT declaratively (nixos-hardware PR
  #1894). Without it a custom SD image fails exactly the two failure modes documented in
  nixos-hardware issue #1928 (missing Pi 5 DTBs, then "no kernel to load").
- `generic-extlinux-compatible` generations live on SD p3 and are rewritten on every
  `nixos-rebuild switch`; rollback = previous entry at the U-Boot prompt.

### Storage

microSD (written once per host by the bootstrap image; declaratively refreshed afterwards):

| Partition | FS | Mount | Owner | Notes |
|-----------|----|-------|-------|-------|
| p1 | FAT32 | `/boot/firmware` | main OS config (`hardware.raspberry-pi.firmware`) | firmware, DTBs, overlays, `config.txt`, `u-boot.bin` |
| p2 | ext4 | `/` (when rescue is booted) | `rpi5-rescue` config only | installer-flavored OS, own extlinux generations live inside p2 |
| p3 | ext4 | `/boot` (main OS) | main OS config | `extlinux.conf` + kernel/initrd per generation, `configurationLimit`-pruned |

NVMe (a single-host data disk, the only thing disko ever wipes):

| Subvol | Mount | Lifetime |
|--------|-------|----------|
| `@root` | `/` | rolled back to pristine at every boot (impermanence, btrfs recipe - no tmpfs, RAM matters on 4/8 GB) |
| `@nix` | `/nix` | persists |
| `@persist` | `/persist` | survives reboots: `machine-id`, SSH host keys, `/var/lib/nixos` (UID/GID maps), `/var/lib/incus`, `/var/log` + persistent journald, `/home`, `/root`, git copy of this flake |
| `@snapshots` | `/snapshots` | snapper-managed (nightly + pre-`nixos-rebuild` hook) |

Partition ownership rules (what keeps updates boring):

- SD p1 and p3 are owned by the main host configs; the rescue OS disables firmware-module FAT
  staging so it never fights the main OS.
- SD p2 is owned by `rpi5-rescue` alone; its rebuilds never touch p1/p3/NVMe.
- If the rescue OS is ever beyond repair, re-flashing is safe and expected: the fresh image boots
  p2 again, and the next `nixos-anywhere` run repopulates p3 during install.

### incus

- `virtualisation.incus`, `pkgs.incus-lts`, `ui.enable = true`.
- `networking.nftables.enable = true` (module assertion; iptables is unsupported).
- Preseed runs once: `incusbr0` NAT bridge, `default` profile, `dir` storage pool whose source
  lives under `/persist/var/lib/incus` so instance state rides the persist bind automatically.
- VM images are qcow2 raw on btrfs: CoW disabled (`chattr +C`) on VM disks.
- Documented v2 toggle: switch the pool driver to `btrfs` (CoW clones) - persistence independence
  makes that a safe later swap, not a redesign.

## Decisions ledger (why each piece)

| Decision | Value | Rationale |
|----------|-------|-----------|
| nixpkgs | `nixos-unstable`, pinned in `flake.lock` | stable 26.05 SD images lack Pi 5 boot files (nixpkgs PR #537862 is on unstable); pinning means updates only happen deliberately |
| Board support | `nixos-hardware.nixosModules.raspberry-pi-5` | upstream profile: extlinux + BCM2712 DTB filter + NVMe/PCIe/RP1 initrd + firmware staging options |
| Kernel | mainline `linuxPackages_latest` override | cached on cache.nixos.org (no bespoke builds), 4K pages (vendor `linux-rpi` is 16K-page = KVM guest hazard), headless comfort zone since 6.12 (RP1 solid); vendor kernel is a documented one-line fallback with the `nixos-raspberrypi` cachix |
| Boot device | microSD, boot chain permanently on SD | U-Boot 2026.07 in nixpkgs cannot read boot files from NVMe; upstream NVMe boot landed for U-Boot 2026.10 and will land in nixpkgs later - at that point NVMe-only boot is a config-only change (disko FAT + EEPROM order + delete SD from daily ops) |
| Rescue | installer OS on SD p2 | same `#78`/`#1928` upstream convergence; nixos-anywhere-compatible by construction (`VARIANT_ID=installer`) |
| Filesystem | btrfs (checksums on write + scrubs; no third-party module ever constrains `nix flake update`; ~zero RAM cost vs ZFS ARC on 8/4 GB) | the RAM lens made this the winner; ZFS remains a documented alternative for a future 16 GB host |
| Install | `nixos-anywhere`, kexec skipped | nixos-anywhere's `runKexec()` early-returns when `VARIANT_ID=installer`; kexec on Pi 5 is flaky, so the installer-flavored bootstrap is what buys the one-command experience |
| Topology | standalone pair, no cluster | 2-member Cowsql/Raft clusters lose quorum on a single node update; container live migration is stop-and-move anyway for real workloads; offline `incus move` covers the need |

## Playbooks

### Install (once per host, from the Mac)

```bash
# one-time: flash both SDs with the bootstrap image
nix build .#images.rpi5-bootstrap
zstd -d ./result/sd-image/*.img.zst -o pi5-bootstrap.img
sudo dd if=pi5-bootstrap.img of=/dev/diskX bs=4M status=progress conv=fsync

# first boot: SSH sanity checks (mainline kernel, /dev/nvme0n1 present,
# /etc/os-release contains VARIANT_ID=installer, EEPROM UR log shows no NVMe probe errors)

nix run github:nix-community/nixos-anywhere -- --flake .#rpi5-8gb root@<pi-ip>
nix run github:nix-community/nixos-anywhere -- --flake .#rpi5-4gb root@<pi-ip>
```

nixos-anywhere destroys/creates only the disk disko declares (NVMe). If the Mac build host
misbehaves during install, pre-build the disko script + toplevel and pass `--store-paths`
(nixos-anywhere #18 pattern).

### Update + rollback

```bash
nix flake update          # deliberate bumps only
nixos-rebuild dry-build --flake .#rpi5-8gb   # or --build-host for remote builds
nixos-rebuild switch --flake .#rpi5-8gb --target-host root@<pi-ip>
```

Rollback after a bad update: choose the previous generation at the U-Boot prompt (extlinux menu,
SD p3). Root state is irrelevant (impermanence), so rollback is purely about kernel/generation
correctness.

### Rescue

- NVMe/root trouble: at the U-Boot prompt select the p2 rescue entry; you boot the installer OS
  (btrfs check, re-run nixos-anywhere, etc.).
- Rescue-OS update (rare by design): `nixos-rebuild boot --flake .#rpi5-rescue --target-host`.
- Re-flash (`dd` the bootstrap image again) is always the floor: booting p2 works with an empty
  p3, and install repopulates it.

### Migration between hosts (offline, no cluster)

```bash
incus copy --refresh rpi5-8gb:<instance> rpi5-4gb:   # pre-copy while running
incus stop <instance>; incus move rpi5-8gb:<instance> rpi5-4gb:
incus config device add <instance> zigbee unix-char path=/dev/serial/by-id/<id>
```

USB passthrough devices never migrate with an instance; re-attach at the destination.

## Verification checklist (after first install)

1. `cat /proc/cmdline` -> console as configured, root on btrfs `/dev/nvme0n1p1`
2. U-Boot menu aggregates extlinux entries from both SD p2 and p3 (bootstd bootflow scan).
   Fallback: interrupt U-Boot and boot the partition explicitly; no re-flash required.
3. `reboot` -> root is pristine, `/persist` intact, SSH host keys stable
4. `incus storage show default`, `incus info --resources` (VM driver operational)
5. `incus launch <LXC>` and `incus launch <VM> --vm` both work (VM boot validates the 4K-page
   mainline kernel choice); snapshot + restore once

## Known risks

- U-Boot multi-partition extlinux menu behavior is the one upstream behavior we verify on-device
  (item 2 above); the fallback path never requires re-flashing.
- NVMe adapter/EEPROM quirks exist for some M.2 hats (nvmd/nixos-raspberrypi #117) - only relevant
  to the future NVMe-b path; the SD boot path is immune.
- Impermanence blind-spots: forgetting to persist a service's state is silent (state lost on
  reboot). Any new service gets reviewed against `pi5-common.nix`'s persist list.
- Power: 27 W USB-C PSU + active cooling required for incus-sustained load on either board.

## Future paths (documented, not built)

- NVMe-only boot once nixpkgs ships U-Boot 2026.10: add NVMe FAT to disko, EEPROM
  `BOOT_ORDER` includes NVMe, retire the SD from daily duty (keep as rescue disk).
- incus btrfs storage pool driver swap.
- WireGuard/tailscale, zigbee passthrough details, secondary hosts at scale - additive.
