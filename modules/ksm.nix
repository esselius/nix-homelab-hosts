{ pkgs, ... }:
{
  hardware.ksm.enable = true;

  systemd.services.ksm-tune = {
    description = "Tune KSM for container density";
    wantedBy = [ "multi-user.target" ];
    after = [ "enable-ksm.service" ];
    requires = [ "enable-ksm.service" ];
    path = [ pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      echo 1 > /sys/kernel/mm/ksm/use_zero_pages
      echo scan-time > /sys/kernel/mm/ksm/advisor_mode
      echo 600 > /sys/kernel/mm/ksm/advisor_target_scan_time
      echo 25 > /sys/kernel/mm/ksm/advisor_max_cpu
    '';
  };
}
