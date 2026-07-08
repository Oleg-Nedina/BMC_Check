#!/usr/bin/env bash
# =============================================================================
# stress_noise_flood.sh
# -----------------------------------------------------------------------------
# @brief  Corner Case 3 - Background Noise Parsing Tax.
#
# @note   The XDP hook must parse every incoming packet to determine if it is
#         a valid UDP port-11211 GET request. Background UDP floods targeting
#         other ports force the XDP program to parse and discard packets,
#         consuming CPU cycles in the driver context without serving any request.
#
# @note   This script uses trafgen on CLIENT2 to inject a sustained UDP flood
#         targeting port 80 (non-Memcached) while CLIENT1 runs the standard
#         memaslap closed-loop benchmark. The Memcached throughput degradation
#         as a function of noise rate is measured.
#
# @note   Assumption targeted: The paper evaluates BMC only in a clean isolated
#         lab network. Pre-stack filtering cost under non-Memcached traffic is
#         never measured.
#
# Usage:
#   ./stress_noise_flood.sh -S <sut_host> -C <client_host> -N <noise_client> \
#                           -i <iface> [OPTIONS]
#
# Options:
#   -S <sut_host>       SSH hostname of the SUT node. REQUIRED.
#   -C <client_host>    SSH hostname of the primary memaslap client. REQUIRED.
#   -N <noise_client>   SSH hostname of the noise-generating client. REQUIRED.
#   -i <iface>          Experiment interface name on the SUT. REQUIRED.
#   -u <ssh_user>       SSH username. (default: olleg)
#   -k <ssh_key>        Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
#   -o <local_out>      Local results directory. (default: ./results/stress/noise_flood)
#   -d <duration>       Benchmark duration per run in seconds. (default: 30)
#   -h, --help          Print this help and exit.
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
NOISE_CLIENT=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/stress/noise_flood"

DURATION=30
MC_PORT=11211
MC_MEMORY_MB=4096
THREADS=4
CONCURRENCY=128

# Noise injection rates to sweep (trafgen pps notation).
NOISE_RATES=("0" "100k" "500k" "1000k" "2000k")

usage() {
    echo "Usage: $0 -S <sut_host> -C <client_host> -N <noise_client> -i <iface> [OPTIONS]"
    echo "Corner Case 3: Background noise parsing tax measurement."
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S) SUT_HOST="$2"; shift 2 ;;
        -C) CLIENT_HOST="$2"; shift 2 ;;
        -N) NOISE_CLIENT="$2"; shift 2 ;;
        -i) IFACE="$2"; shift 2 ;;
        -u) SSH_USER="$2"; shift 2 ;;
        -k) SSH_KEY="$2"; shift 2 ;;
        -o) LOCAL_OUT="$2"; shift 2 ;;
        -d) DURATION="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" || -z "${NOISE_CLIENT}" || -z "${IFACE}" ]]; then
    echo "[ERROR] -S, -C, -N, and -i are required."
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

log "Copying setup scripts to SUT and clients..."
scp_to_sut "${SCRIPT_DIR}/server_setup.sh"       "${REMOTE_DIR}/server_setup.sh"
scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh ${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "mkdir -p ${REMOTE_DIR}/results"

for CLI in "${CLIENT_HOST}" "${NOISE_CLIENT}"; do
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" "mkdir -p ${REMOTE_DIR}/results"
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SCRIPT_DIR}/client_run.sh" \
        "${SSH_USER}@${CLI}:${REMOTE_DIR}/client_run.sh"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI}" \
        "chmod +x ${REMOTE_DIR}/client_run.sh"
done

SUT_EXP_IP=$(get_sut_exp_ip)
log "SUT experiment IP: ${SUT_EXP_IP}"

SUMMARY_CSV="${LOCAL_OUT}/noise_flood_summary.csv"
echo "mode,noise_rate_pps,memcached_tps,tps_degradation_pct" > "${SUMMARY_CSV}"

##
# @brief Write a minimal trafgen configuration for UDP port-80 flood.
# @param $1  SUT experiment IP address.
# @param $2  Destination port for the noise flood.
##
write_noise_cfg() {
    local DST_IP="$1"
    local DST_PORT="${2:-80}"
    local CFG_FILE="/tmp/noise_flood.cfg"
    cat > "${CFG_FILE}" << CFG
{
  /* Ethernet header */
  0x00, 0x00, 0x00, 0x00, 0x00, 0x01,  /* dst MAC */
  0x00, 0x00, 0x00, 0x00, 0x00, 0x02,  /* src MAC */
  0x08, 0x00,                            /* EtherType: IPv4 */
  /* IPv4 header */
  0x45, 0x00, 0x00, 0x1c,              /* Version, IHL, TOS, Total Length=28 */
  0x00, 0x00, 0x40, 0x00,              /* ID, Flags, Fragment Offset */
  0x40, 0x11, 0x00, 0x00,              /* TTL=64, Protocol=UDP, Checksum (0=auto) */
  drnd(4),                               /* src IP (random) */
  $(echo "${DST_IP}" | awk -F. '{printf "0x%02x, 0x%02x, 0x%02x, 0x%02x", $1,$2,$3,$4}'),
  /* UDP header */
  drnd(2),                               /* src port (random) */
  const16(${DST_PORT}),                  /* dst port */
  0x00, 0x08,                            /* length=8 */
  0x00, 0x00,                            /* checksum (0=disabled) */
}
CFG
    echo "${CFG_FILE}"
}

