#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
plain='\033[0m'
NC='\033[0m'
VERSION='2.4'
set -o noclobber

# ------------------ Configurable defaults ------------------
VXLAN_DIR="/etc/vxlan-tunnels"
UPDOWN_DIR="/usr/local/sbin"
DEF_PORT="443"
DEF_VNI="10"
DEF_LOCAL_MASK="/64"
DEF_MTU="1400"
IF_PREFIX="vxlan"   # final iface will be IF_PREFIX_name
SYSTEMD_DIR="/etc/systemd/system"
# ------------------ helper functions -----------------------
require_root() {
  if [ "$EUID" -ne 0 ]; then
    echo "[!] This script must be run as root (sudo)."
    exit 1
  fi
}

install_jq() {
    if ! command -v jq &> /dev/null; then
        if command -v apt-get &> /dev/null; then
            echo -e "${RED}jq is not installed. Installing...${NC}"
            sleep 1
            sudo apt-get update
            sudo apt-get install -y jq
        else
            echo -e "${RED}Error: Unsupported package manager. Please install jq manually.${NC}\n"
            read -p "Press any key to continue..."
            exit 1
        fi
    fi
}

loader(){
    install_jq
    SERVER_IP=$(hostname -I | awk '{print $1}')
    SERVER_COUNTRY=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.country')
    SERVER_ISP=$(curl -sS "http://ip-api.com/json/$SERVER_IP" | jq -r '.isp')
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
    echo "| VXLAN tunnel over UDP This tool configures a point-to-point VXLAN tunnel over UDP                   |"
    echo "+-----------------------------------------------------------------------------------------------------+"                                        
    echo -e "| Telegram Channel : ${YELLOW}@DVHOST_CLOUD ${NC} | YouTube : ${RED}youtube.com/@dvhost_cloud${NC} |  Version : ${GREEN} ${VERSION} ${NC} "
    echo "+-----------------------------------------------------------------------------------------------------+"             
    echo -e "|${GREEN} Server Location:${NC} $SERVER_COUNTRY ${NC}"
    echo -e "|${GREEN} Server IP:${NC} $SERVER_IP ${NC}"
    echo -e "|${GREEN} Server ISP:${NC} $SERVER_ISP ${NC}"
    echo "+-----------------------------------------------------------------------------------------------------+"                                        
    echo -e "${YELLOW}|  1  - Install XUI Subscription Template"
    echo -e "|  2  - Edit Configuation"
    echo -e "|  3  - Unistall"
    echo -e "|  0  - Exit${NC}"
    echo "+-----------------------------------------------------------------------------------------------------+"                                        
    
    read -p "Please choose an option: " choice
    
    case $choice in
        1)
            clear
            menu
            echo "+---------------------------------------+"
            echo -e "| ${YELLOW}Installation completed successfully! ${NC} |"
            echo "+---------------------------------------+"

            ;;
            2) edit_config_file ;;
            3) remove_project ;;
            0)
                echo -e "${GREEN}Exiting program...${NC}"
                exit 0
            ;;
            *)
                echo "Not valid"
            ;;
    esac
    
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

get_dev_for_remote() {
  local remote="$1"
  ip route get "$remote" 2>/dev/null | awk '{for(i=1;i<=NF;i++){if($i=="dev"){print $(i+1); exit}}}'
}

ensure_dirs() {
  mkdir -p "$VXLAN_DIR"
  mkdir -p "$UPDOWN_DIR"
}

