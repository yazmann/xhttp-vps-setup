#!/usr/bin/env bash
set -Eeuo pipefail

# Universal unattended 3x-ui VPN server / remote-node installer for a fresh Ubuntu VPS.
# The script is interactive only during the initial questionnaire.
# Independent automation project; not affiliated with or endorsed by 3x-ui,
# XTLS/Xray or Cloudflare. Third-party names remain their owners' property.
# See THIRD_PARTY_NOTICES.md in the project repository.

green='\033[1;32m'; yellow='\033[1;33m'; red='\033[1;31m'; cyan='\033[1;36m'; blue='\033[1;34m'; plain='\033[0m'
CURRENT_STEP='startup'
INSTALLATION_STARTED=0
RECOVERY_SCRIPT='/root/finish-xhttp-vps.sh'
log() { CURRENT_STEP="$*"; printf '\n%b[%s]%b %b%s%b\n' "$blue" "$(date +'%H:%M:%S')" "$plain" "$cyan" "$*" "$plain"; }
warn() { printf '\n%bWARNING%b %s\n' "$yellow" "$plain" "$*" >&2; }
recovery_hint() {
  local solution="${1:-}"
  if [[ -n "$solution" ]]; then
    printf '%bSuggested solution:%b %s\n' "$yellow" "$plain" "$solution" >&2
  elif [[ "$INSTALLATION_STARTED" == 1 ]]; then
    printf '%bSuggested solution:%b Fix the reason above, then run: %s\n' "$yellow" "$plain" "$RECOVERY_SCRIPT" >&2
  else
    printf '%bSuggested solution:%b Fix the reason above, then start this installer again. No existing service was changed automatically.\n' "$yellow" "$plain" >&2
  fi
}
die() {
  local reason="$1" solution="${2:-}"
  printf '\n%b================================================================%b\n' "$red" "$plain" >&2
  printf '%bINSTALLATION STOPPED%b\n' "$red" "$plain" >&2
  printf '%bReason:%b %s\n' "$red" "$plain" "$reason" >&2
  printf '%bCurrent step:%b %s\n' "$yellow" "$plain" "$CURRENT_STEP" >&2
  recovery_hint "$solution"
  printf '%b================================================================%b\n' "$red" "$plain" >&2
  exit 1
}
unexpected_error() {
  local exit_code="$1" line="$2"
  printf '\n%b================================================================%b\n' "$red" "$plain" >&2
  printf '%bUNEXPECTED INSTALLATION ERROR%b\n' "$red" "$plain" >&2
  printf '%bStep:%b %s\n' "$yellow" "$plain" "$CURRENT_STEP" >&2
  printf '%bTechnical detail:%b command failed near line %s (exit code %s).\n' "$yellow" "$plain" "$line" "$exit_code" >&2
  recovery_hint
  printf '%b================================================================%b\n' "$red" "$plain" >&2
}
trap 'unexpected_error "$?" "$LINENO"' ERR

[[ ${EUID} -eq 0 ]] || die "Run as root."

