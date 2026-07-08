#!/usr/bin/env bash
# =============================================================================
# stress_spinlock_scaling.sh
# -----------------------------------------------------------------------------
# @brief  Corner Case 5 - BPF Spinlock Contention vs. Core Count Under Hot Skew.
#
# @note   map_kcache uses a per-slot bpf_spin_lock. Under extreme Zipfian skew
#         (alpha=1.2) with a small working set (10k keys), the top-10 keys
#         receive ~90% of all requests. With N CPU cores each running an XDP
#         program that simultaneously tries to acquire the spinlock on the same
#         slot, contention grows. This test sweeps core count from 1 to 8
#         under alpha=1.2 and measures whether BMC continues to scale linearly.
#
# @note   OPEN-LOOP DESIGN: This script uses trafgen (raw packet injection)
#         instead of memaslap. Under closed-loop, RTT bounds prevent the NIC
#         queues from being fully saturated, making spinlock contention invisible.
#         Only under wire-speed open-loop load can per-entry bpf_spin_lock
#         contention across parallel NIC queues be measured accurately.
#         Throughput is measured server-side (BMC hit_count or Memcached cmd_get
#         delta), not client-side, consistent with trafgen methodology.
#
# @note   Assumption targeted: The paper implicitly claims BMC scales linearly
#         with core count. Under extreme hot-key skew, the bpf_spin_lock
#         becomes a serialization bottleneck that caps BMC throughput below
#         MemcachedSR, which uses lock-free per-queue processing.
#
# Usage:
#   ./stress_spinlock_scaling.sh -S <sut_host> -C "<client_hosts>" -i <iface> [OPTIONS]
#
# Options:
#   -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
#   -C <client_hosts> Space-separated SSH hostnames of client nodes. REQUIRED.
#   -i <iface>        Experiment interface name on the SUT. REQUIRED.
#   -u <ssh_user>     SSH username. (default: olleg)
#   -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
#   -o <local_out>    Local results directory. (default: ./results/stress/spinlock_scaling)
#   -d <duration>     Benchmark duration in seconds. (default: 30)
#   -r <rate>         Trafgen injection rate per client (e.g. 500k, 1m, max). (default: max)
#   -h, --help        Print this help and exit.
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/stress/spinlock_scaling"

DURATION=30
MC_PORT=11211
MC_MEMORY_MB=4096
PPS_RATE="max"

# Core sweep: 1, 2, 4, 8.
CORE_COUNTS=(1 2 4 8)

usage() {
    echo "Usage: $0 -S <sut_host> -C \"<client_hosts>\" -i <iface> [OPTIONS]"
    echo "Corner Case 5 (open-loop): BPF spinlock contention vs. core count under extreme hot-key flood."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S) SUT_HOST="$2"; shift 2 ;;
        -C) CLIENT_HOST="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -u) SSH_USER="$2"; shift 2 ;;
        -k) SSH_KEY="$2"; shift 2 ;;
        -o) LOCAL_OUT="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -r) PPS_RATE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S, -C, and -i are required."
    usage
fi

read -r -a CLIENT_ARRAY <<< "${CLIENT_HOST}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh_sut()    { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "$@"; }
scp_to_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${SUT_HOST}:$2"; }

get_sut_exp_ip() {
    ssh_sut "ip -4 addr show dev ${IFACE} | grep -oP '(?<=inet )[0-9.]+'" 2>/dev/null
}

##
# @brief Query the Memcached cmd_get counter on the SUT via the loopback TCP port.
# @return Integer count of GET commands processed since startup.
##
get_sut_cmd_get() {
    ssh_sut "echo 'stats' | nc -w 1 localhost ${MC_PORT} | grep 'cmd_get' | awk '{print \$3}' | tr -d '\r'" 2>/dev/null || echo 0
}

mkdir -p "${LOCAL_OUT}"