# ------------------ core templated scripts ------------------
# We'll create per-tunnel scripts that source their tunnel's conf file.
write_up_script() {
  local name="$1" conf="$2" upsh="$3"
  cat > "$upsh" <<'EOS'
#!/usr/bin/env bash
CONF="$1"
[ -f "$CONF" ] || { echo "[!] Conf not found: $CONF"; exit 1; }
. "$CONF" 2>/dev/null || { echo "[!] Failed source $CONF"; exit 1; }

# Ensure kernel module
modprobe vxlan 2>/dev/null || true

# Remove existing iface if present
ip link show "$IF_NAME" >/dev/null 2>&1 && ip link del "$IF_NAME" || true

# Create vxlan device
ip link add "$IF_NAME" type vxlan id "$VNI" dev "$DEV" remote "$REMOTE_IP" local "$LOCAL_IP" dstport "$PORT" 2>/dev/null || {
  echo "[!] ip link add failed for $IF_NAME"
  exit 1
}

# MTU, address, up
ip link set mtu "$MTU" dev "$IF_NAME" 2>/dev/null || true
ip addr add "$LOCAL_V6" dev "$IF_NAME" 2>/dev/null || true
ip link set "$IF_NAME" up 2>/dev/null || true

echo "[+] $IF_NAME up (remote $REMOTE_IP) - local v6 $LOCAL_V6"
exit 0
EOS
  # Make executable
  chmod +x "$upsh"
  # Insert conf path as first argument when creating service ExecStart
}

write_down_script() {
  local name="$1" downsh="$2"
  cat > "$downsh" <<'EOS'
#!/usr/bin/env bash
CONF="$1"
[ -f "$CONF" ] || true
. "$CONF" 2>/dev/null || true
IF_NAME="${IF_NAME:-vxlan_unknown}"
ip link show "$IF_NAME" >/dev/null 2>&1 && ip link del "$IF_NAME" || true
echo "[+] $IF_NAME removed (if existed)"
exit 0
EOS
  chmod +x "$downsh"
}

write_health_script() {
  local name="$1" conf="$2" healthsh="$3"
  cat > "$healthsh" <<'EOS'
#!/usr/bin/env bash
CONF="$1"
[ -f "$CONF" ] || { echo "[!] Config missing: $CONF"; exit 0; }
. "$CONF" 2>/dev/null || exit 0

PEER="${REMOTE_V6:-}"
if [ -z "$PEER" ]; then
  echo "[!] REMOTE_V6 not set in $CONF"; exit 0
fi

# Try a few pings (ICMPv6) to remote v6 peer
for i in 1 2 3; do
  ping -6 -c1 -W3 "$PEER" >/dev/null 2>&1 && exit 0
  sleep 2
done

# if we reached here, ping failed -> restart the tunnel service
systemctl restart "vxlan-${NAME}.service" >/dev/null 2>&1 || true
exit 0
EOS
  chmod +x "$healthsh"
}

