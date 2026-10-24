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
| `@persist` | `/persist` | survives reboots: `machine-id`, SSH host keys, `/var/lib/nixos` (UID/GID maps), `/var/lib/incus`, `/var/lib/unbound` (AXFR secondary zonefile), `/var/log` + persistent journald. Deliberately **not** persisted: `/etc/nixos` + `/etc/nix` (declarative, and a flake checkout doesn't belong in `/etc/nixos`), `/root`, `/home` |
| `@snapshots` | `/snapshots` | snapper's snapshot store for `/persist` (also bind-mounted at `/persist/.snapshots` - see note) |

snapper: `services.snapper.configs."persist"` snapshots `/persist` on a nightly timeline
(`TIMELINE_*`). snapper always stores snapshots in `<SUBVOLUME>/.snapshots` and requires that path to
be a subvolume (else snapshots nest inside `@persist` and recurse), so `modules/storage.nix`
bind-mounts the dedicated `@snapshots` subvolume at `/persist/.snapshots` - leaving `/snapshots` as
the clean top-level path. Without it, `snapper-timeline` fails on a fresh install.

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

Config lives in `modules/incus/`, split by concern. Hosts tune only
`local.incus.{network,guest,tls,dnsAddress,metrics}`; each file contributes to an internal
`local.incus.spec`, and `preseed.nix` is the single place that assembles the freeform
`virtualisation.incus.preseed` value (this avoids depending on how the freeform submodule merges
list attributes defined across separate modules). Settings that must be applied idempotently at
runtime (`core.dns_address`, `core.metrics_*`, the network DNS zone) live in `runtime.nix` instead,
so a deploy applies them without restarting incus. Host networking for the VPN lives outside this
directory, in `modules/wireguard.nix`, tuned via `local.wireguard` - see "WireGuard VPN" below.
Site-wide values shared by both hosts (VPN server identity, DNS zone, bootstrap records, TLS/monitoring
toggles) live in `modules/site.nix` and are wired in with `mkDefault`.

| File | Concern |
|------|---------|
| `default.nix` | enable, `pkgs.incus-lts`, UI, `incus-admin` group; declares the `local.incus.spec` interface |
| `network.nix` | managed bridge, explicit subnets, optional macvlan profile, firewall |
| `vpn-bridge.nix` | optional `incusbr-vpn` bridge + `vpn` profile, uplink-scoped egress masquerade |
| `storage.nix` | btrfs `default` pool at `/persist/incus-pool` |
| `profiles.nix` | `default`/`container`/`vm` profiles from a per-host RAM budget |
| `tls.nix` | Let's Encrypt server cert (GoDaddy DNS-01) + trusted client certs |
| `runtime.nix` | idempotent `incus config set` for DNS + metrics (no incus restart needed) |
| `preseed.nix` | assembles `virtualisation.incus.preseed` |

- `virtualisation.incus`, `pkgs.incus-lts`, `ui.enable = true`.
- `networking.nftables.enable = true` (module assertion; iptables is unsupported).
- Storage pool sourced at `/persist/incus-pool` (**not** `/persist/var/lib/incus` - incusd seeds its
  own daemon state there before preseed runs, so that path is never empty when the pool-create step
  fires; the pool needs its own leaf). No `systemd.tmpfiles.rules` entry pre-creates that directory
  (used to, when the pool was `dir`-backed) - the `btrfs` driver creates its own subvolume there on
  first preseed run, and a pre-existing plain directory at that exact path makes `btrfs subvolume
  create` fail with "File exists".
- The preseed unit is a one-shot that does **not** re-run automatically if only its script changes
  under a `nixos-rebuild switch` (observed directly; `RestartIfChanged=false`). It *does* re-run on
  every `incus.service` restart/reboot (`PartOf=incus.service`); if a preseed edit doesn't appear to
  take effect, `systemctl restart incus-preseed` once (plain `start` is a no-op while it is already
  active). Also does not change an **existing** pool's driver
  in place (`Error: Storage pool "default" is of type "dir" instead of "btrfs"`) - migrating a live
  pool between drivers means deleting the old one first (`incus storage delete default`, after
  removing whatever profile device references it), then letting preseed recreate it fresh.
- Storage pool driver is `btrfs` (the pool lives on the `@persist` btrfs filesystem): container
  rootfs volumes are genuine CoW subvolumes (`btrfs subvolume show` shows a real `Parent UUID`) and
  `incus snapshot create` works. VM images are qcow2 raw on btrfs with CoW disabled (`chattr +C`).

#### Networking

- Managed bridge `incusbr0`, NAT on both families, with **explicit subnets** rather than `auto`:
  `rpi5-8gb` = `10.42.0.1/24` + `fd42:0::1/64`, `rpi5-4gb` = `10.42.1.1/24` + `fd42:1::1/64`. Keeps
  addressing predictable and non-colliding if the pair is ever routed.
- A second, NAT-less bridge `incusbr-vpn` carries instances that must be reachable from other
  WireGuard VPN clients - see "WireGuard VPN" below. Its network address is derived from
  `local.incus.network.vpn.ipv4` (never configured separately), so the bridge and the egress
  masquerade cannot drift apart.
- `incusbr0` is in `networking.firewall.trustedInterfaces`; the API/UI port is opened from
  `local.incus.httpsPort` (default `8443`), the same option that sets `core.https_address`.
- Optional `local.incus.network.macvlan` emits a `lan` profile (`nictype = macvlan`, `parent =
  end0`) for instances that should be first-class LAN citizens (own MAC, router DHCP). Apply with
  `incus launch ... -p default -p lan`; the later profile overrides `default`'s bridged `eth0`
  NIC device (profiles merge by device name). Caveat: the host cannot reach a macvlan guest
  directly. Here `parent` is the *host* uplink, which is `end0` on the Pi 5 vendor kernel/DTB
  (`wld0` is wireless) - **not** `eth0`; confirm per board.

#### Profiles & resource limits

- `default` carries connectivity + storage only (NIC + root disk), no limits.
- Limits are separate, limit-only profiles applied alongside `default`: `container` (50% of the
  host budget, `limits.memory.enforce = hard` - without hard enforcement a runaway container can
  still OOM the host) and `vm` (75%), both with `limits.cpu` = core count. `vm` is only emitted when
  `local.incus.guest.vms = true` (the 4 GB board is containers-only).
- These are **per-instance ceilings, not reservations**: running a VM and a container together can
  exceed `local.incus.guest.memoryMiB` by design (on `rpi5-8gb`, 4608 + 3072 MiB against a 6144 MiB
  budget). Host budgets (`local.incus.guest.memoryMiB`): `rpi5-8gb` 6144 (~2 GB left for host +
  zram), `rpi5-4gb` 2560.

#### TLS / remote access

Motivation: incusd's auto-generated cert is self-signed with SANs only for the hostname + loopback,
so a browser warns and connecting via LAN IP is a name mismatch regardless of trust.

- **Server cert: Let's Encrypt, DNS-01 via GoDaddy**, using incus-native ACME
  (`acme.domain` / `email` / `challenge = DNS-01` / `provider = godaddy`). DNS-01 needs no inbound
  reachability and no name resolution on the Pi; the GoDaddy API key/secret live in a sops secret
  (`godaddy_acme`) injected as `systemd.services.incus.serviceConfig.EnvironmentFile`. Clients still
  need the name to resolve (A record) to connect.
- **Client auth: no mTLS and no IdP.** Client certs (`local.incus.tls.clientCertificates`) are
  trusted idempotently by an `incus-trust-clients` oneshot, not via the preseed `certificates` list
  (which is create-only and errors "already in trust store" on the re-runs that happen whenever
  `incus.service` restarts) - no CA, no join token, no OIDC broker. (Considered and rejected - see
  decisions ledger.)
- Names: `rpi5-8gb.x.esselius.dev` / `rpi5-4gb.x.esselius.dev` (`local.incus.tls.serverName`).
- `acme.enable` defaults to `true` for both main hosts in `modules/site.nix` (a host can override it).
  A host cannot decrypt the GoDaddy secret - and therefore cannot issue its cert - until its SSH
  host key is an age recipient (see Playbooks > secrets); until then, set
  `local.incus.tls.acme.enable = false` on a new host to avoid a failing sops unit at boot.

#### Secrets (sops)

- Recipients live in `.sops.yaml`: each Pi's SSH host key (`ssh-keyscan <ip> | ssh-to-age`) plus the
  Mac's on-disk SSH key. sops 3.13.3 does **not** read `~/.ssh/id_ed25519` directly (its SSH
  fallback is `~/.ssh/id_rsa` only), so the devshell exports
  `SOPS_AGE_KEY_CMD="ssh-to-age -private-key -i ~/.ssh/id_ed25519"`, deriving a native age identity
  from the same key. Passphrase-protected SSH keys are unsupported by `agessh`.