remove_installation() {
  local keep_script="${1:-0}" skip_confirmation="${2:-0}" script_path answer shown_answer
  script_path="$(readlink -f "$0")"
  mapfile -t states < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
  [[ ${#states[@]} -eq 1 ]] || die "Expected one 3x-ui installer state file in /root; found ${#states[@]}."
  # shellcheck disable=SC1090
  source "${states[0]}"
  printf '%bThis removes the 3x-ui installation for %s and its generated data.%b\n' "$yellow" "$DOMAIN" "$plain"
  if [[ "$skip_confirmation" != 1 ]]; then
    if ! read -r -p "Continue? [yes/NO]: " answer; then
      die "Removal cancelled: no confirmation was received from the terminal. Re-run the script and enter yes."
    fi
    # Strip a possible carriage return from an SSH terminal and normalise case.
    # Bash is required by this installer, and Ubuntu ships Bash 4+.
    answer="${answer//$'\r'/}"
    answer="${answer,,}"
    if [[ "$answer" != "yes" && "$answer" != "y" ]]; then
      if [[ -z "$answer" ]]; then
        die "Removal cancelled: an empty answer was entered. Type yes (or y) to continue."
      fi
      printf -v shown_answer '%q' "$answer"
      die "Removal cancelled: expected yes or y, but received ${shown_answer}."
    fi
  fi
  warn "Removal restores the configuration created by this script and removes packages it installed. Ubuntu security updates are intentionally kept."

  systemctl disable --now x-ui 2>/dev/null || true
  systemctl disable --now nginx 2>/dev/null || true
  rm -f /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service /usr/bin/x-ui /etc/default/x-ui
  rm -rf /usr/local/x-ui /etc/x-ui /var/log/x-ui
  systemctl daemon-reload
  rm -f /etc/nginx/sites-enabled/3xui-self-steal.conf /etc/nginx/sites-available/3xui-self-steal.conf
  rm -rf /var/www/3xui-cover
  rm -f "${RESULT_FILE:-}"
  rm -f /etc/fail2ban/filter.d/3x-ui.conf /etc/fail2ban/jail.d/3x-ui.conf

  if [[ -x /root/.acme.sh/acme.sh ]]; then
    /root/.acme.sh/acme.sh --remove -d "$DOMAIN" >/dev/null 2>&1 || true
  fi
  rm -rf "/root/cert/${DOMAIN}"
  if [[ -d /root/.acme.sh ]] && [[ -z "$(find /root/cert -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ]]; then
    /root/.acme.sh/acme.sh --uninstall >/dev/null 2>&1 || true
    rm -rf /root/.acme.sh /root/cert
  fi

  [[ "${UFW_HTTP_RULE_EXISTED:-1}" == 1 ]] || ufw --force delete allow 80/tcp >/dev/null 2>&1 || true
  [[ "${UFW_HTTPS_RULE_EXISTED:-1}" == 1 ]] || ufw --force delete allow 443/tcp >/dev/null 2>&1 || true
  [[ "${UFW_PANEL_RULE_EXISTED:-1}" == 1 ]] || ufw --force delete allow "${PANEL_PORT}/tcp" >/dev/null 2>&1 || true
  if [[ "${UFW_SSH_RULE_EXISTED:-${UFW_OPENSSH_EXISTED:-1}}" == 0 ]]; then
    ufw --force delete allow "${SSH_PORT:-22}/tcp" >/dev/null 2>&1 || true
  fi
  [[ "${UFW_WAS_ACTIVE:-1}" == 1 ]] || ufw --force disable >/dev/null 2>&1 || true

  rm -f /etc/modules-load.d/bbr.conf /etc/sysctl.d/99-xhttp-vps-network.conf /etc/sysctl.d/99-3xui-node-network.conf
  if [[ "${SWAP_CREATED_BY_SCRIPT:-0}" == 1 ]]; then
    if ! swapoff /swapfile; then
      die "Could not disable the swap created by this script. Keep /swapfile and its /etc/fstab entry, free memory, then retry removal."
    fi
    if swapon --noheadings --show=NAME 2>/dev/null | grep -Fxq /swapfile; then
      die "The swap created by this script is still active after swapoff. Removal stopped to protect the running system."
    fi
    sed -i '\|^/swapfile[[:space:]]\+none[[:space:]]\+swap[[:space:]]\+sw[[:space:]]\+0[[:space:]]\+0[[:space:]]*$|d' /etc/fstab
    rm -f /swapfile
  fi
  rm -f /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades
  sysctl -w "net.core.default_qdisc=${PREV_QDISC:-fq_codel}" >/dev/null 2>&1 || true
  sysctl -w "net.ipv4.tcp_congestion_control=${PREV_CC:-cubic}" >/dev/null 2>&1 || true
  sysctl -w "net.ipv6.conf.all.disable_ipv6=${PREV_IPV6_ALL:-0}" >/dev/null 2>&1 || true
  sysctl -w "net.ipv6.conf.default.disable_ipv6=${PREV_IPV6_DEFAULT:-0}" >/dev/null 2>&1 || true
  sysctl -w "net.ipv6.conf.lo.disable_ipv6=${PREV_IPV6_LO:-0}" >/dev/null 2>&1 || true

  rm -f "${states[0]}"
  if [[ -n "${PACKAGES_INSTALLED_BY_SCRIPT:-}" ]]; then
    # shellcheck disable=SC2086
    apt-get purge -y $PACKAGES_INSTALLED_BY_SCRIPT || true
    apt-get autoremove -y || true
  fi
  printf '%bRemoval complete.%b The VPN installation, generated data and recorded configuration changes were removed. Ubuntu package updates were kept for security.\n' "$green" "$plain"
  [[ "$keep_script" == 1 ]] || rm -f "$script_path"
}

prepare_vps() {
  local script_path
  script_path="$(readlink -f "$0")"
  mapfile -t states < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
  if [[ ${#states[@]} -eq 1 ]]; then
    printf '%bPREPARATION:%b a previous installation created by this script was found. It can be removed safely.\n' "$yellow" "$plain"
    printf '%bPREPARATION:%b continuing without an extra prompt because menu item 4 was selected explicitly.\n' "$yellow" "$plain"
    remove_installation 1 1
    printf '%bVPS preparation complete.%b Restarting the installer.\n' "$green" "$plain"
    exec "$script_path"
  elif [[ ${#states[@]} -eq 0 ]]; then
    die "No installation managed by this script was found. For safety, automatic preparation will not delete unknown Nginx, 3x-ui or firewall settings. Use a fresh VPS or remove those services manually."
  else
    die "Found ${#states[@]} managed installation state files. Remove or archive the extra state files before preparation."
  fi
}

printf '\nInstallation mode:\n1) Standalone VPN server\n2) Node for an existing 3x-ui panel\n3) Remove every change made by this script\n4) Prepare VPS for a fresh installation\n0) Exit\n'
read -rp "Select [1]: " ACTION
ACTION="${ACTION:-1}"
case "$ACTION" in
  1) INSTALL_MODE="standalone" ;;
  2) INSTALL_MODE="node" ;;
  3) remove_installation; exit 0 ;;
  4) prepare_vps ;;
  0) exit 0 ;;
  *) die "Unknown menu item: $ACTION" ;;
esac

TLS_MODE="production"
printf '%bTLS:%b production Lets Encrypt certificate (required).\n' "$cyan" "$plain"

[[ -r /etc/os-release ]] || die "Cannot identify the operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "A fresh Ubuntu VPS is required. Found: ${ID:-unknown}."
UBUNTU_VERSION="${VERSION_ID:-unknown}"
case "$UBUNTU_VERSION" in
  22.04*|24.04*|26.04*) ;;
  *)
    if [[ "$UBUNTU_VERSION" =~ ^[0-9]+\.[0-9]+$ ]] && dpkg --compare-versions "$UBUNTU_VERSION" ge 22.04; then
      warn "Ubuntu ${UBUNTU_VERSION} is newer or non-LTS and has not been explicitly tested; package availability will be checked."
    else
      die "Supported Ubuntu releases start at 22.04. Found: ${UBUNTU_VERSION}"
    fi
    ;;
esac
command -v systemctl >/dev/null || die "systemd is required."
case "$(uname -m)" in
  x86_64|amd64|aarch64|arm64|armv7l|s390x) ;;
  *) die "Unsupported CPU architecture: $(uname -m)" ;;
esac
mapfile -t EXISTING_STATES < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
if ((${#EXISTING_STATES[@]} > 0)); then
  if ((${#EXISTING_STATES[@]} == 1)); then
    # shellcheck disable=SC1090
    source "${EXISTING_STATES[0]}"
    if [[ "${INSTALL_PHASE:-}" == "bootstrap" ]]; then
      warn "An earlier installation stopped before 3x-ui was ready. Removing only its recorded partial changes, then restarting safely."
      remove_installation 1 1
      exec "$(readlink -f "$0")"
    fi
  fi
  die "This VPS already has an installation managed by this script. Select menu item 3 to remove it, or run /root/finish-xhttp-vps.sh to repair an interrupted installation."
fi
[[ ! -e /etc/x-ui/x-ui.db && ! -x /usr/local/x-ui/x-ui ]] \
  || die "3x-ui is already installed. To protect the existing panel, this installer will not overwrite it. Use a fresh VPS or remove the existing panel first."
if command -v nginx >/dev/null || \
  dpkg-query -W -f='${db:Status-Status}\n' nginx 2>/dev/null | grep -qx 'installed' || \
  [[ -x /usr/local/nginx/sbin/nginx ]]; then
  die "Nginx is already installed. To protect the existing website configuration, use a fresh VPS for this installer."
fi
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  die "UFW is already active. To avoid changing an existing firewall policy, use a fresh VPS or disable and document the current rules before installation."
fi

read -rp "Domain already pointed to this VPS (example: vpn.example.com): " DOMAIN
DOMAIN="${DOMAIN,,}"
[[ "$DOMAIN" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "Invalid domain: ${DOMAIN}"
[[ ${#DOMAIN} -le 253 ]] || die "Domain is longer than the DNS limit (253 characters)."
IFS='.' read -r -a DOMAIN_LABELS <<<"$DOMAIN"
for DOMAIN_LABEL in "${DOMAIN_LABELS[@]}"; do
  [[ ${#DOMAIN_LABEL} -le 63 ]] || die "A DNS label in the domain is longer than 63 characters."
done

DEFAULT_INSTANCE="$(hostname -s | tr -cd 'A-Za-z0-9_-')"
INSTANCE_NAME="${DEFAULT_INSTANCE:-$([[ "$INSTALL_MODE" == "standalone" ]] && echo VPN1 || echo NODE1)}"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  DEFAULT_VPN_NAME="${DOMAIN%%.*} VPN"
  NAME_LABEL="VPN name"
  read -rp "VPN name shown in subscriptions [${DEFAULT_VPN_NAME}]: " VPN_NAME
else
  DEFAULT_VPN_NAME="${DOMAIN%%.*} Node"
  NAME_LABEL="Node name"
  read -rp "Node name shown in the local 3x-ui panel [${DEFAULT_VPN_NAME}]: " VPN_NAME
fi
VPN_NAME="${VPN_NAME:-$DEFAULT_VPN_NAME}"
[[ ${#VPN_NAME} -ge 1 && ${#VPN_NAME} -le 64 ]] || die "${NAME_LABEL} must contain 1-64 characters."
if LC_ALL=C grep -q '[[:cntrl:]]' <<<"$VPN_NAME"; then die "${NAME_LABEL} contains control characters."; fi
read -rp "Route .ru domains and geoip:ru through Cloudflare WARP? [Y/n]: " WARP_ANSWER
WARP_ANSWER="${WARP_ANSWER//$'\r'/}"
WARP_ANSWER="${WARP_ANSWER,,}"
case "${WARP_ANSWER:-y}" in
  y|yes) ENABLE_WARP=1 ;;
  n|no) ENABLE_WARP=0 ;;
  *) die "Expected yes or no for Cloudflare WARP routing." ;;
esac

cat <<'EOF'
Cover-site design:
  1) Automatic (stable selection based on domain)
  2) Engineering consultancy
  3) Digital infrastructure
  4) Logistics and operations
  5) Architecture studio
  6) Industrial service
EOF
read -rp "Select cover design [1]: " COVER_CHOICE
COVER_CHOICE="${COVER_CHOICE:-1}"
if [[ "$COVER_CHOICE" == 1 ]]; then
  COVER_STYLE=$(( $(printf '%s' "$DOMAIN" | cksum | awk '{print $1}') % 5 + 2 ))
else
  COVER_STYLE="$COVER_CHOICE"
fi
[[ "$COVER_STYLE" =~ ^[2-6]$ ]] || die "Unknown cover design: ${COVER_CHOICE}"
case "$COVER_STYLE" in
  2) COVER_LABEL="Engineering consultancy" ;;
  3) COVER_LABEL="Digital infrastructure" ;;
  4) COVER_LABEL="Logistics and operations" ;;
  5) COVER_LABEL="Architecture studio" ;;
  6) COVER_LABEL="Industrial service" ;;
esac

PACKAGES_INSTALLED_BY_SCRIPT=""
if ! command -v curl >/dev/null; then
  export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update
  for package in ca-certificates curl; do
    dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' \
      || PACKAGES_INSTALLED_BY_SCRIPT+=" ${package}"
  done
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ca-certificates curl
fi
PUBLIC_IP="$(curl -4fsS --max-time 10 https://api4.ipify.org || true)"
[[ "$PUBLIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Could not detect the public IPv4."
SSH_PORT="$(awk '{print $4}' <<<"${SSH_CONNECTION:-}" 2>/dev/null || true)"
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
  SSH_PORT="$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}' || true)"
fi
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || SSH_PORT=22

random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
port_busy() { command -v ss >/dev/null && ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .; }
random_port() {
  local p
  while :; do
    p=$((20000 + 0x$(od -An -N 2 -tx2 /dev/urandom | tr -d ' ') % 40000))
    [[ "$p" != "40000" && "$p" != "443" && "$p" != "80" ]] || continue
    port_busy "$p" || { printf '%s' "$p"; return; }
  done
}

PANEL_PORT="$(random_port)"
while :; do SUB_PORT="$(random_port)"; [[ "$SUB_PORT" != "$PANEL_PORT" ]] && break; done
while :; do FALLBACK_PORT="$(random_port)"; [[ "$FALLBACK_PORT" != "$PANEL_PORT" && "$FALLBACK_PORT" != "$SUB_PORT" ]] && break; done
PANEL_PATH="panel-$(random_hex 10)"
SUB_PATH="feed-$(random_hex 10)"
SUB_JSON_PATH=""
SUB_CLASH_PATH=""
MIHOMO_ROUTING_PATH=""
if [[ "$INSTALL_MODE" == "standalone" ]]; then PANEL_USERNAME="vpn$(random_hex 4)"; else PANEL_USERNAME="node$(random_hex 4)"; fi
PANEL_PASSWORD="$(random_hex 18)"
PANEL_API_TOKEN=""
CLIENT_UUID=""
CLIENT_SUB_ID=""
CLIENT_EMAIL=""
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)"
  CLIENT_SUB_ID="$(random_hex 8)"
  CLIENT_EMAIL="${INSTANCE_NAME}-primary"
  SUB_JSON_PATH="json-$(random_hex 10)"
  SUB_CLASH_PATH="mihomo-$(random_hex 10)"
  MIHOMO_ROUTING_PATH="mihomo-routing-$(random_hex 10).yaml"
fi
SAFE_INSTANCE="$(printf '%s' "$INSTANCE_NAME" | tr -cs 'A-Za-z0-9_-' '_')"
STATE_FILE="/root/3xui-vps-${SAFE_INSTANCE}.env"
RESULT_FILE="/root/xhttp-vps-result-${SAFE_INSTANCE}.txt"
CERT_DIR="/root/cert/${DOMAIN}"
PREV_QDISC="$(cat /proc/sys/net/core/default_qdisc 2>/dev/null || echo fq_codel)"
PREV_CC="$(cat /proc/sys/net/ipv4/tcp_congestion_control 2>/dev/null || echo cubic)"
PREV_IPV6_ALL="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
PREV_IPV6_DEFAULT="$(cat /proc/sys/net/ipv6/conf/default/disable_ipv6 2>/dev/null || echo 0)"
PREV_IPV6_LO="$(cat /proc/sys/net/ipv6/conf/lo/disable_ipv6 2>/dev/null || echo 0)"
UFW_WAS_ACTIVE=0
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; then
  UFW_WAS_ACTIVE=1
fi
UFW_SSH_RULE_EXISTED=0
if command -v ufw >/dev/null && ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])(${SSH_PORT}/tcp|OpenSSH)([[:space:]]|$)"; then
  UFW_SSH_RULE_EXISTED=1
fi
UFW_HTTP_RULE_EXISTED=0
UFW_HTTPS_RULE_EXISTED=0
UFW_PANEL_RULE_EXISTED=0
SWAP_CREATED_BY_SCRIPT=0
if command -v ufw >/dev/null; then
  ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])80/tcp([[:space:]]|$)" && UFW_HTTP_RULE_EXISTED=1
  ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])443/tcp([[:space:]]|$)" && UFW_HTTPS_RULE_EXISTED=1
  ufw status 2>/dev/null | grep -Eq "(^|[[:space:]])${PANEL_PORT}/tcp([[:space:]]|$)" && UFW_PANEL_RULE_EXISTED=1
fi

install_recovery_script() {
  local temporary_file source_file
  temporary_file="${RECOVERY_SCRIPT}.new"
  source_file="$(dirname "$(readlink -f "$0")")/finish-xhttp-vps.sh"
  if [[ -r "$source_file" ]]; then
    install -m 700 "$source_file" "$temporary_file"
    mv -f "$temporary_file" "$RECOVERY_SCRIPT"
  else
    rm -f "$temporary_file"
    warn "Recovery script was not installed: upload finish-xhttp-vps.sh alongside this installer before starting. The repository is private, so anonymous GitHub downloads are unavailable."
  fi
}

