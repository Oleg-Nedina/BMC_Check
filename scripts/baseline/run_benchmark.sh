#!/usr/bin/env bash
# =============================================================================
# run_benchmark.sh
# -----------------------------------------------------------------------------
# Purpose : Orchestrate a complete BMC benchmark experiment from the control
#           machine (your laptop or the CloudLab control node).
#           Copies server_setup.sh and client_run.sh to the respective nodes,
#           sequences their execution with correct timing, and pulls all result
#           files back to a local results directory.
#
# Prerequisites:
#   - Passwordless SSH access to both SUT and CLIENT nodes (standard on CloudLab).
#   - server_setup.sh and client_run.sh in the same directory as this script.
#   - The bmc-cache repository already cloned and binaries built on the SUT node.
#
# Usage   : ./run_benchmark.sh [OPTIONS]
#   -S <sut_host>     SSH hostname or IP of the SUT node. REQUIRED.
#   -C <client_host>  SSH hostname or IP of the client node. REQUIRED.
#   -i <iface>        Experiment interface name on SUT (e.g., enp6s0f1). REQUIRED.
#   -u <ssh_user>     SSH username (default: $(whoami)).
#   -k <ssh_key>      Path to SSH private key (default: ~/.ssh/id_rsa).
#   -r <remote_dir>   Remote working directory on both nodes (default: ~/bmc_bench).
#   -o <local_out>    Local directory to pull results into (default: ./results).
#   --baseline        Run a single baseline sweep only (1,2,4,8 threads, GET-only).
#   --stress          Run the stress/exploration sweep (Zipf alpha and payload sweeps).
#   --all             Run both baseline and stress sweeps (equivalent to --baseline --stress).
#
# Experiment Modes:
#   Baseline  - Multi-core throughput scaling (1,2,4,8 RX queues), GET-heavy (95%),
#               64-byte values, high Zipf skew (alpha=0.99). Replicates Figure 3 of
#               the BMC paper.
#   Stress    - Explores failure modes: Zipf alpha sweep (0.1 to 1.2), large payload
#               (8192B), write-heavy workload (SET ratio 50%), medium payload (1000-1400B).
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# Defaults
# ---------------------------------------------------------------------------
SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/closed_loop"
RUN_BASELINE=0
RUN_STRESS=0
USE_BMC=0
USE_VANILLA=0
COLLECT_PERF=0      # When 1, wraps memcached with perf stat to capture CPU cycles.

DURATION=30          # Seconds per experiment run.
MC_PORT=11211
MC_MEMORY_MB=4096
CONCURRENCY=128

# ---------------------------------------------------------------------------

# Argument parsing
# ---------------------------------------------------------------------------
##
# @brief Print a comprehensive usage reference and exit.
# @note  Triggered by -h or --help. Covers all flags, modes, defaults, and examples.
##
usage() {
    cat <<EOF
=============================================================================
run_benchmark.sh -- BMC Benchmark Orchestrator
=============================================================================

DESCRIPTION
    Orchestrates a complete BMC benchmark experiment from the local control
    machine. Copies the appropriate server and client scripts to the remote
    CloudLab nodes, sequences their execution with correct timing, and pulls
    all result files back to a local output directory.

PREREQUISITES
    - Passwordless SSH access to both SUT and Client nodes (standard on CloudLab).
    - server_setup.sh, server_setup_nobmc.sh, and client_run.sh must be in
      the same directory as this script.
    - The bmc-cache repository must already be cloned and all binaries compiled
      on the SUT node (see CONFIGURATION.sut).
    - memaslap must be compiled on the Client node (see CONFIGURATION_CLIENT.md).

USAGE
    ./run_benchmark.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]

REQUIRED ARGUMENTS
    -S <sut_host>       SSH hostname or IP of the SUT (System Under Test) node.
    -C <client_host>    SSH hostname or IP of the Client (load generator) node.
    -i <iface>          Experiment network interface name on the SUT.
                        Must be the interface carrying the private 10.x.x.x IP.
                        Example: ens1f1np1

