#!/usr/bin/env bash
# =============================================================================
# stress_working_set.sh
# -----------------------------------------------------------------------------
# @brief  Stress BMC by sweeping the working set size far beyond the capacity
#         of the in-kernel BPF cache (BMC_CACHE_ENTRY_COUNT = 3,250,000 slots).
#
# @note   This script targets the implicit assumption that the hot working set
#         fits within the direct-mapped BPF_MAP_TYPE_ARRAY. When the working
#         set exceeds cache capacity, hash collisions cause constant evictions
#         and the BMC hit rate degrades to near zero even under high Zipf skew.
#
# @note   Assumption targeted: "The working set is small enough to yield
#         significant cache hit rates in the direct-mapped eBPF array."
#
# Usage:
#   ./stress_working_set.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]
#
# Options:
#   -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
#   -C <client_host>  SSH hostname of the Client node. REQUIRED.
#   -i <iface>        Experiment interface name on the SUT. REQUIRED.
#   -u <ssh_user>     SSH username. (default: olleg)
#   -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
#   -o <local_out>    Local results directory. (default: ./results)
#   -h, --help        Print this help and exit.
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
LOCAL_OUT="./results/stress/working_set"

DURATION=30
MC_PORT=11211
MC_MEMORY_MB=4096

##
# @brief Working set sizes to sweep. The BMC cache holds 3,250,000 slots.
#        We test below, at, and well above that capacity to observe the
#        transition from high hit rate to near-zero hit rate.
##
WORKING_SETS=(10000 100000 500000 1000000 2000000 3250000 4000000 6000000)

##
# @brief Print usage and exit.
##
usage() {
    cat <<EOF
=============================================================================
stress_working_set.sh -- Working Set Size vs. BMC Cache Capacity Sweep
=============================================================================

DESCRIPTION
    Sweeps the memaslap working set size from well below to well above the
    BMC direct-mapped cache capacity (3,250,000 slots), measuring how QPS and
    the BMC hit rate degrade as the cache becomes insufficient.

USAGE
    ./stress_working_set.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]

OPTIONS
    -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
    -C <client_host>  SSH hostname of the Client node. REQUIRED.
    -i <iface>        Experiment interface name on the SUT. REQUIRED.
    -u <ssh_user>     SSH username. (default: olleg)
    -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
    -o <local_out>    Local results directory. (default: ./results)
    -h, --help        Print this help and exit.

WORKING SET SIZES TESTED
    10k, 100k, 500k, 1M, 2M, 3.25M (cache capacity), 4M, 6M keys.
    Value size fixed at 64B. Zipf alpha fixed at 0.99. GET ratio: 95%.

OUTPUT
    Results are appended to <local_out>/summary.csv with tags like:
    working_set_10000, working_set_3250000_nobmc, etc.
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
# Setup remote directories and copy scripts
# ---------------------------------------------------------------------------
log "Setting up SUT remote directory..."
ssh_sut "mkdir -p ${REMOTE_DIR}/results"

log "Copying server_setup_nobmc.sh and server_setup.sh to SUT..."
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
# @brief Run one experiment pair (BMC and No-BMC) for a given working set size.
# @param $1  Working set size in number of keys.
##
run_pair() {
    local KEY_COUNT="$1"
    local SERVER_TOTAL_DURATION=$(( DURATION + 10 ))

    for MODE in "nobmc" "bmc"; do
        local TAG="working_set_${KEY_COUNT}_${MODE}"
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
                -z 0.99 -r 0.99 -v 64 \
                -o ${REMOTE_DIR}/results \
                -g ${TAG}_${CLI} \
                --warm --udp" &
            CLI_PIDS+=($!)
        done

        # Wait for all client jobs to finish.
        for PID in "${CLI_PIDS[@]}"; do
            wait "${PID}" || log "WARNING: client job exited with non-zero status."
        done
        wait "${SUT_JOB}" || log "WARNING: server job exited with non-zero status."

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

        # Collect BMC hit rate from the SUT stats counter (BMC mode only).
        local HIT_RATE="N/A"
        if [[ "${MODE}" == "bmc" ]]; then
            log "Collecting BMC hit rate stats from SUT..."
            local STATS_FILE="${LOCAL_OUT}/stats_${TAG}.txt"
            # Pull the BMC stats file written by server_setup.sh.
            scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
                "${SSH_USER}@${SUT_HOST}:${REMOTE_DIR}/results/stats_${TAG}.txt" \
                "${STATS_FILE}" 2>/dev/null || true
            if [[ -f "${STATS_FILE}" ]]; then
                local HITS MISSES
                HITS=$(grep -i 'hit_count' "${STATS_FILE}" | awk '{print $NF}' | tail -1 || echo 0)
                MISSES=$(grep -i 'miss_count' "${STATS_FILE}" | awk '{print $NF}' | tail -1 || echo 0)
                if [[ -n "${HITS}" && -n "${MISSES}" ]] && (( HITS + MISSES > 0 )); then
                    HIT_RATE=$(awk "BEGIN {printf \"%.4f\", ${HITS} / (${HITS} + ${MISSES})}")
                    log "BMC hit rate: ${HIT_RATE} (hits=${HITS}, misses=${MISSES})"
                fi
            else
                log "WARNING: BMC stats file not found for ${TAG}. hit_rate will be N/A."
            fi
        fi

        # Append aggregated row to summary.csv directly from the orchestrator
        local SUMMARY_CSV="${LOCAL_OUT}/summary.csv"
        if [[ ! -f "${SUMMARY_CSV}" ]]; then
            echo "tag,server_ip,threads,concurrency,duration_s,keys,value_size_b,get_ratio,zipf_alpha,tps,hit_rate" > "${SUMMARY_CSV}"
        fi
        local CLIENT_COUNT=${#CLIENT_ARRAY[@]}
        local TOTAL_CONCURRENCY=$(( 512 * CLIENT_COUNT ))
        echo "${TAG},${SUT_EXP_IP},4,${TOTAL_CONCURRENCY},${DURATION},${KEY_COUNT},64,0.99,0.99,${TOTAL_TPS},${HIT_RATE}" >> "${SUMMARY_CSV}"

        log "--- Completed: ${TAG} ---"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Main sweep loop
# ---------------------------------------------------------------------------
log "====== WORKING SET SIZE SWEEP ======"
log "BMC cache capacity: 3,250,000 slots. Value: 64B. Zipf alpha: 0.99."

for WS in "${WORKING_SETS[@]}"; do
    run_pair "${WS}"
done

# ---------------------------------------------------------------------------
# Pull results back to local machine
# ---------------------------------------------------------------------------
log "Pulling results from SUT..."
scp_from_sut "${REMOTE_DIR}/results/*" "${LOCAL_OUT}/" 2>/dev/null || true

log "Pulling configuration files from all clients..."
for CLI in "${CLIENT_ARRAY[@]}"; do
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}:${REMOTE_DIR}/results/*.cfg" "${LOCAL_OUT}/" 2>/dev/null || true
done

log "====== Working set sweep complete. Results in ${LOCAL_OUT}/ ======"
