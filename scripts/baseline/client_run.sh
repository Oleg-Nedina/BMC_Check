#!/usr/bin/env bash
# =============================================================================
# client_run.sh
# -----------------------------------------------------------------------------
# @brief  Drive the workload generation side of a BMC benchmark experiment.
#         Runs on a CloudLab client node. Generates Memcached GET/SET traffic
#         using memaslap (from libmemcached-awesome), which was pre-compiled at
#         ~/libmemcached-awesome/build/contrib/bin/memaslap/memaslap.
#
# @note   memaslap does not support native Zipfian key popularity sweeps via
#         CLI flags. Key popularity distribution is uniform within the working
#         set window. The Zipfian sweep is approximated at the orchestrator
#         level by varying the working set size relative to the cache capacity.
#
# Usage   : ./client_run.sh [OPTIONS]
#   -s <server_ip>   IP of the SUT on the Experiment Network. REQUIRED.
#   -p <port>        Memcached port (default: 11211).
#   -t <threads>     Number of memaslap worker threads (default: 4).
#   -c <conns>       Concurrent connections (default: 32).
#   -d <duration>    Benchmark duration in seconds (default: 30).
#   -k <key_count>   Working set size: number of distinct keys (default: 100000).
#   -r <ratio>       GET ratio as fraction of total ops (default: 0.95).
#   -v <val_size>    Value size in bytes (default: 64).
#   -o <out_dir>     Directory where results are written (default: /tmp/bmc_results).
#   -g <tag>         Experiment tag appended to output filename (default: auto).
#   -z <zipf>        Zipfian alpha parameter (stored in CSV metadata only).
#   --warm           If set, populate the server cache before the benchmark.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SERVER_IP=""
MC_PORT=11211
CLIENT_THREADS=4
CONCURRENCY=32
DURATION=30
KEY_COUNT=100000
ZIPF_ALPHA=0.99
GET_RATIO=0.95
VAL_SIZE=64
OUT_DIR="/tmp/bmc_results"
TAG=""
WARM=0
USE_UDP=0

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

##
# @brief Print usage summary and exit.
##
usage() {
    echo "Usage: $0 -s <server_ip> [-p <port>] [-t <threads>] [-c <conns>] [-d <duration>]"
    echo "          [-k <keys>] [-z <zipf_alpha>] [-r <get_ratio>] [-v <val_size>]"
    echo "          [-o <out_dir>] [-g <tag>] [--warm] [--udp]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s) SERVER_IP="$2"; shift 2 ;;
        -p) MC_PORT="$2"; shift 2 ;;
        -t) CLIENT_THREADS="$2"; shift 2 ;;
        -c) CONCURRENCY="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -k) KEY_COUNT="$2"; shift 2 ;;
        -z) ZIPF_ALPHA="$2"; shift 2 ;;
        -r) GET_RATIO="$2"; shift 2 ;;
        -v) VAL_SIZE="$2"; shift 2 ;;
        -o) OUT_DIR="$2"; shift 2 ;;
        -g) TAG="$2"; shift 2 ;;
        --warm) WARM=1; shift ;;
        --udp)  USE_UDP=1; shift ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SERVER_IP}" ]]; then
    echo "[ERROR] -s <server_ip> is required."
    usage
fi

# Auto-generate experiment tag if not provided.
if [[ -z "${TAG}" ]]; then
    TAG="z${ZIPF_ALPHA}_v${VAL_SIZE}_r${GET_RATIO}_t${CLIENT_THREADS}_$(date '+%Y%m%d_%H%M%S')"
fi

mkdir -p "${OUT_DIR}"

# memaslap --win_size requires the format "Nk" (e.g. "100k" for 100000 keys).
# Compute it once here so both the warm-up and benchmark steps use it.
WIN_SIZE_K="$(( KEY_COUNT / 1000 ))k"

##
# @brief Logging helpers.
# @note  log() prints to stdout with timestamp. die() prints to stderr and exits.
##
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 0: Locate the memaslap binary
# ---------------------------------------------------------------------------
##
# @brief Resolve the memaslap binary path.
# @note  Priority: system PATH, then the libmemcached-awesome build tree.
#        The binary is pre-compiled at the path below; no on-the-fly build
#        is performed since the client node has no internet access on the
#        experiment network.
##
MEMASLAP_AWESOME="${HOME}/libmemcached-awesome/build/contrib/bin/memaslap/memaslap"
MEMASLAP_LOCAL="${HOME}/memaslap"
MEMASLAP_BIN=""