OPTIONAL ARGUMENTS
    -u <ssh_user>       SSH username on both nodes. (default: olleg)
    -k <ssh_key>        Path to SSH private key file. (default: ~/.ssh/id_ed25519_net)
    -r <remote_dir>     Working directory on both remote nodes. (default: ~/bmc_bench)
    -o <local_out>      Local directory where results are pulled. (default: ./results/closed_loop)
    -h, --help          Print this help message and exit.

EXPERIMENT MODE FLAGS
    --baseline          Run the multi-core throughput scaling suite.
                        Sweeps threads = 1, 2, 4, 8. Fixed: 64B values, GET ratio=0.95,
                        Zipf alpha=0.99. Replicates Figure 3 of the BMC paper.
    --stress            Run the failure-boundary exploration suite.
                        Covers: Zipf alpha sweep (0.1 to 1.2), medium payload boundary
                        (1000B, 1200B, 1400B), write-heavy (50% SET), extreme write (90% SET).
    --all               Run both --baseline and --stress suites sequentially.

SERVER MODE FLAGS (controls which Memcached configuration is used on the SUT)
    -b                  Enable BMC in-kernel XDP/TC cache acceleration.
                        Uses server_setup.sh which loads the eBPF programs.
                        If omitted, runs MemcachedSR without BMC (uses server_setup_nobmc.sh).
    --vanilla           Use stock Vanilla Memcached binary (no SO_REUSEPORT).
                        Implies no BMC. Used only for initial multi-core scaling validation.

EXAMPLES
    # Run the 3-way baseline comparison (Vanilla vs. MemcachedSR vs. BMC):
    ./run_benchmark.sh -S hp146.utah.cloudlab.us -C hp130.utah.cloudlab.us -i ens1f1np1 --baseline --vanilla
    ./run_benchmark.sh -S hp146.utah.cloudlab.us -C hp130.utah.cloudlab.us -i ens1f1np1 --baseline
    ./run_benchmark.sh -S hp146.utah.cloudlab.us -C hp130.utah.cloudlab.us -i ens1f1np1 --baseline -b

    # Run the stress exploration suite comparing MemcachedSR vs. BMC:
    ./run_benchmark.sh -S hp146.utah.cloudlab.us -C hp130.utah.cloudlab.us -i ens1f1np1 --stress
    ./run_benchmark.sh -S hp146.utah.cloudlab.us -C hp130.utah.cloudlab.us -i ens1f1np1 --stress -b

OUTPUT
    Results are saved locally in <local_out>/ (default: ./results/closed_loop/).
    - summary.csv          : Aggregated throughput per experiment run.
    - raw_<tag>.txt        : Raw memaslap output for each run.
    - stats_<tag>.txt      : BMC server-side hit/miss counters (BMC mode only).
    - interval_<tag>.csv   : Per-5-second BMC counters timeseries (BMC mode only).
=============================================================================
EOF
    exit 0
}


while [[ $# -gt 0 ]]; do
    case "$1" in
        -S) SUT_HOST="$2"; shift 2 ;;
        -C) CLIENT_HOST="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -u) SSH_USER="$2"; shift 2 ;;
        -k) SSH_KEY="$2"; shift 2 ;;
        -r) REMOTE_DIR="$2"; shift 2 ;;
        -o) LOCAL_OUT="$2"; shift 2 ;;
        --baseline) RUN_BASELINE=1; shift ;;
        --stress)   RUN_STRESS=1; shift ;;
        --all)      RUN_BASELINE=1; RUN_STRESS=1; shift ;;
        -b)         USE_BMC=1; shift ;;
        --vanilla)  USE_VANILLA=1; shift ;;
        --perf)     COLLECT_PERF=1; shift ;;
        -h|--help)  usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S <sut_host>, -C <client_host>, and -i <iface> are required."
    usage
