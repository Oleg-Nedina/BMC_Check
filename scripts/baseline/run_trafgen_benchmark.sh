#!/usr/bin/env bash
# =============================================================================
# run_trafgen_benchmark.sh
# -----------------------------------------------------------------------------
# Purpose : Orchestrate open-loop Memcached UDP benchmarking using trafgen on
#           clients to flood SUT, validating XDP bypass under wire-speed.
#
# Usage   : ./run_trafgen_benchmark.sh -S <sut_host> -C "<client_hosts>" -i <iface> [OPTIONS]
#   -b                  Enable BMC.
#   -r <rate>           PPS rate per client (e.g. 500k, 1m, or 'max' for wire-speed). Default: 500k
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/open_loop"
USE_BMC=0
USE_VANILLA=0
DURATION=30
PPS_RATE="500k"
MC_PORT=11211
MC_MEMORY_MB=4096
THREADS=8

usage() {
    echo "Usage: $0 -S <sut_host> -C <client_hosts> -i <iface> [-b] [--vanilla] [-t <threads>] [-r <rate>] [-d <duration>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S) SUT_HOST="$2"; shift 2 ;;
        -C) CLIENT_HOST="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -t) THREADS="$2"; shift 2 ;;
        -b) USE_BMC=1; shift ;;
        --vanilla) USE_VANILLA=1; shift ;;
        -r) PPS_RATE="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S <sut_host>, -C <client_host>, and -i <iface> are required."
    usage
fi

read -r -a CLIENT_ARRAY <<< "${CLIENT_HOST}"

log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

ssh_sut()    { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "$@"; }
scp_to_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${SUT_HOST}:$2"; }
scp_to_cli() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${2}:$3"; }

# ---------------------------------------------------------------------------
# Setup and Dependency Check
# ---------------------------------------------------------------------------
log "Checking SUT connection..."
ssh_sut "uname -a" >/dev/null || die "Cannot connect to SUT ${SUT_HOST}"

log "Checking and installing netsniff-ng (trafgen) on clients..."
for CLI in "${CLIENT_ARRAY[@]}"; do
    log "Checking client ${CLI}..."
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "which trafgen >/dev/null || (sudo apt-get update && sudo apt-get install -y netsniff-ng)"
done

# Copy configurations
log "Copying config files to clients..."
# Client 1 uses trafgen_c1.cfg, Client 2 uses trafgen_c2.cfg
scp_to_cli "scripts/trafgen_c1.cfg" "${CLIENT_ARRAY[0]}" "~/trafgen.cfg"
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    scp_to_cli "scripts/trafgen_c2.cfg" "${CLIENT_ARRAY[1]}" "~/trafgen.cfg"
fi
scp_to_cli "scripts/trafgen_warmup.py" "${CLIENT_ARRAY[0]}" "~/trafgen_warmup.py"

# Get SUT Experiment Network IP
SUT_EXP_IP=$(ssh_sut "ip -4 addr show dev ${IFACE} | grep -oP '(?<=inet )[0-9.]+'" 2>/dev/null)
log "SUT Experiment IP: ${SUT_EXP_IP}"

# ---------------------------------------------------------------------------
# Start Memcached Server on SUT
# ---------------------------------------------------------------------------
log "Stopping residual Memcached on SUT..."
ssh_sut "sudo killall -9 memcached bmc 2>/dev/null || true"

# Setup SUT directory
ssh_sut "mkdir -p ${REMOTE_DIR}/results"
scp_to_sut "scripts/server_setup.sh" "${REMOTE_DIR}/server_setup.sh"
scp_to_sut "scripts/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh ${REMOTE_DIR}/server_setup_nobmc.sh"

SERVER_DURATION=$(( DURATION + 25 ))

if [[ "${USE_BMC}" -eq 1 ]]; then
    log "Starting SUT Memcached + BMC (${THREADS} threads)..."
    ssh_sut "sudo bash ${REMOTE_DIR}/server_setup.sh -i ${IFACE} -t ${THREADS} -p ${MC_PORT} -d ${SERVER_DURATION} -m ${MC_MEMORY_MB} -b ~/bmc-cache/bmc -s ~/bmc-cache/memcached-sr -o ${REMOTE_DIR}/results" &
    SUT_JOB=$!
    sleep 8
else
    EXTRA_FLAGS=""
    if [[ "${USE_VANILLA}" -eq 1 ]]; then
        EXTRA_FLAGS="-v"
        log "Starting SUT Vanilla Memcached (${THREADS} threads, no BMC)..."
    else
        log "Starting SUT MemcachedSR (${THREADS} threads, no BMC)..."
    fi
    ssh_sut "sudo bash ${REMOTE_DIR}/server_setup_nobmc.sh -i ${IFACE} -t ${THREADS} -p ${MC_PORT} -d ${SERVER_DURATION} -m ${MC_MEMORY_MB} -s ~/bmc-cache/memcached-sr -o ${REMOTE_DIR}/results ${EXTRA_FLAGS}" &
    SUT_JOB=$!
    sleep 3
fi

