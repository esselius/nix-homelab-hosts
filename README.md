# NixOS Raspberry Pi 5 incus VM-host pair (`rpi5-8gb`, `rpi5-4gb`)

Two standalone NixOS incus servers on Raspberry Pi 5 boards (8 GB and 4 GB), declared from this
repo, built from a macOS (Apple Silicon) host, installed via nixos-anywhere without kexec, root on
NVMe, ephemeral root state (impermanence), microSD carrying the bootloader.

## Hosts

| Host | Board | Role | incus workloads |
|------|-------|------|-----------------|
| `rpi5-8gb` | Pi 5 8 GB | primary | VMs (KVM/QEMU) + LXC containers |
| `rpi5-4gb` | Pi 5 4 GB | secondary | LXC containers only |
| `rpi5-bootstrap` | either | short-lived installer image, stock nixpkgs sd-image-aarch64.nix | none |

`rpi5-bootstrap` is not a permanent resident. It is flashed, used once to run `nixos-anywhere`
against the target disk, and then forgotten; if the SD card or its bootloader generation ever
breaks, the fix is to reflash this image again (2 minutes, NVMe untouched - see Playbooks).
An earlier design kept a persistent third "rescue" partition on every SD card so recovery could
happen without walking back to a Mac. It was dropped: in practice every real incident this project
hit still ended in a reflash, while the extra partition added real bugs (hand-rolled partition
math, boot-order ambiguity between two bootable partitions, double the surface area to debug).
The simple two-partition shape below is deliberately the same shape `nixpkgs`' own
`sd-image-aarch64.nix` produces.

## Architecture

Boot chain (both hosts, identical):

```
Pi 5 EEPROM (SPI) -> stock firmware (SD p1 FAT) -> u-boot.bin -> extlinux.conf (SD p2 ext4)
-> vendor kernel + initrd -> NVMe root (btrfs)
```

