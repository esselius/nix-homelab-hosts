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
| `@persist` | `/persist` | survives reboots: `machine-id`, SSH host keys, `/var/lib/nixos` (UID/GID maps), `/var/lib/incus`, `/var/log` + persistent journald. Deliberately **not** persisted: `/etc/nixos` + `/etc/nix` (declarative, and a flake checkout doesn't belong in `/etc/nixos`), `/root`, `/home` |
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
`local.incus.{network,guest,tls}`; each file contributes to an internal `local.incus.spec`, and
`preseed.nix` is the single place that assembles the freeform `virtualisation.incus.preseed` value
(this avoids depending on how the freeform submodule merges list attributes defined across separate
modules). Host networking for the VPN lives outside this directory, in `modules/wireguard.nix`,
tuned via `local.wireguard` - see "WireGuard VPN" below.

| File | Concern |
|------|---------|
| `default.nix` | enable, `pkgs.incus-lts`, UI, `incus-admin` group; declares the `local.incus.spec` interface |
| `network.nix` | managed bridge, explicit subnets, optional macvlan profile, firewall |
| `storage.nix` | btrfs `default` pool at `/persist/incus-pool` |
| `profiles.nix` | `default`/`container`/`vm` profiles from a per-host RAM budget |
| `tls.nix` | Let's Encrypt server cert (GoDaddy DNS-01) + trusted client certs |
| `preseed.nix` | assembles `virtualisation.incus.preseed` |

- `virtualisation.incus`, `pkgs.incus-lts`, `ui.enable = true`.
- `networking.nftables.enable = true` (module assertion; iptables is unsupported).
- Storage pool sourced at `/persist/incus-pool` (**not** `/persist/var/lib/incus` - incusd seeds its
  own daemon state there before preseed runs, so that path is never empty when the pool-create step
  fires; the pool needs its own leaf). No `systemd.tmpfiles.rules` entry pre-creates that directory
  (used to, when the pool was `dir`-backed) - the `btrfs` driver creates its own subvolume there on
  first preseed run, and a pre-existing plain directory at that exact path makes `btrfs subvolume
  create` fail with "File exists".
- The preseed unit is a one-shot that does **not** re-run automatically if its script changes under
  a `nixos-rebuild switch` (observed directly); if a preseed edit doesn't appear to take effect,
  `systemctl start incus-preseed` manually once. Also does not change an **existing** pool's driver
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
  WireGuard VPN clients - see "WireGuard VPN" below.
- `incusbr0` is in `networking.firewall.trustedInterfaces`; the API/UI port `8443` is opened.
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
- Host budgets (`local.incus.guest.memoryMiB`): `rpi5-8gb` 6144 (~2 GB left for host + zram),
  `rpi5-4gb` 2560.

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
- `acme.enable` is set per host. A host cannot decrypt the GoDaddy secret - and therefore cannot
  issue its cert - until its SSH host key is an age recipient (see Playbooks > secrets).

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
- `wg_private_key` is `rpi5-8gb`'s base64 WireGuard private key (read by `modules/wireguard.nix`).
  Its public key (`wg pubkey`) must be configured on the router - see "WireGuard VPN".

### WireGuard VPN (ASUS router server, Pis as split-tunnel nodes)

The router is an ASUS running its own WireGuard VPN server (VPN Fusion); each Pi joins as a
**split-tunnel node**, not a road-warrior client. `modules/wireguard.nix` (host-tuned via
`local.wireguard`) brings up `wg0` with the Pi's
tunnel address, a single peer (the router), `persistentKeepalive = 25` (so the server can always
push packets back through the Pi's home NAT), and `allowedIPs = 10.6.0.0/24` - the VPN subnet only.
Deliberately *not* `0.0.0.0/0`: a default route via `wg0` would drag all of the host's and its
instances' traffic through the router, whereas the split tunnel still reaches every VPN client and
lets instance reply traffic return to them. The private key is the sops secret `wg_private_key`;
`wg0` is a firewall-trusted interface and `net.ipv4.ip_forward` is enabled.

#### Host split DNS for the VPN bridge

A coredns instance on the VPN bridge (`10.43.0.14`) resolves the internal `int.esselius.dev` zone.
`local.incus.network.vpn.dns` + `dnsDomains = [ "~int.esselius.dev" ]` register it on the
`incusbr-vpn` link via `systemd-resolved` (a oneshot service waits for the bridge, since
`incus.service` returns before its networks are created). It is attached to the **bridge, not
`wg0`**: systemd-resolved binds a link's queries to that link, so a resolver on `incusbr-vpn` is
unreachable when registered on `wg0` (confirmed on hardware - direct queries worked, resolved fell
back to `1.1.1.1`). The `~` prefix makes it a routing-only domain: only that suffix goes to
coredns, every other lookup stays direct. This needs `services.resolved`, which the module turns on
(openresolv/glibc cannot route a domain to a specific server). The same block disables **LLMNR and
mDNS**: nothing on these subnets answers them, so a reverse (PTR) lookup - which `ping` without `-n`
and other tools do to print a name - would fall through to LLMNR + mDNS and wait out both timeouts
(~10s) even though the DNS answer came back instantly (confirmed on hardware).

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

Measured on `rpi5-8gb` <-> adama over the gigabit LAN: ~630 Mbit/s single-stream and ~900 Mbit/s
aggregate with `iperf3 -P 4` (~line rate), versus ~225 Mbit/s when it hairpinned through the router.

#### VPN-reachable instances

A separate managed bridge `incusbr-vpn` (`10.43.0.1/24`, IPv4-only) carries instances that other VPN
clients must reach. It is applied with the `vpn` profile, stacking on `default` exactly like `lan`
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
ip saddr 10.43.0.0/24 oifname "end0" masquerade
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
- **Allow IPs (Server)**: `<pi-wg-address>/32, 10.43.0.0/24` - for `rpi5-8gb`,
  `10.6.0.3/32, 10.43.0.0/24`. The ASUS default is just the peer `/32`; adding the incus subnet is
  the same edit the ASUS guide makes when it appends the client LAN
  (`10.6.0.2/32,192.168.100.0/24`). The server needs it to reach instances *and* to accept their
  return packets. **This is the one edit that matters.**
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

`rpi5-8gb` is the only host wired up so far: tunnel address `10.6.0.3/32`, public key
`5+zTY39/YS5sstc4dvw1A74eLfv5v+qkdgoMBkqqhDw=` (derive any host's with `wg pubkey`). `rpi5-4gb` and
cross-host instance routing (static routes between the two incus subnets over the LAN) are
additive, deferred until that board is in service.

### Monitoring (Grafana Alloy)

`modules/monitoring-agent.nix` (opt-in via `local.monitoringAgent`; enabled on `rpi5-8gb`) runs
`services.alloy` and ships node metrics and the systemd journal to the monitoring workload on the VPN
bridge: Prometheus remote-write to `monitoring.int.esselius.dev:8428` (VictoriaMetrics) and Loki push
to `:3100`. The endpoints resolve through the `int.esselius.dev` split DNS above, so the module is
outbound-only - no firewall or DNS changes on the host. A `prometheus.relabel` stamps
`host=<hostname>` on every series, and the journal source labels `host` / `job=systemd-journal`. The
NixOS `alloy` module runs the service as the `alloy` user in the `systemd-journal` group and reads
`/etc/alloy/config.alloy`, which this module owns via `environment.etc`.

It also scrapes Incus's per-instance metrics (`services.alloy` job `incus`, `local.monitoringAgent.scrapeIncus`).
`modules/incus/preseed.nix` exposes Incus's `/1.0/metrics` on a loopback-only listener
(`local.incus.metrics`, enabled on `rpi5-8gb`; `core.metrics_address = 127.0.0.1:9100`,
`core.metrics_authentication = false`). That endpoint is HTTPS with Incus's own certificate, so the
scrape skips TLS verification and never leaves the host - no firewall hole and no metrics client cert.
Note: the listener is set imperatively by preseed, so removing it from config does not unset it on a
running daemon (`incus config unset core.metrics_address`).

Requires a `monitoring` record in the coredns zone (the workload repo) pointing at the monitoring
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
| Client auth | incus client cert trusted via preseed | avoids running a CA for mTLS and avoids an OIDC broker; `step-ca`/PKI and GitHub-via-Dex were both overkill for two hosts, and kanidm can't do the device grant incus requires |
| Bridge addressing | explicit per-host subnets | predictable and non-colliding vs `auto`; easy to firewall |
| Guest memory budget | per-host (6 GiB / 2.5 GiB) | leaves headroom for host + zram on the 8/4 GB boards |
| VPN topology | router = WireGuard server; Pis = split-tunnel nodes (`10.6.0.0/24` only) | full tunnel (`0.0.0.0/0`) would route the host's and instances' traffic through the router and disturb direct LAN/instance paths; split tunnel keeps management/LAN direct while still reaching every VPN client |
| VPN-reachable instances | separate `incusbr-vpn` bridge (`10.43.0.0/24`), `ipv4.nat = false` + uplink-scoped masquerade | incus NAT rewrites instance source IPs on any non-bridge egress (incl. `wg0`) and breaks inbound VPN connections; disabling it and masquerading only to the uplink (`end0`) preserves source IPs while keeping internet egress |
| WireGuard key | sops secret `wg_private_key` | matches the existing sops pattern; never in the Nix store or git |
| VPN DNS | split DNS: `~int.esselius.dev` to the bridge resolver `10.43.0.14`, registered on `incusbr-vpn` via systemd-resolved, LLMNR/mDNS off | scopes internal lookups without making normal DNS depend on the instance; must be on the bridge, not `wg0` (resolved binds link queries to the link, making an off-link resolver unreachable); LLMNR/mDNS are disabled because their unanswered reverse-lookup timeouts add ~10s to `ping`/lookups; openresolv/glibc cannot do per-domain forwarding, so `services.resolved` is required |
| Direct WG peers | `local.wireguard.extraPeers` + fixed `listenPort`, key swap both ends | avoids the router hairpin and its double crypto; the peer's `/32` is more specific than the router's `vpnSubnet` so routing stays unambiguous; measured 225 -> ~900 Mbit/s aggregate over gigabit |
| Secrets | sops-nix, age to host SSH keys + the Mac's SSH key | matches `konfig`; no long-lived shared age key stored on the Pis |
| Monitoring agent | Grafana Alloy (`local.monitoringAgent`), node metrics + journal to `monitoring.int.esselius.dev` | self-hosted metrics/logs; reuses the `int.esselius.dev` split DNS so it is outbound-only |
| Incus metrics | Alloy scrapes Incus `/1.0/metrics` (`local.incus.metrics`, loopback-only, unauthenticated) | per-instance CPU/mem/disk/network with no firewall hole or metrics client cert; the listener is only exposed where a collector runs |

## Playbooks

`root@<pi-ip>` below always refers to the bootstrap installer (which allows root SSH - required by
`nixos-anywhere` itself). Once a main system (`rpi5-8gb`/`rpi5-4gb`) is actually running, root SSH
is disabled there - use `admin@<pi-ip>` + `--sudo` instead (see "Update + rollback" below).

These commands are wrapped as `task` targets in `Taskfile.yml` (`task --list` shows them all). Each
honours `HOST` (default `rpi5-8gb`) and `IP` (default `192.168.50.80`), e.g.
`task deploy HOST=rpi5-4gb IP=192.168.50.81`; `task install` is the hard reset, `task install:mount`
the soft reset, `task bootstrap`/`task flash DISK=/dev/rdiskX` handle the SD image.

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

### Secrets + ACME bootstrap (two-phase)

sops is keyed to each Pi's SSH host key, which only exists after first boot, so a fresh host is
installed before it can decrypt the GoDaddy secret:

```bash
# after first boot of a host, add its age recipient:
nix develop
ssh admin@<pi-ip> sudo cat /etc/ssh/ssh_host_ed25519_key.pub | ssh-to-age   # -> .sops.yaml

# create / rekey the secret (run inside `nix develop`, whose shellHook sets
# SOPS_AGE_KEY_CMD to derive an age identity from ~/.ssh/id_ed25519):
sops secrets/rpi5.yaml              # godaddy_acme: |
                                    #   GODADDY_API_KEY=...
                                    #   GODADDY_API_SECRET=...
sops updatekeys secrets/rpi5.yaml   # re-run after adding/removing recipients
```

Then set `local.incus.tls.acme.enable = true;` on any host whose key is a recipient, and rebuild.
The host also needs a DNS A record (`<host>.x.esselius.dev` -> its IP) for clients to reach it;
DNS-01 validation itself needs no inbound access.

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
nixos-rebuild switch --flake .#rpi5-8gb \
  --target-host admin@<pi-ip> --build-host admin@<pi-ip> --sudo
```

`--build-host` (the Pi building its own closure) matters here: the vendor kernel is uncached, and the
Pi already has it in its store, so building on the Mac would rebuild it via the `linux-builder`.

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
  set through the preseed, creds from the sops `godaddy_acme` EnvironmentFile, `nixos-rebuild
  switch` from macOS via `--build-host` (host reuses its uncached kernel)
- preseed client-cert trust: the browser-generated UI cert (`incus-ui-localho.st`) is enrolled via
  `local.incus.tls.clientCertificates` and accepted by incusd (`incus config trust list`)
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

Pre-flight tested from macOS (not on the Pi):

- sops decrypts `secrets/rpi5.yaml` via the SSH-key-derived age identity (devshell
  `SOPS_AGE_KEY_CMD`), yielding `GODADDY_API_KEY` / `GODADDY_API_SECRET`
- GoDaddy DNS-01 against **Let's Encrypt staging**: creds authenticate, the `_acme-challenge`
  TXT record is written and served by GoDaddy's authoritative NS (and deleted); the only snag was
  recursive-resolver propagation lag (fixed via `LEGO_DNS_PROPAGATION_DISABLE_RNS`)

Not yet verified on hardware:

- the 4 GB host (`rpi5-8gb` is the one exercised so far): needs its SSH key as a sops recipient and
  `acme.enable = true`
- WireGuard client (`wg0`) on `rpi5-8gb`: handshake with the router, `10.6.0.0/24` route via `wg0`,
  and `incusbr-vpn` instances reachable from another VPN client with the real instance source IP
  preserved (also depends on the router-side peer route/forwarding above)

## Known risks

- Impermanence blind-spots: forgetting to persist a service's state is silent (state lost on
  reboot). Any new service gets reviewed against `modules/storage.nix`'s persist list.
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
  re-running `sops updatekeys secrets/rpi5.yaml` from a machine that can already decrypt.
- VPN reachability depends on router-side config that lives outside this repo (each Pi peer's
  `AllowedIPs` must include the incus subnet, and forwarding between VPN clients and it must be
  permitted). A missing route or forward rule presents as "the Pi's wg IP pings, an instance
  doesn't".
- The WireGuard keys live in the shared `secrets/rpi5.yaml`, which every age recipient can fully
  decrypt; a future `rpi5-4gb` key must therefore use its own name rather than reuse
  `wg_private_key`.
- ACME: DNS-01 depends on GoDaddy API availability and is subject to Let's Encrypt rate limits. The
  client still needs an A record for the name to connect; validation itself does not.

## Future paths (documented, not built)

- NVMe-only boot once nixpkgs ships U-Boot 2026.10: add NVMe FAT to disko, EEPROM `BOOT_ORDER`
  includes NVMe, retire the SD from daily duty entirely.
- Re-evaluate mainline kernel once nixos-hardware/nixpkgs settle the Pi 5 DTB story further
  (tracked via nixos-hardware issue #78).
- WireGuard on `rpi5-4gb` (same `local.wireguard` options) plus static LAN routes so instances on
  both hosts reach each other; zigbee passthrough details; secondary hosts at scale - additive.
