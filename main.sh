#!/usr/bin/env bash
# ==================================================================================
#  VXLAN Tunnel Manager v2.2 - DualStack (IPv4+IPv6) + MultiPeer + DVHOST Banner
#  Author : DVHOST_CLOUD
#  Desc   : Create multiple VXLAN tunnels (UDP/443 by default) with per-tunnel
#           systemd service + health timer. Supports internal IPv4 + IPv6 subnets.
#  Path   : /usr/local/sbin/vxlan-tunnel.sh
# ==================================================================================

# -------------------- Color Definitions --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

VERSION="v2.2 DualStack"
VXLAN_DIR="/etc/vxlan-tunnels"
UPDOWN_DIR="/usr/local/sbin"
SYSTEMD_DIR="/etc/systemd/system"

DEF_PORT="443"
DEF_VNI="10"
DEF_LOCAL_MASK_V4="/24"
DEF_LOCAL_MASK_V6="/64"
DEF_MTU="1400"
IF_PREFIX="vxlan"

# ============================================================
#                        PRE-FUNCTIONS
# ============================================================
require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "[!] Please run as root (sudo)."
    exit 1
  fi
}
pause_any(){ read -rp $'\nPress Enter to continue...' _; }
ask() {
  local prompt="$1" default="$2" val
  if [ -n "$default" ]; then
    read -rp "$prompt [$default]: " val
    echo "${val:-$default}"
  else
    read -rp "$prompt: " val
    echo "$val"
  fi
}
ensure_dirs(){ mkdir -p "$VXLAN_DIR" "$UPDOWN_DIR" >/dev/null 2>&1; }
get_dev_for_remote() {
  local remote="$1"
  ip route get "$remote" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

# ============================================================
#                        LOADER + BANNER
# ============================================================
loader(){
  # jq for geo
  if ! command -v jq >/dev/null 2>&1; then
    if command -v apt >/dev/null 2>&1; then
      apt update -y >/dev/null 2>&1 && apt install -y jq >/dev/null 2>&1
    elif command -v yum >/dev/null 2>&1; then
      yum install -y jq >/dev/null 2>&1
    fi
  fi
  SERVER_IP=$(hostname -I | awk '{print $1}')
  GEO_JSON=$(curl -sS "http://ip-api.com/json/$SERVER_IP")
  SERVER_COUNTRY=$(echo "$GEO_JSON" | jq -r '.country')
  SERVER_ISP=$(echo "$GEO_JSON" | jq -r '.isp')
  [ "$SERVER_COUNTRY" = "null" ] && SERVER_COUNTRY="Unknown"
  [ "$SERVER_ISP" = "null" ] && SERVER_ISP="Unknown"
}
banner(){
  loader
  clear
  echo "+-----------------------------------------------------------------------------------------------------+"
  echo "|  _    ___  __ __    ___    _   __   __                         __    __   __  ______  ____    _     |"
  echo "| | |  / / |/ // /   /   |  / | / /  / /___  ______  ____  ___  / /  _/_/  / / / / __ \/ __ \  | |    |"
  echo "| | | / /|   // /   / /| | /  |/ /  / __/ / / / __ \/ __ \/ _ \/ /  / /   / / / / / / / /_/ /  / /    |"
  echo "| | |/ //   |/ /___/ ___ |/ /|  /  / /_/ /_/ / / / / / / /  __/ /  / /   / /_/ / /_/ / ____/  / /     |"
  echo "| |___//_/|_/_____/_/  |_/_/ |_/   \__/\__,_/_/ /_/_/ /_/\___/_/  / /    \____/_____/_/     _/_/      |"
  echo "|                                                                 |_|                      /_/        |"
  echo "| VXLAN tunnel over UDP — MultiPeer DualStack Manager                                                    |"
  echo "+-----------------------------------------------------------------------------------------------------+"
  echo -e "| Telegram : ${YELLOW}@DVHOST_CLOUD${NC} | YouTube : ${RED}youtube.com/@dvhost_cloud${NC} | Version : ${GREEN}${VERSION}${NC}"
  echo "+-----------------------------------------------------------------------------------------------------+"
  echo -e "|${GREEN} Server Location:${NC} ${SERVER_COUNTRY}"
  echo -e "|${GREEN} Server IP:${NC} ${SERVER_IP}"
  echo -e "|${GREEN} Server ISP:${NC} ${SERVER_ISP}"
  echo "+-----------------------------------------------------------------------------------------------------+"
}

# ============================================================
#                     SCRIPT GENERATORS
# ============================================================
write_up_script(){
  local upsh="$1"
  cat > "$upsh" <<'EOS'
#!/usr/bin/env bash
CONF="$1"
. "$CONF" 2>/dev/null || exit 1

modprobe vxlan 2>/dev/null || true
# Clean old iface if exists
ip link show "$IF_NAME" >/dev/null 2>&1 && ip link del "$IF_NAME" || true

# Create VxLAN device
ip link add "$IF_NAME" type vxlan id "$VNI" dev "$DEV" remote "$REMOTE_IP" local "$LOCAL_IP" dstport "$PORT" 2>/dev/null || exit 1
ip link set mtu "$MTU" dev "$IF_NAME" 2>/dev/null || true

# Assign internal IPv4 / IPv6 if provided
if [ -n "$LOCAL_V4" ]; then
  ip addr add "$LOCAL_V4" dev "$IF_NAME" 2>/dev/null || true
fi
if [ -n "$LOCAL_V6" ]; then
  ip -6 addr add "$LOCAL_V6" dev "$IF_NAME" 2>/dev/null || true
fi

ip link set "$IF_NAME" up 2>/dev/null || true
exit 0
EOS
  chmod +x "$upsh"
}
write_down_script(){
  local downsh="$1"
  cat > "$downsh" <<'EOS'
#!/usr/bin/env bash
CONF="$1"
. "$CONF" 2>/dev/null || true
ip link show "$IF_NAME" >/dev/null 2>&1 && ip link del "$IF_NAME" || true
exit 0
EOS
  chmod +x "$downsh"
}
write_health_script(){
  local healthsh="$1"
  cat > "$healthsh" <<'EOS'
#!/usr/bin/env bash
CONF="$1"
. "$CONF" 2>/dev/null || exit 0

# Prefer IPv6 if defined; else IPv4. Try both if both defined.
TARGETS=""
[ -n "$REMOTE_V6" ] && TARGETS="$TARGETS $REMOTE_V6"
[ -n "$REMOTE_V4" ] && TARGETS="$TARGETS $REMOTE_V4"

for tgt in $TARGETS; do
  case "$tgt" in
    *:*)  # IPv6
      for i in 1 2 3; do
        ping -6 -c1 -W3 "$tgt" >/dev/null 2>&1 && exit 0
        sleep 2
      done
      ;;
    *)    # IPv4
      for i in 1 2 3; do
        ping -c1 -W3 "$tgt" >/dev/null 2>&1 && exit 0
        sleep 2
      done
      ;;
  esac