- lego's GoDaddy DNS-01 propagation check queries recursive resolvers, which can serve a *previous*
  challenge TXT for the full record TTL (~600s) even after GoDaddy's authoritative NS has the new
  value, causing a timeout. The daemon sets `LEGO_DNS_PROPAGATION_DISABLE_RNS=true` (a lego env flag
  incusd's children inherit) so only authoritative NS are checked. `GODADDY_PROPAGATION_TIMEOUT=300`
  (lego's own default) is pinned in the daemon env for visibility, not in the sops secret.
- `sops-nix` with `age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ]` and
  `useSystemdActivation = true`. The decryption unit runs before `sysinit.target`, so
  `/run/secrets/godaddy_acme` always exists before `incus.service` starts.
- The `godaddy_acme` value is the lego environment file contents: `GODADDY_API_KEY=...` /
  `GODADDY_API_SECRET=...`.
- `wg_private_key` is `rpi5-8gb`'s base64 WireGuard private key and `wg_private_key_4gb` is
  `rpi5-4gb`'s (selected per host with `local.wireguard.privateKeySecret`). Their public keys
  (`wg pubkey`) must be configured on the router - see "WireGuard VPN".

### WireGuard VPN (ASUS router server, Pis as split-tunnel nodes)

The router is an ASUS running its own WireGuard VPN server (VPN Fusion); each Pi joins as a
**split-tunnel node**, not a road-warrior client. `modules/wireguard.nix` (host-tuned via
`local.wireguard`) brings up `wg0` with the Pi's
tunnel address, the router as a peer, `persistentKeepalive = 25` (so the server can always push
packets back through the Pi's home NAT), and `allowedIPs = 10.6.0.0/24` - the VPN subnet only.
Deliberately *not* `0.0.0.0/0`: a default route via `wg0` would drag all of the host's and its
instances' traffic through the router, whereas the split tunnel still reaches every VPN client and
lets instance reply traffic return to them. Each Pi also lists the other as a direct peer (see
below). The private keys are the sops secrets `wg_private_key` (`rpi5-8gb`) and
`wg_private_key_4gb` (`rpi5-4gb`); `wg0` is a firewall-trusted interface and
`net.ipv4.ip_forward` is enabled.

#### Host resolver for VPN clients

`modules/dns.nix` runs Unbound on the host and listens on the host's **WireGuard** address
(`10.6.0.3` on `rpi5-8gb`, `10.6.0.5` on `rpi5-4gb`, plus loopback), not on `incusbr-vpn`. VPN
clients use that stable address as their resolver. This deliberately removes Incus from the DNS
data path: if Incus or `incusbr-vpn` does not start, the host resolver still serves the internet and
cached internal records.

On `rpi5-8gb`, Unbound is the authoritative secondary for `int.esselius.dev`, transferring the zone
from the local Incus built-in DNS (`127.0.0.1:1053`) and persisting it in a zonefile under
`/var/lib/unbound` (which is on `/persist`, so the cached zone survives reboots even if Incus is
down). Incus serves only AXFR; Unbound is the queryable resolver. On `rpi5-4gb` the zone records live
on `rpi5-8gb`, so
its Unbound forwards `int.esselius.dev` to `10.6.0.3` over the direct peer instead of transferring a
copy. Everything outside the zone is recursively resolved. Static `local-data` keeps `cache.int`,
`monitoring.int`, and the `_mqtt._tcp` SRV record available even when Incus or the zone transfer is
unavailable. The host's own `systemd-resolved` routes only `~int.esselius.dev` to `127.0.0.1`; all
other lookups keep using the normal per-link resolvers. LLMNR and mDNS are disabled for the same
reason as before: unanswered reverse lookups add ~10 seconds.

`local.dns.listenAddresses` defaults to loopback plus the host's `local.wireguard.address` (the
literal `10.6.0.3`/`10.6.0.5`), so it cannot drift from the tunnel; override it only to add more
listeners. Unbound is ordered after `wireguard-wg0.service` but has no dependency on
`incus.service`. WireGuard client configs must use that address as their DNS (`rpi5-8gb`:
`DNS = 10.6.0.3`; `rpi5-4gb`: `DNS = 10.6.0.5`).

#### Direct peers (bypass the router)

By default each host's only peer is the router, so VPN traffic between two hosts (and between an
instance and a client) hairpins through the ASUS WireGuard server: it is decrypted and re-encrypted
there, and measured ~225 Mbit/s. `local.wireguard.extraPeers` (with a fixed `listenPort`, so the host
is dialable) adds another host as a directly-dialed peer. The peer's VPN `/32` is more specific than
the router peer's `vpnSubnet`, so WireGuard's cryptokey routing sends that address directly; the
router peer stays for the rest of the subnet. `allowedIPsAsRoutes` adds the matching route, and the
module opens the UDP `listenPort` inbound (a direct peer dials in from outside `wg0`).

Both ends must list each other - it is a plain public-key swap (get a host's with
`wg show wg0 public-key`; public keys are safe to commit, private keys stay in sops). Giving the
direct peer the incus subnets (`10.42.0.0/24`, `10.43.0.0/24`) in its AllowedIPs on the client side
also makes instance -> client traffic take the direct path, since the host forwards for its instances
and the route already points at the direct peer; instance source IPs still survive (the VPN bridge is
`nat = false`, see below).

Measured on `rpi5-8gb` <-> the 4 GB board (then named adama) over the gigabit LAN: ~630 Mbit/s
single-stream and ~900 Mbit/s
aggregate with `iperf3 -P 4` (~line rate), versus ~225 Mbit/s when it hairpinned through the router.

The two Pis are direct peers too: `rpi5-8gb` listens on `51820`, `rpi5-4gb` on `51821`, and each
lists the other's `/32`. The peer also carries the cross-host instance subnets: `rpi5-4gb` routes
`10.42.0.0/24` (8gb's default bridge) and `10.43.0.0/24` (8gb's VPN bridge) to `rpi5-8gb`, and
`rpi5-8gb` routes `10.42.1.0/24` (4gb's default bridge) and `10.43.1.0/24` (4gb's VPN bridge)
back. DNS forwarding, monitoring, and
cross-host instance traffic therefore take the LAN path and keep working when the router peer is
absent. The default bridges keep Incus's NAT, so traffic between `incusbr0` instances on different
hosts is masqueraded to the source host's WireGuard address (`10.6.0.3`/`10.6.0.5`); instances that
need their real source IP across hosts belong on a VPN bridge.

#### VPN-reachable instances

A separate managed bridge `incusbr-vpn` (IPv4-only) carries instances that other VPN clients must
reach. Each host has its own: `10.43.0.1/24` on `rpi5-8gb`, `10.43.1.1/24` on `rpi5-4gb`. It is
applied with the `vpn` profile, stacking on `default` exactly like `lan`
(`incus launch ... -p default -p vpn`), which overrides `default`'s bridged `eth0` onto the VPN
bridge; `incusbr0`/`default` are unchanged for non-exposed workloads. The VPN bridge is IPv4-only
(`ipv6.address = "none"` and the masquerade table is family `ip`), so IPv6 is out of scope until
someone adds it deliberately.

The bridge is created with **`ipv4.nat = false`**, which is the non-obvious part. An incus bridge
with NAT masquerades instance traffic leaving via *any* non-bridge interface - including `wg0` - so
instance source IPs would be rewritten on the VPN path and inbound VPN-client -> instance
connections would break (the incus docs confirm NAT preserves source addresses only *between
managed bridges*). With NAT off, a host nftables rule supplies internet egress scoped to the uplink
only:

```
ip saddr <host-vpn-subnet> oifname "end0" masquerade   # 10.43.0.0/24 or 10.43.1.0/24
```

so the VPN path keeps real instance source IPs while instances still reach the internet. The uplink
is `end0` on the Pi 5 vendor kernel/DTB (there is no `eth0`); if `local.incus.network.vpn.uplink`
does not match the real uplink the rule never matches and VPN-bridge instances lose internet egress
(they can still reach each other and the host).

**Required router-side config (ASUS WireGuard VPN server)** - outside this repo, and constrained to
what the ASUS WebUI actually exposes. The Pi's profile is set up as ASUS's site-to-site **scenario 3
("two-way communication")** (ASUS FAQ 1048281). In **VPN > VPN Server > WireGuard VPN**, open the
profile created for this host and set:

- **Access intranet**: Enable.
- **Allow IPs (Server)**: `<pi-wg-address>/32, <pi-default-subnet>, <pi-vpn-subnet>` - for
  `rpi5-8gb`, `10.6.0.3/32, 10.42.0.0/24, 10.43.0.0/24`; for `rpi5-4gb`,
  `10.6.0.5/32, 10.42.1.0/24, 10.43.1.0/24`. The ASUS default is just the peer `/32`; adding the
  incus subnets is the same edit the ASUS guide makes when it appends the client LAN
  (`10.6.0.2/32,192.168.100.0/24`). The server needs them to reach instances *and* to accept their
  return packets. Keep these **per peer and specific**: a client can use the aggregate
  `AllowedIPs = 10.6.0.0/24, 10.42.0.0/15`, but a `/15` on a router peer swallows the other host's
  `10.43.0.0/24` and breaks VPN access to it. **This is the edit that matters.**
- **Allow IPs (Client)**: keep the default `0.0.0.0/0`, which already routes `10.43.0.0/24` into the
  tunnel for every exported client profile. The ASUS UI exposes only this **one global**
  client-AllowedIPs field (no per-client split tunnel), so don't narrow it.
- **Enable NAT**: the default (enabled) is fine - the client -> instance path is routed straight into
  the tunnel, not NATed through the router. (Disabling it, as scenario 3 does, would let instances
  see the client's real WG address instead of the router's, but also stops clients tunnelling their
  internet through the router - choose per need.)

Settings the ASUS UI does **not** expose - and this design does not need - are a per-peer server
AllowedIPs beyond **Allow IPs (Server)**, the server's own tunnel subnet, MTU, or per-peer
forwarding toggles. A pre-shared key is optional under **Advanced Settings** (off by default; this
repo configures none - if you enable it, the exported `PresharedKey` must also be added to the Pi's
peer).

Without the **Allow IPs (Server)** entry a VPN client reaches the Pi's wg address but not its
instances.

If the firmware in use doesn't actually expose **Allow IPs (Server)** for editing, the fallback is
to attach the instances to the router's LAN instead (the existing `lan` macvlan profile) with
**Access intranet** enabled - VPN clients already reach the router's LAN - trading the dedicated
subnet and host-to-guest reachability for LAN DHCP addresses.

#### Verification checklist

1. Egress: `incus exec <vpn-instance> -- ping -c1 1.1.1.1` (needs `vpn.uplink` = the real uplink).
2. Router route: from a VPN client, `ping <vpn-instance-10.43.x.y>` (needs the router peer +
   client `AllowedIPs` above). When it fails, the Pi's own `10.6.0.3` still pings.
3. Same-bridge L2: `incus exec <vpn-instance> -- ping -c1 <another-vpn-instance>`.
4. `incusbr-vpn` reports `DOWN` while it has zero members (a managed bridge with no carrier); it
   comes up and serves DHCP once an instance attaches - confirm via `incus network list`.

Both Pis are wired up:

| Host | Tunnel address | Public key (`wg pubkey`) | Direct listen |
|------|----------------|--------------------------|---------------|
| `rpi5-8gb` | `10.6.0.3/32` | `NmlbH35CycjE1thGKwfU4pbYDCevMg+ui+jr9PiK9UM=` | `51820` |
| `rpi5-4gb` | `10.6.0.5/32` | `9MuNcL6y5nT0F2EQSI42mJ01BTEnhSRpc5sPZyKBEFU=` | `51821` |

Both router peers are configured with their host's subnets (addresses pinned by router DHCP
reservations). A VPN client with `AllowedIPs = 10.6.0.0/24, 10.42.0.0/15` reaches both WG
addresses, both resolvers, both default bridges, and both VPN bridges. Cross-host instance routing
is wired over the direct peer (`10.42.0.0/24` <-> `10.42.1.0/24` and `10.43.0.0/24` <->
`10.43.1.0/24`); the default `incusbr0` bridges NAT cross-host traffic to the source host's WG
address, while VPN bridges preserve it.

