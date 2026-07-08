#!/usr/bin/env bash
# =============================================================================
# stress_cache_warmup.sh
# -----------------------------------------------------------------------------
# @brief  Corner Case 1 - Cache Cold-Start Warm-Up Curve.
#
# @note   BMC is a demand-populated cache: entries are written into map_kcache
#         only after the TC egress hook captures a Memcached response. At t=0
#         the cache is completely cold. This script samples the BMC hit rate
#         every SAMPLE_INTERVAL seconds for TOTAL_DURATION seconds and records
#         the time-series so the warm-up trajectory can be plotted.
#
# @note   Assumption targeted: The paper never specifies a warm-up protocol or
#         acknowledges cold-start measurement bias. Under short benchmarks on
#         a large working set, the cache may never fully warm, making results
#         equivalent to MemcachedSR.
#
# Usage:
#   ./stress_cache_warmup.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]
#
# Options:
#   -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
#   -C <client_host>  SSH hostname of the Client node. REQUIRED.
#   -i <iface>        Experiment interface name on the SUT. REQUIRED.
#   -u <ssh_user>     SSH username. (default: olleg)
#   -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
#   -o <local_out>    Local results directory. (default: ./results/stress/cache_warmup)
#   -z <zipf_alpha>   Zipfian alpha. (default: 0.99)
#   -K <keys>         Working set size in number of keys. (default: 100000)
#   -T <total_dur>    Total observation window in seconds. (default: 120)
#   -I <interval>     Hit-rate sampling interval in seconds. (default: 5)
#   -h, --help        Print this help and exit.
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/stress/cache_warmup"

TOTAL_DURATION=120
SAMPLE_INTERVAL=5
MC_PORT=11211
MC_MEMORY_MB=4096
ZIPF_ALPHA="0.99"
KEY_COUNT=100000
THREADS=4

usage() {
    echo "Usage: $0 -S <sut_host> -C <client_host> -i <iface> [OPTIONS]"
    echo "Corner Case 1: Cold-start cache warm-up curve measurement."
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
        -z) ZIPF_ALPHA="$2"; shift 2 ;;
        -K) KEY_COUNT="$2"; shift 2 ;;
        -T) TOTAL_DURATION="$2"; shift 2 ;;
        -I) SAMPLE_INTERVAL="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S <sut_host>, -C <client_host>, and -i <iface> are required."
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

log "Copying setup scripts to SUT and client..."
scp_to_sut "${SCRIPT_DIR}/server_setup.sh"       "${REMOTE_DIR}/server_setup.sh"
scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh ${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "mkdir -p ${REMOTE_DIR}/results"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}/results"
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SCRIPT_DIR}/client_run.sh" "${SSH_USER}@${CLIENT_HOST}:${REMOTE_DIR}/client_run.sh"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" "chmod +x ${REMOTE_DIR}/client_run.sh"

SUT_EXP_IP=$(get_sut_exp_ip)
log "SUT experiment IP: ${SUT_EXP_IP}"

