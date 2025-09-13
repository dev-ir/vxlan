#!/usr/bin/env bash
# vxlan-tunnel.sh - VXLAN over UDP(443) manager (v1.2-safemode)
# Safe Mode: no 'set -euo', tolerant errors, always shows menu.
# Scenario: force 'dev <iface>' + IPv6 /64 addressing (works like your manual commands)

# ------------------------------ Disclaimer --------------------------------
# VXLAN Tunnel Manager v1.2 (Safe Mode)
# Configures IPv6 /64 over VXLAN (UDP/443) with systemd + health-check.
# ---------------------------------------------------------------------------

# --- paths
CONF_FILE="/etc/vxlan-tunnel.conf"
UP_SCRIPT="/usr/local/sbin/vxlan_up.sh"
DOWN_SCRIPT="/usr/local/sbin/vxlan_down.sh"
CHK_SCRIPT="/usr/local/sbin/vxlan_healthcheck.sh"
SVC_FILE="/etc/systemd/system/vxlan-tunnel.service"
SVC_HEALTH="/etc/systemd/system/vxlan-tunnel-health.service"
TIMER_FILE="/etc/systemd/system/vxlan-tunnel-health.timer"

# --- defaults
IF_NAME="vxlan10"
DEF_PORT="443"
DEF_VNI="10"
DEF_V6_PREFIX="fd00:10::"
DEF_LOCAL_MASK="/64"
DEF_MTU="1400"

require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run as root (sudo)."; read -rp "Press Enter..." _; exit 1
  fi
}

banner() {
  clear
  echo "+------------------------------------------------------------------+"
  echo "|                    VXLAN over UDP (443) Manager                  |"
  echo "+------------------------------------------------------------------+"
  echo "| Host IP   : $(hostname -I 2>/dev/null | awk '{print $1}')"
  echo "| Kernel    : $(uname -r)"
  ip -V >/dev/null 2>&1 && echo "| iproute2  : $(ip -V | head -n1)" || echo "| iproute2  : N/A"
  echo "+------------------------------------------------------------------+"
  echo "| Disclaimer: VXLAN Tunnel Manager v1.2 (Safe Mode)                |"
  echo "| IPv6 /64 over VXLAN (UDP/443), systemd persistence + health.     |"
  echo "+------------------------------------------------------------------+"
}

pause_any(){ read -rp "Press Enter to continue..." _; }

ask() {
  local p="$1" d="$2" v
  read -rp "$p [$d]: " v
  echo "${v:-$d}"
}