configure_warp_swap() {
  local memory_kib free_kib
  memory_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  if ! [[ "$memory_kib" =~ ^[0-9]+$ ]] || (( memory_kib > 1100000 )); then
    return 0
  fi
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    log "Keeping existing swap for low-memory WARP VPS"
    return 0
  fi
  if [[ -e /swapfile ]]; then
    warn "Low-memory WARP VPS has /swapfile, but it is not active. The installer will not modify an existing file."
    return 0
  fi
  free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  if ! [[ "$free_kib" =~ ^[0-9]+$ ]] || (( free_kib < 1310720 )); then
    warn "Low-memory WARP VPS has insufficient free disk space for the required 1 GiB swap."
    return 0
  fi
  log "Adding 1 GiB swap for low-memory WARP VPS"
  if ! fallocate -l 1G /swapfile; then
    warn "Could not allocate /swapfile; continuing without managed swap."
    return 0
  fi
  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null; then
    rm -f /swapfile
    warn "Could not format /swapfile; continuing without managed swap."
    return 0
  fi
  if ! swapon /swapfile; then
    rm -f /swapfile
    warn "Could not enable /swapfile; continuing without managed swap."
    return 0
  fi
  if ! printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab; then
    swapoff /swapfile >/dev/null 2>&1 || true
    rm -f /swapfile
    warn "Could not persist /swapfile in /etc/fstab; continuing without managed swap."
    return 0
  fi
  SWAP_CREATED_BY_SCRIPT=1
}

write_state() {
  local temporary_file
  temporary_file="${STATE_FILE}.new"
  umask 077
  cat > "$temporary_file" <<EOF
INSTANCE_NAME=${INSTANCE_NAME}
VPN_NAME=$(printf '%q' "$VPN_NAME")
INSTALL_MODE=${INSTALL_MODE}
TLS_MODE=${TLS_MODE}
INSTALL_PHASE=${INSTALL_PHASE:-bootstrap}
DOMAIN=${DOMAIN}
PUBLIC_IP=${PUBLIC_IP}
PANEL_PORT=${PANEL_PORT}
PANEL_PATH=${PANEL_PATH}
SUB_PORT=${SUB_PORT}
SUB_PATH=${SUB_PATH}
SUB_JSON_PATH=${SUB_JSON_PATH}
SUB_CLASH_PATH=${SUB_CLASH_PATH}
MIHOMO_ROUTING_PATH=${MIHOMO_ROUTING_PATH}
FALLBACK_PORT=${FALLBACK_PORT}
PANEL_USERNAME=${PANEL_USERNAME}
PANEL_PASSWORD=${PANEL_PASSWORD}
PANEL_API_TOKEN=${PANEL_API_TOKEN}
CLIENT_UUID=${CLIENT_UUID}
CLIENT_SUB_ID=${CLIENT_SUB_ID}
CLIENT_EMAIL=${CLIENT_EMAIL}
REALITY_PUBLIC=${REALITY_PUBLIC:-}
SHORT_ID=${SHORT_ID:-}
ENABLE_WARP=${ENABLE_WARP}
COVER_STYLE=${COVER_STYLE}
RESULT_FILE=${RESULT_FILE}
PREV_QDISC=${PREV_QDISC}
PREV_CC=${PREV_CC}
PREV_IPV6_ALL=${PREV_IPV6_ALL}
PREV_IPV6_DEFAULT=${PREV_IPV6_DEFAULT}
PREV_IPV6_LO=${PREV_IPV6_LO}
UFW_WAS_ACTIVE=${UFW_WAS_ACTIVE}
SSH_PORT=${SSH_PORT}
UFW_SSH_RULE_EXISTED=${UFW_SSH_RULE_EXISTED}
UFW_HTTP_RULE_EXISTED=${UFW_HTTP_RULE_EXISTED}
UFW_HTTPS_RULE_EXISTED=${UFW_HTTPS_RULE_EXISTED}
UFW_PANEL_RULE_EXISTED=${UFW_PANEL_RULE_EXISTED}
PACKAGES_INSTALLED_BY_SCRIPT="${PACKAGES_INSTALLED_BY_SCRIPT# }"
SWAP_CREATED_BY_SCRIPT=${SWAP_CREATED_BY_SCRIPT:-0}
EOF
  chmod 600 "$temporary_file"
  mv -f "$temporary_file" "$STATE_FILE"
  INSTALLATION_STARTED=1
  if [[ ! -x "$RECOVERY_SCRIPT" ]]; then
    install_recovery_script
  fi
  umask 022
}

cat <<EOF

Configuration summary
  Mode:          $([[ "$INSTALL_MODE" == "standalone" ]] && echo "standalone VPN server" || echo "node for an existing panel")
  $([[ "$INSTALL_MODE" == "standalone" ]] && echo "VPN name" || echo "Node name"):      ${VPN_NAME}
  Host name:     ${INSTANCE_NAME}
  Ubuntu:        ${UBUNTU_VERSION} ($(uname -m))
  Domain/IP:     ${DOMAIN} / ${PUBLIC_IP}
  SSH port:      ${SSH_PORT} (current Termius session preserved)
  Panel port:    ${PANEL_PORT}
  Subscription:  ${SUB_PORT} (local only)
  Self-steal:    127.0.0.1:${FALLBACK_PORT}
  Cover site:    ${COVER_LABEL}
  WARP for RU:   $([[ "$ENABLE_WARP" -eq 1 ]] && echo yes || echo no)
EOF
read -rp "Start installation? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || die "Cancelled."
INSTALL_PHASE=bootstrap
write_state

log "Refreshing Ubuntu repositories and upgrading installed packages"
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 -y -o Dpkg::Options::="--force-confold" upgrade
UBUNTU_UPGRADE_OK=1

log "Checking availability and installing required packages"

REQUIRED_PACKAGES=(ca-certificates curl iproute2 jq nginx openssl procps socat sqlite3 tar ufw unattended-upgrades unzip wget wireguard-tools)
OPTIONAL_PACKAGES=(fail2ban htop lsof)
INSTALL_PACKAGES=()
MISSING_PACKAGES=()
for package in "${REQUIRED_PACKAGES[@]}"; do
  if apt-cache show "$package" >/dev/null 2>&1; then
    INSTALL_PACKAGES+=("$package")
  else
    MISSING_PACKAGES+=("$package")
  fi
done

DNS_PACKAGE=""
for candidate in dnsutils bind9-dnsutils; do
  if apt-cache show "$candidate" >/dev/null 2>&1; then
    DNS_PACKAGE="$candidate"
    INSTALL_PACKAGES+=("$candidate")
    break
  fi
done
[[ -n "$DNS_PACKAGE" ]] || MISSING_PACKAGES+=("dnsutils-or-bind9-dnsutils")

