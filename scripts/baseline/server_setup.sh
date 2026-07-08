#!/usr/bin/env bash
# =============================================================================
# server_setup.sh
# -----------------------------------------------------------------------------
# Purpose : Set up and run BMC on the CloudLab SUT (System Under Test) node.
#           This script handles BPF filesystem mounting, RX queue configuration,
#           memcached-sr startup, BMC loader attachment, and TC egress hook setup.
#           It is intended to be copied to the SUT and invoked remotely by
#           run_benchmark.sh, or run manually during development.
#
# Usage   : ./server_setup.sh [OPTIONS]
#   -i <iface>     Experiment network interface name (e.g., enp6s0f1). REQUIRED.
#   -t <threads>   Number of memcached-sr worker threads (= RX queue count). REQUIRED.
#   -p <port>      Memcached UDP/TCP port (default: 11211).
#   -d <duration>  Stats collection duration in seconds (default: 30).
#   -m <memory>    Memcached memory limit in MB (default: 4096).
#   -b <bmc_dir>   Absolute path to the directory containing the bmc binary.
#   -s <mc_dir>    Absolute path to the memcached-sr directory.
#   -o <out_dir>   Directory where results are written (default: /tmp/bmc_results).
#
# Output  : /tmp/bmc_stats.txt            -- final aggregate stats (written on SIGTERM)
#           /tmp/bmc_stats_interval.txt   -- per-interval stats timeseries
#           <out_dir>/server_stats_<tag>.csv  -- copied results for the orchestrator
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
IFACE=""
NUM_THREADS=""
MC_PORT=11211
DURATION=30
MC_MEMORY_MB=4096
BMC_DIR=""
MC_DIR=""
OUT_DIR="/tmp/bmc_results"
BPF_FS="/sys/fs/bpf"
TC_PIN_PATH="${BPF_FS}/bmc_tx_filter"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
##
# @brief Print a comprehensive usage reference and exit.
# @note  Triggered by -h or --help.
##
usage() {
    cat <<EOF
=============================================================================
server_setup.sh -- SUT-side BMC + Memcached-SR Lifecycle Manager
=============================================================================

DESCRIPTION
    Configures the SUT network interface, mounts the BPF filesystem, launches
    memcached-sr, loads the BMC eBPF programs via the user-space loader, attaches
    the TC egress hook, waits for the experiment duration, then performs a full
    teardown and saves BMC statistics.

    This script is intended to be copied to the SUT by run_benchmark.sh and
    executed remotely via SSH, but it can also be run manually on the SUT.

USAGE
    ./server_setup.sh -i <iface> -t <threads> [OPTIONS]

REQUIRED ARGUMENTS
    -i <iface>      Experiment network interface name (e.g., ens1f1np1).
                    Must carry a private 10.x.x.x IP address.
    -t <threads>    Number of memcached-sr worker threads (= hardware RX queue count).

OPTIONAL ARGUMENTS
    -p <port>       Memcached TCP and UDP port. (default: 11211)
    -d <duration>   Benchmark duration in seconds. The server stays alive for
                    duration + 10 seconds to allow client warmup. (default: 30)
    -m <memory_mb>  Memcached memory limit in MB. (default: 4096)
    -b <bmc_dir>    Absolute path to the directory containing the bmc binary.
                    (default: <script_dir>/../bmc-cache/bmc)
    -s <mc_dir>     Absolute path to the memcached-sr directory.
                    (default: <script_dir>/../bmc-cache/memcached-sr)
    -o <out_dir>    Directory where BMC statistics are written. (default: /tmp/bmc_results)
    -h, --help      Print this help message and exit.

OUTPUT FILES
    /tmp/bmc_stats.txt           : Final aggregate hit/miss counters (written on SIGTERM).
    /tmp/bmc_stats_interval.txt  : Per-5-second counters timeseries.
    <out_dir>/stats_<tag>.txt    : Timestamped copy of final stats for the orchestrator.
    <out_dir>/interval_<tag>.csv : Timestamped copy of interval stats.

TEARDOWN
    On completion, all TC filters, qdiscs, XDP programs, and the BPF pin at
    /sys/fs/bpf/bmc_tx_filter are cleaned up automatically.
=============================================================================
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i) IFACE="$2"; shift 2 ;;
        -t) NUM_THREADS="$2"; shift 2 ;;
        -p) MC_PORT="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -m) MC_MEMORY_MB="$2"; shift 2 ;;
        -b) BMC_DIR="$2"; shift 2 ;;
        -s) MC_DIR="$2"; shift 2 ;;
        -o) OUT_DIR="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done


if [[ -z "${IFACE}" || -z "${NUM_THREADS}" ]]; then
    echo "[ERROR] -i <iface> and -t <threads> are required."
    usage
fi

if [[ -z "${BMC_DIR}" ]]; then
    # Assume bmc binary lives one directory above this script in bmc-cache/bmc/
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    BMC_DIR="${SCRIPT_DIR}/../bmc-cache/bmc"
fi