##
# @brief Run the warm-up experiment for one server mode.
# @param $1  Mode string: "bmc" or "nobmc".
##
run_warmup() {
    local MODE="$1"
    local SERVER_TOTAL_DURATION=$(( TOTAL_DURATION + 15 ))
    local TAG="warmup_${MODE}"

    log "====== Starting: ${TAG} ======"

    if [[ "${MODE}" == "bmc" ]]; then
        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup.sh \
            -i ${IFACE} -t ${THREADS} -p ${MC_PORT} \
            -d ${SERVER_TOTAL_DURATION} -m ${MC_MEMORY_MB} \
            -b ~/bmc-cache/bmc -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_DIR}/results" &
        local SUT_JOB=$!
        sleep 8
    else
        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup_nobmc.sh \
            -i ${IFACE} -t ${THREADS} -p ${MC_PORT} \
            -d ${SERVER_TOTAL_DURATION} -m ${MC_MEMORY_MB} \
            -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_DIR}/results" &
        local SUT_JOB=$!
        sleep 3
    fi

    # Launch client with NO pre-warm phase (cold start intentional).
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "bash ${REMOTE_DIR}/client_run.sh \
            -s ${SUT_EXP_IP} -p ${MC_PORT} \
            -t ${THREADS} -c 128 -d ${TOTAL_DURATION} \
            -k ${KEY_COUNT} -z ${ZIPF_ALPHA} -r 0.95 -v 64 \
            -o ${REMOTE_DIR}/results \
            -g ${TAG}_${CLIENT_HOST} \
            --udp" &
    local CLI_JOB=$!

    # Sampling loop for BMC: record hit-rate time series.
    local TIMESERIES_CSV="${LOCAL_OUT}/timeseries_${TAG}.csv"
    echo "elapsed_s,hit_count,miss_count,hit_rate,get_recv_count" > "${TIMESERIES_CSV}"

    if [[ "${MODE}" == "bmc" ]]; then
        local ELAPSED=0
        while (( ELAPSED < TOTAL_DURATION )); do
            sleep "${SAMPLE_INTERVAL}"
            ELAPSED=$(( ELAPSED + SAMPLE_INTERVAL ))
            local STATS
            STATS=$(ssh_sut "cat /tmp/bmc_live_stats.txt 2>/dev/null || echo ''")
            local HITS MISSES RECV HIT_RATE
            HITS=$(echo "${STATS}"   | grep -i 'hit_count'      | awk '{print $NF}' || echo 0)
            MISSES=$(echo "${STATS}" | grep -i 'miss_count'     | awk '{print $NF}' || echo 0)
            RECV=$(echo "${STATS}"   | grep -i 'get_recv_count' | awk '{print $NF}' || echo 0)
            HITS="${HITS:-0}"; MISSES="${MISSES:-0}"; RECV="${RECV:-0}"
            if (( HITS + MISSES > 0 )); then
                HIT_RATE=$(awk "BEGIN {printf \"%.4f\", ${HITS} / (${HITS} + ${MISSES})}")
            else
                HIT_RATE="0.0000"
            fi
            log "t=${ELAPSED}s  hits=${HITS}  misses=${MISSES}  hit_rate=${HIT_RATE}"
            echo "${ELAPSED},${HITS},${MISSES},${HIT_RATE},${RECV}" >> "${TIMESERIES_CSV}"
        done
    else
        sleep "${TOTAL_DURATION}"
    fi

    wait "${CLI_JOB}" || log "WARNING: client job exited non-zero."
    wait "${SUT_JOB}" || log "WARNING: server job exited non-zero."

    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
        "${SSH_USER}@${CLIENT_HOST}:${REMOTE_DIR}/results/raw_${TAG}_${CLIENT_HOST}.txt" \
        "${LOCAL_OUT}/" 2>/dev/null || true

    log "====== ${TAG} complete ======"
}

log "====== CORNER CASE 1: Cache Cold-Start Warm-Up Curve ======"
log "Keys: ${KEY_COUNT}  Zipf: ${ZIPF_ALPHA}  Window: ${TOTAL_DURATION}s  Interval: ${SAMPLE_INTERVAL}s"

run_warmup "nobmc"
sleep 10
run_warmup "bmc"

log "====== Warm-up sweep complete. Results in ${LOCAL_OUT}/ ======"
ls -lh "${LOCAL_OUT}/"

# ---------------------------------------------------------------------------
# Generate plots from collected results.
# ---------------------------------------------------------------------------
SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 &>/dev/null; then
    log "Generating plots with plot_cache_warmup.py..."
    cd "$(dirname "${LOCAL_OUT}")/../../.." 2>/dev/null || cd .
    python3 "${SCRIPT_SELF}/plot_cache_warmup.py" || log "WARNING: plot generation failed."
fi
