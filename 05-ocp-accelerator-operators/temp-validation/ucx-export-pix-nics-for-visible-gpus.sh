#!/bin/bash
# Pure-bash PIX NIC selection + RoCEv2 GID export. No Python, no JSON, no external scripts.
# Walks /sys PCIe topology to find NICs on the same switch as visible GPUs, then picks the
# first RoCEv2 IPv4-mapped GID on each selected HCA.
#
# stdout: shell export lines (eval'd by bash-env.sh)
# stderr: [pd-pix] diagnostic logs visible in `oc logs`
#
# Pair with KSERVE_INFER_ROCE=false. Optional: KSERVE_INFER_IB_GID_INDEX_GREP (default "RoCE v2").
#
# Usage: eval "$(./ucx-export-pix-nics-for-visible-gpus.sh)"
set -euo pipefail

log() { echo "[pd-pix] $*" >&2; }
_HOST="${HOSTNAME:-$(cat /proc/sys/kernel/hostname 2>/dev/null || echo unknown)}"
log "ucx-export-pix: starting on $_HOST"

GID_GREP="${KSERVE_INFER_IB_GID_INDEX_GREP:-RoCE v2}"

# --- PCIe switch helper ---
get_pcie_switch() {
  local full_path rel_path
  full_path=$(readlink -f "/sys/bus/pci/devices/$1" 2>/dev/null) || { echo ""; return; }
  rel_path=${full_path#/sys/devices/}
  IFS='/' read -ra parts <<< "$rel_path"
  local n=${#parts[@]}
  if [ "$n" -ge 5 ]; then echo "${parts[2]}"
  elif [ "$n" -ge 4 ]; then echo "${parts[1]}"
  else echo "${parts[0]}"; fi
}

# --- GID hex to dotted IPv4 ---
gid_to_ipv4() {
  local gid="$1"
  [[ "$gid" == *ffff:* ]] || { echo "(not-ipv4)"; return; }
  local hex_tail="${gid##*ffff:}"
  hex_tail="${hex_tail//:}"
  [ ${#hex_tail} -ge 8 ] || { echo "(parse-err)"; return; }
  printf '%d.%d.%d.%d' "0x${hex_tail:0:2}" "0x${hex_tail:2:2}" "0x${hex_tail:4:2}" "0x${hex_tail:6:2}"
}

# --- 1) Discover GPU BDFs and their PCIe switches ---
if ! command -v nvidia-smi >/dev/null 2>&1; then
  log "ERROR: nvidia-smi not found"; exit 1
fi

gpu_bdfs=()
gpu_switches=()
while IFS= read -r line; do
  local_bdf=$(echo "$line" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
  local_bdf=$(echo "$local_bdf" | sed 's/^00000000:/0000:/')
  gpu_bdfs+=("$local_bdf")
  gpu_switches+=("$(get_pcie_switch "$local_bdf")")
done < <(nvidia-smi --query-gpu=pci.bus_id --format=csv,noheader 2>/dev/null)

n_gpu=${#gpu_bdfs[@]}
if [ "$n_gpu" -eq 0 ]; then
  log "ERROR: no GPUs visible"; exit 1
fi
log "visible GPUs: $n_gpu"
for ((i=0; i<n_gpu; i++)); do
  log "  GPU $i  bdf=${gpu_bdfs[$i]}  switch=${gpu_switches[$i]}"
done

# --- 2) Discover RDMA HCAs and their PCIe switches ---
declare -a hca_names=() hca_switches=()
for rd in /sys/class/infiniband/*; do
  [ -d "$rd" ] || continue
  local_name=$(basename "$rd")
  local_pci=$(basename "$(readlink -f "$rd/device" 2>/dev/null)") || continue
  local_sw=$(get_pcie_switch "$local_pci")
  hca_names+=("$local_name")
  hca_switches+=("$local_sw")
  log "  HCA $local_name  bdf=$local_pci  switch=$local_sw"
done

# --- 3) Match: one HCA per GPU (same PCIe switch = PIX) ---
ucx_devs=""
nccl_hcas=""
used_hcas=""
for ((g=0; g<n_gpu; g++)); do
  matched=""
  for ((h=0; h<${#hca_names[@]}; h++)); do
    if [ "${hca_switches[$h]}" = "${gpu_switches[$g]}" ]; then
      case ",$used_hcas," in *,${hca_names[$h]},*) continue ;; esac
      matched="${hca_names[$h]}"
      used_hcas="${used_hcas:+$used_hcas,}$matched"
      break
    fi
  done
  if [ -n "$matched" ]; then
    log "GPU $g -> PIX match: $matched"
    ucx_devs="${ucx_devs:+$ucx_devs,}${matched}:1"
    nccl_hcas="${nccl_hcas:+$nccl_hcas,}${matched}"
  else
    log "WARN: GPU $g -> no PIX NIC found (switch=${gpu_switches[$g]})"
  fi
done

if [ -z "$ucx_devs" ]; then
  log "ERROR: no PIX-matched HCAs"; exit 1
fi

echo "export UCX_NET_DEVICES=$ucx_devs"
echo "export NCCL_IB_HCA=$nccl_hcas"
echo "export NVSHMEM_HCA_LIST=$ucx_devs"

# --- 4) Find best RoCEv2 IPv4-mapped GID index ---
if [ -z "${NCCL_IB_GID_INDEX:-}" ]; then
  best_idx=""
  IFS=',' read -ra hca_arr <<< "$nccl_hcas"
  for hca in "${hca_arr[@]}"; do
    base="/sys/class/infiniband/$hca/ports/1"
    found_idx=""
    for tpath in "$base"/gid_attrs/types/*; do
      [ -f "$tpath" ] || continue
      gtype=$(cat "$tpath" 2>/dev/null) || continue
      [[ "$gtype" == *${GID_GREP}* ]] || continue
      idx=$(basename "$tpath")
      gval=$(cat "$base/gids/$idx" 2>/dev/null) || continue
      if [[ "$gval" == *ffff:* ]]; then
        found_idx="$idx"
        ipv4=$(gid_to_ipv4 "$gval")
        log "GID scan: $hca idx=$idx type=[$gtype] raw=[$gval] -> IPv4=$ipv4"
        break
      fi
    done
    if [ -z "$found_idx" ]; then
      log "GID scan: $hca -> NO RoCEv2 IPv4 GID (grep=$GID_GREP)"
    fi
    if [ -n "$found_idx" ] && [ -z "$best_idx" ]; then
      best_idx="$found_idx"
    fi
  done

  if [ -z "$best_idx" ]; then
    log "ERROR: no RoCE v2 IPv4 GID on any PIX HCA"; exit 1
  fi
  echo "export NCCL_IB_GID_INDEX=$best_idx"
  echo "export NVSHMEM_IB_GID_INDEX=$best_idx"
  echo "export UCX_IB_GID_INDEX=$best_idx"
else
  best_idx="$NCCL_IB_GID_INDEX"
fi

# --- 5) Final verification ---
log "RESULT: host=$_HOST UCX_NET_DEVICES=$ucx_devs NCCL_IB_HCA=$nccl_hcas gid_index=$best_idx"
IFS=',' read -ra hca_arr <<< "$nccl_hcas"
for hca in "${hca_arr[@]}"; do
  base="/sys/class/infiniband/$hca/ports/1"
  gval=$(cat "$base/gids/$best_idx" 2>/dev/null) || gval="(read-error)"
  gtype=$(cat "$base/gid_attrs/types/$best_idx" 2>/dev/null) || gtype="(read-error)"
  ipv4=$(gid_to_ipv4 "$gval")
  log "VERIFY: $hca port=1 gid[$best_idx] type=[$gtype] raw=[$gval] -> IPv4=$ipv4"
done