if ((${#MISSING_PACKAGES[@]} > 0)); then
  die "Required packages are unavailable on Ubuntu ${UBUNTU_VERSION}: ${MISSING_PACKAGES[*]}. Check that main, universe and security repositories are enabled."
fi
for package in "${OPTIONAL_PACKAGES[@]}"; do
  if apt-cache show "$package" >/dev/null 2>&1; then
    INSTALL_PACKAGES+=("$package")
  else
    warn "Optional package '${package}' is unavailable on Ubuntu ${UBUNTU_VERSION}; continuing without it."
  fi
done
for package in "${INSTALL_PACKAGES[@]}"; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' \
    || PACKAGES_INSTALLED_BY_SCRIPT+=" ${package}"
done
write_state
apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${INSTALL_PACKAGES[@]}"
write_state

for command in curl dig ip jq nginx openssl ss sqlite3 sysctl systemctl ufw wg; do
  command -v "$command" >/dev/null || die "Package installation completed, but required command '${command}' is missing."
done
log "Enabling daily Ubuntu security updates without automatic reboot"
cat > /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
cat > /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades <<'EOF'
// Managed by the XHTTP VPS installer. Official Ubuntu security updates only.
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
EOF
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
log "Enabling BBR and disabling IPv6"
cat > /etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF
modprobe tcp_bbr 2>/dev/null || true
grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control \
  || die "The VPS kernel does not provide BBR. Available algorithms: $(cat /proc/sys/net/ipv4/tcp_available_congestion_control)"
cat > /etc/sysctl.d/99-xhttp-vps-network.conf <<'EOF'
# Managed by the XHTTP VPS installer
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
net.ipv6.conf.lo.disable_ipv6=1
EOF
sysctl --system >/dev/null
[[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] || die "BBR could not be activated."
[[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] || die "fq queue discipline could not be activated."
[[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == "1" ]] || die "IPv6 could not be disabled."
log "Network tuning active: BBR + fq, IPv6 disabled"

log "Checking DNS"
mapfile -t DNS_IPS < <(dig +short A "$DOMAIN" | sort -u)
printf '%s\n' "${DNS_IPS[@]}" | grep -Fxq "$PUBLIC_IP" \
  || die "${DOMAIN} does not resolve to ${PUBLIC_IP}. Cloudflare must be DNS only (grey cloud)."
if dig +short AAAA "$DOMAIN" | grep -q .; then
  die "Remove the AAAA record for ${DOMAIN}, then run the script again."
fi

log "Configuring UFW"
ufw default deny incoming
ufw default allow outgoing
ufw allow "$SSH_PORT"/tcp comment 'SSH - preserve remote access'
if [[ "$TLS_MODE" == "production" ]]; then
  ufw allow 80/tcp comment 'ACME HTTP-01'
fi
ufw allow 443/tcp comment 'Xray XHTTP Reality'
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  ufw allow "$PANEL_PORT"/tcp comment '3x-ui VPN panel via domain TLS'
else
  ufw allow "$PANEL_PORT"/tcp comment '3x-ui remote node panel via domain TLS'
fi
ufw --force enable

log "Installing the latest stable 3x-ui"
systemctl stop nginx || true
port_busy 80 && die "TCP/80 is occupied."
for p in "$PANEL_PORT" "$SUB_PORT" 443 "$FALLBACK_PORT"; do port_busy "$p" && die "TCP/${p} is occupied."; done
XUI_VERSION="$(curl -fsS --max-time 10 https://api.github.com/repos/MHSanaei/3x-ui/releases/latest | jq -r '.tag_name // empty' || true)"
[[ -n "$XUI_VERSION" ]] || die "Could not determine the current 3x-ui release from GitHub. Check VPS Internet access and try again."
INSTALLER=/tmp/3x-ui-install.sh
curl -fL --retry 3 "https://raw.githubusercontent.com/MHSanaei/3x-ui/${XUI_VERSION}/install.sh" -o "$INSTALLER"
chmod 700 "$INSTALLER"
if [[ "$TLS_MODE" == "production" ]]; then
  XUI_NONINTERACTIVE=1 XUI_SERVER_IP="$PUBLIC_IP" XUI_USERNAME="$PANEL_USERNAME" \
    XUI_PASSWORD="$PANEL_PASSWORD" XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$PANEL_PATH" \
    XUI_DB_TYPE=sqlite XUI_SSL_MODE=domain XUI_DOMAIN="$DOMAIN" XUI_ACME_HTTP_PORT=80 \
    bash "$INSTALLER" "$XUI_VERSION"
  [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]] || die "Let's Encrypt certificate issuance failed. Check DNS, Cloudflare DNS-only mode and TCP/80, then run /root/finish-xhttp-vps.sh."
else
  XUI_NONINTERACTIVE=1 XUI_SERVER_IP="$PUBLIC_IP" XUI_USERNAME="$PANEL_USERNAME" \
    XUI_PASSWORD="$PANEL_PASSWORD" XUI_PANEL_PORT="$PANEL_PORT" XUI_WEB_BASE_PATH="$PANEL_PATH" \
    XUI_DB_TYPE=sqlite XUI_SSL_MODE=none \
    bash "$INSTALLER" "$XUI_VERSION"
  log "Creating a 30-day self-signed TLS certificate for test mode"
  install -d -m 700 "$CERT_DIR"
  openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days 30 \
    -keyout "$CERT_DIR/privkey.pem" -out "$CERT_DIR/fullchain.pem" \
    -subj "/CN=${DOMAIN}" -addext "subjectAltName=DNS:${DOMAIN}" >/dev/null 2>&1
  chmod 600 "$CERT_DIR/privkey.pem"
  chmod 644 "$CERT_DIR/fullchain.pem"
  /usr/local/x-ui/x-ui cert -webCert "$CERT_DIR/fullchain.pem" -webCertKey "$CERT_DIR/privkey.pem" >/dev/null
fi

# The installer's result file is authoritative. Reading it also protects us
# from future installer-side normalization of the port or web base path.
if [[ -r /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  PANEL_USERNAME="${XUI_USERNAME:-$PANEL_USERNAME}"
  PANEL_PASSWORD="${XUI_PASSWORD:-$PANEL_PASSWORD}"
  PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
  PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
  PANEL_API_TOKEN="${XUI_API_TOKEN:-$PANEL_API_TOKEN}"
  PANEL_PATH="${PANEL_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}"
  write_state
fi
# Current 3x-ui writes the one-time plaintext token to install-result.env.
# Use the CLI only when the installer omitted a token: on recent 3x-ui releases
# that command mints a new fallback token and must never be called routinely.
if [[ -z "$PANEL_API_TOKEN" ]]; then
  PANEL_API_TOKEN="$(/usr/local/x-ui/x-ui setting -getApiToken true 2>/dev/null \
    | awk -F': ' '/apiToken:/{gsub(/[[:space:]]/, "", $2); print $2; exit}')"
fi
# Keep the panel private while it is being configured. Public IPv4 listening
# is enabled only after every API mutation and verification has completed.
/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 -resetTwoFactor=true >/dev/null
[[ -n "$PANEL_API_TOKEN" ]] || die "The official 3x-ui installer did not provide an API token in /etc/x-ui/install-result.env."

log "Creating the TLS self-steal site"
install -d -m 755 /var/www/3xui-cover
DOMAIN_ROOT="${DOMAIN%%.*}"
DOMAIN_ROOT="$(printf '%s' "$DOMAIN_ROOT" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++){$i=toupper(substr($i,1,1)) substr($i,2)} print}')"
case "$COVER_STYLE" in
  2)
    BRAND="${DOMAIN_ROOT} Engineering"; KICKER="Independent engineering consultancy"
    HEADLINE="Technical clarity for complex building systems."
    INTRO="We help project teams move from early technical studies to coordinated delivery with clear documentation, practical analysis and disciplined project controls."
    S1="Technical studies"; D1="Feasibility reviews, system assessments and clearly structured recommendations."
    S2="Design coordination"; D2="Cross-discipline technical alignment from concept through construction information."
    S3="Delivery support"; D3="Documentation reviews, commissioning planning and structured handover support."
    ACCENT="#e56b3f"; ACCENT2="#f2b84b"; SURFACE="#f5f1eb"; INK="#17202a"; MODE="warm"
    PHOTO_ID="xYeGSXRhV80"; PHOTO_ASSET="engineering.jpg"; PHOTO_CREDIT="Dave Meckler" ;;
  3)
    BRAND="${DOMAIN_ROOT} Infrastructure"; KICKER="Digital systems & operations"
    HEADLINE="Infrastructure designed to stay dependable."
    INTRO="Architecture, automation and operational guidance for teams that need secure, observable and maintainable digital systems without unnecessary complexity."
    S1="Platform architecture"; D1="Practical system design shaped around reliability, scale and operating constraints."
    S2="Operational readiness"; D2="Monitoring, runbooks and recovery workflows prepared before services go live."
    S3="Lifecycle improvement"; D3="Measured modernization of existing environments with controlled implementation risk."
    ACCENT="#3b82f6"; ACCENT2="#22c1a3"; SURFACE="#09111f"; INK="#eef5ff"; MODE="dark"
    PHOTO_ID="k27hkqXuveo"; PHOTO_ASSET="infrastructure.jpg"; PHOTO_CREDIT="Eric Stoynov" ;;
  4)
    BRAND="${DOMAIN_ROOT} Operations"; KICKER="Logistics planning & coordination"
    HEADLINE="A clearer route from planning to delivery."
    INTRO="We support complex operational flows with structured planning, supplier coordination and useful reporting that keeps decisions close to real-world conditions."
    S1="Network planning"; D1="Flow analysis and practical operating models for evolving distribution requirements."
    S2="Delivery coordination"; D2="Milestone control, supplier alignment and concise exception reporting."
    S3="Process improvement"; D3="Focused reviews that remove friction without disrupting day-to-day operations."
    ACCENT="#bbf451"; ACCENT2="#57d6c7"; SURFACE="#13251f"; INK="#f4f8ef"; MODE="green"
    PHOTO_ID="F2C_mSrb6iM"; PHOTO_ASSET="logistics.jpg"; PHOTO_CREDIT="Bernd Dittrich" ;;
  5)
    BRAND="${DOMAIN_ROOT} Studio"; KICKER="Architecture & spatial strategy"
    HEADLINE="Thoughtful spaces, resolved with precision."
    INTRO="An independent studio working across early design, technical coordination and project delivery to create places that are calm, useful and built to last."
    S1="Spatial strategy"; D1="Brief development, site response and clear options for informed early decisions."
    S2="Design development"; D2="Material, detail and system coordination carried through with consistency."
    S3="Project continuity"; D3="Design intent protected through documentation, review and on-site collaboration."
    ACCENT="#9d7d62"; ACCENT2="#d8c6b4"; SURFACE="#eeeae4"; INK="#24211f"; MODE="stone"
    PHOTO_ID="A9HNu8LiHQc"; PHOTO_ASSET="architecture.jpg"; PHOTO_CREDIT="Grigorii Shcheglov" ;;
  6)
    BRAND="${DOMAIN_ROOT} Service Group"; KICKER="Industrial maintenance & support"
    HEADLINE="Keeping essential equipment working well."
    INTRO="Planned maintenance, technical documentation and service coordination for commercial and industrial equipment throughout its operating life."
    S1="Maintenance planning"; D1="Asset-led schedules, service scopes and practical maintenance documentation."
    S2="Technical support"; D2="Structured fault review, supplier coordination and clear action tracking."
    S3="Lifecycle services"; D3="Condition reviews and replacement planning grounded in operational priorities."
    ACCENT="#ffb000"; ACCENT2="#f05d3e"; SURFACE="#101418"; INK="#f4f6f8"; MODE="industrial"
    PHOTO_ID="VFrbWve7eAs"; PHOTO_ASSET="industrial-service.jpg"; PHOTO_CREDIT="TECNIC Bioprocess Solutions" ;;
esac
PHOTO_PAGE="https://unsplash.com/photos/${PHOTO_ID}"
PHOTO_FILE="/var/www/3xui-cover/hero.jpg"
REPO_ASSET_BASE="${REPO_ASSET_BASE:-https://raw.githubusercontent.com/yazmann/xhttp-vps-setup/main/assets}"
if ! curl -fsSL --retry 2 --connect-timeout 10 --max-time 60 \
  "${REPO_ASSET_BASE}/${PHOTO_ASSET}" -o "$PHOTO_FILE" 2>/dev/null; then
  warn "Photo is not present in GitHub assets yet; downloading the licensed Unsplash original."
  rm -f "$PHOTO_FILE"
  curl -fsSL --retry 3 --connect-timeout 10 --max-time 90 \
    "https://unsplash.com/photos/${PHOTO_ID}/download?force=true&w=1800&fm=jpg" -o "$PHOTO_FILE"
fi
[[ -s "$PHOTO_FILE" && "$(stat -c '%s' "$PHOTO_FILE")" -gt 50000 ]] \
  || die "The licensed cover photo could not be downloaded correctly."
chmod 644 "$PHOTO_FILE"
cat > /var/www/3xui-cover/index.html <<HTML
<!doctype html>
<html lang="en" data-theme="${MODE}">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="description" content="${KICKER}. ${INTRO}"><title>${BRAND} — ${KICKER}</title>
  <style>
    :root{--accent:${ACCENT};--accent2:${ACCENT2};--surface:${SURFACE};--ink:${INK};--muted:color-mix(in srgb,var(--ink) 62%,transparent);--line:color-mix(in srgb,var(--ink) 14%,transparent);--panel:color-mix(in srgb,var(--surface) 91%,var(--ink) 9%);--max:1180px}
    *{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;background:var(--surface);color:var(--ink);font-family:Inter,ui-sans-serif,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:16px;line-height:1.55;-webkit-font-smoothing:antialiased}a{color:inherit;text-decoration:none}.shell{width:min(calc(100% - 40px),var(--max));margin:auto}
    header{height:82px;display:flex;align-items:center;border-bottom:1px solid var(--line)}nav{display:flex;align-items:center;justify-content:space-between;width:100%}.brand{display:flex;gap:12px;align-items:center;font-weight:680;letter-spacing:-.02em}.mark{width:34px;height:34px;border:1px solid var(--line);border-radius:10px;display:grid;place-items:center;background:linear-gradient(145deg,color-mix(in srgb,var(--accent) 22%,transparent),transparent)}.mark svg{width:18px}.links{display:flex;align-items:center;gap:30px;color:var(--muted);font-size:14px}.links a:hover{color:var(--ink)}
    .hero{min-height:720px;padding:96px 0 84px;display:grid;grid-template-columns:minmax(0,1.08fr) minmax(340px,.92fr);gap:72px;align-items:center}.eyebrow{text-transform:uppercase;letter-spacing:.16em;font-size:12px;font-weight:700;color:var(--accent);margin-bottom:26px}.hero h1{font-size:clamp(48px,6.3vw,82px);line-height:.98;letter-spacing:-.055em;max-width:850px;margin:0}.intro{font-size:19px;line-height:1.65;color:var(--muted);max-width:580px;margin:36px 0}.action{display:inline-flex;align-items:center;gap:12px;border-bottom:1px solid var(--ink);padding:8px 0;font-weight:650}.action span{transition:transform .2s}.action:hover span{transform:translateX(5px)}.visual{position:relative;margin:0;min-height:540px;border-radius:4px 42px 4px 4px;overflow:hidden;background:var(--panel);box-shadow:0 26px 70px color-mix(in srgb,var(--ink) 16%,transparent)}.visual:after{content:"";position:absolute;inset:0;background:linear-gradient(180deg,transparent 48%,rgba(5,10,15,.76))}.visual img{position:absolute;width:100%;height:100%;object-fit:cover;filter:saturate(.88) contrast(1.04)}.visual-note{position:absolute;z-index:1;left:28px;right:28px;bottom:26px;color:#fff;font-size:14px}.visual-note strong{display:block;font-size:17px;margin-bottom:7px}.credit{position:absolute;z-index:2;right:14px;top:14px;padding:6px 9px;border-radius:20px;background:rgba(0,0,0,.42);backdrop-filter:blur(8px);color:rgba(255,255,255,.82);font-size:10px}
    .band{border-top:1px solid var(--line);border-bottom:1px solid var(--line);padding:25px 0}.band-row{display:flex;justify-content:space-between;gap:30px;color:var(--muted);font-size:13px;text-transform:uppercase;letter-spacing:.1em}.dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:var(--accent);margin-right:10px}
    section{padding:110px 0}.section-head{display:grid;grid-template-columns:1fr 2fr;gap:60px;margin-bottom:64px}.section-head p{margin:0;color:var(--muted);max-width:700px;font-size:18px}.label{font-size:12px;text-transform:uppercase;letter-spacing:.15em;font-weight:700;color:var(--accent)}.services{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--line)}.service{padding:34px 34px 42px 0;border-bottom:1px solid var(--line)}.service+.service{border-left:1px solid var(--line);padding-left:34px}.num{font-variant-numeric:tabular-nums;color:var(--accent);font-size:12px}.service h2{font-size:24px;letter-spacing:-.025em;margin:50px 0 15px}.service p{color:var(--muted);margin:0;max-width:330px}
    .approach{background:var(--panel);border-radius:28px;padding:70px;display:grid;grid-template-columns:1fr 1fr;gap:80px}.approach h2{font-size:clamp(36px,4vw,58px);line-height:1.05;letter-spacing:-.045em;margin:0}.steps{counter-reset:step}.step{counter-increment:step;display:grid;grid-template-columns:38px 1fr;gap:15px;padding:20px 0;border-bottom:1px solid var(--line)}.step:before{content:"0" counter(step);color:var(--accent);font-size:12px}.step strong{display:block;margin-bottom:5px}.step span{color:var(--muted);font-size:14px}
    footer{padding:44px 0;border-top:1px solid var(--line);color:var(--muted);font-size:13px}.footer-row{display:flex;justify-content:space-between;gap:30px}.domain{color:var(--ink)}
    @media(max-width:800px){.links a:not(:last-child){display:none}.hero{grid-template-columns:1fr;min-height:auto;padding:72px 0 64px;gap:50px}.visual{min-height:430px;border-radius:4px 30px 4px 4px}.band-row{flex-wrap:wrap}.section-head,.approach{grid-template-columns:1fr}.services{grid-template-columns:1fr}.service+.service{border-left:0;padding-left:0}.approach{padding:38px;gap:45px}.footer-row{flex-direction:column}.hero h1{font-size:clamp(44px,14vw,70px)}}
    @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}.action span{transition:none}}
  </style>