# ---------------------------------------------------------------------------
# Setup: copy scripts to SUT and all clients, install trafgen if needed
# ---------------------------------------------------------------------------
log "Copying setup scripts to SUT..."
scp_to_sut "${SCRIPT_DIR}/server_setup.sh"       "${REMOTE_DIR}/server_setup.sh"
scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh ${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "mkdir -p ${REMOTE_DIR}/results"

log "Checking and installing trafgen on clients..."
for CLI in "${CLIENT_ARRAY[@]}"; do
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" \
        "which trafgen >/dev/null 2>&1 || (sudo apt-get update && sudo apt-get install -y netsniff-ng)"
done

# Distribute trafgen config files: client 1 uses trafgen_c1.cfg, client 2 uses trafgen_c2.cfg
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SCRIPT_DIR}/trafgen_c1.cfg" "${SSH_USER}@${CLIENT_ARRAY[0]}:~/trafgen.cfg"
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
        "${SCRIPT_DIR}/trafgen_c2.cfg" "${SSH_USER}@${CLIENT_ARRAY[1]}:~/trafgen.cfg"
fi
# Copy the warm-up script (TCP-based memaslap warm-up to populate map_kcache before flood)
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    "${SCRIPT_DIR}/trafgen_warmup.py" "${SSH_USER}@${CLIENT_ARRAY[0]}:~/trafgen_warmup.py"

SUT_EXP_IP=$(get_sut_exp_ip)
log "SUT experiment IP: ${SUT_EXP_IP}"

# trafgen rate flag
RATE_ARG=""
if [[ "${PPS_RATE}" == "500k" ]]; then
    RATE_ARG="--rate 500000pps"
elif [[ "${PPS_RATE}" == "1m" ]]; then
    RATE_ARG="--rate 1000000pps"
elif [[ "${PPS_RATE}" != "max" ]]; then
    RATE_ARG="--rate ${PPS_RATE}"
fi

SUMMARY_CSV="${LOCAL_OUT}/spinlock_scaling_summary.csv"
echo "mode,threads,pps_rate,duration_s,processed_ops,tps,tps_per_core,hit_rate" > "${SUMMARY_CSV}"