if command -v memaslap >/dev/null 2>&1; then
    MEMASLAP_BIN="memaslap"
elif [[ -x "${MEMASLAP_LOCAL}" ]]; then
    MEMASLAP_BIN="${MEMASLAP_LOCAL}"
elif [[ -x "${MEMASLAP_AWESOME}" ]]; then
    MEMASLAP_BIN="${MEMASLAP_AWESOME}"
else
    die "memaslap not found. Expected at: ${MEMASLAP_LOCAL} or ${MEMASLAP_AWESOME}. Pre-build it on the control network."
fi

log "Using memaslap binary: ${MEMASLAP_BIN}"

# ---------------------------------------------------------------------------
# Step 1: Generate the memaslap configuration file
# ---------------------------------------------------------------------------
##
# @brief Generate a memaslap workload config file.
# @note  memaslap does not accept GET ratio or value size as CLI flags directly.
#        Instead, it reads them from a structured config file specified via
#        --cfg_cmd. The format defines key size range, value size range, and
#        the proportion of GET vs SET commands.
#
#        Key size is fixed at 16 bytes (memaslap enforces a minimum of 16 bytes).
#        Value size is fixed at VAL_SIZE bytes.
#        GET:SET ratio is GET_RATIO:(1-GET_RATIO).
##
CFG_FILE="${OUT_DIR}/memaslap_${TAG}.cfg"
SET_RATIO=$(echo "1 - ${GET_RATIO}" | bc -l | awk '{printf "%.2f", $1}')

cat > "${CFG_FILE}" <<EOF
# memaslap workload configuration
# Generated by client_run.sh for experiment: ${TAG}

key
16 16 1.0

value
${VAL_SIZE} ${VAL_SIZE} 1.0

cmd
0 ${SET_RATIO}
1 ${GET_RATIO}
EOF

log "memaslap config written to ${CFG_FILE}."

# ---------------------------------------------------------------------------
# Step 2: Wait for the server to be reachable on the Experiment Network
# ---------------------------------------------------------------------------
##
# @brief Poll the server TCP port until it becomes reachable or timeout.
# @param SERVER_IP  IP of the SUT on the experiment network (10.10.1.x).
# @param MC_PORT    Memcached TCP/UDP port (default 11211).
##
log "Waiting for server ${SERVER_IP}:${MC_PORT} to become reachable..."
WAIT=0
MAX_WAIT=60
until nc -z "${SERVER_IP}" "${MC_PORT}" 2>/dev/null; do
    sleep 1
    WAIT=$(( WAIT + 1 ))
    if [[ ${WAIT} -ge ${MAX_WAIT} ]]; then
        die "Server ${SERVER_IP}:${MC_PORT} did not become reachable in ${MAX_WAIT} seconds."
    fi
done
log "Server is reachable."

# ---------------------------------------------------------------------------
# Step 3: (Optional) Warm-up the server cache
# ---------------------------------------------------------------------------
##
# @brief Pre-populate the Memcached cache with KEY_COUNT key-value pairs.
# @note  This ensures BMC has data to serve from the in-kernel cache on the
#        first benchmark request. Warm-up uses 100% SET operations for 15s.
##
if [[ "${WARM}" -eq 1 ]]; then
    log "Warming up server with ${KEY_COUNT} key-value pairs (size=${VAL_SIZE}B)..."
    WARM_CFG="${OUT_DIR}/memaslap_warmup.cfg"
    cat > "${WARM_CFG}" <<EOF
key
16 16 1.0

value
${VAL_SIZE} ${VAL_SIZE} 1.0

cmd
0 1.0
1 0.0
EOF
    WARM_EXTRA_ARGS=""
    if [[ "${USE_UDP}" -eq 1 ]]; then
        WARM_EXTRA_ARGS="--udp"
    fi
    "${MEMASLAP_BIN}" \
        --servers="${SERVER_IP}:${MC_PORT}" \
        --threads=2 \
        --concurrency=16 \
        --time=15s \
        --win_size="${WIN_SIZE_K}" \
        --cfg_cmd="${WARM_CFG}" \
        ${WARM_EXTRA_ARGS} \
        >/dev/null 2>&1 || log "WARNING: Warm-up phase returned non-zero. Server may need more time."
    log "Warm-up complete."
    sleep 2
