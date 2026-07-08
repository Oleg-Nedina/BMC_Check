#!/usr/bin/env bash
# =============================================================================
# stress_hot_invalidation.sh
# -----------------------------------------------------------------------------
# @brief  Stress BMC by generating a write pattern that targets only the hottest
#         keys in a Zipfian distribution, simulating repeated invalidation of
#         the most cache-warm entries.
#
# @note   This script targets the implicit assumption that SET operations target
#         a uniformly random subset of keys. In production, hot keys (e.g.,
#         session tokens, counters, rate limiters) are often written frequently.
#         Repeated invalidation of the BMC's most-used cache slots via
#         BMC_PROG_XDP_INVALIDATE_CACHE forces constant re-population via the
#         TC egress hook, increasing both CPU and memory bus overhead.
#
# @note   Assumption targeted: "Write operations are uniformly distributed
#         across the key space and do not disproportionately target hot keys."
#
# @note   Implementation note: memaslap does not support targeting a specific
#         hot key subset for writes while using a different distribution for
#         reads. This script approximates the scenario by reducing the working
#         set window size for mixed-workload runs to concentrate writes on a
#         small, highly contested set of keys.
#
# Usage:
#   ./stress_hot_invalidation.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/stress/hot_invalidation"

DURATION=30
MC_PORT=11211
MC_MEMORY_MB=4096

##
# @brief Experiment matrix:
#   - GET_RATIO: fraction of operations that are GETs (rest are SETs).
#   - KEY_COUNT: working set size. Smaller values concentrate writes on fewer keys.
##
declare -a GET_RATIOS=("0.90" "0.80" "0.70" "0.50")
declare -a KEY_COUNTS=(1000 5000 20000 100000)

##
# @brief Print usage and exit.
##
usage() {
    cat <<EOF
=============================================================================
stress_hot_invalidation.sh -- Hot Key Write Invalidation Stress Test
=============================================================================

DESCRIPTION
    Measures BMC performance degradation when write operations are concentrated
    on a small set of hot keys (small working set + mixed GET/SET ratio).
    This simulates a production scenario where frequently updated keys (e.g.,
    session data, rate-limit counters) are repeatedly invalidated in the
    in-kernel cache, forcing constant re-population via the TC egress hook.

USAGE
    ./stress_hot_invalidation.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]

OPTIONS
    -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
    -C <client_host>  SSH hostname of the Client node. REQUIRED.
    -i <iface>        Experiment interface name on the SUT. REQUIRED.
    -u <ssh_user>     SSH username. (default: olleg)
    -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
    -o <local_out>    Local results directory. (default: ./results)
    -h, --help        Print this help and exit.

EXPERIMENT MATRIX
    GET ratios: 90%, 80%, 70%, 50%.
    Key counts: 1k, 5k, 20k, 100k (smaller = more concentrated writes on hot keys).
    All runs at 4 threads, 64B values, Zipf alpha 0.99.
    Each combination runs once with BMC and once without.

NOTE
    This test is a behavioral approximation. memaslap does not natively support
    a split distribution (Zipfian reads, hot-key-targeted writes). The small
    working set window concentrates both reads and writes on the same hot keys,
    which is a conservative approximation of the target scenario.
=============================================================================
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -S) SUT_HOST="$2"; shift 2 ;;
        -C) CLIENT_HOST="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -u) SSH_USER="$2"; shift 2 ;;
        -k) SSH_KEY="$2"; shift 2 ;;
        -o) LOCAL_OUT="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S <sut_host>, -C <client_host>, and -i <iface> are required."
    usage
fi

# Parse client hosts into an array for parallel multi-client execution
read -r -a CLIENT_ARRAY <<< "${CLIENT_HOST}"


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh_sut()    { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "$@"; }
ssh_client() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" "$@"; }
scp_to_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${SUT_HOST}:$2"; }
scp_to_cli() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${CLIENT_HOST}:$2"; }
scp_from_cli() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}:$1" "$2"; }
scp_from_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}:$1" "$2"; }

get_sut_exp_ip() {
    ssh_sut "ip -4 addr show dev ${IFACE} | grep -oP '(?<=inet )[0-9.]+'" 2>/dev/null \
        || { echo "[ERROR] Cannot determine SUT experiment IP on ${IFACE}."; exit 1; }
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
log "Setting up SUT remote directory..."
ssh_sut "mkdir -p ${REMOTE_DIR}/results"

scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
scp_to_sut "${SCRIPT_DIR}/server_setup.sh"       "${REMOTE_DIR}/server_setup.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup_nobmc.sh ${REMOTE_DIR}/server_setup.sh"

for CLI in "${CLIENT_ARRAY[@]}"; do
    log "Setting up client ${CLI} remote directory..."
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "mkdir -p ${REMOTE_DIR}/results"
    log "Copying client_run.sh to client ${CLI}..."
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SCRIPT_DIR}/client_run.sh" "${SSH_USER}@${CLI}:${REMOTE_DIR}/client_run.sh"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "chmod +x ${REMOTE_DIR}/client_run.sh"
done


mkdir -p "${LOCAL_OUT}"
SUT_EXP_IP=$(get_sut_exp_ip)
log "SUT experiment IP: ${SUT_EXP_IP}"

