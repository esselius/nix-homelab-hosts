{ config, lib, ... }:
let
  cfg = config.local.monitoringAgent;
  hostName = config.networking.hostName;
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
  };

  config = lib.mkIf cfg.enable {
    # The NixOS module runs Alloy as the `alloy` user and adds it to the
    # systemd-journal group, so the journal source below can read logs. It reads
    # /etc/alloy/config.alloy (its configPath default), which we own here.
    services.alloy.enable = true;

    environment.etc."alloy/config.alloy".text = ''
      prometheus.exporter.unix "node" {
        enable_collectors = ["systemd"]
      }

      prometheus.scrape "node" {
        targets    = prometheus.exporter.unix.node.targets
        forward_to = [prometheus.relabel.host.receiver]
      }

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
