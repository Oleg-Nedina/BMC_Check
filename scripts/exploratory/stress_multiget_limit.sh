#!/usr/bin/env bash
# =============================================================================
# stress_multiget_limit.sh
# -----------------------------------------------------------------------------
# @brief  Corner Case 4 - Multi-GET >30 Key Silent Packet-Loss Boundary.
#
# @note   BMC_MAX_KEY_IN_MULTIGET = 30 (bmc_kern.c). If a UDP GET datagram
#         contains more than 30 keys, the XDP program returns XDP_DROP instead
#         of XDP_PASS. The packet is silently discarded at the NIC driver level.
#         User-space Memcached never sees the request; the client receives a
#         socket timeout rather than a protocol error.
#
# @note   This script sends multi-GET datagrams containing exactly 1, 20, 31,
#         and 50 keys and measures the client-side packet loss rate (expected
#         100% loss for >30 keys under BMC, 0% under MemcachedSR).
#
# @note   Assumption targeted: Client libraries batch multiple GET operations
#         into a single datagram for efficiency. BMC silently drops these
#         requests beyond a hardcoded limit, with no error or fallback.
#
# Usage:
#   ./stress_multiget_limit.sh -S <sut_host> -C <client_host> -i <iface> [OPTIONS]
#
# Options:
#   -S <sut_host>     SSH hostname of the SUT node. REQUIRED.
#   -C <client_host>  SSH hostname of the Client node. REQUIRED.
#   -i <iface>        Experiment interface name on the SUT. REQUIRED.
#   -u <ssh_user>     SSH username. (default: olleg)
#   -k <ssh_key>      Path to SSH private key. (default: ~/.ssh/id_ed25519_net)
#   -o <local_out>    Local results directory. (default: ./results/stress/multiget_limit)
#   -n <requests>     Number of test requests to send per key count. (default: 100)
#   -h, --help        Print this help and exit.
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
IFACE=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"
REMOTE_DIR="~/bmc_bench"
LOCAL_OUT="./results/stress/multiget_limit"

NUM_REQUESTS=100
MC_PORT=11211
MC_MEMORY_MB=4096
THREADS=4

# Key counts to sweep. 30 is the BMC limit; 31+ expected to trigger XDP_DROP.
KEY_COUNTS=(1 10 20 30 31 50)

usage() {
    echo "Usage: $0 -S <sut_host> -C <client_host> -i <iface> [OPTIONS]"
    echo "Corner Case 4: Multi-GET >30 key silent packet-loss boundary test."
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
        -n) NUM_REQUESTS="$2"; shift 2 ;;
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

log "Copying setup scripts to SUT..."
scp_to_sut "${SCRIPT_DIR}/server_setup.sh"       "${REMOTE_DIR}/server_setup.sh"
scp_to_sut "${SCRIPT_DIR}/server_setup_nobmc.sh" "${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "chmod +x ${REMOTE_DIR}/server_setup.sh ${REMOTE_DIR}/server_setup_nobmc.sh"
ssh_sut "mkdir -p ${REMOTE_DIR}/results"
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" "mkdir -p ${REMOTE_DIR}"

SUT_EXP_IP=$(get_sut_exp_ip)
log "SUT experiment IP: ${SUT_EXP_IP}"

# Write the Python multi-GET UDP probe to the client.
# This script sends a Memcached UDP ASCII GET with N keys and measures response rate.
cat > /tmp/multiget_probe.py << 'PYEOF'
#!/usr/bin/env python3
"""
multiget_probe.py
-----------------
Sends Memcached ASCII UDP GET requests with a configurable number of keys
and measures the response success rate. Under BMC with >30 keys, XDP_DROP
causes 100% packet loss (no response). Under MemcachedSR, all requests
should receive a response (END or VALUE for cached keys).

Usage: python3 multiget_probe.py <server_ip> <port> <key_count> <num_requests> <timeout_s>
"""
import socket
import sys
import struct
import time

def send_multiget(server_ip, port, key_count, num_requests, timeout_s):
    keys = [f"testkey{i:04d}" for i in range(key_count)]
    cmd = "get " + " ".join(keys) + "\r\n"
    cmd_bytes = cmd.encode()

    received = 0
    lost = 0

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout_s)

    for req_id in range(num_requests):
        # Memcached UDP header: request_id(2B), seq_num(2B), num_datagrams(2B), reserved(2B)
        udp_header = struct.pack(">HHHH", req_id, 0, 1, 0)
        datagram = udp_header + cmd_bytes
        try:
            sock.sendto(datagram, (server_ip, port))
            data, _ = sock.recvfrom(65535)
            received += 1
        except socket.timeout:
            lost += 1
        except Exception as e:
            lost += 1

    sock.close()
    loss_rate = lost / num_requests * 100.0
    success_rate = received / num_requests * 100.0
    print(f"key_count={key_count} sent={num_requests} received={received} lost={lost} "
          f"success_pct={success_rate:.1f} loss_pct={loss_rate:.1f}")
    return received, lost

