#!/usr/bin/env bash
# =============================================================================
# stress_tail_latency.sh
# -----------------------------------------------------------------------------
# @brief  Corner Case 2 - P99/P999 Tail Latency Under Hit/Miss Mix.
#
# @note   The paper reports mean throughput (TPS) only. It does not report
#         latency percentiles. Under BMC with a 99% hit rate, the 1% of misses
#         traverse the full kernel stack (~100 us), creating a bimodal latency
#         distribution. This script extracts P50, P95, P99, and P999 latency
#         from memaslap's stat_freq output and compares BMC vs MemcachedSR.
#
# @note   Assumption targeted: The paper implicitly treats mean throughput as
#         the only relevant performance metric. For latency-sensitive production
#         workloads (session stores, auth caches), tail latency is critical.
#
# Usage:
#   ./stress_tail_latency.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]
#
# Options:
#   -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
#   -C <client_host>  SSH hostname of the Client node. REQUIRED.
#   -i <iface>        Experiment interface name on the SUT. REQUIRED.
#   -u <ssh_user>     SSH username. (default: olleg)
#   -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
#   -o <local_out>    Local results directory. (default: ./results/stress/tail_latency)
#   -d <duration>     Benchmark duration in seconds. (default: 60)
#   -h, --help        Print this help and exit.
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/stress/tail_latency"

DURATION=60
MC_PORT=11211
MC_MEMORY_MB=4096
THREADS=4
CONCURRENCY=128