fi

if [[ "${RUN_BASELINE}" -eq 0 && "${RUN_STRESS}" -eq 0 ]]; then
    echo "[ERROR] Specify at least one experiment mode: --baseline, --stress, or --all."
    usage
fi

# Parse client hosts into an array for parallel multi-client execution
read -r -a CLIENT_ARRAY <<< "${CLIENT_HOST}"


# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ssh_sut()    { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "$@"; }
ssh_client() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" "$@"; }
scp_to_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${SUT_HOST}:$2"; }
scp_to_cli() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "$1" "${SSH_USER}@${CLIENT_HOST}:$2"; }
scp_from_sut() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}:$1" "$2"; }
scp_from_cli() { scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}:$1" "$2"; }

# Get the SUT IP on the experiment network (used by the client to target it).
# This assumes the experiment interface ${IFACE} carries a 10.x.x.x address.
get_sut_exp_ip() {
    ssh_sut "ip -4 addr show dev ${IFACE} | grep -oP '(?<=inet )[0-9.]+'" 2>/dev/null \
        || die "Cannot determine experiment IP of ${IFACE} on SUT. Is the interface up?"
}

# Run an experiment: start server, wait for it to be ready, start client, wait for both.
# Args: <thread_count> <zipf_alpha> <val_size_bytes> <get_ratio> <experiment_tag>
run_experiment() {
    local THREADS="$1"
    local ZIPF="$2"
    local VALSIZE="$3"
    local GETRATIO="$4"
    local TAG="$5"

    # Set tagging suffix based on active mode
    if [[ "${USE_VANILLA}" -eq 1 ]]; then
        TAG="${TAG}_vanilla"
    elif [[ "${USE_BMC}" -eq 0 ]]; then
        TAG="${TAG}_nobmc"
    fi

    log "--- Starting experiment: ${TAG} ---"
    log "  Threads=${THREADS}  Zipf=${ZIPF}  ValueSize=${VALSIZE}B  GET_ratio=${GETRATIO}"

    local REMOTE_OUT="${REMOTE_DIR}/results"

    # Total orchestration time = server startup grace + benchmark duration + teardown grace.
    local SERVER_TOTAL_DURATION=$(( DURATION + 60 ))

    if [[ "${USE_BMC}" -eq 1 ]]; then
        # Launch server setup in the background with BMC active.
        log "Launching server_setup.sh on SUT..."
        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup.sh \
            -i ${IFACE} \
            -t ${THREADS} \
            -p ${MC_PORT} \
            -d ${SERVER_TOTAL_DURATION} \
            -m ${MC_MEMORY_MB} \
            -b ~/bmc-cache/bmc \
            -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_OUT}" &
        local SUT_JOB=$!
        
        # Give the server time to verify and pin BMC.
        log "Waiting 8 seconds for BMC server to become ready..."
        sleep 8
    else
        # Launch server setup in the background without BMC (could be MemcachedSR or Vanilla stock).
        local EXTRA_FLAGS=""
        if [[ "${USE_VANILLA}" -eq 1 ]]; then
            EXTRA_FLAGS="-v"
            log "Launching server_setup_nobmc.sh in VANILLA mode on SUT..."
        else
            log "Launching server_setup_nobmc.sh in MemcachedSR-only mode on SUT..."
        fi

        ssh_sut "sudo bash ${REMOTE_DIR}/server_setup_nobmc.sh \
            -i ${IFACE} \
            -t ${THREADS} \
            -p ${MC_PORT} \
            -d ${SERVER_TOTAL_DURATION} \
            -m ${MC_MEMORY_MB} \
            -s ~/bmc-cache/memcached-sr \
            -o ${REMOTE_OUT} \
            ${EXTRA_FLAGS}" &
        local SUT_JOB=$!
        
        # Less time needed for startup without BMC loading.
        log "Waiting 3 seconds for server to become ready..."
        sleep 3
    fi

    # Determine the SUT experiment network IP.
    local SUT_EXP_IP
    SUT_EXP_IP=$(get_sut_exp_ip)
    log "SUT experiment IP: ${SUT_EXP_IP}"

    # Launch client workloads on all client nodes in parallel.
    local CLI_PIDS=()
    for CLI in "${CLIENT_ARRAY[@]}"; do
        log "Launching client_run.sh on client ${CLI}..."
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "bash ${REMOTE_DIR}/client_run.sh \
            -s ${SUT_EXP_IP} \
            -p ${MC_PORT} \
            -t ${THREADS} \
            -c ${CONCURRENCY} \
            -d ${DURATION} \
            -k 100000 \
            -z ${ZIPF} \
            -r ${GETRATIO} \
            -v ${VALSIZE} \
            -o ${REMOTE_OUT} \
            -g ${TAG}_${CLI} \
            --warm \
            --udp" &
        CLI_PIDS+=($!)
    done

    # Wait for both sides to complete.
    log "Waiting for experiment to finish..."
    for PID in "${CLI_PIDS[@]}"; do
        wait "${PID}" || log "WARNING: a client job exited with non-zero status."
    done
    wait "${SUT_JOB}" || log "WARNING: server job exited with non-zero status."

    # Pull raw results from all clients and calculate aggregate TPS and weighted avg latency
    local TOTAL_TPS=0
    local SUM_TPS_TIMES_LATENCY=0
    local TOTAL_VALID_TPS=0
    local AVG_LATENCY_US="N/A"

    for CLI in "${CLIENT_ARRAY[@]}"; do
        log "Pulling raw results from client ${CLI}..."
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}:${REMOTE_OUT}/raw_${TAG}_${CLI}.txt" "${LOCAL_OUT}/" 2>/dev/null || log "WARNING: Failed to pull raw results from ${CLI}"
        
        local RAW_FILE="${LOCAL_OUT}/raw_${TAG}_${CLI}.txt"
        local TPS=0
        local LATENCY_MS=""
        if [[ -f "${RAW_FILE}" ]]; then
            if grep -qi "TPS:" "${RAW_FILE}"; then
                TPS=$(grep -i "TPS:" "${RAW_FILE}" | tail -1 | grep -oP 'TPS:\s*\K[0-9]+' || echo 0)
            fi
            if grep -qi "Get Statistics" "${RAW_FILE}"; then
                LATENCY_MS=$(grep -i "Get Statistics" "${RAW_FILE}" | tail -1 | grep -oP 'Avg:\s*\K[0-9.]+' || echo "")
            fi
        fi
        log "Client ${CLI} TPS: ${TPS}  Latency: ${LATENCY_MS:-N/A} ms"
        TOTAL_TPS=$(( TOTAL_TPS + TPS ))

        if [[ -n "${LATENCY_MS}" ]] && (( TPS > 0 )); then
            local LAT_US
            LAT_US=$(awk "BEGIN {print ${LATENCY_MS} * 1000}")
            SUM_TPS_TIMES_LATENCY=$(awk "BEGIN {print ${SUM_TPS_TIMES_LATENCY} + (${TPS} * ${LAT_US})}")
            TOTAL_VALID_TPS=$(( TOTAL_VALID_TPS + TPS ))
        fi
    done

    if (( TOTAL_VALID_TPS > 0 )); then
        AVG_LATENCY_US=$(awk "BEGIN {printf \"%.1f\", ${SUM_TPS_TIMES_LATENCY} / ${TOTAL_VALID_TPS}}")
    fi
    log "Aggregate Throughput: ${TOTAL_TPS} TPS"
    log "Aggregate Avg Latency: ${AVG_LATENCY_US} us"

    # Collect CPU cycle statistics from the SUT using perf stat (optional).
    local CPU_CYCLES="N/A"
    local IPC="N/A"
    if [[ "${COLLECT_PERF}" -eq 1 ]]; then
        log "Collecting perf stat CPU cycle data from SUT for tag ${TAG}..."
        # Find the PID of the running memcached process on the SUT.
        local MC_PID
        MC_PID=$(ssh_sut "pgrep -n memcached 2>/dev/null || echo ''")
        if [[ -n "${MC_PID}" ]]; then
            # Run perf stat against the running process for a 10-second sample window.
            local PERF_OUT="${LOCAL_OUT}/perf_${TAG}.txt"
            ssh_sut "sudo perf stat -p ${MC_PID} -e cycles,instructions,cache-misses,cache-references \
                sleep ${DURATION} 2>&1" > "${PERF_OUT}" 2>&1 || true
            # Extract cycles and IPC from the perf stat output.
            if [[ -f "${PERF_OUT}" ]]; then
                CPU_CYCLES=$(grep -E 'cycles' "${PERF_OUT}" | awk '{gsub(/,/,""); print $1}' | head -1 || echo "N/A")
                local RAW_INSTR
                RAW_INSTR=$(grep -E 'instructions' "${PERF_OUT}" | awk '{gsub(/,/,""); print $1}' | head -1 || echo "0")
                if [[ "${CPU_CYCLES}" != "N/A" && "${CPU_CYCLES}" -gt 0 ]] 2>/dev/null; then
                    IPC=$(awk "BEGIN {printf \"%.3f\", ${RAW_INSTR}/${CPU_CYCLES}}")
                fi
                log "perf stat: cycles=${CPU_CYCLES}  IPC=${IPC}"
            fi
        else
            log "WARNING: could not find memcached PID on SUT for perf stat collection."
        fi
    fi

    # Append aggregated row to summary.csv directly from the orchestrator
    local SUMMARY_CSV="${LOCAL_OUT}/summary.csv"
    if [[ ! -f "${SUMMARY_CSV}" ]]; then
        echo "tag,server_ip,threads,concurrency,duration_s,keys,value_size_b,get_ratio,zipf_alpha,tps,cpu_cycles,ipc,avg_latency_us" > "${SUMMARY_CSV}"
    fi
    local CLIENT_COUNT=${#CLIENT_ARRAY[@]}
    local TOTAL_CONCURRENCY=$(( CONCURRENCY * CLIENT_COUNT ))
    echo "${TAG},${SUT_EXP_IP},${THREADS},${TOTAL_CONCURRENCY},${DURATION},100000,${VALSIZE},${GETRATIO},${ZIPF},${TOTAL_TPS},${CPU_CYCLES},${IPC},${AVG_LATENCY_US}" >> "${SUMMARY_CSV}"

    log "--- Experiment ${TAG} complete ---"
}

