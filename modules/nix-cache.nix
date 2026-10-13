{
  lib,
  ...
}:
let
  # External, always-available substituter: Cachix. The host is the
  # bootstrap-critical machine, so it must not depend on the Attic cache, which
  # runs *on* this cluster (and may be down precisely when a host is being
  # fixed). `cachix push` skips paths already on cache.nixos.org, so the cache
  # holds only the uncached bits - essentially the vendor kernel.
  cachixUrl = "https://esselius.cachix.org";
  cachixPublicKey = "esselius.cachix.org-1:h6FQzpdflxdZfnnL0caV88xt5K5sNzgO0VIHQthTymA=";

  # Local Attic cache (the `attic` workload in nix-workloads): a fast,
  # deduplicated accelerant while it is reachable. Best-effort - nix skips an
  # unreachable substituter, and a host deploy never depends on it.
  atticUrl = "https://cache.int.esselius.dev/homelab";

  # The Attic narinfo key is generated when the cache is *created*, so it can
  # only be filled in after the one-time bootstrap:
  #   attic cache info homelab   ->   Public Key: homelab:<base64>
  atticPublicKey = null;
in
{
  nix.settings = {
    extra-substituters = [
      cachixUrl
      atticUrl
    ];
    extra-trusted-public-keys = [
      cachixPublicKey
    ]
    ++ lib.optional (atticPublicKey != null) atticPublicKey;
  };
}