done

# If none succeeded, restart tunnel service
systemctl restart "vxlan-${NAME}.service" >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "$healthsh"
}
write_systemd_units(){
  local name="$1" conf="$2" upsh="$3" downsh="$4" healthsh="$5"
  # main tunnel unit
  cat > "${SYSTEMD_DIR}/vxlan-${name}.service" <<EOF
[Unit]
Description=VXLAN tunnel ${name}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${upsh} ${conf}
ExecStop=${downsh} ${conf}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

  # health check service + timer
  cat > "${SYSTEMD_DIR}/vxlan-${name}-health.service" <<EOF
[Unit]
Description=VXLAN ${name} health check
[Service]
Type=oneshot
ExecStart=${healthsh} ${conf}
EOF
  cat > "${SYSTEMD_DIR}/vxlan-${name}-health.timer" <<EOF
[Unit]
Description=Run VXLAN ${name} health check periodically
[Timer]
OnBootSec=20s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=vxlan-${name}-health.service
[Install]
WantedBy=timers.target
EOF
}

# ============================================================
#                        MAIN ACTIONS
# ============================================================
do_install_single(){
  banner
  local name role IR_IP DE_IP PORT VNI V4_PREFIX V6_PREFIX MTU
  local LOCAL_IP REMOTE_IP LOCAL_V4 REMOTE_V4 LOCAL_V6 REMOTE_V6 DEV CONF
  name=$(ask "Enter tunnel name (e.g., de1, nl1)")
  [ -z "$name" ] && { echo "Name required"; pause_any; return; }

  echo "[*] Choose node role (where this script runs):"
  echo "  1) IRAN node"
  echo "  2) Foreign node"
  role=$(ask "Role (1/2)" "1")

  IR_IP=$(ask "Enter IRAN public IPv4")
  DE_IP=$(ask "Enter remote public IPv4")
  PORT=$(ask "Enter UDP port" "$DEF_PORT")
  VNI=$(ask "Enter VXLAN VNI" "$DEF_VNI")

  # DualStack prefixes (user can customize)
  V4_PREFIX=$(ask "Enter internal IPv4 prefix (e.g., 10.${VNI}.10.)" "10.${VNI}.10.")
  V6_PREFIX=$(ask "Enter internal IPv6 prefix (e.g., fd00:${VNI}::)" "fd00:${VNI}::")
  MTU=$(ask "Enter MTU" "$DEF_MTU")

  if [ "$role" = "1" ]; then
    LOCAL_IP="$IR_IP";  REMOTE_IP="$DE_IP"
    LOCAL_V4="${V4_PREFIX}1${DEF_LOCAL_MASK_V4}"
    REMOTE_V4="${V4_PREFIX}2"
    LOCAL_V6="${V6_PREFIX}1${DEF_LOCAL_MASK_V6}"
    REMOTE_V6="${V6_PREFIX}2"
  else
    LOCAL_IP="$DE_IP";  REMOTE_IP="$IR_IP"
    LOCAL_V4="${V4_PREFIX}2${DEF_LOCAL_MASK_V4}"
    REMOTE_V4="${V4_PREFIX}1"
    LOCAL_V6="${V6_PREFIX}2${DEF_LOCAL_MASK_V6}"
    REMOTE_V6="${V6_PREFIX}1"
  fi

  DEV=$(get_dev_for_remote "$REMOTE_IP"); [ -z "$DEV" ] && DEV="eth0"

  CONF="$VXLAN_DIR/${name}.conf"
  cat > "$CONF" <<EOF
NAME="${name}"
IF_NAME="${IF_PREFIX}_${name}"
LOCAL_IP="${LOCAL_IP}"
REMOTE_IP="${REMOTE_IP}"
PORT="${PORT}"
VNI="${VNI}"
DEV="${DEV}"
LOCAL_V4="${LOCAL_V4}"
REMOTE_V4="${REMOTE_V4}"
LOCAL_V6="${LOCAL_V6}"
REMOTE_V6="${REMOTE_V6}"
MTU="${MTU}"
EOF
  chmod 600 "$CONF"

  local upsh="$UPDOWN_DIR/vxlan_${name}_up.sh"
  local downsh="$UPDOWN_DIR/vxlan_${name}_down.sh"
  local healthsh="$UPDOWN_DIR/vxlan_${name}_health.sh"

  write_up_script "$upsh"
  write_down_script "$downsh"
  write_health_script "$healthsh"
  write_systemd_units "$name" "$CONF" "$upsh" "$downsh" "$healthsh"

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "vxlan-${name}.service" "vxlan-${name}-health.timer" >/dev/null 2>&1 || true

  echo -e "${GREEN}[+] Tunnel '${name}' installed and started (DualStack).${NC}"
  echo "    If firewall is active, allow UDP/${PORT} on both ends."
  pause_any
}

