#!/usr/bin/env bash
# =============================================================================
# deploy_all.sh
# -----------------------------------------------------------------------------
# Purpose : Automate SUT and client initialization, dependency installation,
#           compilation, and memaslap binary distribution on new CloudLab nodes.
#
# Usage   : ./deploy_all.sh -S <sut_host> -C "<client1> <client2>"
# =============================================================================

set -euo pipefail

SUT_HOST=""
CLIENT_HOST=""
SSH_USER="olleg"
SSH_KEY="${HOME}/.ssh/id_ed25519_net"

usage() {
    echo "Usage: $0 -S <sut_host> -C \"<client_hosts>\" [-u <ssh_user>] [-k <ssh_key>]"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -S) SUT_HOST="$2"; shift 2 ;;
        -C) CLIENT_HOST="$2"; shift 2 ;;
        -u) SSH_USER="$2"; shift 2 ;;
        -k) SSH_KEY="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "[ERROR] Unknown argument: $1"; usage ;;
    esac
done

if [[ -z "${SUT_HOST}" || -z "${CLIENT_HOST}" ]]; then
    echo "[ERROR] -S <sut_host> and -C <client_hosts> are required."
    usage
fi

read -r -a CLIENT_ARRAY <<< "${CLIENT_HOST}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }
ssh_sut() { ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "$@"; }
ssh_cli() { local CLI_TARGET="${1}"; shift; ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLI_TARGET}" "$@"; }

# ---------------------------------------------------------------------------
# Step 1: Update local SSH config
# ---------------------------------------------------------------------------
log "Updating local SSH config (~/.ssh/config)..."
SSH_CONFIG="${HOME}/.ssh/config"
cp "${SSH_CONFIG}" "${SSH_CONFIG}.bak"

# Clean old entries for Host sut, client1, client2
sed -i '/Host sut/,+5d' "${SSH_CONFIG}" || true
sed -i '/Host client1/,+5d' "${SSH_CONFIG}" || true
sed -i '/Host client2/,+5d' "${SSH_CONFIG}" || true

# Append new clean mappings
cat >> "${SSH_CONFIG}" <<EOF

Host sut
    HostName ${SUT_HOST}
    Port 22
    User ${SSH_USER}
    IdentityFile ${SSH_KEY}

Host client1
     HostName ${CLIENT_ARRAY[0]}
     Port 22
     User ${SSH_USER}
     IdentityFile ${SSH_KEY}
EOF

if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    cat >> "${SSH_CONFIG}" <<EOF

Host client2
     HostName ${CLIENT_ARRAY[1]}
     Port 22
     User ${SSH_USER}
     IdentityFile ${SSH_KEY}
EOF
fi
log "SSH config updated successfully."

# ---------------------------------------------------------------------------
# Step 2: Connectivity verification & host key learning
# ---------------------------------------------------------------------------
log "Testing SSH connectivity and accepting host keys..."
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}" "uname -a" >/dev/null
ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_ARRAY[0]}" "uname -a" >/dev/null
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    ssh -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${CLIENT_ARRAY[1]}" "uname -a" >/dev/null
fi
log "Connectivity established."

# ---------------------------------------------------------------------------
# Step 3: Install SUT and Client dependencies
# ---------------------------------------------------------------------------
log "Installing dependencies on SUT..."
ssh_sut "sudo apt-get update -qq && sudo apt-get install -y build-essential clang llvm libelf-dev libevent-dev autoconf automake libtool libmemcached-tools flex bison libssl-dev bc cmake" &
SUT_DEP_JOB=$!

log "Installing dependencies on Client 1..."
ssh_cli "${CLIENT_ARRAY[0]}" "sudo apt-get update -qq && sudo apt-get install -y build-essential libevent-dev libsasl2-dev cmake libmemcached-dev" &
CLI1_DEP_JOB=$!

CLI2_DEP_JOB=""
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    log "Installing dependencies on Client 2..."
    ssh_cli "${CLIENT_ARRAY[1]}" "sudo apt-get update -qq && sudo apt-get install -y build-essential libevent-dev libsasl2-dev cmake libmemcached-dev" &
    CLI2_DEP_JOB=$!