# ---------------------------------------------------------------------------
# Setup: create remote directories and copy scripts
# ---------------------------------------------------------------------------
log "Setting up SUT remote directory..."
ssh_sut "mkdir -p ${REMOTE_DIR}/results"

if [[ "${USE_BMC}" -eq 1 ]]; then
    log "Copying server_setup.sh to SUT..."
    scp_to_sut "${SCRIPT_DIR}/server_setup.sh" "${REMOTE_DIR}/server_setup.sh"
    ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh"
else
    log "Copying server_setup_nobmc.sh to SUT..."
    scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
    ssh_sut "chmod +x ${REMOTE_DIR}/server_setup_nobmc.sh"
fi

for CLI in "${CLIENT_ARRAY[@]}"; do
    log "Setting up client ${CLI} remote directory..."
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "mkdir -p ${REMOTE_DIR}/results"
    log "Copying client_run.sh to client ${CLI}..."
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SCRIPT_DIR}/client_run.sh" "${SSH_USER}@${CLI}:${REMOTE_DIR}/client_run.sh"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "chmod +x ${REMOTE_DIR}/client_run.sh"
done
mkdir -p "${LOCAL_OUT}"


# ---------------------------------------------------------------------------
# Baseline Experiment Suite
# Replicates the multi-core throughput scaling result (Figure 3 of the paper).
# Fixed: GET-heavy (99%), 64B values, high Zipf skew (alpha=0.99).
# Variable: number of memcached-sr worker threads (= RX queue count).
# ---------------------------------------------------------------------------
if [[ "${RUN_BASELINE}" -eq 1 ]]; then
    log "====== BASELINE SUITE: Multi-Core Throughput Scaling ======"
    for THREADS in 1 2 4 8; do
        run_experiment "${THREADS}" "0.99" "64" "0.95" "baseline_t${THREADS}"
        # Short pause between runs to let the system quiesce and interface stats reset.
        sleep 5
    done
    log "Baseline suite complete."
