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
- `nixpkgs.overlays` patches `makeModulesClosure` with `allowMissing = true` - the
  `raspberry-pi-5` profile's initrd wants modules (e.g. `tpm-crb`) that the vendor kernel fork
  doesn't build; without this override the initrd build fails outright on the first missing module.
  (Not an effect of `hardware.enableAllHardware`, which is `false` in this config - verified via
  `nix eval` and by confirming the build genuinely fails without the overlay.)

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

### The bootloader-install caveat (historical - now fixed, see disko-sd.nix)

`nixos-anywhere`'s install phase only auto-mounts filesystems **disko** declares - it has no flag
to also mount other filesystems (confirmed via `--help`; no such option exists). Originally `disko`
in this repo only knew about the NVMe disk, so the installer's bootloader step wrote extlinux files
into a plain directory on the NVMe root (`@root/boot/...`) instead of onto the SD. The generation
booted once from that path, by luck, and then **impermanence wiped `@root` on the next boot**,
taking the bootloader files with it - requiring a manual chroot + `switch-to-configuration boot`
dance after every install.

**Fixed**: `disko-sd.nix` now describes the SD card's existing partitions (FAT `FIRMWARE` + ext4
`NIXOS_BOOT`) via disko's legacy `table` type (`format = "msdos"`, since the SD uses MBR not GPT).
This is declared purely for `disko`'s **mount** mode - running
`nixos-anywhere --flake .#rpi5-8gb --disko-mode mount <host>` now mounts NVMe *and* the SD card
together automatically, so the bootloader-install step succeeds on its own. Verified end-to-end on
real hardware: no manual dance needed anymore for either a soft reset (SD reflash, NVMe untouched)
or deploying onto an existing NVMe install. See Playbooks below.

`disko-sd.nix`'s `table`/`msdos` partitions must **never** be used with disko's default `disko` or
`format` modes - only `mount`. (disko's `_create` step for the `table` type checks `blkid` and
skips re-partitioning if a table already exists, but the *nested filesystem* content's own
`_create` would still unconditionally run `mkfs` - which would destroy the SD's bootstrap content.
This repo's hosts never run disko in anything but `mount` mode against the SD; only the NVMe disk
is ever destroyed/recreated, and only when explicitly requested.)

### Root-wipe mechanics (impermanence)

`boot.initrd.systemd.services.root-wipe` runs before `sysroot.mount`, deletes `@root`, recreates it
empty. Several non-obvious things had to be fixed empirically:

1. **systemd auto-creates nested subvolumes** under `/` on first boot (`@root/srv`,
   `@root/var/lib/portables`, `@root/var/lib/machines`, `@root/tmp`, `@root/var/tmp`). A plain
   `btrfs subvolume delete /btrfs_tmp/@root` fails with "Directory not empty" because of these
   children - they must be deleted first.
2. **The initrd environment has no `awk`**, and its shell wrapper does not reliably support bash
   array syntax or process substitution (`< <(...)`) - a version using either of those *hung the
   whole boot* rather than failing cleanly. The working recipe parses `btrfs subvolume list`
   output with a POSIX `while read` loop against a temp file, no arrays, no process substitution.
3. **`serviceConfig.RemainAfterExit = true` is required.** Without it, systemd started
   `root-wipe.service` *twice* per boot (confirmed via `journalctl`: two separate "Starting Reset
   @root..." lines, ~1.5s apart, same boot) - two near-simultaneous `mount` + btrfs-subvolume
   delete/create passes against the same NVMe device during fragile early-initrd timing reliably
   hung the entire boot with zero further console output. This was the actual cause of every boot
   hang encountered during initial bring-up (initially, and wrongly, suspected to be async discard,
   DTB generation, device-unit ordering, or a vendor-kernel/NVMe hardware issue - all ruled out by
   direct testing before the real cause was found). Diagnosed safely by replaying the exact
   mount/delete/create sequence against a disposable test subvolume (shaped identically to a real
   `@root`, including the same 5 systemd-created nested subvolumes) via a temporary diagnostic
   initrd unit, from an already-booted warm system - reproduced the double-start and the fix there,
   with zero reboot-cycle risk, before touching the real `root-wipe` service again.
4. `neededForBoot` on `/boot` and `/boot/firmware` is **not** needed and actively harmful: U-Boot
   has already loaded the kernel+initrd into memory before Linux starts, so initrd never needs
   those SD-card mounts. Marking them `neededForBoot = true` forces initrd to probe the SD/MMC
   controller concurrently with NVMe PCIe enumeration, which contributed to early hangs before the
   `RemainAfterExit` issue was found.

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

`root@<pi-ip>` below always refers to the bootstrap installer (which allows root SSH - required by
`nixos-anywhere` itself). Once a main system (`rpi5-8gb`/`rpi5-4gb`) is actually running, root SSH
is disabled there - use `admin@<pi-ip>` + `--sudo` instead (see "Update + rollback" below).

**Why root SSH can't be disabled on the bootstrap installer too**: tried this (disable root,
`admin@` + passwordless sudo, same as the main systems) and it fails specifically for
`nixos-anywhere`, for a hardcoded reason in its own source
(`libexec/nixos-anywhere/nixos-anywhere.sh`):