</head>
<body>
  <header><div class="shell"><nav><a class="brand" href="#"><span class="mark"><svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 17.5 12 4l8 13.5M7 14h10" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round"/></svg></span>${BRAND}</a><div class="links"><a href="#capabilities">Capabilities</a><a href="#approach">Approach</a><a href="#about">About</a></div></nav></div></header>
  <main>
    <div class="shell hero"><div><div class="eyebrow">${KICKER}</div><h1>${HEADLINE}</h1><p class="intro">${INTRO}</p><a class="action" href="#capabilities">Explore our capabilities <span>→</span></a></div><figure class="visual"><img src="/hero.jpg" alt="${KICKER}" width="900" height="1100"><a class="credit" href="${PHOTO_PAGE}" rel="noreferrer">Photo: ${PHOTO_CREDIT} / Unsplash</a><figcaption class="visual-note"><strong>Measured, collaborative, accountable.</strong>Clear technical thinking and decisions grounded in the realities of delivery.</figcaption></figure></div>
    <div class="band"><div class="shell band-row"><span><i class="dot"></i>Independent practice</span><span>Planning & coordination</span><span>Documentation & delivery</span></div></div>
    <section id="capabilities"><div class="shell"><div class="section-head"><div class="label">What we do</div><p>Focused support at the points where good information and careful coordination have the greatest impact on project outcomes.</p></div><div class="services"><article class="service"><div class="num">01</div><h2>${S1}</h2><p>${D1}</p></article><article class="service"><div class="num">02</div><h2>${S2}</h2><p>${D2}</p></article><article class="service"><div class="num">03</div><h2>${S3}</h2><p>${D3}</p></article></div></div></section>
    <section id="approach"><div class="shell approach"><div><div class="label">How we work</div><h2>Useful detail.<br>Decisive progress.</h2></div><div class="steps"><div class="step"><div><strong>Understand the context</strong><span>Define the real constraints, responsibilities and measures of success.</span></div></div><div class="step"><div><strong>Make the work visible</strong><span>Turn complex information into an organised, reviewable plan.</span></div></div><div class="step"><div><strong>Follow through</strong><span>Keep decisions, documentation and delivery aligned as the work develops.</span></div></div></div></div></section>
  </main>
  <footer id="about"><div class="shell footer-row"><span class="domain">${DOMAIN}</span><span>${BRAND} · Professional services</span><span>© $(date +%Y)</span></div></footer>