# ------------------ systemd unit writers --------------------
write_systemd_units() {
  local name="$1" conf="$2" upsh="$3" downsh="$4" healthsh="$5"
  # main service
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

  # health check service
  cat > "${SYSTEMD_DIR}/vxlan-${name}-health.service" <<EOF
[Unit]
Description=VXLAN ${name} health check

[Service]
Type=oneshot
ExecStart=${healthsh} ${conf}
EOF

  # health timer
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

# ------------------ tunnel actions ---------------------------
create_tunnel_conf() {
  local name="$1" conf="$2"
  # variables expected in env
  cat > "$conf" <<EOF
# vxlan tunnel config for ${name}
NAME="${name}"
IF_NAME="${IF_PREFIX}_${name}"
LOCAL_IP="${LOCAL_IP}"
REMOTE_IP="${REMOTE_IP}"
PORT="${PORT}"
VNI="${VNI}"
DEV="${DEV}"
LOCAL_V6="${LOCAL_V6}"
REMOTE_V6="${REMOTE_V6}"
MTU="${MTU}"
EOF
  chmod 600 "$conf"
}

do_install_single_interactive() {
  local name
  name=$(ask "Enter tunnel name (short, e.g., de1, nl1):")
  [ -z "$name" ] && { echo "[!] Name required."; pause_any; return; }

  local role IR_IP DE_IP PORT VNI V6_PREFIX MTU DEV
  echo "[*] Choose role (where this script runs):"
  echo "  1) IRAN node (local is Iran)"
  echo "  2) Kharej node (local is remote)"
  role=$(ask "Role (1/2)" "1")

  IR_IP=$(ask "Enter IRAN public IPv4" )
  DE_IP=$(ask "Enter remote public IPv4" )
  PORT=$(ask "Enter UDP port" "$DEF_PORT")
  VNI=$(ask "Enter VXLAN VNI" "$DEF_VNI")
  V6_PREFIX=$(ask "Enter IPv6 base prefix (e.g., fd00:10::)" "fd00:${VNI}::")
  MTU=$(ask "Enter MTU" "$DEF_MTU")

  local LOCAL_IP REMOTE_IP LOCAL_V6 REMOTE_V6
  if [ "$role" = "1" ]; then
    LOCAL_IP="${IR_IP}"
    REMOTE_IP="${DE_IP}"
    LOCAL_V6="${V6_PREFIX}1${DEF_LOCAL_MASK}"
    REMOTE_V6="${V6_PREFIX}2"
  else
    LOCAL_IP="${DE_IP}"
    REMOTE_IP="${IR_IP}"
    LOCAL_V6="${V6_PREFIX}2${DEF_LOCAL_MASK}"
    REMOTE_V6="${V6_PREFIX}1"
  fi

  DEV="$(get_dev_for_remote "$REMOTE_IP")"
  [ -z "$DEV" ] && DEV="eth0"

  # export minimal env for create_tunnel_conf
  export NAME="$name"
  export IF_PREFIX
  export LOCAL_IP REMOTE_IP PORT VNI DEV LOCAL_V6 REMOTE_V6 MTU

  local conf="${VXLAN_DIR}/${name}.conf"
  local upsh="${UPDOWN_DIR}/vxlan_${name}_up.sh"
  local downsh="${UPDOWN_DIR}/vxlan_${name}_down.sh"
  local healthsh="${UPDOWN_DIR}/vxlan_${name}_health.sh"

  create_tunnel_conf "$name" "$conf"
  write_up_script "$name" "$conf" "$upsh"
  write_down_script "$name" "$downsh"
  write_health_script "$name" "$conf" "$healthsh"
  write_systemd_units "$name" "$conf" "$upsh" "$downsh" "$healthsh"

  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "vxlan-${name}.service" "vxlan-${name}-health.timer" 2>/dev/null || true

  echo "[+] Tunnel '${name}' created and services enabled."
  echo "    systemctl status vxlan-${name}.service"
  pause_any
}

do_list_tunnels() {
  echo "Known tunnels (configs in $VXLAN_DIR):"
  for f in "$VXLAN_DIR"/*.conf; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .conf)
    echo " - $name"
  done
}

do_status_all() {
  echo "------ VXLAN Tunnels Status ------"
  for f in "$VXLAN_DIR"/*.conf; do
    [ -f "$f" ] || continue
    . "$f"
    echo ""
    echo "Tunnel: $NAME"
    echo " Interface: $IF_NAME"
    if ip link show "$IF_NAME" >/dev/null 2>&1; then
      echo "  ✓ link: up"
      ip -6 addr show dev "$IF_NAME" 2>/dev/null | awk '/inet6/ {print "  addr: "$2}'
    else
      echo "  ✗ link: down"
    fi
    systemctl is-active --quiet "vxlan-${NAME}.service" && echo "  service: active" || echo "  service: inactive"
    systemctl is-active --quiet "vxlan-${NAME}-health.timer" && echo "  health timer: active" || echo "  health timer: inactive"
    echo "  Remote v6: ${REMOTE_V6:-N/A}"
    # quick ping check
    if [ -n "${REMOTE_V6:-}" ]; then
      if ping -6 -c1 -W3 "${REMOTE_V6}" >/dev/null 2>&1; then
        echo "  ping6 -> OK"
      else
        echo "  ping6 -> FAIL"
      fi
    fi
  done
  echo "----------------------------------"
  pause_any
}

do_restart_select() {
  echo "Select tunnel to restart:"
  local arr=()
  local i=1
  for f in "$VXLAN_DIR"/*.conf; do
    [ -f "$f" ] || continue
    name=$(basename "$f" .conf)
    printf " %2d) %s\n" "$i" "$name"
    arr+=("$name")
    i=$((i+1))
  done
  [ "${#arr[@]}" -eq 0 ] && { echo "[!] No tunnels."; pause_any; return; }
  read -rp "Choose number: " sel
  sel=${sel:-1}
  if ! [[ "$sel" =~ ^[0-9]+$ ]] || [ "$sel" -lt 1 ] || [ "$sel" -gt "${#arr[@]}" ]; then
    echo "Invalid selection"; pause_any; return
  fi
  name="${arr[$((sel-1))]}"
  systemctl restart "vxlan-${name}.service" >/dev/null 2>&1 || true
  echo "[+] Restarted vxlan-${name}.service"
  pause_any
}

do_uninstall_all() {
  read -rp "Are you sure? This will stop & disable ALL vxlan-*.service and remove configs (y/N): " ans
  case "$ans" in
    y|Y)
      for f in "$VXLAN_DIR"/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        systemctl stop "vxlan-${name}.service" >/dev/null 2>&1 || true
        systemctl disable "vxlan-${name}.service" >/dev/null 2>&1 || true
        systemctl stop "vxlan-${name}-health.timer" >/dev/null 2>&1 || true
        systemctl disable "vxlan-${name}-health.timer" >/dev/null 2>&1 || true
        rm -f "${SYSTEMD_DIR}/vxlan-${name}.service" "${SYSTEMD_DIR}/vxlan-${name}-health.service" "${SYSTEMD_DIR}/vxlan-${name}-health.timer"
        rm -f "${UPDOWN_DIR}/vxlan_${name}_up.sh" "${UPDOWN_DIR}/vxlan_${name}_down.sh" "${UPDOWN_DIR}/vxlan_${name}_health.sh"
        rm -f "$VXLAN_DIR/${name}.conf"
        echo "[+] Removed tunnel $name"
      done
      systemctl daemon-reload >/dev/null 2>&1 || true
      echo "[+] All tunnels removed."
      ;;
    *)
      echo "Aborted."
      ;;
  esac
  pause_any
}

do_uninstall_one() {
  read -rp "Enter tunnel name to remove: " name
  [ -z "$name" ] && { echo "Name required"; pause_any; return; }
  if [ -f "$VXLAN_DIR/${name}.conf" ]; then
    systemctl stop "vxlan-${name}.service" >/dev/null 2>&1 || true
    systemctl disable "vxlan-${name}.service" >/dev/null 2>&1 || true
    systemctl stop "vxlan-${name}-health.timer" >/dev/null 2>&1 || true
    systemctl disable "vxlan-${name}-health.timer" >/dev/null 2>&1 || true
    rm -f "${SYSTEMD_DIR}/vxlan-${name}.service" "${SYSTEMD_DIR}/vxlan-${name}-health.service" "${SYSTEMD_DIR}/vxlan-${name}-health.timer"
    rm -f "${UPDOWN_DIR}/vxlan_${name}_up.sh" "${UPDOWN_DIR}/vxlan_${name}_down.sh" "${UPDOWN_DIR}/vxlan_${name}_health.sh"
    rm -f "$VXLAN_DIR/${name}.conf"
    systemctl daemon-reload >/dev/null 2>&1 || true
    echo "[+] Tunnel $name removed."
  else
    echo "[!] Tunnel $name not found."
  fi
  pause_any
}

# ------------------ init & menu ------------------------------
require_root
ensure_dirs

main_menu() {
  while true; do
    banner
    echo "1) Add / Configure a tunnel"
    echo "2) List tunnels"
    echo "3) Status (all tunnels)"
    echo "4) Restart a tunnel"
    echo "5) Remove a tunnel"
    echo "6) Uninstall all (wipe)"
    echo "0) Exit"
    echo "--------------------------------"
    read -rp "Choose option: " op
    case "$op" in
      1) do_install_single_interactive ;;
      2) do_list_tunnels ; pause_any ;;
      3) do_status_all ;;
      4) do_restart_select ;;
      5) do_uninstall_one ;;
      6) do_uninstall_all ;;
      0) exit 0 ;;
      *) echo "Invalid option"; sleep 1 ;;
    esac
  done
}

# Run
main_menu
