#!/usr/bin/env bash
# =============================================================================
# stress_payload_boundary.sh
# -----------------------------------------------------------------------------
# @brief  Fine-grained payload size sweep around BMC_MAX_VAL_LENGTH = 1000 bytes.
#
# @note   This script targets the implicit assumption that the performance cliff
#         at the 1000B value size boundary is abrupt and well-defined. The paper
#         only tests 64B (cacheable) and 8192B (non-cacheable) extremes. The
#         behavior at exactly 1000B, 1001B, and a few bytes on each side is
#         never characterized. This script measures the exact transition point.
#
# @note   Assumption targeted: "Values either fit in the cache (<=1000B) or
#         bypass it (>1000B) with negligible performance difference between
#         the two cases."
#
# Usage:
#   ./stress_payload_boundary.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]
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
LOCAL_OUT="./results/stress/payload_boundary"

DURATION=30
MC_PORT=11211
MC_MEMORY_MB=4096

##
# @brief Payload sizes to sweep around the BMC_MAX_VAL_LENGTH=1000B boundary.
#        Sizes below 1000B should be cached by BMC. Sizes above should bypass it.
#        The interesting question is whether the transition is sharp or gradual,
#        and whether there is any overhead asymmetry just below vs. just above.
##
PAYLOAD_SIZES=(64 500 900 950 990 999 1000 1001 1010 1050 1100 1200 1500 2000)

##
# @brief Print usage and exit.
##
usage() {
    cat <<EOF
=============================================================================
stress_payload_boundary.sh -- Fine-Grained Payload Boundary Sweep
=============================================================================

DESCRIPTION
    Sweeps value payload sizes around the BMC_MAX_VAL_LENGTH=1000B boundary
    in fine-grained steps to precisely measure the QPS and hit rate cliff at
    the point where BMC stops caching values.

USAGE
    ./stress_payload_boundary.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]

OPTIONS
    -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
    -C <client_host>  SSH hostname of the Client node. REQUIRED.
    -i <iface>        Experiment interface name on the SUT. REQUIRED.
    -u <ssh_user>     SSH username. (default: olleg)
    -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
    -o <local_out>    Local results directory. (default: ./results)
    -h, --help        Print this help and exit.

SIZES TESTED
    64, 500, 900, 950, 990, 999, 1000, 1001, 1010, 1050, 1100, 1200, 1500, 2000 bytes.
    Threads fixed at 4. Zipf alpha fixed at 0.99. GET ratio: 95%.
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
# @brief Run one experiment pair (BMC and No-BMC) for a given payload size.
# @param $1  Value payload size in bytes.
##
run_pair() {
    local VAL_SIZE="$1"
    local SERVER_TOTAL_DURATION=$(( DURATION + 10 ))

    for MODE in "nobmc" "bmc"; do
        local TAG="payload_fine_${VAL_SIZE}B_${MODE}"
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
                -k 100000 \
                -z 0.99 -r 0.99 -v ${VAL_SIZE} \
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
        echo "${TAG},${SUT_EXP_IP},4,${TOTAL_CONCURRENCY},${DURATION},100000,${VAL_SIZE},0.99,0.99,${TOTAL_TPS}" >> "${SUMMARY_CSV}"

        log "--- Completed: ${TAG} ---"
        sleep 5
    done
}

# ---------------------------------------------------------------------------
# Main sweep loop
# ---------------------------------------------------------------------------
log "====== FINE-GRAINED PAYLOAD BOUNDARY SWEEP ======"
log "BMC_MAX_VAL_LENGTH = 1000 bytes. Threads: 4. Zipf alpha: 0.99."

for SIZE in "${PAYLOAD_SIZES[@]}"; do
    run_pair "${SIZE}"
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

log "====== Payload boundary sweep complete. Results in ${LOCAL_OUT}/ ======"