### Monitoring (Grafana Alloy)

`modules/monitoring-agent.nix` (opt-in via `local.monitoringAgent`; enabled on both Pis) runs
`services.alloy` and ships node metrics and the systemd journal to the monitoring workload on the VPN
bridge: Prometheus remote-write to `monitoring.int.esselius.dev:8428` (VictoriaMetrics) and Loki push
to `:3100`. The endpoints resolve through the `int.esselius.dev` split DNS above, so the module is
outbound-only - no firewall or DNS changes on the host. A `prometheus.relabel` stamps
`host=<hostname>` on every series, and the journal source labels `host` / `job=systemd-journal`. The
NixOS `alloy` module runs the service as the `alloy` user in the `systemd-journal` group and reads
`/etc/alloy/config.alloy`, which this module owns via `environment.etc`.

It also scrapes Incus's per-instance metrics (`services.alloy` job `incus`,
`local.monitoringAgent.scrapeIncus`; asking for the scrape enables `local.incus.metrics` by default).
`modules/incus/runtime.nix` exposes Incus's `/1.0/metrics` on a loopback-only listener
(`core.metrics_address = 127.0.0.1:9100`, `core.metrics_authentication = false`). That endpoint is
HTTPS with Incus's own certificate, so the scrape skips TLS verification and never leaves the host -
no firewall hole and no metrics client cert. The listener settings are applied with
`incus config set` by the `incus-runtime-config` oneshot, which re-runs on every `incus.service`
start and on each deploy that changes it - no manual incus restart needed. (It only sets keys; to
remove one, use `incus config unset`.)

