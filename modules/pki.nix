{
  # Trust the Esselius root CA (step-ca in `konfig`) so the hosts can verify
  # internal HTTPS endpoints. Nix itself is the important consumer: the Attic
  # substituter (`https://cache.int.esselius.dev/homelab`) serves a certificate
  # signed by this root, and without it every Nix invocation retries, warns
  # "unable to get local issuer certificate", and skips the local cache.
  #
  # The certificate is public material (no key); `certs/esselius-root-ca.crt`
  # is a copy of `konfig/root_ca.crt`. Rotating the root means replacing it
  # here - the same trust decision `konfig` makes on its own hosts.
  security.pki.certificateFiles = [ ../certs/esselius-root-ca.crt ];
}
