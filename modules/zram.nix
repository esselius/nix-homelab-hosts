{ pkgs, ... }:
{
  zramSwap = {
    enable = true;
    algorithm = "zstd";
    memoryPercent = 50;
  };

  systemd.tmpfiles.rules = [
    "d /run/node_exporter/textfile 0755 root root -"
  ];

  systemd.services.zram-metrics = {
    description = "Publish zram statistics for node_exporter";
    path = [ pkgs.coreutils ];
    serviceConfig.Type = "oneshot";
    script = ''
      set -euo pipefail
      [ -r /sys/block/zram0/mm_stat ] || exit 0
      read -r orig compr mem_used mem_limit mem_used_max same_pages pages_compacted huge_pages huge_pages_since < /sys/block/zram0/mm_stat
      dir=/run/node_exporter/textfile
      install -d -m 0755 "$dir"
      tmp="$dir/.zram.prom.$$"
      {
        echo "# HELP node_zram_orig_data_bytes Uncompressed bytes stored in zram."
        echo "# TYPE node_zram_orig_data_bytes gauge"
        echo "node_zram_orig_data_bytes{device=\"zram0\"} $orig"
        echo "# HELP node_zram_compr_data_bytes Compressed bytes stored in zram."
        echo "# TYPE node_zram_compr_data_bytes gauge"
        echo "node_zram_compr_data_bytes{device=\"zram0\"} $compr"
        echo "# HELP node_zram_mem_used_bytes RAM held by zram."
        echo "# TYPE node_zram_mem_used_bytes gauge"
        echo "node_zram_mem_used_bytes{device=\"zram0\"} $mem_used"
        echo "# HELP node_zram_mem_limit_bytes zram memory limit."
        echo "# TYPE node_zram_mem_limit_bytes gauge"
        echo "node_zram_mem_limit_bytes{device=\"zram0\"} $mem_limit"
        echo "# HELP node_zram_mem_used_max_bytes Peak RAM held by zram."
        echo "# TYPE node_zram_mem_used_max_bytes gauge"
        echo "node_zram_mem_used_max_bytes{device=\"zram0\"} $mem_used_max"
        echo "# HELP node_zram_same_pages Pages stored zram-internal deduplicated."
        echo "# TYPE node_zram_same_pages gauge"
        echo "node_zram_same_pages{device=\"zram0\"} $same_pages"
        echo "# HELP node_zram_pages_compacted Pages compacted."
        echo "# TYPE node_zram_pages_compacted gauge"
        echo "node_zram_pages_compacted{device=\"zram0\"} $pages_compacted"
        echo "# HELP node_zram_huge_pages Pages stored using huge pages."
        echo "# TYPE node_zram_huge_pages gauge"
        echo "node_zram_huge_pages{device=\"zram0\"} $huge_pages"
        echo "# HELP node_zram_huge_pages_since Huge pages stored since boot."
        echo "# TYPE node_zram_huge_pages_since gauge"
        echo "node_zram_huge_pages_since{device=\"zram0\"} $huge_pages_since"
      } > "$tmp"
      mv "$tmp" "$dir/zram.prom"
    '';
  };

  systemd.timers.zram-metrics = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "15s";
      OnUnitActiveSec = "30s";
    };
  };
}
