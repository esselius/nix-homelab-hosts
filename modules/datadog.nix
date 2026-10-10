{ config, lib, ... }:
let
  # Datadog agent v7 (services.datadog-agent), US1 site. The API key lives in
  # the shared sops file (secrets/rpi5.yaml -> datadog_api_key) and is injected
  # via apiKeyFile. The agent's unit runs as the `datadog` user and reads the
  # key itself, so the secret is chowned to that user (sops-nix defaults to a
  # root-only 0400 file, which the agent could not read).
  #
  # integrations-core 7.70.2 names its Python distributions datadog-checks-base,
  # datadog-disk, ... while the nix derivations use the bare integration
  # directory name as pname (checks-base, disk, ...). The python-metadata-check
  # hook added on nixos-unstable looks the dist up by pname, cannot find it, and
  # aborts the build before the agent is even reached. Re-call the upstream
  # integrations-core file with a buildPythonPackage that sets
  # dontCheckPythonMetadata = true - scoped to just that file (a plain `//`, not
  # overrideScope, so the integrations' own dependencies still come from the
  # cached python set). Upstream already sets doCheck = false there; drop this
  # once the metadata check is fixed upstream.
  datadogIntegrationsOverlay =
    _final: prev:
    let
      python3Packages = prev.python3Packages // {
        buildPythonPackage =
          args: prev.python3Packages.buildPythonPackage (args // { dontCheckPythonMetadata = true; });
      };
    in
    {
      datadog-integrations-core = lib.setFunctionArgs (
        extras:
        lib.callPackageWith (prev // { inherit python3Packages; }) (
          prev.path + "/pkgs/tools/networking/dd-agent/integrations-core.nix"
        ) { extraIntegrations = extras; }
      ) (lib.functionArgs prev.datadog-integrations-core);
    };
in
{
  nixpkgs.overlays = [ datadogIntegrationsOverlay ];

  sops.secrets.datadog_api_key = {
    sopsFile = ../secrets/rpi5.yaml;
    owner = "datadog";
    restartUnits = [ "datadog-agent.service" ];
  };

  services.datadog-agent = {
    enable = true;
    apiKeyFile = config.sops.secrets.datadog_api_key.path;
    hostname = config.networking.hostName;
    # Live Process collection (process_config.process_collection.enabled).
    enableLiveProcessCollection = true;
    # The module default is use_mount = "false" (a string), which the disk check
    # cannot unmarshal into bool and refuses to load; pass a real boolean.
    diskCheck = {
      init_config = { };
      instances = [ { use_mount = false; } ];
    };
    # The agent defaults run_path to /opt/datadog-agent/run, which does not exist
    # on NixOS, so remote-config and version-history writes fail at startup.
    extraConfig.run_path = "/run/datadog-agent";

    # Scrape Incus's Prometheus metrics (exposed loopback-only by
    # modules/incus/preseed.nix) through the OpenMetrics check. OpenMetrics is
    # not one of the module's default integrations, so pull it into the agent's
    # Python env explicitly. Every scraped series is a Datadog *custom metric*;
    # `metrics = [ ".*" ]` collects the full documented set.
    extraIntegrations = lib.mkIf config.local.incus.metrics.enable {
      openmetrics = (ps: [ ps.prometheus-client ]);
    };
    checks = lib.mkIf config.local.incus.metrics.enable {
      openmetrics = {
        init_config = { };
        instances = [
          {
            # The metrics listener is HTTPS; the cert is Incus's own
            # (self-signed unless ACME is on), so skip verification on loopback.
            openmetrics_endpoint = "https://${config.local.incus.metrics.address}/1.0/metrics";
            namespace = "incus";
            # Strip the raw prefix so the namespace does not double it:
            # incus_cpu_seconds_total -> incus.cpu_seconds.count.
            raw_metric_prefix = "incus_";
            tls_verify = false;
            metrics = [ ".*" ];
          }
        ];
      };
    };
  };

  # dogstatsd tries a unixgram socket under /var/run/datadog as well as UDP, and
  # the agent writes runtime state under run_path; neither dir is created for us.
  systemd.tmpfiles.rules = [
    "d /run/datadog 0755 datadog datadog -"
    "d /run/datadog-agent 0755 datadog datadog -"
  ];
}