Unbound and WireGuard exporters (`modules/dns.nix`, `modules/wireguard.nix`) run loopback-only and
are scraped by the same agent (`job=unbound`, `job=wireguard`), adding query/cache/rcode and peer
handshake/transfer series to the host dashboards.

Requires a `monitoring` record in the network zone (the workload repo) pointing at the monitoring
instance; until then the DNS name will not resolve.

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
| TLS server cert | Let's Encrypt, DNS-01 via GoDaddy | publicly trusted (no browser warning, no keychain import), no inbound `:80`, no CA to run or rotate; GoDaddy creds held in sops |
| Internal TLS trust | vendored Esselius root CA (`modules/pki.nix`) | Attic serves a step-ca certificate, so the hosts need the root in their bundle; this is the same public certificate `konfig` trusts, and a root rotation replaces one file |
| Client auth | incus client cert trusted by an idempotent `incus-trust-clients` oneshot | avoids running a CA for mTLS and avoids an OIDC broker; `step-ca`/PKI and GitHub-via-Dex were both overkill for two hosts, and kanidm can't do the device grant incus requires. The preseed `certificates` list is create-only and errors on incus restarts, so it is not used |
| Bridge addressing | explicit per-host subnets | predictable and non-colliding vs `auto`; easy to firewall. The VPN bridge's network address is derived from its `ipv4` CIDR so the masquerade can never disagree with it |
| Guest memory budget | per-host (6 GiB / 2.5 GiB), used as a basis for **per-instance caps** | leaves headroom for host + zram on the 8/4 GB boards; the `container`/`vm` limits are ceilings, not reservations, so one of each can deliberately exceed the budget |
| Bootstrap ZFS | disabled (`boot.supportedFilesystems.zfs = false`) | the upstream sd-image base profile enables ZFS, pulling in `zfs-kernel`; that needs the kernel's `dev` output, which is absent from the binary caches, forcing a full `linux-rpi` build per image. The installer only mounts btrfs/ext4/ESP |
| VPN topology | router = WireGuard server; Pis = split-tunnel nodes (`10.6.0.0/24` only) | full tunnel (`0.0.0.0/0`) would route the host's and instances' traffic through the router and disturb direct LAN/instance paths; split tunnel keeps management/LAN direct while still reaching every VPN client |
| VPN-reachable instances | separate `incusbr-vpn` bridge per host (`10.43.0.0/24`, `10.43.1.0/24`), `ipv4.nat = false` + uplink-scoped masquerade | incus NAT rewrites instance source IPs on any non-bridge egress (incl. `wg0`) and breaks inbound VPN connections; disabling it and masquerading only to the uplink (`end0`) preserves source IPs while keeping internet egress |
| WireGuard key | sops secrets `wg_private_key` (8gb), `wg_private_key_4gb` (4gb) | matches the existing sops pattern; never in the Nix store or git |
| VPN DNS | host Unbound on the WireGuard address (`10.6.0.3` on 8gb, `10.6.0.5` on 4gb); 8gb is the authoritative secondary for the Incus AXFR zone, 4gb forwards to it over the direct peer; `cache`/`monitoring`/SRV static; host resolved routes only `~int` to it | keeps internet working when Incus or its zone transfer is down; the WireGuard address survives a failed Incus bridge, unlike `10.43.0.1`; LLMNR/mDNS off avoids reverse-lookup timeouts |
| Direct WG peers | `local.wireguard.extraPeers` + fixed `listenPort`, key swap both ends | avoids the router hairpin and its double crypto; the peer's `/32` is more specific than the router's `vpnSubnet` so routing stays unambiguous; measured 225 -> ~900 Mbit/s aggregate over gigabit |
| Cross-host instance routing | direct-peer `allowedIPs` carry `10.42.0.0/24` <-> `10.42.1.0/24` and `10.43.0.0/24` <-> `10.43.1.0/24` | routes over the LAN direct peer (no router dependency); default-bridge traffic stays NATed, while VPN-bridge traffic keeps real source IPs |
| Secrets | sops-nix, age to host SSH keys + the Mac's SSH key | matches `konfig`; no long-lived shared age key stored on the Pis |
| Monitoring agent | Grafana Alloy (`local.monitoringAgent`), node metrics + journal to `monitoring.int.esselius.dev` | self-hosted metrics/logs; reuses the `int.esselius.dev` split DNS so it is outbound-only |
| Incus metrics | Alloy scrapes Incus `/1.0/metrics` (`local.incus.metrics`, loopback-only, unauthenticated), applied by `incus-runtime-config` | per-instance CPU/mem/disk/network with no firewall hole or metrics client cert; the listener is only exposed where a collector runs, and a deploy applies it without restarting incus |
| Metrics exporters | Unbound + WireGuard exporters, loopback-only, scraped by Alloy | query/cache/rcode and handshake/transfer visibility without exposing another listener on the LAN or `wg0` |
| Shared site config | `modules/site.nix` (`local.site`) + `mkDefault` | the VPN server identity, DNS zone/bootstrap records, UI client cert and monitoring/TLS toggles must agree across the pair; keeping them in one place removes duplicated host config and the risk of the two hosts drifting apart |
| Issue tracking | `bd` (beads) in the dev shell; `.beads/` committed with a tracked JSONL snapshot | git-native, dependency-aware tracker that an agent can drive offline from the CLI; JSONL is the sync path because embedded Dolt push hangs against GitHub |