fi

# ---------------------------------------------------------------------------
# Step 4: Run the actual benchmark
# ---------------------------------------------------------------------------
##
# @brief Execute the memaslap benchmark and capture raw output.
# @param --servers         SUT address and port.
# @param --threads         Number of client threads.
# @param --concurrency     Total concurrent connections.
# @param --time            Duration string, e.g. "30s".
# @param --win_size        Working set size (number of keys).
# @param --cfg_cmd         Path to the workload config file generated above.
# @param --fixed_size      Fixed value payload size in bytes.
##
RAW_OUT="${OUT_DIR}/raw_${TAG}.txt"

log "Starting memaslap benchmark..."
log "  Server      : ${SERVER_IP}:${MC_PORT}"
log "  Threads     : ${CLIENT_THREADS}"
log "  Concurrency : ${CONCURRENCY}"
log "  Duration    : ${DURATION}s"
log "  Keys        : ${KEY_COUNT}"
log "  Value size  : ${VAL_SIZE}B"
log "  GET ratio   : ${GET_RATIO}  SET ratio: ${SET_RATIO}"

BENCH_EXTRA_ARGS=""
if [[ "${USE_UDP}" -eq 1 ]]; then
    BENCH_EXTRA_ARGS="--udp"
fi

timeout --foreground -s KILL $(( DURATION + 15 )) "${MEMASLAP_BIN}" \
    --servers="${SERVER_IP}:${MC_PORT}" \
    --threads="${CLIENT_THREADS}" \
    --concurrency="${CONCURRENCY}" \
    --time="${DURATION}s" \
    --win_size="${WIN_SIZE_K}" \
    --cfg_cmd="${CFG_FILE}" \
    --fixed_size="${VAL_SIZE}" \
    ${BENCH_EXTRA_ARGS} \
    2>&1 | grep -v "didn't set success" | tee "${RAW_OUT}" || log "WARNING: memaslap returned non-zero exit status or was killed due to timeout."


# ---------------------------------------------------------------------------
# Step 5: Parse throughput from raw output and write CSV summary
# ---------------------------------------------------------------------------
##
# @brief Extract TPS from memaslap output and append to the results CSV.
# @note  memaslap reports throughput as "TPS: <value>" in its summary block.
#        The last occurrence is used to capture the steady-state rate.
##
log "Benchmark complete. Raw output: ${RAW_OUT}"

TPS=0
if grep -qi "TPS:" "${RAW_OUT}"; then
    TPS=$(grep -i "TPS:" "${RAW_OUT}" | tail -1 | grep -oP 'TPS:\s*\K[0-9]+')
fi

##
# @brief Extract average GET latency from memaslap's per-interval statistics block.
# @note  memaslap reports: "Get Statistics   Min:X   Max:Y   Avg:Z   Std Err:W"
#        The value is in milliseconds; we convert to microseconds for the CSV.
##
AVG_LATENCY_US="N/A"
if grep -qi "Get Statistics" "${RAW_OUT}"; then
    AVG_MS=$(grep -i "Get Statistics" "${RAW_OUT}" | tail -1 \
        | grep -oP 'Avg:\s*\K[0-9.]+' || echo "")
    if [[ -n "${AVG_MS}" ]]; then
        # Convert ms -> us (multiply by 1000).
        AVG_LATENCY_US=$(awk "BEGIN {printf \"%.1f\", ${AVG_MS} * 1000}")
    fi
fi

log "Summary -- TPS: ${TPS}  Avg_Latency: ${AVG_LATENCY_US} us"

SUMMARY_CSV="${OUT_DIR}/summary.csv"
if [[ ! -f "${SUMMARY_CSV}" ]]; then
    echo "tag,server_ip,threads,concurrency,duration_s,keys,value_size_b,get_ratio,zipf_alpha,tps,avg_latency_us" \
        > "${SUMMARY_CSV}"
fi
echo "${TAG},${SERVER_IP},${CLIENT_THREADS},${CONCURRENCY},${DURATION},${KEY_COUNT},${VAL_SIZE},${GET_RATIO},${ZIPF_ALPHA},${TPS},${AVG_LATENCY_US}" \
    >> "${SUMMARY_CSV}"
log "Summary appended to ${SUMMARY_CSV}."

log "Client run complete."