- No U-Boot fork, no EEPROM configuration, no ACPI/EDK2 detour.
- `hardware.raspberry-pi.firmware = { enable = true; uboot.enable = true; }` stages firmware,
  DTBs, overlays, `config.txt`, and `u-boot.bin` onto the FAT declaratively (nixos-hardware PR
  #1894). Without it a custom SD image fails exactly the two failure modes documented in
  nixos-hardware issue #1928 (missing Pi 5 DTBs, then "no kernel to load").
- `generic-extlinux-compatible` generations live on SD p2 and are rewritten on every
  `nixos-rebuild switch` **once the FAT/boot partitions are mounted** - see the bootloader-install
  caveat below, this does not happen automatically through `nixos-anywhere`.
- **Kernel: the `nixos-hardware` vendor default (`linux-rpi`), not mainline.** An earlier revision
  of this repo pinned `pkgs.linuxPackages_latest` (mainline, 7.2.9 at the time) for cache-hit and
  4K-page reasons. In practice that kernel/firmware-DTB pairing produced `rp1_driver` probe
  failures (`-22`/EINVAL) that killed USB *and* Ethernet (RP1 hosts both on the Pi 5), confirmed via
  `dmesg`. Reverting to the profile's vendor kernel (`linux-rpi`, currently `6.18.50`) fixed it
  immediately - this is the kernel/DTB pairing the firmware package actually ships for. The
  trade-off: uncached kernel builds on `nix flake update` (no public Hydra jobset yet, tracked by
  nixos-hardware #1777/#854), and 16K pages. Empirically, **incus VM guests (4K-page Debian 13
  cloud image) boot fine on this 16K host kernel** - the commonly cited 16K-host/4K-guest KVM
  incompatibility did not reproduce in testing on this board/kernel combination.
- `hardware.raspberry-pi.firmware.useGenerationDeviceTree = true` re-stages the FAT with the
  *booted generation's* device trees on every switch, instead of only the vendor firmware
  package's. Belt-and-suspenders alongside the vendor kernel choice.
- `nixpkgs.overlays` patches `makeModulesClosure` with `allowMissing = true` - the profile's
  `hardware.enableAllHardware = true` (inherited from the stock sd-image module) requests modules
  like `dw-hdmi` that the vendor kernel fork doesn't build; without this override the initrd build
  fails outright.

### Storage

microSD (flashed once per host via the bootstrap image; `/boot` is then owned and rewritten by the
main host config on every rebuild):

| Partition | FS | Mount | Notes |
|-----------|----|-------|-------|
| p1 | FAT32 | `/boot/firmware` | firmware, DTBs, overlays, `config.txt`, `u-boot.bin` |
| p2 | ext4, bootable | `/boot` | `extlinux.conf` + kernel/initrd per generation |

NVMe (the only disk disko / `nixos-anywhere` ever wipes):

| Subvol | Mount | Lifetime |
|--------|-------|----------|
| `@root` | `/` | rolled back to pristine at every boot (impermanence, btrfs recipe - no tmpfs, RAM matters on 4/8 GB) |
| `@nix` | `/nix` | persists |
| `@persist` | `/persist` | survives reboots: `machine-id`, SSH host keys, `/var/lib/nixos` (UID/GID maps), `/var/lib/incus`, `/var/log` + persistent journald, `/home`, `/root`, git copy of this flake |
| `@snapshots` | `/snapshots` | snapper-managed (nightly + pre-`nixos-rebuild` hook) |

### The bootloader-install caveat (read this before your first install)

`nixos-anywhere`'s install phase only auto-mounts filesystems **disko** declares - it has no flag
to also mount other filesystems (confirmed via `--help`; no such option exists). Since `disko` in
this repo only knows about the NVMe disk, the installer's bootloader step writes extlinux files
into a plain directory on the NVMe root (`@root/boot/...`) instead of onto the SD. The generation
boots once from that path, by luck, and then **impermanence wipes `@root` on the next boot**,
taking the bootloader files with it.

This means **every `nixos-anywhere` run must be followed by one manual step**: mount the installed
system and the SD boot partitions together in a chroot, then run that generation's
`switch-to-configuration boot` so the bootloader install actually targets the SD (commands in
Playbooks below). This has been exercised by hand several times this session; it is not yet wrapped
in a script - deliberately, until it's been run enough times unattended to trust blindly.

### Root-wipe mechanics (impermanence)

`boot.initrd.systemd.services.root-wipe` runs before `sysroot.mount`, deletes `@root`, recreates it
empty. Two non-obvious things had to be fixed empirically:

1. **systemd auto-creates nested subvolumes** under `/` on first boot (`@root/srv`,
   `@root/var/lib/portables`, `@root/var/lib/machines`, `@root/var/tmp`). A plain
   `btrfs subvolume delete /btrfs_tmp/@root` fails with "Directory not empty" because of these
   children - they must be deleted first.
2. **The initrd environment has no `awk`**, and its shell wrapper does not reliably support bash
   array syntax or process substitution (`< <(...)`) - a version using either of those *hung the
   whole boot* rather than failing cleanly. The working recipe parses `btrfs subvolume list`
   output with a POSIX `while read` loop against a temp file, no arrays, no process substitution.

### incus

- `virtualisation.incus`, `pkgs.incus-lts`, `ui.enable = true`.
- `networking.nftables.enable = true` (module assertion; iptables is unsupported).
- Preseed: `incusbr0` NAT bridge, `default` profile, `dir` storage pool sourced at
  `/persist/incus-pool` (**not** `/persist/var/lib/incus` - incusd seeds its own daemon state there
  before preseed runs, so that path is never empty when the pool-create step fires; the pool needs
  its own leaf). A `systemd.tmpfiles.rules` entry pre-creates that directory, since incus's preseed
  does not create pool source directories itself.
- The preseed unit is a one-shot that does **not** re-run automatically if its script changes under
  a `nixos-rebuild switch` (observed directly); if a preseed edit doesn't appear to take effect,
  `systemctl start incus-preseed` manually once.
- VM images are qcow2 raw on btrfs: CoW disabled (`chattr +C`) on VM disks.
- Documented v2 toggle: switch the pool driver to `btrfs` (CoW clones).

## Decisions ledger (why each piece)

| Decision | Value | Rationale |
|----------|-------|-----------|
| nixpkgs | `nixos-unstable`, pinned in `flake.lock` | stable 26.05 SD images lack Pi 5 boot files (nixpkgs PR #537862 is on unstable); pinning means updates only happen deliberately |
| Board support | `nixos-hardware.nixosModules.raspberry-pi-5` | upstream profile: extlinux + BCM2712 DTB filter + NVMe/PCIe/RP1 initrd + firmware staging options |
| Kernel | **vendor `linux-rpi` (profile default)** | mainline (`linuxPackages_latest`) produced `rp1_driver -22` against this firmware package's DTBs, killing USB+Ethernet; the vendor kernel is the pairing the firmware was actually built for. Trade-off documented above |
| Boot device | microSD, bootloader permanently on SD | U-Boot 2026.07 in nixpkgs cannot read boot files from NVMe; upstream NVMe boot landed for U-Boot 2026.10 and will land in nixpkgs later - at that point NVMe-only boot is a config-only change |
| SD layout | plain 2-partition (stock `sd-image-aarch64.nix`) | a 3-partition design with a persistent rescue OS was tried and reverted - see Hosts section |
| Filesystem | btrfs (checksums on write + scrubs; no third-party module ever constrains `nix flake update`) | the RAM lens made this the winner over ZFS for 8/4 GB boards |
| Install | `nixos-anywhere`, kexec skipped | `VARIANT_ID=installer` on the bootstrap image makes nixos-anywhere's `runKexec()` early-return; kexec on Pi 5 is flaky |
| Topology | standalone pair, no cluster | 2-member Cowsql/Raft clusters lose quorum on a single node update; container live migration is stop-and-move anyway for real workloads; offline `incus move` covers the need |

## Playbooks

### Install (once per host, from the Mac)

```bash
nix build .#images.rpi5-bootstrap
zstd -d ./result/sd-image/*.img.zst -o pi5-bootstrap.img
diskutil unmountDisk /dev/diskX   # macOS
sudo dd if=pi5-bootstrap.img of=/dev/rdiskX bs=4M status=progress conv=fsync

# boot the Pi (NVMe attached), then:
nix run github:nix-community/nixos-anywhere -- --flake .#rpi5-8gb root@<pi-ip>

# REQUIRED follow-up (see "bootloader-install caveat" above) - nixos-anywhere will have rebooted
# the Pi back into this same installer (the SD's boot partition is still empty); from there:
ssh root@<pi-ip> 'bash -s' <<'DANCE'
set -ex
mkdir -p /mb /mb/nix /mb/persist /mb/boot/firmware
mount -o subvol=@root /dev/nvme0n1p1 /mb
mount -o subvol=@nix /dev/nvme0n1p1 /mb/nix
mount -o subvol=@persist /dev/nvme0n1p1 /mb/persist
mount /dev/mmcblk0p2 /mb/boot
mount /dev/mmcblk0p1 /mb/boot/firmware
closure=$(ls /mb/nix/store/ | grep 'nixos-system-rpi5' | head -1)
nixos-enter --root /mb -- "/nix/store/$closure/bin/switch-to-configuration" boot
sync
umount /mb/boot/firmware /mb/boot /mb/persist /mb/nix /mb
DANCE
ssh root@<pi-ip> reboot
```

If the Mac build host misbehaves during install, pre-build the disko script + toplevel and pass
`--store-paths` (nixos-anywhere #18 pattern).

### Update + rollback

```bash
nix flake update          # deliberate bumps only
nixos-rebuild switch --flake .#rpi5-8gb --target-host root@<pi-ip>
```

Rollback after a bad update: choose the previous generation at the U-Boot prompt (extlinux menu, SD
p2). Root state is irrelevant (impermanence), so rollback is purely about kernel/generation
correctness.

### Recovery (pick the narrowest one that applies)

| Symptom | Fix | NVMe impact |
|---|---|---|
| SD card / bootloader broken, NVMe fine | the mount + `nixos-enter` dance above, no `nixos-anywhere` | none |
| SD card physically dead or unknown state | reflash `images.rpi5-bootstrap` | none |
| Want a genuinely clean slate | reflash + re-run `nixos-anywhere` | **wiped** (disko's default mode destroys + recreates) |

### Migration between hosts (offline, no cluster)

```bash
incus copy --refresh rpi5-8gb:<instance> rpi5-4gb:   # pre-copy while running
incus stop <instance>; incus move rpi5-8gb:<instance> rpi5-4gb:
incus config device add <instance> zigbee unix-char path=/dev/serial/by-id/<id>
```

USB passthrough devices never migrate with an instance; re-attach at the destination.

## Verification status

Confirmed working on real hardware (8 GB board):

- Vendor kernel boots, RP1 (USB + Ethernet) alive, NVMe enumerated on PCIe
- Full impermanence mount tree (`@root`, `@nix`, `@persist` + binds, `@snapshots`)
- `nixos-rebuild switch` from macOS, including the declarative FAT refresh (stale DTBs pruned)
- incus: `incusbr0` bridge + NAT, `default` dir pool, LXC container with working DHCP + egress,
  **VM guest (Debian 13 cloud image, 4K-page) booted and reachable via incus-agent** on the 16K-page
  vendor kernel host, snapshot create/restore
- The mount + `nixos-enter` dance (mount NVMe subvolumes + SD partitions,
  `switch-to-configuration boot`) successfully populates the SD boot partition after an install -
  exercised by hand several times, not yet scripted

Still to re-verify after the partition-layout simplification: the full wipe-cycle test (marker file
on `/` disappears after reboot, `/persist` marker survives) - the POSIX-safe `root-wipe` rewrite was
in place but the test run was interrupted before the result was captured.

## Known risks

- Impermanence blind-spots: forgetting to persist a service's state is silent (state lost on
  reboot). Any new service gets reviewed against `pi5-common.nix`'s persist list.
- NVMe adapter/EEPROM quirks exist for some M.2 hats (nvmd/nixos-raspberrypi #117) - only relevant
  to a future NVMe-boot path; irrelevant to the current SD-boot design.
- Power: 27 W USB-C PSU + active cooling required for incus-sustained load on either board.
- Vendor kernel builds are uncached (no public Hydra jobset for `linux-rpi` yet); a `nix flake
  update` that bumps nixos-hardware can mean a multi-hour local kernel build.

## Future paths (documented, not built)

- NVMe-only boot once nixpkgs ships U-Boot 2026.10: add NVMe FAT to disko, EEPROM `BOOT_ORDER`
  includes NVMe, retire the SD from daily duty entirely.
- incus btrfs storage pool driver swap.
- Re-evaluate mainline kernel once nixos-hardware/nixpkgs settle the Pi 5 DTB story further
  (tracked via nixos-hardware issue #78).
- WireGuard/tailscale, zigbee passthrough details, secondary hosts at scale - additive.