do_list_tunnels(){
  banner
  echo -e "${YELLOW}Known tunnels in ${VXLAN_DIR}:${NC}"
  for f in "$VXLAN_DIR"/*.conf; do
    [ -f "$f" ] || continue
    echo " - $(basename "$f" .conf)"
  done
  pause_any
}

do_status_all(){
  banner
  echo -e "${YELLOW}------ VXLAN Tunnels Status ------${NC}"
  for f in "$VXLAN_DIR"/*.conf; do
    [ -f "$f" ] || continue
    . "$f"
    echo -e "${GREEN}Tunnel:${NC} $NAME | ${GREEN}Iface:${NC} $IF_NAME"
    if ip link show "$IF_NAME" >/dev/null 2>&1; then
      echo "  ✓ Interface: up"
    else
      echo "  ✗ Interface: down"
    fi
    systemctl is-active --quiet "vxlan-${NAME}.service" && echo "  Service : active" || echo "  Service : inactive"
    systemctl is-active --quiet "vxlan-${NAME}-health.timer" && echo "  Health  : active" || echo "  Health  : inactive"

    # quick pings if available
    [ -n "$REMOTE_V4" ] && ( ping -c1 -W2 "$REMOTE_V4" >/dev/null 2>&1 && echo "  Ping4   : OK" || echo "  Ping4   : FAIL" )
    [ -n "$REMOTE_V6" ] && ( ping -6 -c1 -W2 "$REMOTE_V6" >/dev/null 2>&1 && echo "  Ping6   : OK" || echo "  Ping6   : FAIL" )
    echo "----------------------------------------------"
  done
  pause_any
}

do_restart(){
  banner
  read -rp "Enter tunnel name to restart: " name
  systemctl restart "vxlan-${name}.service" >/dev/null 2>&1 && echo "[+] Restarted." || echo "[!] Failed."
  pause_any
}

do_uninstall_one(){
  banner
  read -rp "Enter tunnel name to remove: " name
  local conf="$VXLAN_DIR/${name}.conf"
  if [ ! -f "$conf" ]; then echo "[!] Not found."; pause_any; return; fi
  systemctl disable --now "vxlan-${name}.service" "vxlan-${name}-health.timer" >/dev/null 2>&1
  rm -f "$conf" \
        "$UPDOWN_DIR/vxlan_${name}_up.sh" \
        "$UPDOWN_DIR/vxlan_${name}_down.sh" \
        "$UPDOWN_DIR/vxlan_${name}_health.sh" \
        "$SYSTEMD_DIR/vxlan-${name}.service" \
        "$SYSTEMD_DIR/vxlan-${name}-health.service" \
        "$SYSTEMD_DIR/vxlan-${name}-health.timer"
  systemctl daemon-reload >/dev/null 2>&1 || true
  echo "[+] Removed tunnel: $name"
  pause_any
}

do_uninstall_all(){
  banner
  read -rp "Are you sure to REMOVE ALL tunnels? (y/N): " a
  [ "$a" != "y" ] && return
  for f in "$VXLAN_DIR"/*.conf; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .conf)"
    systemctl disable --now "vxlan-${name}.service" "vxlan-${name}-health.timer" >/dev/null 2>&1
    rm -f "$f" \
          "$UPDOWN_DIR/vxlan_${name}_up.sh" \
          "$UPDOWN_DIR/vxlan_${name}_down.sh" \
          "$UPDOWN_DIR/vxlan_${name}_health.sh" \
          "$SYSTEMD_DIR/vxlan-${name}.service" \
          "$SYSTEMD_DIR/vxlan-${name}-health.service" \
          "$SYSTEMD_DIR/vxlan-${name}-health.timer"
    echo "Removed: $name"
  done
  systemctl daemon-reload >/dev/null 2>&1 || true
  echo -e "${GREEN}[+] All tunnels removed.${NC}"
  pause_any
}

# ============================================================
#                          MENU
# ============================================================
main_menu(){
  while true; do
    banner
    echo -e "${YELLOW}| 1 - Add / Configure Tunnel${NC}"
    echo -e "${YELLOW}| 2 - List Tunnels${NC}"
    echo -e "${YELLOW}| 3 - Status (All)${NC}"
    echo -e "${YELLOW}| 4 - Restart Tunnel${NC}"
    echo -e "${YELLOW}| 5 - Remove One Tunnel${NC}"
    echo -e "${YELLOW}| 6 - Uninstall All${NC}"
    echo -e "${YELLOW}| 0 - Exit${NC}"
    echo "+-----------------------------------------------------------------------------------------------------+"
    read -rp "Please choose an option: " choice
    case "$choice" in
      1) do_install_single ;;
      2) do_list_tunnels ;;
      3) do_status_all ;;
      4) do_restart ;;
      5) do_uninstall_one ;;
      6) do_uninstall_all ;;
      0) echo "Exiting..."; exit 0 ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

# ============================================================
#                       EXECUTION
# ============================================================
require_root
ensure_dirs
main_menu