if __name__ == "__main__":
    if len(sys.argv) != 6:
        print("Usage: python3 multiget_probe.py <server_ip> <port> <key_count> <num_requests> <timeout_s>")
        sys.exit(1)
    server_ip   = sys.argv[1]
    port        = int(sys.argv[2])
    key_count   = int(sys.argv[3])
    num_reqs    = int(sys.argv[4])
    timeout_s   = float(sys.argv[5])
    send_multiget(server_ip, port, key_count, num_reqs, timeout_s)
PYEOF

scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no \
    /tmp/multiget_probe.py "${SSH_USER}@${CLIENT_HOST}:${REMOTE_DIR}/multiget_probe.py"

SUMMARY_CSV="${LOCAL_OUT}/multiget_limit_summary.csv"
echo "mode,key_count,sent,received,lost,success_pct,loss_pct" > "${SUMMARY_CSV}"

##
# @brief Run the multi-GET probe sweep for one server mode.
# @param $1  Mode: "bmc" or "nobmc".
##
run_multiget_sweep() {
    local MODE="$1"
    local SERVER_TOTAL=300
    local TAG="multiget_${MODE}"

    log "====== Starting multi-GET probe: mode=${MODE} ======"

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

    # Pre-populate a small set of test keys via SET so GET can potentially hit them.
    log "Pre-populating test keys in Memcached..."
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
        "python3 -c \"
import socket, struct
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2)
for i in range(50):
    key = f'testkey{i:04d}'
    val = 'value' * 4
    cmd = f'set {key} 0 0 {len(val)}\r\n{val}\r\n'.encode()
    hdr = struct.pack('>HHHH', i, 0, 1, 0)
    try: s.sendto(hdr + cmd, ('${SUT_EXP_IP}', ${MC_PORT})); s.recvfrom(1024)
    except: pass
s.close()
print('Pre-population complete.')
\"" 2>/dev/null || log "WARNING: pre-population may have partially failed."

    # Run the probe for each key count.
    for KC in "${KEY_COUNTS[@]}"; do
        log "Probing: mode=${MODE} key_count=${KC}"
        local PROBE_OUT
        PROBE_OUT=$(ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_HOST}" \
            "python3 ${REMOTE_DIR}/multiget_probe.py \
                ${SUT_EXP_IP} ${MC_PORT} ${KC} ${NUM_REQUESTS} 0.1" 2>/dev/null || echo "error")

        log "  Probe result: ${PROBE_OUT}"

        # Parse output fields.
        local SENT RECEIVED LOST SUCCESS LOSS
        SENT=$(echo "${PROBE_OUT}" | grep -oP 'sent=\K[0-9]+' || echo 0)
        RECEIVED=$(echo "${PROBE_OUT}" | grep -oP 'received=\K[0-9]+' || echo 0)
        LOST=$(echo "${PROBE_OUT}" | grep -oP 'lost=\K[0-9]+' || echo 0)
        SUCCESS=$(echo "${PROBE_OUT}" | grep -oP 'success_pct=\K[0-9.]+' || echo 0)
        LOSS=$(echo "${PROBE_OUT}" | grep -oP 'loss_pct=\K[0-9.]+' || echo 0)

        echo "${MODE},${KC},${SENT},${RECEIVED},${LOST},${SUCCESS},${LOSS}" >> "${SUMMARY_CSV}"
        sleep 1
    done

    # Terminate the server.
    ssh_sut "sudo pkill -f memcached 2>/dev/null || true" || true
    kill "${SUT_JOB}" 2>/dev/null || true

    log "====== Multi-GET probe ${MODE} complete ======"
    sleep 5
}

log "====== CORNER CASE 4: Multi-GET Packet-Loss Safety Boundary ======"
log "Threshold: BMC_MAX_KEY_IN_MULTIGET=30. Keys >30 expected XDP_DROP."

run_multiget_sweep "nobmc"
sleep 10
run_multiget_sweep "bmc"

log "====== Multi-GET sweep complete. Results in ${LOCAL_OUT}/ ======"
cat "${SUMMARY_CSV}"

# ---------------------------------------------------------------------------
# Generate plots from collected results.
# ---------------------------------------------------------------------------
SCRIPT_SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if command -v python3 &>/dev/null; then
    log "Generating plots with plot_multiget_limit.py..."
    cd "${SCRIPT_SELF}/.." || cd .
    python3 "${SCRIPT_SELF}/plot_multiget_limit.py" || log "WARNING: plot generation failed."
fi
