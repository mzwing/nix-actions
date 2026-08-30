#!/bin/sh
# The numbers that decide whether a builder is about to fall over, as one line of key=value pairs.
# Piped to `sh -s` on the builder, so it stays POSIX and derives every value from something both runner families ship.
set -u

mb_free() {
  kb="$(df -k "$1" 2>/dev/null | awk 'NR == 2 {print $4}')"
  case "${kb}" in
    '' | *[!0-9]*) printf 'NA' ;;
    *) printf '%s' "$((kb / 1024))" ;;
  esac
}

printf 'nix_free_mb=%s root_free_mb=%s ' "$(mb_free /nix)" "$(mb_free /)"

if [ -r /proc/meminfo ]; then
  awk '
    /^MemAvailable:/ { avail = $2 }
    /^SwapTotal:/    { total = $2 }
    /^SwapFree:/     { free = $2 }
    END { printf "mem_avail_mb=%d swap_used_mb=%d ", avail / 1024, (total - free) / 1024 }
  ' /proc/meminfo
  awk '/^pswpout / { printf "swapouts=%s ", $2 }' /proc/vmstat
  awk '{ printf "load1=%s\n", $1 }' /proc/loadavg
else
  # Free plus inactive plus speculative is what macOS will hand back without swapping; wired and compressed pages are not reclaimable and so are excluded.
  # compressed_mb is the field to read first: Apple silicon compresses long before it swaps, so mem_avail_mb still looks survivable while the machine is already in trouble.
  vm_stat | awk '
    /page size of/                  { page = $8 }
    /^Pages free/                   { free = $3 }
    /^Pages inactive/               { inactive = $3 }
    /^Pages speculative/            { spec = $3 }
    /^Pages occupied by compressor/ { compressed = $5 }
    /^Swapouts/                     { swapouts = $2 }
    END { printf "mem_avail_mb=%d compressed_mb=%d swapouts=%d ", (free + inactive + spec) * page / 1048576, compressed * page / 1048576, swapouts }
  '
  # A cumulative swapouts counter that starts climbing is the tell; swap_used only reports the steady state it settles at.
  sysctl -n vm.swapusage | awk '{ used = $6; unit = substr(used, length(used)); sub(/[A-Za-z]$/, "", used); if (unit == "G") used *= 1024; printf "swap_used_mb=%.0f ", used }'
  sysctl -n vm.loadavg | awk '{ printf "load1=%s\n", $2 }'
fi