## Playbooks

`root@<pi-ip>` below always refers to the bootstrap installer (which allows root SSH - required by
`nixos-anywhere` itself). Once a main system (`rpi5-8gb`/`rpi5-4gb`) is actually running, root SSH
is disabled there - use `admin@<pi-ip>` + `--sudo` instead (see "Update + rollback" below).

These commands are wrapped as `task` targets in `Taskfile.yml` (`task --list` shows them all).
`HOST` (default `rpi5-8gb`) is the source of truth; the address comes from `inventory.nix`, e.g.
`task deploy HOST=rpi5-4gb`. Set `IP=` only for a temporary/bootstrap address, and then also
`ALLOW_IP_OVERRIDE=1`; a mismatched `HOST`/`IP` is refused. `task install` is the hard reset
(needs `CONFIRM=WIPE`), `task install:mount` the soft reset (needs `CONFIRM=MOUNT`), and
`task flash DISK=/dev/rdiskX` writes the SD image (needs `CONFIRM=FLASH`).

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
task bootstrap                    # nix build + decompress to pi5-bootstrap.img
CONFIRM=FLASH task flash DISK=/dev/rdiskX   # unmountDisk + dd

# boot the Pi (NVMe attached), then:
CONFIRM=WIPE task install HOST=rpi5-8gb
```

If the NVMe previously held a ZFS pool, the bootstrap's disabled ZFS means disko cannot
`zpool destroy` it and its leftover label can make disko skip `mkfs.btrfs` (`unknown filesystem type
'zfs_member'`). Wipe it first from the booted installer:

```bash
ssh admin@<pi-ip> 'sudo blkdiscard -f /dev/nvme0n1'
```

That's it - no manual follow-up dance needed anymore (see "bootloader-install caveat" above:
`disko-sd.nix` lets `nixos-anywhere` mount the SD card's existing partitions automatically, so the
bootloader install step succeeds in the same run and the Pi reboots straight into the real system).

If the Mac build host misbehaves during install, pre-build the disko script + toplevel and pass
`--store-paths` (nixos-anywhere #18 pattern).

### Soft reset (SD reflash, reuse existing NVMe content - e.g. after a wedged SD/bootloader)

```bash
# reflash the bootstrap image as above, boot the Pi, then:
CONFIRM=MOUNT task install:mount HOST=rpi5-8gb
```

`--disko-mode mount` mounts the *existing* NVMe partitions and the SD card without destroying
anything, then runs the normal install + bootloader-install phases against them. Verified
end-to-end on real hardware: NVMe content (incus storage pool, containers, VMs) survives
untouched, bootloader install succeeds automatically, Pi reboots straight into the working system.
This replaces the old manual chroot + `nixos-enter` dance entirely for this case too.

### Secrets + ACME bootstrap (two-phase)

sops is keyed to each Pi's SSH host key, which only exists after first boot, so a fresh host is
installed before it can decrypt the GoDaddy secret:

```bash
# after first boot of a host, add its age recipient:
nix develop
ssh admin@<pi-ip> sudo cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age   # -> .sops.yaml