```bash
# Installation will fail if non-root user is used for installer.
# Switch to root user by copying authorized_keys.
if [[ ${isInstaller} == "y" ]] && [[ ${sshUser} != "root" ]]; then
  runSsh "${maybeSudo} mkdir -p /root/.ssh; ${maybeSudo} cp ~/.ssh/authorized_keys /root/.ssh || true"
  sshConnection="root@${sshHost}"
fi
```

For any target with `system.nixos.variant_id = "installer"` (which this bootstrap image sets,
deliberately, to make `nixos-anywhere`'s `runKexec()` early-return and skip kexec entirely - Pi 5
kexec is flaky; this isn't just our own finding, it matches other reports of full homelab NixOS
migrations hitting the same Pi 5 limitation and choosing the identical SD-image workaround), it
unconditionally switches to `root@<host>` for the rest of the install, regardless of what user was
originally targeted. There's no flag to override this. So: skipping kexec (deliberate, for Pi 5
stability) and disabling root SSH on the installer are mutually exclusive; this repo keeps kexec
skipped and root SSH enabled, contained to a throwaway image that gets reflashed before every use.

### Install / hard reset (wipes NVMe, from the Mac)

```bash
nix build .#images.rpi5-bootstrap
zstd -d ./result/sd-image/*.img.zst -o pi5-bootstrap.img
diskutil unmountDisk /dev/diskX   # macOS
sudo dd if=pi5-bootstrap.img of=/dev/rdiskX bs=4M status=progress conv=fsync

# boot the Pi (NVMe attached), then:
nix run github:nix-community/nixos-anywhere -- --flake .#rpi5-8gb root@<pi-ip>
```

That's it - no manual follow-up dance needed anymore (see "bootloader-install caveat" above:
`disko-sd.nix` lets `nixos-anywhere` mount the SD card's existing partitions automatically, so the
bootloader install step succeeds in the same run and the Pi reboots straight into the real system).

If the Mac build host misbehaves during install, pre-build the disko script + toplevel and pass
`--store-paths` (nixos-anywhere #18 pattern).

### Soft reset (SD reflash, reuse existing NVMe content - e.g. after a wedged SD/bootloader)

```bash
# reflash the bootstrap image as above, boot the Pi, then:
nix run github:nix-community/nixos-anywhere -- --flake .#rpi5-8gb --disko-mode mount root@<pi-ip>
```

`--disko-mode mount` mounts the *existing* NVMe partitions and the SD card without destroying
anything, then runs the normal install + bootloader-install phases against them. Verified
end-to-end on real hardware: NVMe content (incus storage pool, containers, VMs) survives
untouched, bootloader install succeeds automatically, Pi reboots straight into the working system.
This replaces the old manual chroot + `nixos-enter` dance entirely for this case too.

### Update + rollback

Root SSH login is disabled on the main systems (`PermitRootLogin = "no"`, `modules/ssh-access.nix`)
- day-to-day access is via `admin` (passwordless `sudo`):

```bash
nix flake update          # deliberate bumps only
nixos-rebuild switch --flake .#rpi5-8gb --target-host admin@<pi-ip> --sudo
```

Rollback after a bad update: choose the previous generation at the U-Boot prompt (extlinux menu, SD
p2). Root state is irrelevant (impermanence), so rollback is purely about kernel/generation
correctness.

### Recovery (pick the narrowest one that applies)

| Symptom | Fix | NVMe impact |
|---|---|---|
| SD card / bootloader broken, NVMe fine | reflash `images.rpi5-bootstrap`, then **soft reset** above | none |
| SD card physically dead or unknown state | reflash `images.rpi5-bootstrap`, then **soft reset** above | none |
| Want a genuinely clean slate | reflash, then **hard reset** above (default `nixos-anywhere`, no `--disko-mode`) | **wiped** (disko's default mode destroys + recreates) |

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
- Full impermanence wipe-cycle test, post partition-layout-simplification and post
  `root-wipe` `RemainAfterExit` fix: marker file on `/` correctly disappears after reboot,
  `/persist` marker correctly survives, two consecutive clean reboots, zero failed units each time
- `nixos-anywhere --disko-mode mount` (soft reset, `disko-sd.nix`): mounts NVMe + SD together
  automatically, bootloader install succeeds with zero manual steps, verified end-to-end on real
  hardware including a full reboot into the working system afterward - the old manual chroot +
  `nixos-enter` dance is no longer required for either install path

## Known risks

- Impermanence blind-spots: forgetting to persist a service's state is silent (state lost on
  reboot). Any new service gets reviewed against `modules/impermanence-persist.nix`'s persist list.
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