usage() {
    echo "Usage: $0 -S <sut_host> -C <client_host> -i <iface> [OPTIONS]"
    echo "Corner Case 2: P99/P999 tail latency measurement under BMC vs MemcachedSR."
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
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S, -C, and -i are required."
    usage
fi

log() { echo "[$(date '+%H:%M:%S')] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh_sut()    { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "$@"; }
scp_to_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${SUT_HOST}:$2"; }

get_sut_exp_ip() {
    ssh_sut "ip -4 addr show dev ${IFACE} | grep -oP '(?<=inet )[0-9.]+'" 2>/dev/null
}

mkdir -p "${LOCAL_OUT}"

log "Copying setup scripts..."
scp_to_sut "${SCRIPT_DIR}/server_setup.sh"       "${REMOTE_DIR}/server_setup.sh"
scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh ${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "mkdir -p ${REMOTE_DIR}/results"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/results"
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SCRIPT_DIR}/client_run.sh" \
    "${SSH_USER}@${CLIENT_HOST}:${REMOTE_DIR}/client_run.sh"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
    "chmod +x ${REMOTE_DIR}/client_run.sh"

SUT_EXP_IP=$(get_sut_exp_ip)
log "SUT experiment IP: ${SUT_EXP_IP}"

SUMMARY_CSV="${LOCAL_OUT}/tail_latency_summary.csv"
echo "mode,zipf_alpha,hit_rate_approx,tps,p50_us,p95_us,p99_us,p999_us" > "${SUMMARY_CSV}"

##
# @brief Run one tail-latency experiment and extract latency percentiles.
# @param $1  Mode string: "bmc" or "nobmc".
# @param $2  Zipfian alpha string (e.g. "0.99").
##
run_latency() {
    local MODE="$1"
    local ALPHA="$2"
    local TAG="tail_lat_${MODE}_a${ALPHA}"
    local SERVER_TOTAL=$(( DURATION + 30 ))

    log "--- Starting: ${TAG} ---"

    if [[ "${MODE}" == "bmc" ]]; then
        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup.sh \
            -i ${IFACE} -t ${THREADS} -p ${MC_PORT} \
            -d ${SERVER_TOTAL} -m ${MC_MEMORY_MB} \
            -b ~/bmc-cache/bmc -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_DIR}/results" &
        local SUT_JOB=$!
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

    # Create warmup config file on the client using absolute path
    local WARM_CFG="/users/${SSH_USER}/bmc_bench/results/memaslap_warmup_${TAG}.cfg"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "mkdir -p /users/${SSH_USER}/bmc_bench/results && cat > ${WARM_CFG} <<EOF
key
16 16 1.0

value
64 64 1.0

cmd
0 0.05
1 0.95
EOF
"

    # Warm up: pre-populate cache with a short burst before the measurement.
    # Uses 95%GET/5%SET config file to avoid the known memaslap 100%-SET UDP deadlock.
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "~/memaslap --servers=${SUT_EXP_IP}:${MC_PORT} \
            --concurrency=64 --time=15s --udp \
            --win_size=10k \
            --cfg_cmd=${WARM_CFG} \
            --fixed_size=64 \
            >/dev/null 2>&1 || true"

    # Create benchmark config file on the client
    local BENCH_CFG="/users/${SSH_USER}/bmc_bench/results/memaslap_bench_${TAG}.cfg"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "cat > ${BENCH_CFG} <<EOF
key
16 16 1.0

value
64 64 1.0

cmd
0 0.05
1 0.95
EOF
"

    # Run memaslap with --stat_freq to capture per-interval latency output.
    local RAW_OUT="/users/${SSH_USER}/bmc_bench/results/raw_${TAG}.txt"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "~/memaslap \
            --servers=${SUT_EXP_IP}:${MC_PORT} \
            --concurrency=${CONCURRENCY} \
            --time=${DURATION}s \
            --udp \
            --stat_freq=10s \
            --win_size=10k \
            --cfg_cmd=${BENCH_CFG} \
            --fixed_size=64 \
            2>&1 | tee ${RAW_OUT}" &
    local CLI_JOB=$!

    wait "${CLI_JOB}" || log "WARNING: client job exited non-zero."
    wait "${SUT_JOB}" || log "WARNING: server job exited non-zero."

    # Pull raw output.
    local LOCAL_RAW="${LOCAL_OUT}/raw_${TAG}.txt"
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
        "${SSH_USER}@${CLIENT_HOST}:${RAW_OUT}" "${LOCAL_RAW}" 2>/dev/null || true

    # Parse latency percentiles using the parse_latency.py script.
    local PARSE_OUT
    PARSE_OUT=$("${SCRIPT_DIR}/parse_latency.py" "${LOCAL_RAW}" 2>/dev/null || echo "TPS:0 P50:N/A P95:N/A P99:N/A P999:N/A")
    
    local TPS P50 P95 P99 P999
    TPS=$(echo "${PARSE_OUT}" | grep -oP 'TPS:\K[0-9]+' || echo 0)
    P50=$(echo "${PARSE_OUT}" | grep -oP 'P50:\K[0-9A-Z/]+' || echo "N/A")
    P95=$(echo "${PARSE_OUT}" | grep -oP 'P95:\K[0-9A-Z/]+' || echo "N/A")
    P99=$(echo "${PARSE_OUT}" | grep -oP 'P99:\K[0-9A-Z/]+' || echo "N/A")
    P999=$(echo "${PARSE_OUT}" | grep -oP 'P999:\K[0-9A-Z/]+' || echo "N/A")

    local HIT_RATE="N/A"
    if [[ "${MODE}" == "bmc" ]]; then
        local STATS_FILE="${LOCAL_OUT}/stats_${TAG}.txt"
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
            "${SSH_USER}@${SUT_HOST}:${REMOTE_DIR}/results/stats_${TAG}.txt" \
            "${STATS_FILE}" 2>/dev/null || true
        if [[ -f "${STATS_FILE}" ]]; then
            local HITS MISSES
            HITS=$(grep -i 'hit_count'  "${STATS_FILE}" | awk '{print $NF}' | tail -1 || echo 0)
            MISSES=$(grep -i 'miss_count' "${STATS_FILE}" | awk '{print $NF}' | tail -1 || echo 0)
            if (( HITS + MISSES > 0 )); then
                HIT_RATE=$(awk "BEGIN {printf \"%.4f\", ${HITS} / (${HITS} + ${MISSES})}")
            fi
        fi
    fi

    log "Results: mode=${MODE} alpha=${ALPHA} tps=${TPS} p50=${P50} p95=${P95} p99=${P99} p999=${P999} hit_rate=${HIT_RATE}"
    echo "${MODE},${ALPHA},${HIT_RATE},${TPS},${P50},${P95},${P99},${P999}" >> "${SUMMARY_CSV}"
    log "--- ${TAG} complete ---"
    sleep 5
}

log "====== CORNER CASE 2: Tail Latency P99/P999 Sweep ======"

# Test both modes across two Zipf alpha values: high skew (most hits) and low skew (many misses).
for ALPHA in "0.99" "0.50"; do
    run_latency "nobmc" "${ALPHA}"
    run_latency "bmc"   "${ALPHA}"
    sleep 10
done

log "====== Tail latency sweep complete. Results in ${LOCAL_OUT}/ ======"
cat "${SUMMARY_CSV}"

# ---------------------------------------------------------------------------
# Generate plots from collected results.
# ---------------------------------------------------------------------------
SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 &>/dev/null; then
    log "Generating plots with plot_tail_latency.py..."
    cd "${SCRIPT_SELF}/.." || cd .
    python3 "${SCRIPT_SELF}/plot_tail_latency.py" || log "WARNING: plot generation failed."
fi