fi

wait "${SUT_DEP_JOB}"
wait "${CLI1_DEP_JOB}"
if [[ -n "${CLI2_DEP_JOB}" ]]; then
    wait "${CLI2_DEP_JOB}"
fi
log "Dependencies installed successfully on all nodes."

# ---------------------------------------------------------------------------
# Step 4: Clone SUT Repo, Download Kernel, Compile BMC & Memcached
# ---------------------------------------------------------------------------
log "Setting up repository and kernel sources on SUT..."
ssh_sut "git clone https://github.com/Orange-OpenSource/bmc-cache.git ~/bmc-cache"
ssh_sut "wget -O ~/bmc-cache/linux-5.3.tar.xz https://mirrors.edge.kernel.org/pub/linux/kernel/v5.x/linux-5.3.tar.xz"
ssh_sut "cd ~/bmc-cache && ./kernel-src-prepare.sh"

log "Copying local corrected bmc_kern.c with verifier fixes to SUT..."
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no bmc-cache/bmc/bmc_kern.c "${SSH_USER}@${SUT_HOST}:~/bmc-cache/bmc/bmc_kern.c"

log "Compiling BMC loader and kernel XDP filters..."
ssh_sut "cd ~/bmc-cache/bmc && make CLANG=clang LLC=llc"

log "Compiling Memcached versions (SO_REUSEPORT and Vanilla)..."
ssh_sut "cd ~/bmc-cache/memcached-sr && ./autogen.sh && CC=clang CFLAGS='-DREUSEPORT_OPT=1 -Wno-deprecated-declarations -Wno-error' ./configure && make CFLAGS='-O2 -DREUSEPORT_OPT=1 -Wno-deprecated-declarations -Wno-error -fcommon' && mv memcached memcached-sr-bin && make clean && CC=clang CFLAGS='-Wno-deprecated-declarations -Wno-error' ./configure && make CFLAGS='-O2 -Wno-deprecated-declarations -Wno-error -fcommon' && mv memcached memcached-vanilla && mv memcached-sr-bin memcached"

# ---------------------------------------------------------------------------
# Step 5: Compile memaslap on SUT and distribute to clients
# ---------------------------------------------------------------------------
log "Compiling memaslap with silent-print patch on SUT..."
ssh_sut "git clone --depth=1 https://github.com/awesomized/libmemcached.git ~/libmemcached-awesome && sed -i '496s/printf/\/\/ printf/' ~/libmemcached-awesome/contrib/bin/memaslap/ms_task.c && cd ~/libmemcached-awesome && mkdir -p build && cd build && cmake -DENABLE_MEMASLAP=ON .. && make -j4"

log "Distributing memaslap binary to clients via local bridge..."
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no "${SSH_USER}@${SUT_HOST}:~/libmemcached-awesome/build/contrib/bin/memaslap/memaslap" /tmp/memaslap
scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no /tmp/memaslap "${SSH_USER}@${CLIENT_ARRAY[0]}:~/memaslap"
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    scp -i "${SSH_KEY}" -o StrictHostKeyChecking=no /tmp/memaslap "${SSH_USER}@${CLIENT_ARRAY[1]}:~/memaslap"
fi
rm -f /tmp/memaslap

log "Verifying memaslap executable on clients..."
ssh_cli "${CLIENT_ARRAY[0]}" "~/memaslap --version"
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    ssh_cli "${CLIENT_ARRAY[1]}" "~/memaslap --version"
fi

# ---------------------------------------------------------------------------
# Step 6: Connectivity Ping Check
# ---------------------------------------------------------------------------
log "Verifying private experiment network connectivity (10.10.1.1)..."
ssh_cli "${CLIENT_ARRAY[0]}" "ping -c 3 10.10.1.1"
if [[ ${#CLIENT_ARRAY[@]} -gt 1 ]]; then
    ssh_cli "${CLIENT_ARRAY[1]}" "ping -c 3 10.10.1.1"
fi

log "====================================================================="
log "DEPLOYMENT COMPLETE: SUT and Client nodes are fully configured!"
log "====================================================================="