</body>
</html>
HTML
cat > /etc/nginx/sites-available/3xui-self-steal.conf <<EOF
server {
    listen 127.0.0.1:${FALLBACK_PORT} ssl;
    server_name ${DOMAIN};
    ssl_certificate ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    root /var/www/3xui-cover;
    index index.html;
    location ^~ /${SUB_PATH}/ {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name ${DOMAIN};
        proxy_set_header Host ${DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location ^~ /${SUB_JSON_PATH:-disabled-json}/ {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name ${DOMAIN};
        proxy_set_header Host ${DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location ^~ /${SUB_CLASH_PATH:-disabled-mihomo}/ {
        proxy_pass https://127.0.0.1:${SUB_PORT};
        proxy_ssl_verify off;
        proxy_ssl_server_name on;
        proxy_ssl_name ${DOMAIN};
        proxy_set_header Host ${DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF
rm -f /etc/nginx/sites-enabled/default
ln -sfn /etc/nginx/sites-available/3xui-self-steal.conf /etc/nginx/sites-enabled/3xui-self-steal.conf
nginx -t
systemctl enable --now nginx
systemctl enable x-ui
systemctl restart x-ui
if [[ "$TLS_MODE" == "production" ]]; then
  /root/.acme.sh/acme.sh --install-cert -d "$DOMAIN" --key-file "$CERT_DIR/privkey.pem" \
    --fullchain-file "$CERT_DIR/fullchain.pem" --reloadcmd "systemctl reload nginx && systemctl restart x-ui"
fi

INSTALL_PHASE=service-ready
write_state

API_BASE="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
API_AUTH=(-H "Authorization: Bearer ${PANEL_API_TOKEN}" -H 'X-Requested-With: XMLHttpRequest')

build_warp_outbound() {
  local data_json="$1" config_json="$2" private_key client_id peer_key endpoint addresses reserved
  WARP_OUT=""
  private_key="$(jq -r '.private_key // empty' <<<"$data_json")"
  client_id="$(jq -r '.client_id // empty' <<<"$data_json")"
  peer_key="$(jq -r '.config.peers[0].public_key // empty' <<<"$config_json")"
  endpoint="$(jq -r '.config.peers[0].endpoint.host // empty' <<<"$config_json")"
  addresses="$(jq -nc --arg v4 "$(jq -r '.config.interface.addresses.v4 // empty' <<<"$config_json")" \
    --arg v6 "$(jq -r '.config.interface.addresses.v6 // empty' <<<"$config_json")" \
    '[$v4, $v6 | select(length > 0) | if contains(":") then . + "/128" else . + "/32" end]')"
  [[ -n "$private_key" && -n "$client_id" && -n "$peer_key" && -n "$endpoint" && "$addresses" != "[]" ]] || return 1
  reserved="$(printf '%s' "$client_id" | base64 -d 2>/dev/null | od -An -tu1 | awk 'BEGIN { printf "[" } { for (i=1; i<=NF; i++) { if (n++) printf ","; printf $i } } END { print "]" }')" || return 1
  [[ "$reserved" != "[]" ]] || return 1
  WARP_OUT="$(jq -nc --arg private "$private_key" --arg public "$peer_key" --arg endpoint "$endpoint" \
    --argjson addresses "$addresses" --argjson reserved "$reserved" \
    '{tag:"warp",protocol:"wireguard",settings:{mtu:1420,secretKey:$private,address:$addresses,reserved:$reserved,domainStrategy:"ForceIPv4v6",peers:[{publicKey:$public,endpoint:$endpoint}],noKernelTun:true}}')" || return 1
}

log "Waiting for the private IPv4 panel API and verifying its bearer token"
API_READY=0; RESPONSE=""; API_HTTP_CODE="000"
for _ in $(seq 1 15); do
  API_PROBE="$(curl -ksS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 \
    -w $'\n%{http_code}' "$API_BASE/panel/api/server/status" 2>&1 || true)"
  API_HTTP_CODE="${API_PROBE##*$'\n'}"
  RESPONSE="${API_PROBE%$'\n'*}"
  if [[ "$API_HTTP_CODE" == "200" ]] && jq -e '.success == true' <<<"$RESPONSE" >/dev/null 2>&1; then
    API_READY=1
    break
  fi
  sleep 1
done
if [[ "$API_READY" -ne 1 ]]; then
  systemctl status x-ui --no-pager || true
  /usr/local/x-ui/x-ui setting -show true 2>/dev/null || true
  ss -ltnp | grep -E ":${PANEL_PORT}([[:space:]]|$)" || true
  die "Private bearer API did not become ready after 15 attempts. HTTP ${API_HTTP_CODE}; response: ${RESPONSE:-<empty>}"
fi

log "Enabling and configuring subscriptions"
RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all")"
SETTINGS="$(jq -c '.obj | if type == "string" then fromjson else . end' <<<"$RESPONSE")"
SETTINGS="$(jq -c --arg d "$DOMAIN" --arg title "$VPN_NAME" --argjson p "$SUB_PORT" --arg path "/${SUB_PATH}/" --arg cert "$CERT_DIR/fullchain.pem" --arg key "$CERT_DIR/privkey.pem" '
  .twoFactorEnable=false
  | .subEnable=true | .subEncrypt=true | .subListen="127.0.0.1" | .subDomain=$d | .subPort=$p | .subPath=$path
  | .subCertFile=$cert | .subKeyFile=$key | .subURI=("https://"+$d+$path) | .subTitle=$title
' <<<"$SETTINGS")"
CLIENT_ROUTING_CONFIGURED=0; MIHOMO_CONFIGURED=0
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  HAPP_ROUTING="$(curl -fsSL --retry 3 --max-time 30 https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/HAPP/DEFAULT.DEEPLINK 2>/dev/null || true)"
  INCY_ROUTING="$(curl -fsSL --retry 3 --max-time 30 https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/INCY/DEFAULT.DEEPLINK 2>/dev/null || true)"
  if [[ "$HAPP_ROUTING" == happ://routing/onadd/* && "$INCY_ROUTING" == incy://routing/onadd/* ]]; then
    SETTINGS="$(jq -c --arg happ "$HAPP_ROUTING" --arg incy "$INCY_ROUTING" \
      --arg jsonPath "/${SUB_JSON_PATH}/" --arg clashPath "/${SUB_CLASH_PATH}/" \
      --arg jsonURI "https://${DOMAIN}/${SUB_JSON_PATH}/" --arg clashURI "https://${DOMAIN}/${SUB_CLASH_PATH}/" '
      .subEnableRouting=true | .subRoutingRules=$happ
      | .subIncyEnableRouting=true | .subIncyRoutingRules=$incy
      | .subJsonEnable=true | .subJsonPath=$jsonPath | .subJsonURI=$jsonURI
      | .subClashEnable=true | .subClashPath=$clashPath | .subClashURI=$clashURI
      | .subClashEnableRouting=false
    ' <<<"$SETTINGS")"
    CLIENT_ROUTING_CONFIGURED=1
    MIHOMO_CONFIGURED=1
  else
    warn "RoscomVPN routing profiles could not be downloaded; HAPP/INCY routing and Mihomo endpoint are left disabled."
  fi
fi
RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -H 'Content-Type: application/json' -X POST "$API_BASE/panel/api/setting/update" --data-binary "$SETTINGS")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Subscription configuration failed: ${RESPONSE}"
SUBSCRIPTION_CONFIGURED=1

if [[ "$INSTALL_MODE" == "standalone" ]]; then
  log "Creating Mihomo subscription with RoscomVPN routing"
  MIHOMO_PROVIDER_URL="https://${DOMAIN}/${SUB_CLASH_PATH}/${CLIENT_SUB_ID}"
  MIHOMO_ROUTING_URL="https://${DOMAIN}/${MIHOMO_ROUTING_PATH}"
  MIHOMO_TEMPLATE="$(curl -fsSL --retry 3 --max-time 60 https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/MIHOMO/default.yaml 2>/dev/null || true)"
  if grep -Fq '<ВВЕДИТЕ URL ПОДПИСКИ>' <<<"$MIHOMO_TEMPLATE"; then
    printf '%s\n' "$MIHOMO_TEMPLATE" | sed "s|<ВВЕДИТЕ URL ПОДПИСКИ>|${MIHOMO_PROVIDER_URL}|g" > "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    chmod 644 "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    MIHOMO_CONFIGURED=1
    write_state
  else
    MIHOMO_CONFIGURED=0
    warn "RoscomVPN Mihomo template could not be downloaded; the Mihomo routing subscription is unavailable."
  fi
fi

log "Creating VLESS + XHTTP + REALITY inbound on TCP/443"
RESPONSE="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/server/getNewX25519Cert")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Reality key generation failed: ${RESPONSE}"
REALITY_PRIVATE="$(jq -r '.obj.privateKey // .obj.private // empty' <<<"$RESPONSE")"
REALITY_PUBLIC="$(jq -r '.obj.publicKey // .obj.public // empty' <<<"$RESPONSE")"
[[ -n "$REALITY_PRIVATE" && -n "$REALITY_PUBLIC" ]] || die "3x-ui returned incomplete Reality keys: ${RESPONSE}"
SHORT_ID="$(random_hex 8)"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  INBOUND_SETTINGS="$(jq -nc --arg id "$CLIENT_UUID" --arg email "$CLIENT_EMAIL" --arg sub "$CLIENT_SUB_ID" \
    '{clients:[{id:$id,flow:"",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,reset:0}],decryption:"none",encryption:"none",fallbacks:[]}')"
else
  INBOUND_SETTINGS="$(jq -nc '{clients:[],decryption:"none",encryption:"none",fallbacks:[]}')"
fi
STREAM_SETTINGS="$(jq -nc --arg d "$DOMAIN" --arg dest "127.0.0.1:${FALLBACK_PORT}" \
  --arg private "$REALITY_PRIVATE" --arg public "$REALITY_PUBLIC" --arg sid "$SHORT_ID" '
  {network:"xhttp",security:"reality",externalProxy:[],
   realitySettings:{show:false,xver:0,dest:$dest,privateKey:$private,minClientVer:"",maxClientVer:"",maxTimeDiff:0,
     serverNames:[$d],shortIds:[$sid],settings:{publicKey:$public,fingerprint:"firefox",serverName:"",spiderX:"/"}},
   xhttpSettings:{host:$d,path:"/",mode:"auto",xPaddingBytes:"100-1000",xPaddingObfsMode:false,
     noSSEHeader:false,scMaxEachPostBytes:"1000000",scMaxBufferedPosts:30,scStreamUpServerSecs:"20-80",headers:{}}}
')"
SNIFFING="$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')"
INBOUND="$(jq -nc --arg remark "${VPN_NAME} — XHTTP Reality" --arg settings "$INBOUND_SETTINGS" \
  --arg stream "$STREAM_SETTINGS" --arg sniff "$SNIFFING" '
  {up:0,down:0,total:0,remark:$remark,enable:true,expiryTime:0,trafficReset:"never",listen:"",port:443,
   protocol:"vless",settings:$settings,streamSettings:$stream,tag:"in-443-xhttp-reality",sniffing:$sniff}
')"
RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "$API_BASE/panel/api/inbounds/add" --data-binary "$INBOUND")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Inbound creation failed: ${RESPONSE}"
RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/server/restartXrayService")"
jq -e '.success == true' <<<"$RESPONSE" >/dev/null || die "Xray restart after inbound creation failed: ${RESPONSE}"
INBOUND_CONFIGURED=1
write_state

if [[ "$ENABLE_WARP" -eq 1 ]]; then
  log "Creating built-in WARP and RU routing"
  RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
  if ! jq -e '.success == true and .obj != null and .obj != ""' <<<"$RESPONSE" >/dev/null; then
    PRIVATE_KEY="$(wg genkey)"; PUBLIC_KEY="$(printf '%s' "$PRIVATE_KEY" | wg pubkey)"
    RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/reg" --data-urlencode "privateKey=$PRIVATE_KEY" --data-urlencode "publicKey=$PUBLIC_KEY")"
    if ! jq -e '.success == true' <<<"$RESPONSE" >/dev/null; then
      die "WARP registration failed. WARP was requested, so installation cannot continue. Panel response: ${RESPONSE}"
    fi
  fi
  if [[ "$ENABLE_WARP" -eq 1 ]]; then
    WARP_DATA_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
    WARP_CONFIG_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/config")"
    WARP_DATA="$(jq -c '.obj | if type=="string" then fromjson else . end' <<<"$WARP_DATA_RESPONSE")"
    WARP_CONFIG="$(jq -c '.obj | if type=="string" then fromjson else . end' <<<"$WARP_CONFIG_RESPONSE")"
    if ! build_warp_outbound "$WARP_DATA" "$WARP_CONFIG"; then
      die "WARP account data is incomplete. WARP was requested, so installation cannot continue."
    else
      RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/")"
      jq -e '.success == true and .obj != null' <<<"$RESPONSE" >/dev/null || die "Could not read Xray configuration: $RESPONSE"
      XRAY="$(jq -c '.obj | if type=="string" then fromjson else . end | .xraySetting | if type=="string" then fromjson else . end' <<<"$RESPONSE")"
      jq -e 'type=="object" and (.outbounds|type=="array")' <<<"$XRAY" >/dev/null || die "Xray configuration has an unexpected format."
      cp -a /etc/x-ui/x-ui.db "/etc/x-ui/x-ui.db.before-warp.$(date +%Y%m%d-%H%M%S)"
      XRAY="$(jq -c --argjson w "$WARP_OUT" '
        .outbounds=((.outbounds//[])|map(select(.tag!="warp")))+[$w]
        | .routing=(.routing//{}) | .routing.domainStrategy="IPIfNonMatch"
        | .routing.rules=[
            {"type":"field","domain":["domain:ru"],"outboundTag":"warp","network":"tcp,udp","ruleTag":"xhttp-vps-warp-ru-domain"},
            {"type":"field","ip":["geoip:ru"],"outboundTag":"warp","network":"tcp,udp","ruleTag":"xhttp-vps-warp-ru-ip"}
          ]+((.routing.rules//[])|map(select(.ruleTag!="xhttp-vps-warp-ru-domain" and .ruleTag!="xhttp-vps-warp-ru-ip")))
      ' <<<"$XRAY")"
      RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/update" --data-urlencode "xraySetting=$XRAY" --data-urlencode 'outboundTestUrl=https://www.cloudflare.com/cdn-cgi/trace')"
      if jq -e '.success == true' <<<"$RESPONSE" >/dev/null; then
        VERIFY_WARP_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/")"
        VERIFY_WARP="$(jq -c '.obj | if type=="string" then fromjson else . end | .xraySetting | if type=="string" then fromjson else . end' <<<"$VERIFY_WARP_RESPONSE")"
        jq -e 'type=="object" and any(.outbounds[]?; .tag=="warp") and any(.routing.rules[]?; .ruleTag=="xhttp-vps-warp-ru-domain" and .outboundTag=="warp") and any(.routing.rules[]?; .ruleTag=="xhttp-vps-warp-ru-ip" and .outboundTag=="warp")' <<<"$VERIFY_WARP" >/dev/null || die "WARP configuration could not be verified after saving."
        WARP_CONFIGURED=1
        configure_warp_swap
      else
        die "WARP routing could not be saved. WARP was requested, so installation cannot continue. Panel response: ${RESPONSE}"
      fi
    fi
  fi
fi
write_state

systemctl restart x-ui
sleep 1
API_READY=0; RESPONSE=""
for _ in $(seq 1 15); do
  RESPONSE="$(curl -kfsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success == true' <<<"$RESPONSE" >/dev/null 2>&1; then API_READY=1; break; fi
  sleep 1
done
[[ "$API_READY" -eq 1 ]] || die "Private bearer API did not return after restart. Last response: ${RESPONSE:-<empty>}"

# Verify the saved configuration through the panel API, not only the TCP port.
INBOUND_VERIFIED=0; CLIENT_VERIFIED=0; SUBSCRIPTION_VERIFIED=0; PUBLIC_SELF_STEAL_VERIFIED=0
CLIENT_ROUTING_VERIFIED=0; MIHOMO_VERIFIED=0; TWO_FACTOR_DISABLED=0
SETTING_VERIFY_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all" || true)"
if jq -e '.success == true and ((.obj | if type=="string" then fromjson else . end).twoFactorEnable == false)' \
  <<<"$SETTING_VERIFY_RESPONSE" >/dev/null 2>&1; then TWO_FACTOR_DISABLED=1; fi
VERIFY_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list" || true)"
if jq -e --arg d "$DOMAIN" --arg dest "127.0.0.1:${FALLBACK_PORT}" '
  .success == true and
  ((.obj | if type=="string" then fromjson else . end) | any(
    .port==443 and .protocol=="vless" and .enable==true and
    ((.streamSettings | if type=="string" then fromjson else . end) as $s |
      $s.network=="xhttp" and $s.security=="reality" and
      (($s.realitySettings.dest // $s.realitySettings.target) == $dest) and
      (($s.realitySettings.serverNames // []) | index($d)) != null and
      $s.xhttpSettings.host==$d and $s.xhttpSettings.path=="/")
  ))' <<<"$VERIFY_RESPONSE" >/dev/null 2>&1; then
  INBOUND_VERIFIED=1
fi
for _ in $(seq 1 20); do
  COVER_RESPONSE="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 "https://${DOMAIN}/" 2>/dev/null || true)"
  if grep -Fq "$DOMAIN" <<<"$COVER_RESPONSE"; then PUBLIC_SELF_STEAL_VERIFIED=1; break; fi
  sleep 1
done
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if jq -e --arg id "$CLIENT_UUID" --arg sub "$CLIENT_SUB_ID" '
    .success == true and
    ((.obj | if type=="string" then fromjson else . end) | any(
      .port==443 and .protocol=="vless" and
      ((.settings | if type=="string" then fromjson else . end).clients | any(.id==$id and .subId==$sub and .enable==true))
    ))' <<<"$VERIFY_RESPONSE" >/dev/null 2>&1; then
    CLIENT_VERIFIED=1
  fi
  for _ in $(seq 1 20); do
    SUB_RESPONSE="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 \
      "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    [[ -n "$SUB_RESPONSE" ]] && { SUBSCRIPTION_VERIFIED=1; break; }
    sleep 1
  done
  if [[ "$CLIENT_ROUTING_CONFIGURED" -eq 1 && "$SUBSCRIPTION_VERIFIED" -eq 1 ]]; then
    SUB_HEADERS="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 -D - -o /dev/null \
      "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    SUB_DECODED="$(printf '%s' "$SUB_RESPONSE" | base64 -d 2>/dev/null || true)"
    if grep -qi '^Routing-Enable:[[:space:]]*true' <<<"$SUB_HEADERS" \
      && grep -qi '^Routing:[[:space:]]*happ://routing/onadd/' <<<"$SUB_HEADERS" \
      && grep -q 'incy://routing/onadd/' <<<"$SUB_DECODED"; then
      CLIENT_ROUTING_VERIFIED=1
    fi
  fi
  if [[ "$MIHOMO_CONFIGURED" -eq 1 ]]; then
    MIHOMO_RESPONSE="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 10 \
      "$MIHOMO_ROUTING_URL" 2>/dev/null || true)"
    if grep -q '^rule-providers:' <<<"$MIHOMO_RESPONSE" && grep -Fq "$MIHOMO_PROVIDER_URL" <<<"$MIHOMO_RESPONSE"; then MIHOMO_VERIFIED=1; fi
  fi
fi

log "Publishing the panel on IPv4 after private configuration"
/usr/local/x-ui/x-ui setting -listenIP 0.0.0.0 >/dev/null
systemctl restart x-ui
PANEL_HTTPS_VERIFIED=0
PANEL_PUBLIC_URL="https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/"
for _ in $(seq 1 20); do
  if curl -kfsS --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" --connect-timeout 2 --max-time 5 \
    -o /dev/null "$PANEL_PUBLIC_URL" 2>/dev/null; then PANEL_HTTPS_VERIFIED=1; break; fi
  sleep 1
done

log "Final checks"
CHECK_FAILURES=0
status_line() {
  local label="$1" result="$2" detail="${3:-}"
  if [[ "$result" == "OK" ]]; then
    printf '  %-32s %bOK%b%s\n' "$label" "$green" "$plain" "${detail:+ — $detail}"
  elif [[ "$result" == "SKIP" ]]; then
    printf '  %-32s %bSKIP%b%s\n' "$label" "$yellow" "$plain" "${detail:+ — $detail}"
  else
    printf '  %-32s %bERROR%b%s\n' "$label" "$red" "$plain" "${detail:+ — $detail}"
    CHECK_FAILURES=$((CHECK_FAILURES + 1))
  fi
}

printf '\n==================== INSTALLATION AUDIT ====================\n'
if [[ "${UBUNTU_UPGRADE_OK:-0}" -eq 1 ]] && apt-get check >/dev/null 2>&1 && [[ -z "$(dpkg --audit)" ]]; then status_line "Ubuntu package upgrade" OK "Ubuntu $UBUNTU_VERSION"; else status_line "Ubuntu package upgrade" ERROR; fi
if apt-get check >/dev/null 2>&1 && [[ -z "$(dpkg --audit)" ]]; then status_line "Required packages" OK; else status_line "Required packages" ERROR; fi
if systemctl is-enabled --quiet apt-daily.timer && systemctl is-enabled --quiet apt-daily-upgrade.timer && [[ -r /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades ]]; then status_line "Daily security updates" OK "automatic reboot disabled"; else status_line "Daily security updates" ERROR; fi
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr && "$(sysctl -n net.core.default_qdisc)" == fq ]]; then status_line "BBR + fq" OK; else status_line "BBR + fq" ERROR; fi
if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]]; then status_line "IPv6 disabled" OK; else status_line "IPv6 disabled" ERROR; fi
if printf '%s\n' "$(dig +short A "$DOMAIN")" | grep -Fxq "$PUBLIC_IP" && ! dig +short AAAA "$DOMAIN" | grep -q .; then status_line "DNS A / AAAA" OK "$DOMAIN → $PUBLIC_IP"; else status_line "DNS A / AAAA" ERROR; fi
if ufw status | grep -q '^Status: active'; then status_line "UFW firewall" OK; else status_line "UFW firewall" ERROR; fi
if openssl x509 -in "$CERT_DIR/fullchain.pem" -checkend 86400 -noout >/dev/null 2>&1; then
  if [[ "$TLS_MODE" == "production" ]]; then
    status_line "TLS certificate" OK "trusted Let's Encrypt"
  else
    status_line "TLS certificate" OK "TEST: self-signed, 30 days"
  fi
else
  status_line "TLS certificate" ERROR
fi
if systemctl is-enabled --quiet x-ui && systemctl is-active --quiet x-ui && [[ "$PANEL_HTTPS_VERIFIED" -eq 1 ]]; then status_line "3x-ui panel HTTPS" OK "$DOMAIN:$PANEL_PORT"; else status_line "3x-ui panel HTTPS" ERROR; fi
if [[ "$TWO_FACTOR_DISABLED" -eq 1 ]]; then status_line "Panel two-factor auth" OK "disabled"; else status_line "Panel two-factor auth" ERROR; fi
if nginx -t >/dev/null 2>&1 && systemctl is-enabled --quiet nginx && systemctl is-active --quiet nginx && port_busy "$FALLBACK_PORT"; then status_line "nginx self-steal" OK "127.0.0.1:$FALLBACK_PORT"; else status_line "nginx self-steal" ERROR; fi
if [[ "$PANEL_HTTPS_VERIFIED" -eq 1 ]]; then status_line "Panel web interface" OK "domain TLS and base path"; else status_line "Panel web interface" ERROR; fi
if curl -kfsSI --resolve "$DOMAIN:$FALLBACK_PORT:127.0.0.1" "https://$DOMAIN:$FALLBACK_PORT/" >/dev/null; then status_line "Cover website" OK; else status_line "Cover website" ERROR; fi
if [[ "$PUBLIC_SELF_STEAL_VERIFIED" -eq 1 ]]; then status_line "Public self-steal website" OK "normal TLS through TCP 443"; else status_line "Public self-steal website" ERROR; fi
if [[ -s /var/www/3xui-cover/hero.jpg && "$(stat -c '%s' /var/www/3xui-cover/hero.jpg)" -gt 50000 ]]; then status_line "Licensed cover photo" OK "$PHOTO_CREDIT / Unsplash"; else status_line "Licensed cover photo" ERROR; fi
if [[ "${INBOUND_CONFIGURED:-0}" -eq 1 && "$INBOUND_VERIFIED" -eq 1 ]] && port_busy 443; then status_line "XHTTP Reality self-steal" OK "TCP 443 → 127.0.0.1:$FALLBACK_PORT"; else status_line "XHTTP Reality self-steal" ERROR; fi
if [[ "${SUBSCRIPTION_CONFIGURED:-0}" -eq 1 ]] && port_busy "$SUB_PORT"; then status_line "Subscription service" OK "127.0.0.1:$SUB_PORT"; else status_line "Subscription service" ERROR; fi
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if [[ "$CLIENT_VERIFIED" -eq 1 ]]; then status_line "First VLESS client" OK "$CLIENT_EMAIL"; else status_line "First VLESS client" ERROR; fi
  if [[ "$SUBSCRIPTION_VERIFIED" -eq 1 ]]; then status_line "Client subscription URL" OK "verified through TCP 443"; else status_line "Client subscription URL" ERROR; fi
  if [[ "$CLIENT_ROUTING_VERIFIED" -eq 1 ]]; then status_line "HAPP + INCY routing" OK "RoscomVPN profiles injected"; else status_line "HAPP + INCY routing" ERROR; fi
  if [[ "$MIHOMO_VERIFIED" -eq 1 ]]; then status_line "Mihomo subscription" OK "YAML endpoint verified"; else status_line "Mihomo subscription" ERROR; fi
else
  status_line "First VLESS client" SKIP "managed by the main panel"
  status_line "Client subscription URL" SKIP "managed by the main panel"
  status_line "HAPP + INCY routing" SKIP "managed by the main panel"
  status_line "Mihomo subscription" SKIP "managed by the main panel"
fi
if command -v fail2ban-client >/dev/null; then
  if systemctl is-active --quiet fail2ban; then status_line "Fail2ban" OK; else status_line "Fail2ban" ERROR; fi
else
  status_line "Fail2ban" SKIP "package unavailable"
fi
if [[ "$ENABLE_WARP" -eq 1 ]]; then
  if [[ "${WARP_CONFIGURED:-0}" -eq 1 ]]; then status_line "WARP RU routing" OK; else status_line "WARP RU routing" ERROR; fi
else
  status_line "WARP RU routing" SKIP "disabled by user"
fi
MEMORY_KIB_FINAL="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
if [[ "$ENABLE_WARP" -eq 1 && "$MEMORY_KIB_FINAL" =~ ^[0-9]+$ ]] && (( MEMORY_KIB_FINAL <= 1100000 )); then
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    status_line "Swap for low-memory WARP" OK
  else
    status_line "Swap for low-memory WARP" ERROR "1 GiB swap is required"
  fi
else
  status_line "Swap for low-memory WARP" SKIP "not required"
fi
printf '============================================================\n'

if [[ "$CHECK_FAILURES" -eq 0 ]]; then
  STANDALONE_STATUS_MESSAGE='The standalone VPN server is ready. Add the matching subscription URL to the client.'
  NODE_STATUS_MESSAGE='The remote node setup is ready. Add it to the main panel with the Panel URL and credentials/API token.'
else
  STANDALONE_STATUS_MESSAGE='Installation finished with failed checks. Do not use the subscription until the ERROR items are fixed.'
  NODE_STATUS_MESSAGE='Node installation finished with failed checks. Do not attach it to the main panel until the ERROR items are fixed.'
fi

if [[ "$INSTALL_MODE" == "standalone" ]]; then
  SUBSCRIPTION_URL="https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}"
  MIHOMO_SUBSCRIPTION_URL="$MIHOMO_ROUTING_URL"
  printf -v MODE_DETAILS 'FIRST CLIENT: %s\nHAPP / INCY SUBSCRIPTION: %s\nMIHOMO SUBSCRIPTION:      %s\n\n%s' \
    "$CLIENT_EMAIL" "$SUBSCRIPTION_URL" "$MIHOMO_SUBSCRIPTION_URL" "$STANDALONE_STATUS_MESSAGE"
else
  printf -v MODE_DETAILS 'API TOKEN:   %s\n\n%s\nThe local inbound is already created; do not deploy a duplicate on port 443.' "${PANEL_API_TOKEN:-not provided by this 3x-ui version}" "$NODE_STATUS_MESSAGE"
fi

umask 077
{
  printf 'MODE: %s\n' "$INSTALL_MODE"
  printf 'TLS MODE: %s\n' "$TLS_MODE"
  printf '%s: %s\n' "$([[ "$INSTALL_MODE" == "standalone" ]] && echo "VPN NAME" || echo "NODE NAME")" "$VPN_NAME"
  printf 'PANEL URL: https://%s:%s/%s/\n' "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH"
  printf 'LOGIN: %s\nPASSWORD: %s\n' "$PANEL_USERNAME" "$PANEL_PASSWORD"
  printf '%s\n' "$MODE_DETAILS"
  if [[ "$INSTALL_MODE" == "node" ]]; then
    printf '\nNODE CONNECTION — COPY TO THE MAIN 3X-UI PANEL\n'
    printf '%s\n' '---------------------------------------------------------------'
    printf 'Name: %s\n' "$VPN_NAME"
    printf 'Remark: \n'
    printf 'Scheme: https\n'
    printf 'Address: %s\n' "$DOMAIN"
    printf 'Port: %s\n' "$PANEL_PORT"
    printf 'Base Path: /%s/\n' "$PANEL_PATH"
    printf 'Enabled: yes\n'
    printf 'Allow private address: no\n'
    printf 'TLS verification: Verify (default CA)\n'
    printf 'API Token: %s\n' "$PANEL_API_TOKEN"
    printf '%s\n' '---------------------------------------------------------------'
  fi
} > "$RESULT_FILE"
chmod 600 "$RESULT_FILE"
umask 022

if [[ "$CHECK_FAILURES" -ne 0 ]]; then
  printf '\n%b================================================================%b\n' "$red" "$plain"
  printf '%bRESULT: %s CHECK(S) FAILED%b\n' "$red" "$CHECK_FAILURES" "$plain"
  printf '%bFix every line marked ERROR above before using the VPN or subscriptions.%b\n' "$yellow" "$plain"
  printf '%bSaved configuration:%b %s\n%bSaved result:%b        %s\n' "$yellow" "$plain" "$STATE_FILE" "$yellow" "$plain" "$RESULT_FILE"
  printf '%bSuggested solution:%b Review the failed checks, then run: %s\n' "$yellow" "$plain" "$RECOVERY_SCRIPT"
  printf '%bDiagnostics:%b systemctl status x-ui nginx --no-pager; nginx -t; journalctl -u x-ui -n 100 --no-pager\n' "$yellow" "$plain"
  printf '%b================================================================%b\n' "$red" "$plain"
  exit 1
fi

# On success, remove the noisy installation transcript from the visible terminal.
# Credentials and subscription URLs are retained in the protected result file above.
clear || true
printf '%b================================================================%b\n' "$green" "$plain"
printf '%b                 VPN INSTALLATION COMPLETED SUCCESSFULLY%b\n' "$green" "$plain"
printf '%b                     ALL CHECKS PASSED%b\n' "$green" "$plain"
printf '%b================================================================%b\n\n' "$green" "$plain"
printf '%b%s:%b          %s\n' "$blue" "$([[ "$INSTALL_MODE" == "standalone" ]] && echo "VPN" || echo "NODE")" "$plain" "$VPN_NAME"
printf '%bTLS:%b          %s\n\n' "$blue" "$plain" "$([[ "$TLS_MODE" == "production" ]] && echo "Trusted Let's Encrypt certificate" || echo "Test self-signed certificate")"
printf '%bPANEL%b\n' "$cyan" "$plain"
printf '  %bURL:%b      https://%s:%s/%s/\n' "$yellow" "$plain" "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH"
printf '  %bLogin:%b    %s\n' "$yellow" "$plain" "$PANEL_USERNAME"
printf '  %bPassword:%b %s\n\n' "$yellow" "$plain" "$PANEL_PASSWORD"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  printf '%bCLIENT SUBSCRIPTIONS%b\n' "$cyan" "$plain"
  printf '  %bHAPP / INCY:%b %s\n' "$yellow" "$plain" "$SUBSCRIPTION_URL"
  printf '  %bMihomo:%b      %s\n' "$yellow" "$plain" "$MIHOMO_SUBSCRIPTION_URL"
  printf '  %bRouting:%b     HAPP and INCY RoscomVPN routing profiles are included.\n\n' "$yellow" "$plain"
else
  printf '%bNODE CONNECTION — COPY TO THE MAIN 3X-UI PANEL%b\n' "$cyan" "$plain"
  printf '%b---------------------------------------------------------------%b\n' "$yellow" "$plain"
  printf 'Name: %s\n' "$VPN_NAME"
  printf 'Remark: \n'
  printf 'Scheme: https\n'
  printf 'Address: %s\n' "$DOMAIN"
  printf 'Port: %s\n' "$PANEL_PORT"
  printf 'Base Path: /%s/\n' "$PANEL_PATH"
  printf 'Enabled: yes\n'
  printf 'Allow private address: no\n'
  printf 'TLS verification: Verify (default CA)\n'
  printf 'API Token: %s\n' "$PANEL_API_TOKEN"
  printf '%b---------------------------------------------------------------%b\n' "$yellow" "$plain"
  printf '%bIn the main panel:%b Nodes → Add node. Fill in the fields above; leave Remark empty.\n\n' "$cyan" "$plain"
fi
printf '%bVPN inbound:%b VLESS + XHTTP + REALITY on TCP/443\n' "$blue" "$plain"
printf '%bWARP routing:%b %s\n' "$blue" "$plain" "$([[ "$ENABLE_WARP" -eq 1 ]] && echo ENABLED || echo DISABLED)"
printf '%bSaved result:%b %s\n' "$blue" "$plain" "$RESULT_FILE"
printf '%bSaved state:%b  %s\n' "$blue" "$plain" "$STATE_FILE"
if [[ -f /var/run/reboot-required ]]; then
  printf '\n%bREBOOT RECOMMENDED:%b Ubuntu updates require a reboot.\n' "$yellow" "$plain"
fi
printf '\n%bKeep the panel password and subscription URLs private.%b\n' "$yellow" "$plain"
printf '%b================================================================%b\n' "$green" "$plain"