##
# @brief Run one open-loop core-scaling data point using trafgen.
# @param $1  Mode: "bmc" or "nobmc".
# @param $2  Thread / core count.
# @note  Throughput is measured server-side: for BMC as the hit_count reported
#        in /tmp/bmc_stats.txt; for NoBMC as the cmd_get counter delta.
##
run_core_point() {
    local MODE="$1"
    local THREADS="$2"
    local TAG="spinlock_${MODE}_t${THREADS}"
    local SERVER_TOTAL=$(( DURATION + 30 ))

    log "--- Starting: ${TAG} (mode=${MODE} threads=${THREADS} rate=${PPS_RATE}) ---"

    # Start the server in the background
    if [[ "${MODE}" == "bmc" ]]; then
        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup.sh \
            -i ${IFACE} -t ${THREADS} -p ${MC_PORT} \
            -d ${SERVER_TOTAL} -m ${MC_MEMORY_MB} \
            -b ~/bmc-cache/bmc -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_DIR}/results" &
        local SUT_JOB=$!
        log "Waiting 8 seconds for BMC to load and pin eBPF programs..."
        sleep 8
    else
        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup_nobmc.sh \
            -i ${IFACE} -t ${THREADS} -p ${MC_PORT} \
            -d ${SERVER_TOTAL} -m ${MC_MEMORY_MB} \
            -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_DIR}/results" &
        local SUT_JOB=$!
        sleep 3
    fi

    # Warm up the cache via TCP memaslap so map_kcache is populated before flood
    log "Warming up map_kcache via TCP (trafgen_warmup.py)..."
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_ARRAY[0]}" \
        "python3 ~/trafgen_warmup.py ${SUT_EXP_IP}" || log "WARNING: warm-up returned non-zero."

    # Snapshot cmd_get before flood (for NoBMC throughput measurement)
    local CMD_GET_BEFORE
    CMD_GET_BEFORE=$(get_sut_cmd_get)
    log "cmd_get before flood: ${CMD_GET_BEFORE}"

    # Launch trafgen flood on all clients in parallel
    log "Launching trafgen flood. Rate=${PPS_RATE}, Duration=${DURATION}s..."
    local CLI_PIDS=()
    for CLI in "${CLIENT_ARRAY[@]}"; do
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" \
            "sudo trafgen --dev ${IFACE} --conf ~/trafgen.cfg ${RATE_ARG} >/dev/null 2>&1" &
        CLI_PIDS+=($!)
    done

    sleep "${DURATION}"

    # Stop trafgen on all clients
    for CLI in "${CLIENT_ARRAY[@]}"; do
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" \
            "sudo killall -2 trafgen 2>/dev/null || true"
    done
    for PID in "${CLI_PIDS[@]}"; do
        wait "${PID}" || true
    done

    # Snapshot cmd_get after flood
    local CMD_GET_AFTER
    CMD_GET_AFTER=$(get_sut_cmd_get)
    log "cmd_get after flood: ${CMD_GET_AFTER}"

    # Tear down server
    if [[ "${MODE}" == "bmc" ]]; then
        ssh_sut "sudo killall -2 bmc 2>/dev/null || true"
        sleep 3
    fi
    ssh_sut "sudo killall -9 memcached 2>/dev/null || true"
    kill "${SUT_JOB}" 2>/dev/null || true

    # Parse throughput
    local HITS_PROCESSED=0
    local HIT_RATE="N/A"

    if [[ "${MODE}" == "bmc" ]]; then
        # Pull BMC stats file for hit_count
        local STATS_FILE="${LOCAL_OUT}/stats_${TAG}.txt"
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
            "${SSH_USER}@${SUT_HOST}:/tmp/bmc_stats.txt" "${STATS_FILE}" 2>/dev/null || true
        if [[ -f "${STATS_FILE}" ]]; then
            HITS_PROCESSED=$(grep "hit_count" "${STATS_FILE}" | awk '{print $3}' || echo 0)
            local MISSES
            MISSES=$(grep "miss_count" "${STATS_FILE}" | awk '{print $3}' || echo 0)
            if (( HITS_PROCESSED + MISSES > 0 )); then
                HIT_RATE=$(awk "BEGIN {printf \"%.4f\", ${HITS_PROCESSED} / (${HITS_PROCESSED} + ${MISSES})}")
            fi
        fi
    else
        HITS_PROCESSED=$(( CMD_GET_AFTER - CMD_GET_BEFORE ))
    fi

    local TPS=0
    if [[ "${HITS_PROCESSED}" -gt 0 ]] 2>/dev/null; then
        TPS=$(echo "${HITS_PROCESSED} / ${DURATION}" | bc)
    fi

    local TPS_PER_CORE=0
    if [[ "${THREADS}" -gt 0 && "${TPS}" -gt 0 ]] 2>/dev/null; then
        TPS_PER_CORE=$(awk "BEGIN {printf \"%.0f\", ${TPS}/${THREADS}}")
    fi

    log "Result: mode=${MODE} threads=${THREADS} tps=${TPS} tps_per_core=${TPS_PER_CORE} hit_rate=${HIT_RATE}"
    echo "${MODE},${THREADS},${PPS_RATE},${DURATION},${HITS_PROCESSED},${TPS},${TPS_PER_CORE},${HIT_RATE}" >> "${SUMMARY_CSV}"
    log "--- ${TAG} complete ---"
    sleep 5
}

log "====== CORNER CASE 5 (Open-Loop): BPF Spinlock Contention vs. Core Count ======"
log "Workload: rate=${PPS_RATE}  cores_sweep=(${CORE_COUNTS[*]})"
log "Expected: MemcachedSR scales linearly. BMC plateaus at high core counts"
log "          due to bpf_spin_lock contention on hot keys under wire-speed flood."

for MODE in "nobmc" "bmc"; do
    log "--- Mode: ${MODE} ---"
    for THREADS in "${CORE_COUNTS[@]}"; do
        run_core_point "${MODE}" "${THREADS}"
    done
    sleep 10
done

log "====== Spinlock scaling sweep complete. Results in ${LOCAL_OUT}/ ======"
cat "${SUMMARY_CSV}"

# ---------------------------------------------------------------------------
# Generate plots from collected results.
# ---------------------------------------------------------------------------
SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 &>/dev/null; then
    log "Generating plots with plot_spinlock_scaling.py..."
    cd "${SCRIPT_SELF}/.." || cd .
    python3 "${SCRIPT_SELF}/plot_spinlock_scaling.py" || log "WARNING: plot generation failed."
fi
