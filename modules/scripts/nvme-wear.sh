#!/usr/bin/env bash
set -euo pipefail

dir=/run/node_exporter/textfile
install -d -m 0755 "$dir"
tmp="$dir/.nvme-wear.prom.$$"
dev=/dev/nvme0n1

write_unsupported() {
  {
    echo "# HELP node_nvme_supported Whether NVMe SMART wear data is available."
    echo "# TYPE node_nvme_supported gauge"
    echo "node_nvme_supported 0"
  } > "$tmp"
  mv "$tmp" "$dir/nvme-wear.prom"
  exit 0
}

[ -e "$dev" ] || write_unsupported
json=$(smartctl -j -a "$dev" 2>/dev/null) || write_unsupported
log=$(printf '%s' "$json" | jq -c '.nvme_smart_health_information_log // empty' 2>/dev/null) || write_unsupported
[ -n "$log" ] || write_unsupported

get() {
  printf '%s' "$log" | jq -r --arg k "$1" '.[$k] // 0'
}

data_units_read=$(get data_units_read)
data_units_written=$(get data_units_written)
host_reads=$(get host_reads)
host_writes=$(get host_writes)
controller_busy=$(get controller_busy_time)
power_cycles=$(get power_cycles)
power_on_hours=$(get power_on_hours)
unsafe_shutdowns=$(get unsafe_shutdowns)
media_errors=$(get media_errors)
num_err_log=$(get num_err_log_entries)
temperature=$(get temperature)
warning_temp=$(get warning_temp_time)
critical_comp=$(get critical_comp_time)
critical_warning=$(get critical_warning)
available_spare=$(get available_spare)
available_spare_threshold=$(get available_spare_threshold)
percentage_used=$(get percentage_used)

{
  echo "# HELP node_nvme_supported Whether NVMe SMART wear data is available."
  echo "# TYPE node_nvme_supported gauge"
  echo "node_nvme_supported 1"
  echo "# HELP node_nvme_percentage_used Vendor-estimated percentage of device life used."
  echo "# TYPE node_nvme_percentage_used gauge"
  echo "node_nvme_percentage_used $percentage_used"
  echo "# HELP node_nvme_available_spare_percent Percentage of spare blocks available."
  echo "# TYPE node_nvme_available_spare_percent gauge"
  echo "node_nvme_available_spare_percent $available_spare"
  echo "# HELP node_nvme_available_spare_threshold_percent Spare threshold below which the device warns."
  echo "# TYPE node_nvme_available_spare_threshold_percent gauge"
  echo "node_nvme_available_spare_threshold_percent $available_spare_threshold"
  echo "# HELP node_nvme_data_read_bytes_total Bytes read by the device, from SMART data units."
  echo "# TYPE node_nvme_data_read_bytes_total counter"
  echo "node_nvme_data_read_bytes_total $(( data_units_read * 512000 ))"
  echo "# HELP node_nvme_data_written_bytes_total Bytes written by the device, from SMART data units."
  echo "# TYPE node_nvme_data_written_bytes_total counter"
  echo "node_nvme_data_written_bytes_total $(( data_units_written * 512000 ))"
  echo "# HELP node_nvme_host_reads_total Host read commands completed."
  echo "# TYPE node_nvme_host_reads_total counter"
  echo "node_nvme_host_reads_total $host_reads"
  echo "# HELP node_nvme_host_writes_total Host write commands completed."
  echo "# TYPE node_nvme_host_writes_total counter"
  echo "node_nvme_host_writes_total $host_writes"
  echo "# HELP node_nvme_controller_busy_minutes_total Minutes the controller was busy."
  echo "# TYPE node_nvme_controller_busy_minutes_total counter"
  echo "node_nvme_controller_busy_minutes_total $controller_busy"
  echo "# HELP node_nvme_power_cycles_total Power cycles."
  echo "# TYPE node_nvme_power_cycles_total counter"
  echo "node_nvme_power_cycles_total $power_cycles"
  echo "# HELP node_nvme_power_on_hours_total Power-on hours."
  echo "# TYPE node_nvme_power_on_hours_total counter"
  echo "node_nvme_power_on_hours_total $power_on_hours"
  echo "# HELP node_nvme_unsafe_shutdowns_total Unsafe shutdowns."
  echo "# TYPE node_nvme_unsafe_shutdowns_total counter"
  echo "node_nvme_unsafe_shutdowns_total $unsafe_shutdowns"
  echo "# HELP node_nvme_media_errors_total Unrecovered media/data integrity errors."
  echo "# TYPE node_nvme_media_errors_total counter"
  echo "node_nvme_media_errors_total $media_errors"
  echo "# HELP node_nvme_num_err_log_entries_total Error log entries."
  echo "# TYPE node_nvme_num_err_log_entries_total counter"
  echo "node_nvme_num_err_log_entries_total $num_err_log"
  echo "# HELP node_nvme_critical_warning NVMe critical warning bitmask."
  echo "# TYPE node_nvme_critical_warning gauge"
  echo "node_nvme_critical_warning $critical_warning"
  echo "# HELP node_nvme_temperature_celsius Composite temperature."
  echo "# TYPE node_nvme_temperature_celsius gauge"
  echo "node_nvme_temperature_celsius $temperature"
  echo "# HELP node_nvme_warning_temp_minutes_total Minutes above the warning temperature."
  echo "# TYPE node_nvme_warning_temp_minutes_total counter"
  echo "node_nvme_warning_temp_minutes_total $warning_temp"
  echo "# HELP node_nvme_critical_comp_time_minutes_total Minutes in critical composite temperature."
  echo "# TYPE node_nvme_critical_comp_time_minutes_total counter"
  echo "node_nvme_critical_comp_time_minutes_total $critical_comp"
} > "$tmp"

mv "$tmp" "$dir/nvme-wear.prom"