fi

# ---------------------------------------------------------------------------
# Stress Experiment Suite
# Explores failure boundaries and non-optimal workloads.
# ---------------------------------------------------------------------------
if [[ "${RUN_STRESS}" -eq 1 ]]; then
    log "====== STRESS SUITE: Failure Boundary Exploration ======"

    # 1. Zipf skew sweep: from near-uniform to highly skewed.
    #    Low alpha means many cold keys miss the BMC kernel cache; overhead increases.
    log "-- Workload 1: Zipf skew sweep (alpha = 0.1 to 1.2) --"
    for ALPHA in 0.1 0.3 0.5 0.7 0.99 1.2; do
        run_experiment "4" "${ALPHA}" "64" "0.99" "zipf_a${ALPHA}"
        sleep 5
    done

    # 2. Large payload ceiling: 8192B values exceed BMC_MAX_VAL_LENGTH (1000B).
    #    BMC will miss all these entries; XDP overhead is a pure cost.
    #    Disabled for UDP runs as memaslap does not support fragmented UDP payloads.
    # log "-- Workload 2: Large payload overhead (8192B values) --"
    # run_experiment "4" "0.99" "8192" "0.99" "large_payload_8192B"
    # sleep 5

    # 3. Medium payload: values near BMC_MAX_VAL_LENGTH boundary (1000-1400B).
    #    Marginal values that may or may not fit, causing partial cache population.
    log "-- Workload 3: Medium payload boundary (1000B and 1400B values) --"
    for VALSIZE in 1000 1200 1400; do
        run_experiment "4" "0.99" "${VALSIZE}" "0.99" "medium_payload_${VALSIZE}B"
        sleep 5
    done


    # 4. Write-heavy workload: high SET ratio forces frequent cache invalidation.
    #    BMC_PROG_XDP_INVALIDATE_CACHE runs on every invalidation, adding overhead.
    log "-- Workload 4: Write-heavy workload (50% SET / 50% GET) --"
    run_experiment "4" "0.99" "64" "0.50" "write_heavy_50pct_set"
    sleep 5

    # 5. Extreme write workload: nearly all SETs, minimal GET benefit.
    log "-- Workload 5: Extreme write workload (90% SET / 10% GET) --"
    run_experiment "4" "0.99" "64" "0.10" "write_extreme_90pct_set"
    sleep 5

    log "Stress suite complete."
fi

# ---------------------------------------------------------------------------
# Result collection: pull everything back to local results directory.
# ---------------------------------------------------------------------------
log "Pulling results from SUT..."
scp_from_sut "${REMOTE_DIR}/results/*" "${LOCAL_OUT}/" 2>/dev/null \
    || log "WARNING: No result files found on SUT. Did the experiments run correctly?"

log "Pulling configuration files from all clients..."
for CLI in "${CLIENT_ARRAY[@]}"; do
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}:${REMOTE_DIR}/results/*.cfg" "${LOCAL_OUT}/" 2>/dev/null || true
done

log "All results saved to ${LOCAL_OUT}/"
ls -lh "${LOCAL_OUT}/"

log "====== All experiments completed. ======"
log "Next step: run plot_results.py against the summary.csv in ${LOCAL_OUT}/"
