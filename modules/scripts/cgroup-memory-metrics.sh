#!/usr/bin/env bash
set -euo pipefail

dir=/run/node_exporter/textfile
install -d -m 0755 "$dir"
tmp="$dir/.cgroup-memory.prom.$$"

{
  cat <<'EOF'
# HELP node_cgroup_memory_current_bytes Current cgroup memory usage.
# TYPE node_cgroup_memory_current_bytes gauge
# HELP node_cgroup_memory_peak_bytes Peak cgroup memory usage since boot.
# TYPE node_cgroup_memory_peak_bytes gauge
# HELP node_cgroup_memory_max_bytes Configured hard memory limit.
# TYPE node_cgroup_memory_max_bytes gauge
# HELP node_cgroup_memory_swap_current_bytes Current cgroup swap usage.
# TYPE node_cgroup_memory_swap_current_bytes gauge
# HELP node_cgroup_memory_swap_max_bytes Configured swap limit.
# TYPE node_cgroup_memory_swap_max_bytes gauge
# HELP node_cgroup_memory_file_bytes Page cache charged to the cgroup.
# TYPE node_cgroup_memory_file_bytes gauge
# HELP node_cgroup_memory_active_file_bytes Active (hot) page cache.
# TYPE node_cgroup_memory_active_file_bytes gauge
# HELP node_cgroup_memory_inactive_file_bytes Inactive (cold) page cache.
# TYPE node_cgroup_memory_inactive_file_bytes gauge
# HELP node_cgroup_memory_anon_bytes Anonymous memory.
# TYPE node_cgroup_memory_anon_bytes gauge
# HELP node_cgroup_memory_kernel_bytes Kernel and slab memory.
# TYPE node_cgroup_memory_kernel_bytes gauge
# HELP node_cgroup_memory_workingset_refault_file_total File pages refaulted after eviction.
# TYPE node_cgroup_memory_workingset_refault_file_total counter
# HELP node_cgroup_memory_workingset_activate_file_total Refaulted file pages that were reused.
# TYPE node_cgroup_memory_workingset_activate_file_total counter
# HELP node_cgroup_memory_workingset_restore_file_total File pages restored from workingset.
# TYPE node_cgroup_memory_workingset_restore_file_total counter
# HELP node_cgroup_memory_pgfault_total Total page faults.
# TYPE node_cgroup_memory_pgfault_total counter
# HELP node_cgroup_memory_pgmajfault_total Page faults that required disk I/O.
# TYPE node_cgroup_memory_pgmajfault_total counter
# HELP node_cgroup_memory_pgscan_total Pages scanned by reclaim.
# TYPE node_cgroup_memory_pgscan_total counter
# HELP node_cgroup_memory_pgsteal_total Pages reclaimed.
# TYPE node_cgroup_memory_pgsteal_total counter
# HELP node_cgroup_memory_oom_kill_total OOM kills in the cgroup.
# TYPE node_cgroup_memory_oom_kill_total counter
# HELP node_cgroup_memory_events_high_total Memory usage crossed the high watermark.
# TYPE node_cgroup_memory_events_high_total counter
# HELP node_cgroup_memory_events_max_total Memory usage hit the hard limit.
# TYPE node_cgroup_memory_events_max_total counter
# HELP node_cgroup_memory_events_oom_total OOM events in the cgroup.
# TYPE node_cgroup_memory_events_oom_total counter
# HELP node_cgroup_memory_events_oom_group_kill_total Group OOM kills in the cgroup.
# TYPE node_cgroup_memory_events_oom_group_kill_total counter
# HELP node_cgroup_memory_swap_events_high_total Swap usage crossed the high watermark.
# TYPE node_cgroup_memory_swap_events_high_total counter
# HELP node_cgroup_memory_swap_events_max_total Swap usage hit the limit.
# TYPE node_cgroup_memory_swap_events_max_total counter
# HELP node_cgroup_memory_swap_events_fail_total Swap allocation failures.
# TYPE node_cgroup_memory_swap_events_fail_total counter
# HELP node_cgroup_memory_workingset_refault_anon_total Anonymous pages refaulted after eviction.
# TYPE node_cgroup_memory_workingset_refault_anon_total counter
EOF

  for d in /sys/fs/cgroup/lxc.payload.*; do
    [ -d "$d" ] || continue
    name=${d##*.}
    declare -A s=()
    while read -r k v; do s[$k]=$v; done < "$d/memory.stat"
    current=$(cat "$d/memory.current")
    peak=$(cat "$d/memory.peak")
    max=$(cat "$d/memory.max")
    swap_current=$(cat "$d/memory.swap.current")
    swap_max=$(cat "$d/memory.swap.max")
    oom_kill=$(awk '$1 == "oom_kill" { print $2 }' "$d/memory.events")
    high=$(awk '$1 == "high" { print $2 }' "$d/memory.events")
    max_events=$(awk '$1 == "max" { print $2 }' "$d/memory.events")
    oom=$(awk '$1 == "oom" { print $2 }' "$d/memory.events")
    oom_group_kill=$(awk '$1 == "oom_group_kill" { print $2 }' "$d/memory.events")
    swap_high=0
    swap_max_events=0
    swap_fail=0
    if [ -r "$d/memory.swap.events" ]; then
      while read -r k v; do
        case "$k" in
        high) swap_high=$v ;;
        max) swap_max_events=$v ;;
        fail) swap_fail=$v ;;
        esac
      done < "$d/memory.swap.events"
    fi
    case "$max" in '' | *[!0-9]*) max=0 ;; esac
    case "$swap_max" in '' | *[!0-9]*) swap_max=0 ;; esac
    case "$oom_kill" in '' | *[!0-9]*) oom_kill=0 ;; esac
    case "$high" in '' | *[!0-9]*) high=0 ;; esac
    case "$max_events" in '' | *[!0-9]*) max_events=0 ;; esac
    case "$oom" in '' | *[!0-9]*) oom=0 ;; esac
    case "$oom_group_kill" in '' | *[!0-9]*) oom_group_kill=0 ;; esac
    case "$swap_high" in '' | *[!0-9]*) swap_high=0 ;; esac
    case "$swap_max_events" in '' | *[!0-9]*) swap_max_events=0 ;; esac
    case "$swap_fail" in '' | *[!0-9]*) swap_fail=0 ;; esac

    printf 'node_cgroup_memory_current_bytes{name="%s"} %s\n' "$name" "$current"
    printf 'node_cgroup_memory_peak_bytes{name="%s"} %s\n' "$name" "$peak"
    printf 'node_cgroup_memory_max_bytes{name="%s"} %s\n' "$name" "$max"
    printf 'node_cgroup_memory_swap_current_bytes{name="%s"} %s\n' "$name" "$swap_current"
    printf 'node_cgroup_memory_swap_max_bytes{name="%s"} %s\n' "$name" "$swap_max"
    printf 'node_cgroup_memory_file_bytes{name="%s"} %s\n' "$name" "${s[file]:-0}"
    printf 'node_cgroup_memory_active_file_bytes{name="%s"} %s\n' "$name" "${s[active_file]:-0}"
    printf 'node_cgroup_memory_inactive_file_bytes{name="%s"} %s\n' "$name" "${s[inactive_file]:-0}"
    printf 'node_cgroup_memory_anon_bytes{name="%s"} %s\n' "$name" "${s[anon]:-0}"
    printf 'node_cgroup_memory_kernel_bytes{name="%s"} %s\n' "$name" "${s[kernel]:-0}"
    printf 'node_cgroup_memory_workingset_refault_file_total{name="%s"} %s\n' "$name" "${s[workingset_refault_file]:-0}"
    printf 'node_cgroup_memory_workingset_activate_file_total{name="%s"} %s\n' "$name" "${s[workingset_activate_file]:-0}"
    printf 'node_cgroup_memory_workingset_restore_file_total{name="%s"} %s\n' "$name" "${s[workingset_restore_file]:-0}"
    printf 'node_cgroup_memory_pgfault_total{name="%s"} %s\n' "$name" "${s[pgfault]:-0}"
    printf 'node_cgroup_memory_pgmajfault_total{name="%s"} %s\n' "$name" "${s[pgmajfault]:-0}"
    printf 'node_cgroup_memory_pgscan_total{name="%s"} %s\n' "$name" "${s[pgscan]:-0}"
    printf 'node_cgroup_memory_pgsteal_total{name="%s"} %s\n' "$name" "${s[pgsteal]:-0}"
    printf 'node_cgroup_memory_oom_kill_total{name="%s"} %s\n' "$name" "$oom_kill"
    printf 'node_cgroup_memory_events_high_total{name="%s"} %s\n' "$name" "$high"
    printf 'node_cgroup_memory_events_max_total{name="%s"} %s\n' "$name" "$max_events"
    printf 'node_cgroup_memory_events_oom_total{name="%s"} %s\n' "$name" "$oom"
    printf 'node_cgroup_memory_events_oom_group_kill_total{name="%s"} %s\n' "$name" "$oom_group_kill"
    printf 'node_cgroup_memory_swap_events_high_total{name="%s"} %s\n' "$name" "$swap_high"
    printf 'node_cgroup_memory_swap_events_max_total{name="%s"} %s\n' "$name" "$swap_max_events"
    printf 'node_cgroup_memory_swap_events_fail_total{name="%s"} %s\n' "$name" "$swap_fail"
    printf 'node_cgroup_memory_workingset_refault_anon_total{name="%s"} %s\n' "$name" "${s[workingset_refault_anon]:-0}"
  done
} > "$tmp"

mv "$tmp" "$dir/cgroup-memory.prom"