##
# @brief Run one noise measurement: memaslap on CLIENT_HOST + optional trafgen on NOISE_CLIENT.
# @param $1  Mode string: "bmc" or "nobmc".
# @param $2  Noise rate string (e.g. "0", "500k", "2000k").
# @param $3  Baseline TPS (0 noise) for percentage calculation.
##
run_noise_experiment() {
    local MODE="$1"
    local NOISE_RATE="$2"
    local BASELINE_TPS="${3:-0}"
    local TAG="noise_${MODE}_${NOISE_RATE}"
    local SERVER_TOTAL=$(( DURATION + 20 ))

    log "--- Starting: ${TAG} (noise=${NOISE_RATE}) ---"

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

    # Launch noise flood on NOISE_CLIENT if rate > 0.
    local NOISE_JOB=""
    if [[ "${NOISE_RATE}" != "0" ]]; then
        log "Injecting noise flood at ${NOISE_RATE} pps from ${NOISE_CLIENT}..."
        # Write trafgen config targeting port 80 on the SUT.
        local NOISE_CFG
        NOISE_CFG=$(write_noise_cfg "${SUT_EXP_IP}" 80)
        scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
            "${NOISE_CFG}" "${SSH_USER}@${NOISE_CLIENT}:/tmp/noise_flood.cfg"
        ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${NOISE_CLIENT}" \
            "sudo trafgen --dev ${IFACE} \
                --conf /tmp/noise_flood.cfg \
                --rate ${NOISE_RATE} \
                --duration ${DURATION}s 2>/dev/null" &
        NOISE_JOB=$!
    fi

    # Run memaslap benchmark on CLIENT_HOST.
    local RAW_TAG="${TAG}_${CLIENT_HOST}"
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "bash ${REMOTE_DIR}/client_run.sh \
            -s ${SUT_EXP_IP} -p ${MC_PORT} \
            -t ${THREADS} -c ${CONCURRENCY} -d ${DURATION} \
            -k 100000 -z 0.99 -r 0.95 -v 64 \
            -o ${REMOTE_DIR}/results \
            -g ${RAW_TAG} --warm --udp" &
    local CLI_JOB=$!

    wait "${CLI_JOB}" || log "WARNING: client job exited non-zero."
    [[ -n "${NOISE_JOB}" ]] && { wait "${NOISE_JOB}" 2>/dev/null || true; }
    wait "${SUT_JOB}" || log "WARNING: server job exited non-zero."

    local LOCAL_RAW="${LOCAL_OUT}/raw_${TAG}.txt"
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
        "${SSH_USER}@${CLIENT_HOST}:${REMOTE_DIR}/results/raw_${RAW_TAG}.txt" \
        "${LOCAL_RAW}" 2>/dev/null || true

    local TPS=0
    if [[ -f "${LOCAL_RAW}" ]]; then
        TPS=$(grep -i 'TPS:' "${LOCAL_RAW}" | tail -1 | grep -oP 'TPS:\s*\K[0-9]+' || echo 0)
    fi

    local DEGRADATION="N/A"
    if [[ "${BASELINE_TPS}" -gt 0 && "${TPS}" -gt 0 ]] 2>/dev/null; then
        DEGRADATION=$(awk "BEGIN {printf \"%.2f\", (1 - ${TPS}/${BASELINE_TPS})*100}")
    fi

    log "Results: mode=${MODE} noise=${NOISE_RATE} tps=${TPS} degradation=${DEGRADATION}%"
    echo "${MODE},${NOISE_RATE},${TPS},${DEGRADATION}" >> "${SUMMARY_CSV}"
    log "--- ${TAG} complete ---"
    sleep 5
}

log "====== CORNER CASE 3: Background Noise Parsing Tax Sweep ======"

for MODE in "nobmc" "bmc"; do
    log "--- Mode: ${MODE} ---"
    BASELINE_TPS=0
    for RATE in "${NOISE_RATES[@]}"; do
        run_noise_experiment "${MODE}" "${RATE}" "${BASELINE_TPS}"
        # Set baseline TPS from the zero-noise run.
        if [[ "${RATE}" == "0" ]]; then
            BASELINE_TPS=$(grep "^${MODE},0," "${SUMMARY_CSV}" | tail -1 | cut -d',' -f3 || echo 0)
            log "Baseline TPS for ${MODE}: ${BASELINE_TPS}"
        fi
    done
    sleep 10
done

log "====== Noise flood sweep complete. Results in ${LOCAL_OUT}/ ======"
cat "${SUMMARY_CSV}"

# ---------------------------------------------------------------------------
# Generate plots from collected results.
# ---------------------------------------------------------------------------
SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 &>/dev/null; then
    log "Generating plots with plot_noise_flood.py..."
    cd "${SCRIPT_SELF}/.." || cd .
    python3 "${SCRIPT_SELF}/plot_noise_flood.py" || log "WARNING: plot generation failed."
fi