# ---------------------------------------------------------------------------
##
# @brief Run one experiment pair (BMC and No-BMC) for a given ratio and key count.
# @param $1  GET ratio (e.g., 0.90).
# @param $2  Working set key count.
##
run_pair() {
    local GET_RATIO="$1"
    local KEY_COUNT="$2"
    local SERVER_TOTAL_DURATION=$(( DURATION + 10 ))
    # Format ratio as integer percent for tag readability (e.g., 0.90 -> 90)
    local RATIO_PCT
    RATIO_PCT=$(echo "${GET_RATIO} * 100" | bc | cut -d. -f1)

    for MODE in "nobmc" "bmc"; do
        local TAG="hotinv_k${KEY_COUNT}_get${RATIO_PCT}pct_${MODE}"
        log "--- Starting: ${TAG} ---"

        if [[ "${MODE}" == "bmc" ]]; then
            ssh_sut "sudo bash ${REMOTE_DIR}/server_setup.sh \
                -i ${IFACE} -t 4 -p ${MC_PORT} -d ${SERVER_TOTAL_DURATION} \
                -m ${MC_MEMORY_MB} \
                -b ~/bmc-cache/bmc -s ~/bmc-cache/memcached-sr \
                -o ${REMOTE_DIR}/results" &
            local SUT_JOB=$!
            sleep 8
        else
            ssh_sut "sudo bash ${REMOTE_DIR}/server_setup_nobmc.sh \
                -i ${IFACE} -t 4 -p ${MC_PORT} -d ${SERVER_TOTAL_DURATION} \
                -m ${MC_MEMORY_MB} -s ~/bmc-cache/memcached-sr \
                -o ${REMOTE_DIR}/results" &
            local SUT_JOB=$!
            sleep 3
        fi

        # Launch client workloads on all client nodes in parallel.
        local CLI_PIDS=()
        for CLI in "${CLIENT_ARRAY[@]}"; do
            log "Launching client_run.sh on client ${CLI}..."
            ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "bash ${REMOTE_DIR}/client_run.sh \
                -s ${SUT_EXP_IP} -p ${MC_PORT} \
                -t 4 -c 512 -d ${DURATION} \
                -k ${KEY_COUNT} \
                -z 0.99 -r ${GET_RATIO} -v 64 \
                -o ${REMOTE_DIR}/results \
                -g ${TAG}_${CLI} \
                --warm --udp" &
            CLI_PIDS+=($!)
        done

        # Wait for all client jobs to finish.
        for PID in "${CLI_PIDS[@]}"; do
            wait "${PID}" || log "WARNING: client job exited with non-zero."
        done
        wait "${SUT_JOB}" || log "WARNING: server job exited with non-zero."

        # Pull raw results from all clients and calculate aggregate TPS
        local TOTAL_TPS=0
        for CLI in "${CLIENT_ARRAY[@]}"; do
            log "Pulling raw results from client ${CLI}..."
            scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}:${REMOTE_DIR}/results/raw_${TAG}_${CLI}.txt" "${LOCAL_OUT}/" 2>/dev/null || log "WARNING: Failed to pull raw results from ${CLI}"
            
            local RAW_FILE="${LOCAL_OUT}/raw_${TAG}_${CLI}.txt"
            local TPS=0
            if [[ -f "${RAW_FILE}" ]]; then
                if grep -qi "TPS:" "${RAW_FILE}"; then
                    TPS=$(grep -i "TPS:" "${RAW_FILE}" | tail -1 | grep -oP 'TPS:\s*\K[0-9]+' || echo 0)
                fi
            fi
            log "Client ${CLI} TPS: ${TPS}"
            TOTAL_TPS=$(( TOTAL_TPS + TPS ))
        done
        log "Aggregate Throughput: ${TOTAL_TPS} TPS"

        # Append aggregated row to summary.csv directly from the orchestrator
        local SUMMARY_CSV="${LOCAL_OUT}/summary.csv"
        if [[ ! -f "${SUMMARY_CSV}" ]]; then
            echo "tag,server_ip,threads,concurrency,duration_s,keys,value_size_b,get_ratio,zipf_alpha,tps" > "${SUMMARY_CSV}"
        fi
        local CLIENT_COUNT=${#CLIENT_ARRAY[@]}
        local TOTAL_CONCURRENCY=$(( 512 * CLIENT_COUNT ))
        echo "${TAG},${SUT_EXP_IP},4,${TOTAL_CONCURRENCY},${DURATION},${KEY_COUNT},64,${GET_RATIO},0.99,${TOTAL_TPS}" >> "${SUMMARY_CSV}"

        log "--- Completed: ${TAG} ---"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------
log "====== HOT KEY INVALIDATION SWEEP ======"
log "Crossing GET ratio and working set size to concentrate writes on hot keys."

for GET_RATIO in "${GET_RATIOS[@]}"; do
    for KEY_COUNT in "${KEY_COUNTS[@]}"; do
        run_pair "${GET_RATIO}" "${KEY_COUNT}"
    done
done

# ---------------------------------------------------------------------------
# Pull results
# ---------------------------------------------------------------------------
log "Pulling results from SUT..."
scp_from_sut "${REMOTE_DIR}/results/*" "${LOCAL_OUT}/" 2>/dev/null || true

log "Pulling configuration files from all clients..."
for CLI in "${CLIENT_ARRAY[@]}"; do
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}:${REMOTE_DIR}/results/*.cfg" "${LOCAL_OUT}/" 2>/dev/null || true
done

log "====== Hot invalidation sweep complete. Results in ${LOCAL_OUT}/ ======"