# create/rekey the files (run inside `nix develop`, whose shellHook sets
# SOPS_AGE_KEY_CMD to derive an age identity from ~/.ssh/id_ed25519):
sops secrets/rpi5-8gb.yaml              # wg_private_key: <base64>
sops secrets/rpi5-4gb.yaml              # wg_private_key_4gb: <base64>
sops secrets/shared/godaddy.yaml        # godaddy_acme: |
                                        #   GODADDY_API_KEY=...
                                        #   GODADDY_API_SECRET=...
sops updatekeys secrets/rpi5-8gb.yaml   # after adding/removing recipients
sops updatekeys secrets/shared/godaddy.yaml
```

The per-host file is readable only by that Pi and the Mac; the shared file is
readable by both Pis and the Mac. Each host sets `local.wireguard.sopsFile` in
`hosts/<host>.nix`, and `modules/incus/tls.nix` reads the shared ACME
credentials.

ACME is already enabled by default (`modules/site.nix`); once the key is a recipient, rebuild and
the cert is issued. The host also needs a DNS A record (`<host>.x.esselius.dev` -> its IP) for
clients to reach it; DNS-01 validation itself needs no inbound access.

Client certs are trusted declaratively by the `incus-trust-clients` oneshot (idempotent, since incus
preseed's `certificates` list is create-only). The repo already enrols the browser-generated UI cert
(`certs/incus-ui-localho.st.crt` -> `clientCertificates."incus-ui-localho.st"`). For the `incus`
CLI, either add the Mac's client cert
the same way (run any `incus` command once to generate `~/.config/incus/client.crt`, commit it under
`certs/`, and add it to `clientCertificates`), or use a one-time join token (`incus config trust
add`). Then:

```bash
incus remote add rpi5-8gb https://rpi5-8gb.x.esselius.dev:8443
```

### Update + rollback

Root SSH login is disabled on the main systems (`PermitRootLogin = "no"`, `modules/ssh-access.nix`)
- day-to-day access is via `admin` (passwordless `sudo`):

```bash
nix flake update          # deliberate bumps only
task cache-push           # push the host closure to Cachix (and Attic if up)
task deploy               # builds (or substitutes), switches, then verifies
task verify               # re-run the smoke test on demand
task rollback             # previous NixOS generation + verify
```

`task deploy` refuses a dirty worktree (override with `ALLOW_DIRTY=1`), runs
`nix flake check` first (skip with `SKIP_CHECK=1`), passes `--diff` to show
changed units, then runs `scripts/verify-host.sh`: systemd state/failed units,
the current system closure, the extlinux entry, incus, `incusbr0`, and cache
reachability. A failed verify leaves the deploy failed; set `AUTO_ROLLBACK=1` to
also switch back immediately, or run `task rollback` afterwards.

Substituters are layered so a host deploy never depends on the cluster
(`modules/nix-cache.nix`): **Cachix** (external, always up - holds the vendor
kernel), then the local **Attic** workload (best-effort), then an **on-target
build** as the last resort. `task deploy` probes the *exact* toplevel path with
`nix path-info --store https://esselius.cachix.org`: on a hit it realizes the
closure locally (from Cachix) and activates the store path with
`--use-substitutes`; on a miss it builds on the Pi itself, which already has the
vendor kernel in its store. A reachable cache endpoint is not enough - a missing
vendor-kernel closure takes the on-target path. Warm the external cache with
`task cache-push` first (`cachix authtoken` once). See the nix-workloads README
("Build cache (Attic)") for the local cache's one-time bootstrap.

