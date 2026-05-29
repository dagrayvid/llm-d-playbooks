#!/bin/bash
# Diff ethtool counters between two captures, showing only changed values.
# Usage: bash diff-nic-counters.sh <before-dir> <after-dir> [node-short]
# Example: bash diff-nic-counters.sh nic-counters-before nic-counters-after dell-b200-1

BEFORE="${1:?Usage: $0 <before-dir> <after-dir> [node-short-filter]}"
AFTER="${2:?Usage: $0 <before-dir> <after-dir> [node-short-filter]}"
FILTER="${3:-}"

# Key counters to highlight (others still shown if changed)
KEY_COUNTERS="vport.*discard|steer_missed|cnp_sent|cnp_handled|slow_restart|adp_retrans|timeout|out_of_sequence|out_of_buffer|signal_integrity|pci_err|cc_|ecn_mark|pause"

echo "=== NIC Counter Changes: ${BEFORE} → ${AFTER} ==="
echo ""

for after_file in "${AFTER}"/*.txt; do
  fname=$(basename "$after_file")
  before_file="${BEFORE}/${fname}"

  [[ -n "$FILTER" && "$fname" != ${FILTER}* ]] && continue
  [[ ! -f "$before_file" ]] && echo "SKIP $fname (no before)" && continue

  # Extract PF name and node from filename (format: node-pf.txt)
  node_pf="${fname%.txt}"

  changes=$(diff <(sort "$before_file") <(sort "$after_file") | grep "^[<>]" | grep -v "^---")

  if [[ -n "$changes" ]]; then
    echo "--- ${node_pf} ---"
    # Show only lines where the counter value actually changed
    while IFS= read -r line; do
      counter_name=$(echo "$line" | sed 's/^[<>] *//' | awk -F: '{print $1}' | xargs)
      if echo "$counter_name" | grep -qiE "$KEY_COUNTERS"; then
        echo "  *** $line"
      else
        echo "      $line"
      fi
    done <<< "$changes"
    echo ""
  fi
done

echo "=== Done. Lines marked *** are key counters (CC, discards, errors) ==="