get_dev_for_remote() {
  local remote="$1"
  ip route get "$remote" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

print_status() {
  echo "----- STATUS -----"
  if [ -f "$CONF_FILE" ]; then
    . "$CONF_FILE" 2>/dev/null || true
    if ip link show "$IF_NAME" >/dev/null 2>&1; then
      local state; state=$(ip link show "$IF_NAME" 2>/dev/null | sed -n 's/.*state \([A-Z]\+\).*/\1/p' | head -n1)
      echo "Interface : $IF_NAME (${state:-UNKNOWN})"
      echo "Device    : ${DEV:-?}"
      echo "Local IPs : $(ip -6 addr show dev "$IF_NAME" 2>/dev/null | awk '/inet6/ {print $2}' | paste -sd, -)"
      echo "Peer v6   : ${REMOTE_V6:-?}"
    else
      echo "Interface : not present"
    fi
    systemctl is-active --quiet vxlan-tunnel.service  && echo "Service   : active"   || echo "Service   : inactive"
    systemctl is-active --quiet vxlan-tunnel-health.timer && echo "HealthTm  : active" || echo "HealthTm  : inactive"
  else
    echo "No config at $CONF_FILE"
  fi
  echo "------------------"
}

do_install() {
  banner
  echo "Choose role:"
  echo "  1) IRAN node"
  echo "  2) Kharej node"
  read -rp "Role (1/2): " role

  local IR_IP DE_IP PORT VNI V6_PREFIX MTU
  IR_IP=$(ask "Enter IRAN public IPv4" )
  DE_IP=$(ask "Enter Kharej public IPv4" )
  PORT=$(ask "Enter UDP port" "$DEF_PORT")
  VNI=$(ask "Enter VXLAN VNI" "$DEF_VNI")
  V6_PREFIX=$(ask "Enter IPv6 prefix (fd00:10::X)" "$DEF_V6_PREFIX")
  MTU=$(ask "Enter MTU" "$DEF_MTU")

  local LOCAL_IP REMOTE_IP LOCAL_V6 REMOTE_V6
  if [ "$role" = "1" ]; then
    LOCAL_IP="$IR_IP";   REMOTE_IP="$DE_IP"
    LOCAL_V6="${V6_PREFIX}1${DEF_LOCAL_MASK}"   # fd00:10::1/64
    REMOTE_V6="${V6_PREFIX}2"                   # fd00:10::2
  else
    LOCAL_IP="$DE_IP";   REMOTE_IP="$IR_IP"
    LOCAL_V6="${V6_PREFIX}2${DEF_LOCAL_MASK}"   # fd00:10::2/64
    REMOTE_V6="${V6_PREFIX}1"                   # fd00:10::1
  fi

  local DEV; DEV="$(get_dev_for_remote "$REMOTE_IP")"; [ -z "$DEV" ] && DEV="eth0"

  cat > "$CONF_FILE" <<EOF
IF_NAME="$IF_NAME"
LOCAL_IP="$LOCAL_IP"
REMOTE_IP="$REMOTE_IP"
PORT="$PORT"
VNI="$VNI"
DEV="$DEV"
LOCAL_V6="$LOCAL_V6"
REMOTE_V6="$REMOTE_V6"
MTU="$MTU"
EOF
  chmod 600 "$CONF_FILE" 2>/dev/null || true

  # UP script (force dev + /64)
  cat > "$UP_SCRIPT" <<'EOS'
#!/usr/bin/env bash
# tolerant UP script
. /etc/vxlan-tunnel.conf 2>/dev/null || exit 0

modprobe vxlan 2>/dev/null || true
ip link show "$IF_NAME" >/dev/null 2>&1 && ip link del "$IF_NAME" || true

ip link add "$IF_NAME" type vxlan id "$VNI" dev "$DEV" remote "$REMOTE_IP" local "$LOCAL_IP" dstport "$PORT" 2>/dev/null || exit 1
ip link set mtu "$MTU" dev "$IF_NAME" 2>/dev/null || true
ip addr add "$LOCAL_V6" dev "$IF_NAME" 2>/dev/null || true
ip link set "$IF_NAME" up 2>/dev/null || true
exit 0
EOS
  chmod +x "$UP_SCRIPT" 2>/dev/null || true

  # DOWN script
  cat > "$DOWN_SCRIPT" <<'EOS'
#!/usr/bin/env bash
IF_NAME="vxlan10"
ip link show "$IF_NAME" >/dev/null 2>&1 && ip link del "$IF_NAME" || true
exit 0
EOS
  chmod +x "$DOWN_SCRIPT" 2>/dev/null || true

  # HealthCheck
  cat > "$CHK_SCRIPT" <<'EOS'
#!/usr/bin/env bash
. /etc/vxlan-tunnel.conf 2>/dev/null || exit 0
PEER="$REMOTE_V6"
for i in 1 2 3; do
  ping -6 -c1 -w3 "$PEER" >/dev/null 2>&1 && exit 0
  sleep 2
done
systemctl restart vxlan-tunnel.service >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "$CHK_SCRIPT" 2>/dev/null || true

  # systemd units
  cat > "$SVC_FILE" <<EOF
[Unit]
Description=VXLAN tunnel bring-up (safe mode)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$UP_SCRIPT
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "$SVC_HEALTH" <<EOF
[Unit]
Description=VXLAN tunnel health check (safe mode)
[Service]
Type=oneshot
ExecStart=$CHK_SCRIPT
EOF

  cat > "$TIMER_FILE" <<EOF
[Unit]
Description=Run VXLAN health check every 30s
[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=vxlan-tunnel-health.service
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now vxlan-tunnel.service >/dev/null 2>&1 || true
  systemctl enable --now vxlan-tunnel-health.timer >/dev/null 2>&1 || true

  echo "[i] If firewall is active, allow UDP/$PORT (e.g., ufw allow $PORT/udp)."
  echo "[+] Installed & attempted start."
  print_status
  pause_any
}

do_restart() {
  systemctl restart vxlan-tunnel.service >/dev/null 2>&1 || true
  echo "[+] Service restarted."
  print_status
  pause_any
}

do_status(){ print_status; pause_any; }

do_uninstall() {
  echo "[i] Stopping services and removing files..."
  systemctl stop vxlan-tunnel-health.timer >/dev/null 2>&1 || true
  systemctl disable vxlan-tunnel-health.timer >/dev/null 2>&1 || true
  systemctl stop vxlan-tunnel.service >/dev/null 2>&1 || true
  systemctl disable vxlan-tunnel.service >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true

  [ -x "$DOWN_SCRIPT" ] && "$DOWN_SCRIPT" || true
  rm -f "$CONF_FILE" "$UP_SCRIPT" "$DOWN_SCRIPT" "$CHK_SCRIPT" \
        "$SVC_FILE" "$SVC_HEALTH" "$TIMER_FILE"
  echo "[+] Uninstalled."
  pause_any
}

do_bestMTU(){
  bash <(curl -Ls https://gist.githubusercontent.com/dev-ir/7ca7ea4c60f220116bee575a22685b10/raw/37a18792937b61586c4f4e4e9f36b2749128e54b/best_mtu.sh)
}

main_menu() {
  while true; do
    banner
    echo "1) Install / Configure"
    echo "2) Status"
    echo "3) Restart service"
    echo "4) Uninstall"
    echo "0) Exit"
    echo "-----------------------"
    read -rp "Enter option: " op
    case "$op" in
      1) do_install ;;
      2) do_status ;;
      3) do_restart ;;
      4) do_uninstall ;;
      5) do_bestMTU ;;
      0) exit 0 ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

require_root
main_menu