The Pi must verify Attic's certificate: `modules/pki.nix` adds the vendored
Esselius root CA (`certs/esselius-root-ca.crt`, a copy of `konfig/root_ca.crt`)
to `security.pki.certificateFiles`, and `modules/nix-cache.nix` pins the cache's
narinfo key. Both are public material. Without the root, every Nix invocation on
the host logs `unable to get local issuer certificate` and silently skips Attic.

Rollback after a bad *activation*: `task rollback` switches to the previous
generation on the running host. If the host does not boot, choose the previous
generation at the U-Boot prompt (extlinux menu, SD p2). Root state is irrelevant
(impermanence), so rollback is purely about kernel/generation correctness.

### Recovery (pick the narrowest one that applies)

| Symptom | Fix | NVMe impact |
|---|---|---|
| SD card / bootloader broken or physically dead, NVMe fine | reflash `images.rpi5-bootstrap`, then **soft reset** above | none |
| Want a genuinely clean slate | reflash, then **hard reset** above (default `nixos-anywhere`, no `--disko-mode`) | **wiped** (disko's default mode destroys + recreates) |

### Migration between hosts (offline, no cluster)

```bash
incus copy --refresh rpi5-8gb:<instance> rpi5-4gb:   # pre-copy while running
incus stop <instance>; incus move rpi5-8gb:<instance> rpi5-4gb:
incus config device add <instance> zigbee unix-char path=/dev/serial/by-id/<id>
```

USB passthrough devices never migrate with an instance; re-attach at the destination.

## Issue tracking (beads)

Issues live in `.beads/` and are driven by [`bd`](https://github.com/steveyegge/beads)
from the dev shell. `.beads/config.yaml`, `metadata.json`, hooks, and the tracked
JSONL snapshot `.beads/issues.jsonl` are committed; the local Dolt database is
ignored. Use it instead of markdown TODOs:

```bash
bd ready                  # unblocked work
bd create "Title" -p 2    # new issue (P0 critical .. P4 backlog)
bd show <id>              # details and dependencies
bd update <id> --claim    # take it
bd close <id>             # done
bd prime                  # full workflow context for agents
```

`bd` auto-exports after writes (`export.auto`), so commit `.beads/issues.jsonl`
with the code. A fresh clone loads it with `bd init --from-jsonl` (or
`bd import .beads/issues.jsonl`). Do not use `bd dolt push` for now: the
embedded Dolt push hangs against GitHub over both SSH and HTTPS (plain git
pushes fine); the tracker uses the JSONL snapshot instead. Only the Mac needs
`bd` from the dev shell, not the hosts.

## Verification status

Confirmed working on real hardware (8 GB board):

- Vendor kernel boots, RP1 (USB + Ethernet) alive, NVMe enumerated on PCIe
- The Pi 5 vendor kernel/DTB exposes the wired uplink as `end0` (`wld0` is wireless) - there is no
  `eth0` on this image; `vpn.uplink` and `macvlan.parent` therefore default to `end0`
- Full impermanence mount tree (`@root`, `@nix`, `@persist` + binds, `@snapshots`)
- `nixos-rebuild switch` from macOS, including the declarative FAT refresh (stale DTBs pruned)
- incus: `incusbr0` bridge + NAT, `default` btrfs pool (CoW subvolumes verified via `btrfs
  subvolume show`), LXC container with working DHCP + egress, snapshot create/restore,
  **VM guest (Debian 13 cloud image, 4K-page) booted and reachable via incus-agent** on the 16K-page
  vendor kernel host
- incus server certificate: Let's Encrypt via GoDaddy DNS-01, issued in-process by incusd and served
  on `:8443` (needed `LEGO_DNS_PROPAGATION_DISABLE_RNS` - see TLS section); `acme.domain`/`provider`
  set through the preseed, creds from the sops `godaddy_acme` EnvironmentFile
- client-cert trust: the browser-generated UI cert (`incus-ui-localho.st`) is enrolled by
  `incus-trust-clients` and accepted by incusd (`incus config trust list`)
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
- Internal TLS trust (`modules/pki.nix`, deployed to `rpi5-8gb`): `curl` against
  `https://cache.int.esselius.dev/homelab/nix-cache-info` returns 200,
  `nix store ping --store https://cache.int.esselius.dev/homelab` succeeds, and Nix no longer logs
  `unable to get local issuer certificate` or retries the Attic substituter
- `rpi5-4gb` from scratch: `nixos-anywhere` install, host deploy, and incus-native ACME issuance.
  After adding its SSH host key to `.sops.yaml` and rekeying, the default-on ACME config produced a
  Let's Encrypt cert for `rpi5-4gb.x.esselius.dev` and `https://rpi5-4gb.x.esselius.dev:8443/`
  returns 200
- WireGuard on `rpi5-8gb`: `wg0` handshakes with the router (`latest handshake` in `wg show`),
  routes `10.6.0.0/24`, and a VPN client (`10.6.0.4`) reaches `incusbr-vpn` instances
  (`cache.int.esselius.dev`, `monitoring.int.esselius.dev`) with its real source IP preserved -
  confirmed in the attic nginx access log
- `rpi5-4gb` WireGuard/DNS/monitoring: `wg0` handshakes with both the router and `rpi5-8gb`
  (`10.6.0.5` -> `10.6.0.3`), a VPN client reaches `10.6.0.5` and resolves
  `homepage.int.esselius.dev` through its Unbound, and Alloy pushes node metrics plus journal to
  VictoriaMetrics/Loki and scrapes Incus metrics (`count({host="rpi5-4gb"})` has both jobs)
- Cross-host instance routing: a throwaway Alpine container on `rpi5-4gb` (`10.42.1.72`) was
  reachable from the `rpi5-8gb` host and from its `attic`/`homepage` containers (`10.43.0.x`), and
  it reached both workloads back over the direct peer (source masqueraded by `incusbr0`)
- `rpi5-4gb`'s `incusbr-vpn` (`10.43.1.0/24`, `nat = false`): a test container (`10.43.1.57`) was
  reachable from `attic`, and its real source IP appeared in attic's nginx access log (no NAT)
- VPN client (`10.6.0.4`, `AllowedIPs = 10.6.0.0/24, 10.42.0.0/15`): both WG addresses, both
  resolvers, both default bridges (`10.42.0.1`, `10.42.1.1`), both VPN bridges (`10.43.0.0/24`,
  `10.43.1.0/24`), and a test container on 4gb's VPN bridge are all reachable
- Both hosts report `job=unbound` and `job=wireguard` alongside the node and Incus scrape jobs

Pre-flight tested from macOS (not on the Pi):

- sops decrypts `secrets/*.yaml` via the SSH-key-derived age identity (devshell
  `SOPS_AGE_KEY_CMD`); the shared ACME file yields `GODADDY_API_KEY` / `GODADDY_API_SECRET`
- GoDaddy DNS-01 against **Let's Encrypt staging**: creds authenticate, the `_acme-challenge`
  TXT record is written and served by GoDaddy's authoritative NS (and deleted); the only snag was
  recursive-resolver propagation lag (fixed via `LEGO_DNS_PROPAGATION_DISABLE_RNS`)

## Known risks

- Impermanence blind-spots: forgetting to persist a service's state is silent (state lost on
  reboot). Any new service gets reviewed against `modules/storage.nix`'s persist list.
- The Incus API/UI listens on all interfaces (`core.https_address = ":8443"`, `local.incus.httpsPort`)
  and the firewall opens that port globally, so it is reachable from the LAN and the VPN, not just
  `wg0`. Client auth is certificate-based; narrowing the listener/firewall to `wg0`/LAN would be
  defense in depth if that exposure ever becomes unwanted.
- Every host eval prints disko's "The legacy table is outdated..." warning: `disko-sd.nix`
  necessarily uses disko's legacy `table`/`msdos` type for the MBR SD card (disko's new `gpt` type is
  GPT-only and partlabel-addressed, so it can't describe this disk). It is mount-only and harmless
  (disko #812 - no way to silence just this warning; `nix --quiet flake check` hides it).
- NVMe adapter/EEPROM quirks exist for some M.2 hats (nvmd/nixos-raspberrypi #117) - only relevant
  to a future NVMe-boot path; irrelevant to the current SD-boot design.
- Power: 27 W USB-C PSU + active cooling required for incus-sustained load on either board.
- Vendor kernel builds are uncached (no public Hydra jobset for `linux-rpi` yet); a `nix flake
  update` that bumps nixos-hardware can mean a multi-hour local kernel build.
- sops: a host whose SSH host key is not a recipient in `.sops.yaml` fails secret decryption at
  boot (so `incus.service` gets no GoDaddy creds and no cert is issued). Adding recipients means
  re-running `sops updatekeys` on that host's `secrets/<host>.yaml` (and
  `secrets/shared/godaddy.yaml`) from a machine that can already decrypt.
- VPN-client -> instance reachability depends on router-side config outside this repo (the Pi
  peer's `AllowedIPs` must include the incus subnet, and forwarding must be permitted). A missing
  route or forward rule presents as "the Pi's wg IP pings, an instance doesn't". Cross-host
  instance traffic does not depend on this - it uses the direct peer.
- The GoDaddy ACME credentials are shared by both hosts (`secrets/shared/godaddy.yaml`); the
  WireGuard keys are per host (`secrets/rpi5-8gb.yaml`, `secrets/rpi5-4gb.yaml`) and not readable
  by the other Pi.
- ACME: DNS-01 depends on GoDaddy API availability and is subject to Let's Encrypt rate limits. The
  client still needs an A record for the name to connect; validation itself does not.
- Internal TLS trust is pinned to the Esselius root CA (`certs/esselius-root-ca.crt`). Rotating the
  step-ca root without updating that file breaks Attic substitution - deploys still work via Cachix
  or an on-target build, but every Nix invocation on the host logs TLS warnings.

Actionable follow-ups from these risks (sops recipient check, vendor-kernel caching, Incus
exposure, root-CA rotation) are tracked in beads: `bd list --label readme-scan` from the dev shell.

## Future paths (tracked in beads)

The longer-horizon work - NVMe-only boot, mainline-kernel re-evaluation, IPv6 on `incusbr-vpn`,
Zigbee passthrough, and multi-host scaling - is tracked in beads instead of duplicated here. Run
`bd list --label readme-scan` (or `bd ready`) from the dev shell; each issue carries its README
source and acceptance criteria.