if [[ -z "${MC_DIR}" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    MC_DIR="${SCRIPT_DIR}/../bmc-cache/memcached-sr"
fi

BMC_BIN="${BMC_DIR}/bmc"
MC_BIN="${MC_DIR}/memcached"

# ---------------------------------------------------------------------------
# Sanity checks
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*"; }
die() { echo "[ERROR] $*" >&2; exit 1; }

[[ -x "${BMC_BIN}" ]] || die "bmc binary not found or not executable at: ${BMC_BIN}. Build it first with 'cd bmc-cache/bmc && make'."
[[ -x "${MC_BIN}" ]]  || die "memcached binary not found at: ${MC_DIR}. Build memcached-sr first."
command -v tc         >/dev/null 2>&1 || die "tc (iproute2) not found."
command -v ethtool    >/dev/null 2>&1 || die "ethtool not found."

mkdir -p "${OUT_DIR}"

# ---------------------------------------------------------------------------
# Derive the interface index (bmc takes numeric interface index, not name)
# ---------------------------------------------------------------------------
IFACE_IDX=$(cat /sys/class/net/"${IFACE}"/ifindex 2>/dev/null) \
    || die "Cannot read ifindex for interface '${IFACE}'. Is the interface name correct?"
log "Interface ${IFACE} has index ${IFACE_IDX}."

# ---------------------------------------------------------------------------
# Step 1: Mount BPF filesystem if not already mounted
# ---------------------------------------------------------------------------
if ! mountpoint -q "${BPF_FS}"; then
    log "Mounting BPF filesystem at ${BPF_FS}..."
    mount -t bpf none "${BPF_FS}" || die "Failed to mount BPF filesystem. Are you running as root?"
else
    log "BPF filesystem already mounted at ${BPF_FS}."
fi

# Clean up any leftover pin from a previous run to avoid EEXIST errors.
# bmc_user.c handles this internally with a goto retry, but we clean up
# proactively to keep logs readable.
if [[ -e "${TC_PIN_PATH}" ]]; then
    log "Removing stale BPF pin at ${TC_PIN_PATH}..."
    rm -f "${TC_PIN_PATH}"
fi

# ---------------------------------------------------------------------------
# Step 2: Clean up any leftover TC hooks from a previous run
# ---------------------------------------------------------------------------
log "Cleaning up previous TC hooks on ${IFACE} (if any)..."
tc filter del dev "${IFACE}" egress 2>/dev/null || true
tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true

# Also detach any existing XDP program from the interface.
ip link set dev "${IFACE}" xdp off 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 3: Configure RX queue count via ethtool
#         This maps one hardware RX queue per memcached-sr worker thread,
#         which is the configuration used in the paper to achieve scaling.
# ---------------------------------------------------------------------------
log "Setting combined channels to ${NUM_THREADS} on ${IFACE}..."
ethtool -L "${IFACE}" combined "${NUM_THREADS}" 2>/dev/null \
    || log "WARNING: ethtool -L failed. The NIC may not support runtime queue reconfiguration. Proceeding anyway."

# ---------------------------------------------------------------------------
# Step 3b: Bind NIC RX queue interrupts to distinct CPU cores
# ---------------------------------------------------------------------------
log "Stopping irqbalance to allow manual affinity mapping..."
systemctl stop irqbalance 2>/dev/null || killall irqbalance 2>/dev/null || true

log "Mapping queue interrupts to distinct CPU cores..."
PCI_ADDR=$(basename $(readlink /sys/class/net/${IFACE}/device))
for i in $(seq 0 $((NUM_THREADS - 1))); do
    IRQ=$(grep -E "mlx5_comp${i}@pci:${PCI_ADDR}" /proc/interrupts | awk '{print $1}' | tr -d ':')
    
    # Fallback to general grep if empty
    if [[ -z "${IRQ}" ]]; then
        IRQ=$(grep -E "${IFACE}-${i}$" /proc/interrupts | awk '{print $1}' | tr -d ':')
    fi
    if [[ -z "${IRQ}" ]]; then
        IRQ=$(grep -E "${IFACE}.*${i}" /proc/interrupts | head -n 1 | awk '{print $1}' | tr -d ':')
    fi

    if [[ -n "${IRQ}" ]]; then
        log "Binding queue ${i} (IRQ ${IRQ}) to CPU core ${i}..."
        echo "${i}" > "/proc/irq/${IRQ}/smp_affinity_list" 2>/dev/null \
            || log "WARNING: Failed to bind IRQ ${IRQ} to CPU core ${i}"
    else
        log "WARNING: Could not find IRQ for queue index ${i} on ${IFACE}."
    fi
done


# ---------------------------------------------------------------------------
# Step 4: Start memcached-sr
#         -p: TCP port, -U: UDP port, -t: worker threads, -m: memory in MB
#         -l: listen on all interfaces
#         We run it in the background and record its PID for cleanup.
# ---------------------------------------------------------------------------
log "Starting memcached-sr with ${NUM_THREADS} threads, ${MC_MEMORY_MB} MB memory on port ${MC_PORT}..."
"${MC_BIN}" -u root -p "${MC_PORT}" -U "${MC_PORT}" -t "${NUM_THREADS}" -m "${MC_MEMORY_MB}" -l 0.0.0.0 &
MC_PID=$!
log "memcached-sr started (PID ${MC_PID})."

# Give memcached a moment to bind and be ready.
sleep 2

if ! kill -0 "${MC_PID}" 2>/dev/null; then
    die "memcached-sr failed to start. Check the output above for errors."
fi

# ---------------------------------------------------------------------------
# Step 5: Launch the BMC loader
#         -c: number of stat collection intervals
#         -i: stat collection interval in seconds
#         The loader runs in the background. It attaches XDP to the interface,
#         populates the prog_array tail call map, and pins bmc_tx_filter.
# ---------------------------------------------------------------------------
STAT_INTERVALS=$(( DURATION / 5 ))
[[ ${STAT_INTERVALS} -lt 1 ]] && STAT_INTERVALS=1

# Log file for BMC loader output (libbpf relocation and verifier messages).
# Redirected to file to avoid cluttering the orchestrator console output.
# On failure the tail of this log is printed for diagnostic purposes.
BMC_LOG="/tmp/bmc_loader.log"

log "Launching BMC loader on interface ${IFACE} (index ${IFACE_IDX})..."
cd "${BMC_DIR}"
./bmc -c "${STAT_INTERVALS}" -i 5 "${IFACE_IDX}" > "${BMC_LOG}" 2>&1 &
BMC_PID=$!
log "BMC loader started (PID ${BMC_PID}). Full output: ${BMC_LOG}"

# Wait for bmc to pin the TX filter program to the BPF filesystem.
# The pin happens during program load, which is fast but not instant.
log "Waiting for BMC to pin bmc_tx_filter to ${TC_PIN_PATH}..."
WAIT=0
MAX_WAIT=15
until [[ -e "${TC_PIN_PATH}" ]]; do
    sleep 1
    WAIT=$(( WAIT + 1 ))
    if [[ ${WAIT} -ge ${MAX_WAIT} ]]; then
        log "--- BMC loader log (last 30 lines) ---"
        tail -30 "${BMC_LOG}" >&2
        log "--- End of BMC loader log ---"
        die "Timeout: bmc_tx_filter was not pinned after ${MAX_WAIT} seconds. BMC may have failed to load. See ${BMC_LOG} above."
    fi
done
log "bmc_tx_filter pinned successfully."

# ---------------------------------------------------------------------------
# Step 6: Attach the TC egress hook
#         This is a manual step required by BMC (not done by the loader).
#         The clsact qdisc enables both ingress and egress classification.
# ---------------------------------------------------------------------------
log "Attaching TC egress hook on ${IFACE}..."
tc qdisc add dev "${IFACE}" clsact \
    || die "Failed to add clsact qdisc. Is the kernel module 'sch_clsact' loaded?"
tc filter add dev "${IFACE}" egress bpf object-pinned "${TC_PIN_PATH}" \
    || die "Failed to attach TC egress BPF filter."
log "TC egress hook attached."

# ---------------------------------------------------------------------------
# Step 7: Wait for the experiment duration, then terminate
# ---------------------------------------------------------------------------
log "Server setup complete. Waiting ${DURATION} seconds for the benchmark to run..."
log "Send SIGUSR1 to BMC (PID ${BMC_PID}) to dump intermediate stats at any time."
sleep "${DURATION}"

# ---------------------------------------------------------------------------
# Step 8: Collect stats and clean up
# ---------------------------------------------------------------------------
log "Sending SIGTERM to BMC to trigger final stats write..."
kill -SIGTERM "${BMC_PID}" 2>/dev/null || true
wait "${BMC_PID}" 2>/dev/null || true

log "Stopping memcached-sr (PID ${MC_PID})..."
kill -SIGTERM "${MC_PID}" 2>/dev/null || true
wait "${MC_PID}" 2>/dev/null || true

# Detach TC hooks and unpin BPF programs.
log "Detaching TC hooks and cleaning up BPF state..."
tc filter del dev "${IFACE}" egress 2>/dev/null || true
tc qdisc del dev "${IFACE}" clsact 2>/dev/null || true
ip link set dev "${IFACE}" xdp off 2>/dev/null || true
rm -f "${TC_PIN_PATH}"

# Copy results to the output directory with a timestamped tag.
TAG="${IFACE}_t${NUM_THREADS}_$(date '+%Y%m%d_%H%M%S')"
if [[ -f /tmp/bmc_stats.txt ]]; then
    cp /tmp/bmc_stats.txt "${OUT_DIR}/stats_${TAG}.txt"
    log "Final stats written to ${OUT_DIR}/stats_${TAG}.txt"
fi
if [[ -f /tmp/bmc_stats_interval.txt ]]; then
    cp /tmp/bmc_stats_interval.txt "${OUT_DIR}/interval_${TAG}.csv"
    log "Interval stats written to ${OUT_DIR}/interval_${TAG}.csv"
fi

log "Server teardown complete."