# ---------------------------------------------------------------------------
# Cache Warm-up from Client 1
# ---------------------------------------------------------------------------
log "Warming up and populating cache for key_test_0000000..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_ARRAY[0]}" "python3 ~/trafgen_warmup.py ${SUT_EXP_IP}"

# ---------------------------------------------------------------------------
# Statistics: Before run
# ---------------------------------------------------------------------------
get_sut_cmd_get() {
    ssh_sut "echo 'stats' | nc -w 1 localhost ${MC_PORT} | grep 'cmd_get' | awk '{print \$3}' | tr -d '\r'" 2>/dev/null || echo 0
}

CMD_GET_BEFORE=$(get_sut_cmd_get)
log "Server cmd_get before experiment: ${CMD_GET_BEFORE}"

# ---------------------------------------------------------------------------
# Run trafgen Load Generation in Parallel on Clients
# ---------------------------------------------------------------------------
RATE_ARG=""
if [[ "${PPS_RATE}" == "500k" ]]; then
    RATE_ARG="--rate 500000pps"
elif [[ "${PPS_RATE}" == "1m" ]]; then
    RATE_ARG="--rate 1000000pps"
elif [[ "${PPS_RATE}" != "max" ]]; then
    RATE_ARG="--rate ${PPS_RATE}"
fi

log "Launching trafgen flood from clients. Rate per client: ${PPS_RATE}, Duration: ${DURATION}s..."

CLI_PIDS=()
for CLI in "${CLIENT_ARRAY[@]}"; do
    log "Launching trafgen on client ${CLI}..."
    # Launch trafgen in background on clients
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" \
        "sudo trafgen --dev ${IFACE} --conf ~/trafgen.cfg ${RATE_ARG} >/dev/null 2>&1" &
    CLI_PIDS+=($!)
done

# Wait for duration
log "Flooding for ${DURATION} seconds..."
sleep "${DURATION}"

# Stop traffic generators on all clients
log "Stopping traffic generators..."
for CLI in "${CLIENT_ARRAY[@]}"; do
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "sudo killall -2 trafgen 2>/dev/null || true"
done

# Wait for client SSH processes to clean up
for PID in "${CLI_PIDS[@]}"; do
    wait "${PID}" || true
done

# ---------------------------------------------------------------------------
# Statistics: After run
# ---------------------------------------------------------------------------
# Query Memcached statistics before killing the process
CMD_GET_AFTER=$(get_sut_cmd_get)
log "Server cmd_get after experiment: ${CMD_GET_AFTER}"

# Stop the server job (BMC writes stats to file when receiving SIGINT)
log "Tearing down server..."
if [[ "${USE_BMC}" -eq 1 ]]; then
    ssh_sut "sudo killall -2 bmc 2>/dev/null || true"
    sleep 3 # Give it a moment to dump statistics to file
fi

# Now kill memcached safely
ssh_sut "sudo killall -9 memcached 2>/dev/null || true"
wait "${SUT_JOB}" || true

HITS_PROCESSED=0
if [[ "${USE_BMC}" -eq 1 ]]; then
    # Pull bmc stats
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}:/tmp/bmc_stats.txt" "${LOCAL_OUT}/bmc_stats_temp.txt" 2>/dev/null || true
    if [[ -f "${LOCAL_OUT}/bmc_stats_temp.txt" ]]; then
        HITS_PROCESSED=$(cat "${LOCAL_OUT}/bmc_stats_temp.txt" | grep "hit_count" | awk '{print $3}' || echo 0)
        rm -f "${LOCAL_OUT}/bmc_stats_temp.txt"
    fi
    log "BMC Server-Side Hits reported: ${HITS_PROCESSED}"
else
    # For no-BMC, Memcached cmd_get diff is the processed throughput
    DIFF=$(( CMD_GET_AFTER - CMD_GET_BEFORE ))
    HITS_PROCESSED=${DIFF}
    log "MemcachedSR processed commands: ${HITS_PROCESSED}"
fi

# Calculate aggregate TPS (hits processed / duration)
TPS=$(echo "${HITS_PROCESSED} / ${DURATION}" | bc)
log "Aggregate Throughput: ${TPS} TPS"

# ---------------------------------------------------------------------------
mkdir -p "${LOCAL_OUT}"
TRAFGEN_CSV="${LOCAL_OUT}/trafgen.csv"
if [[ ! -f "${TRAFGEN_CSV}" ]]; then
    echo "tag,use_bmc,pps_rate,threads,duration_s,processed_ops,tps" > "${TRAFGEN_CSV}"
fi

TAG_NAME="trafgen_rate_${PPS_RATE}_t${THREADS}"
if [[ "${USE_VANILLA}" -eq 1 ]]; then
    TAG_NAME="${TAG_NAME}_vanilla"
elif [[ "${USE_BMC}" -eq 0 ]]; then
    TAG_NAME="${TAG_NAME}_nobmc"
else
    TAG_NAME="${TAG_NAME}_bmc"
fi

echo "${TAG_NAME},${USE_BMC},${PPS_RATE},${THREADS},${DURATION},${HITS_PROCESSED},${TPS}" >> "${TRAFGEN_CSV}"

log "--- Experiment ${TAG_NAME} complete ---"
