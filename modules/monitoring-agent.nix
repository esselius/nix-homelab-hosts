{ config, lib, ... }:
let
  cfg = config.local.monitoringAgent;
  hostName = config.networking.hostName;

  # Incus's per-instance metrics, scraped from the loopback listener that
  # modules/incus/preseed.nix exposes when local.incus.metrics.enable is set.
  # The endpoint is HTTPS with Incus's own certificate, hence skip-verify.
  incusScrape = lib.optionalString (cfg.scrapeIncus && config.local.incus.metrics.enable) ''
    prometheus.scrape "incus" {
      targets      = [{ __address__ = "${config.local.incus.metrics.address}" }]
      scheme       = "https"
      metrics_path = "/1.0/metrics"
      tls_config {
        insecure_skip_verify = true
      }
      forward_to   = [prometheus.relabel.host.receiver]
    }
  '';

  # Unbound and WireGuard exporters listen on loopback; scrape them here so
  # their metrics get the same host label as the rest of the host's series.
  unboundScrape = lib.optionalString config.services.prometheus.exporters.unbound.enable ''
    prometheus.scrape "unbound" {
      targets    = [{ __address__ = "127.0.0.1:${toString config.services.prometheus.exporters.unbound.port}" }]
      job_name   = "unbound"
      forward_to = [prometheus.relabel.host.receiver]
    }
  '';

  wireguardScrape = lib.optionalString config.services.prometheus.exporters.wireguard.enable ''
    prometheus.scrape "wireguard" {
      targets    = [{ __address__ = "127.0.0.1:${toString config.services.prometheus.exporters.wireguard.port}" }]
      job_name   = "wireguard"
      forward_to = [prometheus.relabel.host.receiver]
    }
  '';
in
{
  options.local.monitoringAgent = {
    enable = lib.mkEnableOption ''
      the Grafana Alloy agent, shipping node metrics (Prometheus remote-write) and
      the systemd journal (Loki) to the monitoring workload
    '';

    metricsUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://monitoring.int.esselius.dev:8428/api/v1/write";
      description = "VictoriaMetrics remote-write endpoint.";
    };

    logsUrl = lib.mkOption {
      type = lib.types.str;
      default = "http://monitoring.int.esselius.dev:3100/loki/api/v1/push";
      description = "Loki push endpoint.";
    };

    scrapeIncus = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Also scrape Incus's `/1.0/metrics` (per-instance CPU/memory/disk/network),
        requires `local.incus.metrics.enable`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # The NixOS module runs Alloy as the `alloy` user and adds it to the
    # systemd-journal group, so the journal source below can read logs. It reads
    # /etc/alloy/config.alloy (its configPath default), which we own here.
    services.alloy.enable = true;

    boot.kernelParams = [ "psi=1" ];

    environment.etc."alloy/config.alloy".text = ''
      prometheus.exporter.unix "node" {
        enable_collectors = ["systemd", "ksmd"]
        vmstat {
          fields = "^(oom_kill|pgpg|pswp|pg.*fault|cow_ksm|ksm).*"
        }
        textfile {
          directory = "/run/node_exporter/textfile"
        }
      }

      prometheus.scrape "node" {
        targets    = prometheus.exporter.unix.node.targets
        forward_to = [prometheus.relabel.node.receiver]
      }

      // The incus guests run this same node exporter, so both they and the
      // hosts emit node_* series with job="integrations/unix". Mark the host's
      // own series (the node scrape only - not the incus scrape below) so the
      // physical-node dashboards can tell them apart.
      prometheus.relabel "node" {
        forward_to = [prometheus.relabel.host.receiver]
        rule {
          target_label = "node_type"
          replacement  = "host"
        }
      }

      ${incusScrape}
      ${unboundScrape}
      ${wireguardScrape}

      prometheus.relabel "host" {
        forward_to = [prometheus.remote_write.default.receiver]
        rule {
          target_label = "host"
          replacement  = "${hostName}"
        }
      }

      prometheus.remote_write "default" {
        endpoint {
          url = "${cfg.metricsUrl}"
        }
      }

      loki.source.journal "journal" {
        forward_to = [loki.write.default.receiver]
        labels     = { host = "${hostName}", job = "systemd-journal" }
      }

      loki.write "default" {
        endpoint {
          url = "${cfg.logsUrl}"
        }
      }
    '';
  };
}
