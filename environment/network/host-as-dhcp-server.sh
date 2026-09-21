#!/usr/bin/env bash
# Host-side DHCP for direct Ethernet link to NC1 (Ubuntu + NetworkManager).
# Creates/activates NM "shared" connection on eno2 — board eth0 gets IP via DHCP.
set -euo pipefail

IFACE="${NC1_HOST_IFACE:-eno2}"
CON_NAME="${NC1_HOST_CON:-nc1-direct}"
HOST_IP="${NC1_HOST_IP:-192.168.10.1/24}"

if ! command -v nmcli >/dev/null 2>&1; then
  echo "[host-nc1-dhcp] ERROR: nmcli not found (install NetworkManager)" >&2
  exit 1
fi

if nmcli -t -f NAME connection show | grep -qxF "${CON_NAME}"; then
  echo "[host-nc1-dhcp] connection '${CON_NAME}' exists, bringing up..."
else
  echo "[host-nc1-dhcp] create shared connection on ${IFACE} (${HOST_IP})"
  nmcli connection add type ethernet ifname "${IFACE}" con-name "${CON_NAME}" \
    ipv4.method shared ipv4.addresses "${HOST_IP}" autoconnect yes
fi

nmcli connection up "${CON_NAME}"

echo
echo "[host-nc1-dhcp] === host ==="
ip -br addr show "${IFACE}" 2>/dev/null || true

LEASE_FILE="/var/lib/NetworkManager/dnsmasq-${IFACE}.leases"
if [[ -r "${LEASE_FILE}" ]]; then
  echo
  echo "[host-nc1-dhcp] === DHCP leases ==="
  cat "${LEASE_FILE}" || true
else
  echo
  echo "[host-nc1-dhcp] no leases yet — on the board run: networkctl renew eth0"
fi

echo
echo "[host-nc1-dhcp] OK — SSH: ssh root@<board-ip>  (password: 1234)"
