#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Shared lifecycle and verification functions. No actions on source.

# Audited upstream inputs. Updating any URL requires updating its SHA-256 in the
# same commit after reviewing the upstream diff.
# These constants are consumed by the scripts that source this file.
# shellcheck disable=SC2034
readonly XHTTP_XUI_VERSION='v3.8.5' \
  XHTTP_XUI_INSTALL_SHA256='4e3fe7fe00ef8e904ce6a0e9c36fd8a0c7179fe5e786f23e31801aee84c6347d' \
  XHTTP_ACME_SH_VERSION='3.1.6' \
  XHTTP_ACME_SH_COMMIT='807da6498377ee5e0cf43a78091f46f12dc59a89' \
  XHTTP_ACME_SH_SHA256='ddbe1bcbd1a44a2623a2af167ebdc678669e6e2eb396742f2d1d28e02dc14220' \
  XHTTP_ROUTING_COMMIT='8c141f103a50e3ed6c7034be360291cdeb5685f3' \
  XHTTP_HAPP_SHA256='337156e3601abda728b5133932e46ca74bf363f638bc6b1a2e85954823e4e950' \
  XHTTP_INCY_SHA256='b5f1e4bcac2f68731c83d42444266f7247eff1ced88fb9f6b36227efd3f31096' \
  XHTTP_MIHOMO_SHA256='515f05be855342380fc5291f0e1bdaf43f0ce71a2584e0cf07d087fc2026003c'

xhttp_valid_ipv4() {
  local value="$1" octet
  local -a parts
  IFS='.' read -r -a parts <<<"$value"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for octet in "${parts[@]}"; do
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 1
    ((10#$octet <= 255)) || return 1
  done
}

xhttp_validate_single_dns_ipv4() {
  local expected="$1" value
  local -a addresses=()
  xhttp_valid_ipv4 "$expected" || return 1
  while IFS= read -r value; do
    value="${value//$'\r'/}"
    [[ -z "$value" ]] && continue
    xhttp_valid_ipv4 "$value" || return 1
    addresses+=("$value")
  done
  mapfile -t addresses < <(printf '%s\n' "${addresses[@]}" | sed '/^$/d' | sort -u)
  [[ ${#addresses[@]} -eq 1 && "${addresses[0]}" == "$expected" ]]
}

xhttp_transport_flow() {
  case "$1" in
    vision) printf '%s' 'xtls-rprx-vision' ;;
    xhttp) printf '%s' '' ;;
    *) return 1 ;;
  esac
}

xhttp_transport_label() {
  case "$1" in
    vision) printf '%s' 'VLESS + TCP + XTLS Vision + REALITY' ;;
    xhttp) printf '%s' 'VLESS + XHTTP + REALITY' ;;
    *) return 1 ;;
  esac
}

xhttp_ssh_access_label() {
  case "$1" in
    admin) printf '%s' 'new sudo administrator, SSH key only, direct root login disabled' ;;
    root-key) printf '%s' 'root login by SSH key only; password login disabled' ;;
    existing) printf '%s' 'current SSH policy retained (not recommended)' ;;
    *) return 1 ;;
  esac
}

xhttp_inbound_tag_for() {
  case "$1" in
    vision) printf '%s' 'in-443-vision-reality' ;;
    xhttp) printf '%s' 'in-443-xhttp-reality' ;;
    *) return 1 ;;
  esac
}

xhttp_build_stream_settings() {
  local transport="$1" domain="$2" target="$3" private_key="$4" public_key="$5" short_id="$6"
  local reality
  reality="$(jq -nc --arg d "$domain" --arg target "$target" --arg private "$private_key" \
    --arg public "$public_key" --arg sid "$short_id" '
      {show:false,xver:0,target:$target,privateKey:$private,minClientVer:"",maxClientVer:"",maxTimeDiff:0,
       serverNames:[$d],shortIds:[$sid],settings:{publicKey:$public,fingerprint:"firefox",serverName:"",spiderX:"/"}}
    ')" || return 1
  case "$transport" in
    vision)
      jq -nc --argjson reality "$reality" '
        {network:"tcp",security:"reality",externalProxy:[],realitySettings:$reality,
         tcpSettings:{acceptProxyProtocol:false,header:{type:"none"}}}
      '
      ;;
    xhttp)
      jq -nc --arg d "$domain" --argjson reality "$reality" '
        {network:"xhttp",security:"reality",externalProxy:[],realitySettings:$reality,
         xhttpSettings:{host:$d,path:"/",mode:"auto",xPaddingBytes:"100-1000",xPaddingObfsMode:false,
           noSSEHeader:false,scMaxEachPostBytes:"1000000",scMaxBufferedPosts:30,
           scStreamUpServerSecs:"20-80",headers:{}}}
      '
      ;;
    *) return 1 ;;
  esac
}

xhttp_rebuild_managed_inbound() {
  local transport="$1" domain="$2" target="$3" tag="$4"
  local inbound settings stream private_key public_key short_ids short_id rebuilt_stream sniffing id
  inbound="$(cat)"
  id="$(jq -er '.id | select(type=="number" and .>0 and floor==.)' <<<"$inbound")" || return 1
  settings="$(jq -ce '.settings | if type=="string" then fromjson else . end | select(type=="object")' <<<"$inbound")" || return 1
  stream="$(jq -ce '.streamSettings | if type=="string" then fromjson else . end | select(type=="object")' <<<"$inbound")" || return 1
  private_key="$(jq -er '.realitySettings.privateKey | select(type=="string" and length>0)' <<<"$stream")" || return 1
  public_key="$(jq -er '.realitySettings.settings.publicKey | select(type=="string" and length>0)' <<<"$stream")" || return 1
  short_ids="$(jq -ce '.realitySettings.shortIds | select(type=="array" and length>0 and all(.[]; type=="string" and length>0))' <<<"$stream")" || return 1
  short_id="$(jq -r '.[0]' <<<"$short_ids")"
  rebuilt_stream="$(xhttp_build_stream_settings "$transport" "$domain" "$target" "$private_key" "$public_key" "$short_id")" || return 1
  rebuilt_stream="$(jq -ce --argjson ids "$short_ids" '.realitySettings.shortIds=$ids' <<<"$rebuilt_stream")" || return 1
  sniffing='{"enabled":true,"destOverride":["http","tls","quic"],"metadataOnly":false,"routeOnly":false}'
  jq -ce --argjson id "$id" --arg settings "$settings" --arg stream "$rebuilt_stream" \
    --arg sniffing "$sniffing" --arg tag "$tag" '
      .id=$id | .listen="" | .port=443 | .protocol="vless" | .settings=$settings
      | .streamSettings=$stream | .tag=$tag | .sniffing=$sniffing
    ' <<<"$inbound"
}

xhttp_rotate_node_sync_token() {
  local token_name="${1:-xhttp-node-sync}" response ids id payload token
  [[ "$token_name" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || return 1
  response="$(xhttp_memory_api /panel/api/setting/apiTokens)" || return 1
  ids="$(jq -ce --arg name "$token_name" '
    .obj | if type=="string" then fromjson else . end
    | select(type=="array")
    | map(select(.name==$name and .scope=="node-sync") | .id)
    | select(all(.[]; type=="number" and .>0 and floor==.))
  ' <<<"$response")" || return 1
  while IFS= read -r id; do
    [[ "$id" =~ ^[0-9]+$ ]] || return 1
    payload='{"expectedScope":"node-sync"}'
    xhttp_memory_api "/panel/api/setting/apiTokens/delete/$id" -X POST \
      -H 'Content-Type: application/json' --data-binary "$payload" >/dev/null || return 1
  done < <(jq -r '.[]' <<<"$ids")
  payload="$(jq -nc --arg name "$token_name" '{name:$name,scope:"node-sync",expiresAt:0}')"
  response="$(xhttp_memory_api /panel/api/setting/apiTokens/create -X POST \
    -H 'Content-Type: application/json' --data-binary "$payload")" || return 1
  token="$(jq -er '
    .obj | if type=="string" then fromjson else . end
    | select(.scope=="node-sync" and .enabled==true)
    | .token | select(type=="string" and length>=32)
  ' <<<"$response")" || return 1
  printf '%s' "$token"
}

xhttp_validate_authorized_keys_b64() (
  set -Eeuo pipefail
  local encoded="$1" directory keys line one count=0
  [[ -n "$encoded" && ${#encoded} -le 131072 ]] || return 1
  directory="$(mktemp -d /tmp/xhttp-ssh-key-check.XXXXXXXX)"
  trap 'rm -f "$directory/keys" "$directory/one"; rmdir "$directory"' EXIT
  keys="$directory/keys"; one="$directory/one"
  printf '%s' "$encoded" | base64 -d > "$keys" 2>/dev/null || return 1
  [[ -s "$keys" && "$(stat -c '%s' "$keys")" -le 65536 ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)[[:space:]] ]] \
      || return 1
    printf '%s\n' "$line" > "$one"
    ssh-keygen -l -f "$one" >/dev/null 2>&1 || return 1
    count=$((count + 1))
  done < "$keys"
  (( count > 0 ))
)

xhttp_authorized_key_fingerprints() (
  set -Eeuo pipefail
  local encoded="$1" temporary
  temporary="$(mktemp /tmp/xhttp-ssh-fingerprints.XXXXXXXX)"
  trap 'rm -f "$temporary"' EXIT
  printf '%s' "$encoded" | base64 -d > "$temporary"
  ssh-keygen -l -f "$temporary" | awk '{print $2}' | paste -sd, -
)

xhttp_install_admin_access() {
  local home_dir temporary_sudo
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
  xhttp_validate_authorized_keys_b64 "$ADMIN_KEYS_B64" || return 1
  if getent passwd "$ADMIN_USER" >/dev/null; then
    home_dir="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
    [[ "$home_dir" == "/home/$ADMIN_USER" ]] || return 1
  else
    useradd --create-home --user-group --shell /bin/bash "$ADMIN_USER"
  fi
  home_dir="/home/$ADMIN_USER"
  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$home_dir/.ssh"
  printf '%s' "$ADMIN_KEYS_B64" | base64 -d > "$home_dir/.ssh/authorized_keys.new"
  chown "$ADMIN_USER:$ADMIN_USER" "$home_dir/.ssh/authorized_keys.new"
  chmod 600 "$home_dir/.ssh/authorized_keys.new"
  mv -f "$home_dir/.ssh/authorized_keys.new" "$home_dir/.ssh/authorized_keys"
  usermod -aG sudo "$ADMIN_USER"
  usermod -L "$ADMIN_USER"
  temporary_sudo="$(mktemp /etc/sudoers.d/90-xhttp-vps-admin.XXXXXXXX)"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$ADMIN_USER" > "$temporary_sudo"
  chmod 440 "$temporary_sudo"
  visudo -cf "$temporary_sudo" >/dev/null
  mv -f "$temporary_sudo" /etc/sudoers.d/90-xhttp-vps-admin
  sudo -u "$ADMIN_USER" sudo -n true
}

xhttp_install_root_key_access() {
  xhttp_validate_authorized_keys_b64 "$ADMIN_KEYS_B64" || return 1
  install -d -m 700 -o root -g root /root/.ssh
  printf '%s' "$ADMIN_KEYS_B64" | base64 -d > /root/.ssh/authorized_keys.new
  chown root:root /root/.ssh/authorized_keys.new
  chmod 600 /root/.ssh/authorized_keys.new
  mv -f /root/.ssh/authorized_keys.new /root/.ssh/authorized_keys
}

xhttp_install_ssh_access() {
  case "${SSH_ACCESS_MODE:-admin}" in
    admin) xhttp_install_admin_access ;;
    root-key) xhttp_install_root_key_access ;;
    existing) return 0 ;;
    *) return 1 ;;
  esac
}

xhttp_render_sshd_hardening() {
  local mode="$1" login_user="$2" permit_root allow_user
  case "$mode" in
    admin)
      [[ "$login_user" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$login_user" != root ]] || return 1
      permit_root=no
      allow_user="$login_user"
      ;;
    root-key)
      [[ "$login_user" == root ]] || return 1
      permit_root=prohibit-password
      allow_user=root
      ;;
    *) return 1 ;;
  esac
  cat <<EOF
# Managed by xhttp-vps-setup. Keep local TCP forwarding for the private panel.
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
PermitEmptyPasswords no
PermitRootLogin ${permit_root}
AllowUsers ${allow_user}
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding local
GatewayPorts no
PermitTunnel no
PermitUserEnvironment no
EOF
}

xhttp_harden_sshd() {
  local temporary host_name root_config login_config allow_user target previous had_previous=0
  case "${SSH_ACCESS_MODE:-admin}" in
    admin) allow_user="$ADMIN_USER" ;;
    root-key)
      [[ "$ADMIN_USER" == root ]] || return 1
      allow_user=root
      ;;
    *) return 1 ;;
  esac
  target=/etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf
  previous="$(mktemp /etc/ssh/sshd_config.d/xhttp-vps-previous.XXXXXXXX)"
  if [[ -e "$target" ]]; then
    cp -a "$target" "$previous"
    had_previous=1
  fi
  temporary="$(mktemp /etc/ssh/sshd_config.d/00-xhttp-vps-hardening.conf.XXXXXXXX)"
  if ! xhttp_render_sshd_hardening "${SSH_ACCESS_MODE:-admin}" "$ADMIN_USER" > "$temporary"; then
    rm -f "$temporary" "$previous"
    return 1
  fi
  chmod 600 "$temporary"
  mv -f "$temporary" "$target"
  if ! sshd -t; then
    rm -f "$target"
    if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
    return 1
  fi
  host_name="$(hostname -f 2>/dev/null || hostname)"
  root_config="$(sshd -T -C "user=root,host=${host_name},addr=127.0.0.1")"
  login_config="$(sshd -T -C "user=${allow_user},host=${host_name},addr=127.0.0.1")"
  if [[ "${SSH_ACCESS_MODE:-admin}" == admin ]]; then
    grep -qx 'permitrootlogin no' <<<"$root_config" || {
      rm -f "$target"
      if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
      return 1
    }
  else
    grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$root_config" || {
      rm -f "$target"
      if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
      return 1
    }
  fi
  if ! grep -qx 'passwordauthentication no' <<<"$login_config" \
    || ! grep -qx 'kbdinteractiveauthentication no' <<<"$login_config" \
    || ! grep -qx 'authenticationmethods publickey' <<<"$login_config" \
    || ! grep -Eq "^allowusers( .*)? ${allow_user}( .*)?$|^allowusers ${allow_user}$" <<<"$login_config"; then
    rm -f "$target"
    if [[ "$had_previous" == 1 ]]; then mv -f "$previous" "$target"; else rm -f "$previous"; fi
    return 1
  fi
  rm -f "$previous"
  systemctl reload ssh
  passwd -l root >/dev/null
}

xhttp_verify_ssh_access() {
  local host_name config key_path
  host_name="$(hostname -f 2>/dev/null || hostname)"
  case "${SSH_ACCESS_MODE:-admin}" in
    admin)
      getent passwd "$ADMIN_USER" >/dev/null || return 1
      sudo -u "$ADMIN_USER" sudo -n true || return 1
      key_path="/home/${ADMIN_USER}/.ssh/authorized_keys"
      config="$(sshd -T -C "user=${ADMIN_USER},host=${host_name},addr=127.0.0.1")" || return 1
      grep -qx 'permitrootlogin no' < <(sshd -T -C "user=root,host=${host_name},addr=127.0.0.1") || return 1
      ;;
    root-key)
      [[ "$ADMIN_USER" == root ]] || return 1
      key_path=/root/.ssh/authorized_keys
      config="$(sshd -T -C "user=root,host=${host_name},addr=127.0.0.1")" || return 1
      grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$config" || return 1
      ;;
    *) return 1 ;;
  esac
  [[ -s "$key_path" && "$(stat -c '%a' "$key_path")" == 600 ]] || return 1
  [[ "$(passwd -S root | awk '{print $2}')" == L ]] || return 1
  grep -qx 'passwordauthentication no' <<<"$config" \
    && grep -qx 'kbdinteractiveauthentication no' <<<"$config" \
    && grep -qx 'authenticationmethods publickey' <<<"$config"
}

xhttp_install_fail2ban_sshd() {
  cat > /etc/fail2ban/jail.d/xhttp-vps-sshd.local <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
bantime.increment = true
EOF
  systemctl enable --now fail2ban
  fail2ban-client reload >/dev/null
  fail2ban-client status sshd >/dev/null
}

xhttp_render_maintenance_timer() {
  cat <<EOF
[Unit]
Description=Weekly Ubuntu maintenance schedule for xhttp-vps

[Timer]
OnCalendar=Sun *-*-* 05:00:00 ${MAINTENANCE_TIMEZONE}
AccuracySec=1m
Persistent=false
Unit=xhttp-vps-maintenance.service

[Install]
WantedBy=timers.target
EOF
}

xhttp_install_maintenance() {
  local temporary
  [[ "$MAINTENANCE_TIMEZONE" =~ ^([A-Za-z0-9_+-]+/)*[A-Za-z0-9_+-]+$ ]] || return 1
  [[ -f "/usr/share/zoneinfo/$MAINTENANCE_TIMEZONE" ]] || return 1
  cat > /usr/local/sbin/xhttp-vps-maintenance <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
exec 9>/run/lock/xhttp-vps-maintenance.lock
flock -w 1800 9
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
apt-get -o DPkg::Lock::Timeout=1800 update
apt-get -o DPkg::Lock::Timeout=1800 -y -o Dpkg::Options::="--force-confold" upgrade
apt-get check
[[ -z "$(dpkg --audit)" ]]
nginx -t
for service in ssh x-ui nginx; do
  systemctl is-active --quiet "$service"
done
if [[ -f /var/run/reboot-required ]]; then
  logger -t xhttp-vps-maintenance 'Updates completed; reboot-required is present. Scheduling reboot.'
  systemctl --no-block reboot
else
  logger -t xhttp-vps-maintenance 'Updates completed; reboot is not required.'
fi
EOF
  chmod 700 /usr/local/sbin/xhttp-vps-maintenance
  cat > /etc/systemd/system/xhttp-vps-maintenance.service <<'EOF'
[Unit]
Description=Install weekly Ubuntu updates and reboot only when required
Wants=network-online.target
After=network-online.target apt-daily.service apt-daily-upgrade.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xhttp-vps-maintenance
Nice=10
IOSchedulingClass=idle
UMask=0027
TimeoutStartSec=2h
EOF
  temporary="$(mktemp /etc/systemd/system/xhttp-vps-maintenance.timer.XXXXXXXX)"
  xhttp_render_maintenance_timer > "$temporary"
  chmod 644 "$temporary"
  mv -f "$temporary" /etc/systemd/system/xhttp-vps-maintenance.timer
  systemd-analyze calendar "Sun *-*-* 05:00:00 ${MAINTENANCE_TIMEZONE}" >/dev/null
  systemctl daemon-reload
  systemctl enable --now xhttp-vps-maintenance.timer
}

xhttp_download_verified() {
  local url="$1" expected="$2" output="$3" actual
  curl -fL --retry 3 --connect-timeout 10 --max-time 120 "$url" -o "$output" || {
    rm -f -- "$output"
    return 1
  }
  actual="$(sha256sum "$output" | awk '{print $1}')"
  if [[ "$actual" != "$expected" ]]; then
    printf 'Checksum mismatch for %s: expected %s, received %s\n' "$url" "$expected" "$actual" >&2
    rm -f -- "$output"
    return 1
  fi
}

xhttp_fetch_verified_text() {
  local url="$1" expected="$2" temporary
  temporary="$(mktemp /tmp/xhttp-download.XXXXXXXX)"
  if ! xhttp_download_verified "$url" "$expected" "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  cat -- "$temporary"
  rm -f -- "$temporary"
}

xhttp_create_api_header_file() {
  local token="$1" file
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || return 1
  file="$(mktemp /root/xhttp-api-headers.XXXXXXXX)"
  chmod 600 "$file"
  printf 'Authorization: Bearer %s\nX-Requested-With: XMLHttpRequest\n' "$token" > "$file"
  printf '%s' "$file"
}

xhttp_render_acme_nginx() {
cat <<EOF
server {
    listen 80;
    server_name ${DOMAIN};
    server_tokens off;
    access_log off;
    root /var/www/3xui-cover;
    location ^~ /.well-known/acme-challenge/ {
        default_type text/plain;
        try_files \$uri =404;
    }
    location / { return 301 https://${DOMAIN}\$request_uri; }
}
EOF
}

xhttp_install_acme_nginx() (
  set -Eeuo pipefail
  local staging target=/etc/nginx/sites-available/3xui-self-steal.conf
  local link=/etc/nginx/sites-enabled/3xui-self-steal.conf
  staging="$(mktemp -d /etc/nginx/xhttp-acme-config.XXXXXXXX)"
  trap 'rm -f "$staging/new" "$staging/previous" "$staging/link"; rmdir "$staging"' EXIT
  [[ ! -d "$target" && ! -d "$link" ]] || return 1
  if [[ -e "$target" || -L "$target" ]]; then cp -a "$target" "$staging/previous"; fi
  if [[ -e "$link" || -L "$link" ]]; then cp -a "$link" "$staging/link"; fi
  xhttp_render_acme_nginx > "$staging/new"
  chmod 644 "$staging/new"
  mv -T "$staging/new" "$target"
  ln -sfn "$target" "$link"
  if ! nginx -t; then
    rm -f "$target" "$link"
    if [[ -e "$staging/previous" || -L "$staging/previous" ]]; then mv -T "$staging/previous" "$target"; fi
    if [[ -e "$staging/link" || -L "$staging/link" ]]; then mv -T "$staging/link" "$link"; fi
    return 1
  fi
)

xhttp_render_nginx_http2() {
  local version
  version="${XHTTP_NGINX_VERSION_OVERRIDE:-$(nginx -v 2>&1 | sed -n 's#^nginx version: nginx/\([0-9][0-9.]*\).*#\1#p')}"
  [[ -n "$version" ]] || return 1
  if [[ "$(printf '%s\n' 1.25.1 "$version" | sort -V | head -n 1)" == 1.25.1 ]]; then
    printf '    listen 127.0.0.1:%s ssl;\n    http2 on;\n' "$FALLBACK_PORT"
  else
    printf '    listen 127.0.0.1:%s ssl http2;\n' "$FALLBACK_PORT"
  fi
}

xhttp_install_nginx() (
  set -Eeuo pipefail
  local staging target=/etc/nginx/sites-available/3xui-self-steal.conf
  local link=/etc/nginx/sites-enabled/3xui-self-steal.conf
  staging="$(mktemp -d /etc/nginx/xhttp-config.XXXXXXXX)"
  trap 'rm -f "$staging/new" "$staging/previous" "$staging/link"; rmdir "$staging"' EXIT
  [[ ! -d "$target" && ! -d "$link" ]] || return 1
  if [[ -e "$target" || -L "$target" ]]; then cp -a "$target" "$staging/previous"; fi
  if [[ -e "$link" || -L "$link" ]]; then cp -a "$link" "$staging/link"; fi
  xhttp_render_nginx > "$staging/new"
  chmod 644 "$staging/new"
  mv -T "$staging/new" "$target"
  ln -sfn "$target" "$link"
  if ! nginx -t; then
    rm -f "$target" "$link"
    if [[ -e "$staging/previous" || -L "$staging/previous" ]]; then mv -T "$staging/previous" "$target"; fi
    if [[ -e "$staging/link" || -L "$staging/link" ]]; then mv -T "$staging/link" "$link"; fi
    return 1
  fi
)

xhttp_render_nginx() {
xhttp_render_acme_nginx
cat <<EOF
server {
$(xhttp_render_nginx_http2)
    server_name ${DOMAIN};
    server_tokens off;
    access_log off;
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
}

xhttp_probe_foreign_sni() {
  local response
  response="$(
    printf 'GET / HTTP/1.1\r\nHost: unrelated.invalid\r\nConnection: close\r\n\r\n' \
      | timeout 12 openssl s_client -quiet -connect 127.0.0.1:443 \
          -servername unrelated.invalid -alpn http/1.1 2>/dev/null || true
  )"
  grep -Fq "$DOMAIN" <<<"$response" \
    && ! grep -Eiq '3x-ui|x-ui|panel/api|<title>.*login' <<<"$response"
}

xhttp_probe_no_sni() {
  local response
  response="$(
    printf 'GET / HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n' "$DOMAIN" \
      | timeout 12 openssl s_client -quiet -connect 127.0.0.1:443 \
          -noservername -alpn http/1.1 2>/dev/null || true
  )"
  grep -Fq "$DOMAIN" <<<"$response" \
    && ! grep -Eiq '3x-ui|x-ui|panel/api|<title>.*login' <<<"$response"
}

xhttp_probe_h2_alpn() {
  local response
  response="$(
    printf '' | timeout 12 openssl s_client -connect 127.0.0.1:443 \
      -servername "$DOMAIN" -alpn 'h2,http/1.1' 2>&1 || true
  )"
  grep -Fq 'ALPN protocol: h2' <<<"$response"
}

random_hex() { od -An -N "$1" -tx1 /dev/urandom | tr -d ' \n'; }
port_busy() { ss -H -ltn "sport = :$1" | grep -q .; }
random_port() {
  local p attempt
  for ((attempt=0; attempt<100; attempt++)); do
    p=$((20000 + 0x$(random_hex 2) % 40000))
    [[ "$p" != 40000 ]] || continue
    port_busy "$p" || { printf '%s' "$p"; return; }
  done
  return 1
}

xhttp_warp_config() {
  jq -ce --argjson w "$1" '
    def catchall:
      del(.type,.ruleTag,.outboundTag,.balancerTag)
      | if .network=="tcp,udp" or .network=="udp,tcp" then del(.network) else . end
      | length==0;
    .outbounds=((.outbounds//[])|map(select(.tag!="warp")))+[$w]
    | .routing.domainStrategy="IPOnDemand"
    | ((.routing.rules//[]) | map(select(
        .ruleTag!="xhttp-vps-warp-ru-domain" and .ruleTag!="xhttp-vps-warp-ru-ip"))) as $rules
    | [$rules | to_entries[] | select(.value|catchall) | .key] as $defaults
    | if ($defaults|length)>1 or (($defaults|length)==1 and $defaults[0]!=($rules|length)-1)
      then error("Catch-all must be the final rule; review routing before adding WARP") else . end
    | ($defaults[0] // ($rules|length)) as $at
    | if ($defaults|length)==1 and
        ([.outbounds[] | select(.tag==$rules[$at].outboundTag and .protocol=="freedom")]|length)!=1
      then error("Only a terminal direct/freedom catch-all may follow WARP; review the terminal policy") else . end
    | [.outbounds[] | select(.protocol=="blackhole") | .tag] as $blocked
    | (.api.tag // "api") as $api
    | def protected_rule:
        .outboundTag as $tag
        | ($tag==$api or ($blocked|index($tag))!=null);
      .routing.rules = ($rules | map(select(protected_rule))) + [
        {type:"field",domain:["domain:ru","domain:su","domain:xn--p1ai","geosite:category-ru"],outboundTag:"warp",network:"tcp,udp",ruleTag:"xhttp-vps-warp-ru-domain"},
        {type:"field",ip:["geoip:ru"],outboundTag:"warp",network:"tcp,udp",ruleTag:"xhttp-vps-warp-ru-ip"}
      ] + ($rules | map(select(protected_rule|not)))
  '
}

# Validate regional datasets with the installed core before changing panel state.
xhttp_validate_warp_routes() (
  set -Eeuo pipefail
  umask 077
  local check_dir
  local -a binaries=(/usr/local/x-ui/bin/xray-linux-*)
  [[ -x "${binaries[0]}" ]] || return 1
  check_dir="$(mktemp -d /root/xhttp-route-check.XXXXXXXX)"
  trap 'rm -f "$check_dir/config.json" "$check_dir/log"; rmdir "$check_dir"' EXIT
  jq -ce '{outbounds:[{tag:"direct",protocol:"freedom"}],routing:{domainStrategy:.routing.domainStrategy,rules:[.routing.rules[]|select(.ruleTag=="xhttp-vps-warp-ru-domain" or .ruleTag=="xhttp-vps-warp-ru-ip")|.outboundTag="direct"]}}' > "$check_dir/config.json"
  if ! XRAY_LOCATION_ASSET=/usr/local/x-ui/bin "${binaries[0]}" run -test -config "$check_dir/config.json" > "$check_dir/log" 2>&1; then
    printf '%s\n' 'Russian routing validation failed; check geosite:category-ru and geoip:ru. No panel settings changed.' >&2
    cat "$check_dir/log" >&2
    return 1
  fi
)

xhttp_managed_paths() {
  printf '%s\n' /etc/systemd/system/x-ui.service /usr/lib/systemd/system/x-ui.service \
    /usr/bin/x-ui /etc/default/x-ui /usr/local/x-ui /etc/x-ui /var/log/x-ui \
    /etc/nginx/sites-available/3xui-self-steal.conf /etc/nginx/sites-enabled/3xui-self-steal.conf \
    /etc/nginx/sites-enabled/default /var/www/3xui-cover \
    /etc/modules-load.d/bbr.conf /etc/sysctl.d/99-xhttp-vps-network.conf \
    /etc/apt/apt.conf.d/52xhttp-vps-auto-upgrades /etc/apt/apt.conf.d/53xhttp-vps-unattended-upgrades \
    /etc/fail2ban/jail.d/xhttp-vps-sshd.local \
    /usr/local/sbin/xhttp-vps-maintenance /etc/systemd/system/xhttp-vps-maintenance.service \
    /etc/systemd/system/xhttp-vps-maintenance.timer \
    "/root/cert/$DOMAIN" "$RESULT_FILE"
}

xhttp_validate_ssh_access_state() {
  local ssh_mode
  ssh_mode="${SSH_ACCESS_MODE:-}"
  if [[ -z "$ssh_mode" ]]; then
    if [[ "${SSH_HARDENING:-0}" == 1 ]]; then ssh_mode='admin'; else ssh_mode='existing'; fi
  fi
  case "$ssh_mode" in
    admin)
      [[ "${SSH_HARDENING:-0}" == 1 ]] || return 1
      [[ "${ADMIN_USER:-}" =~ ^[a-z_][a-z0-9_-]{0,30}$ && "$ADMIN_USER" != root ]] || return 1
      xhttp_validate_authorized_keys_b64 "${ADMIN_KEYS_B64:-}" || return 1
      ;;
    root-key)
      [[ "${SSH_HARDENING:-0}" == 1 && "${ADMIN_USER:-}" == root ]] || return 1
      xhttp_validate_authorized_keys_b64 "${ADMIN_KEYS_B64:-}" || return 1
      ;;
    existing)
      [[ "${SSH_HARDENING:-0}" == 0 ]] || return 1
      ;;
    *) return 1 ;;
  esac
}

xhttp_validate_state() {
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]] || return 1
  [[ "$RESULT_FILE" =~ ^/root/xhttp-vps-result-[A-Za-z0-9_-]+\.txt$ ]] || return 1
  [[ "${MANAGED_BACKUP:-}" =~ ^/root/xhttp-managed\.[A-Za-z0-9]+$ ]] || return 1
  [[ -d "$MANAGED_BACKUP" && ! -L "$MANAGED_BACKUP" ]] || return 1
  case "${TRANSPORT:-xhttp}" in vision|xhttp) ;; *) return 1 ;; esac
  xhttp_validate_ssh_access_state
}

xhttp_record_ownership() (
  set -e
  umask 077
  xhttp_validate_state || return 1
  local path index=0
  # Create the journal only once. A failed initial snapshot is never trusted.
  [[ ! -e "$MANAGED_BACKUP/ready" ]] || return 0
  : > "$MANAGED_BACKUP/paths.new"
  while IFS= read -r path; do
    index=$((index+1))
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a -- "$path" "$MANAGED_BACKUP/original-$index"
    fi
    printf '%s\t%s\n' "$index" "$path" >> "$MANAGED_BACKUP/paths.new"
  done < <(xhttp_managed_paths)
  mv "$MANAGED_BACKUP/paths.new" "$MANAGED_BACKUP/paths"
  touch "$MANAGED_BACKUP/ready"
)

xhttp_restore_owned_files() (
  set -e
  umask 077
  xhttp_validate_state || return 1
  [[ -f "$MANAGED_BACKUP/ready" ]] || return 1
  local index path current_dir
  # Validate the entire journal against the exact allowlist before any moving.
  diff -u <(xhttp_managed_paths) <(cut -f2- "$MANAGED_BACKUP/paths") >/dev/null || return 1
  awk -F '\t' '$1!=NR {exit 1}' "$MANAGED_BACKUP/paths" || return 1
  current_dir="$(mktemp -d "$MANAGED_BACKUP/removed.XXXXXXXX")"
  while IFS=$'\t' read -r index path; do
    [[ "$index" =~ ^[0-9]+$ ]] || return 1
    if [[ -e "$path" || -L "$path" ]]; then
      mv -- "$path" "$current_dir/$index"
    fi
    if [[ -e "$MANAGED_BACKUP/original-$index" || -L "$MANAGED_BACKUP/original-$index" ]]; then
      mkdir -p -- "$(dirname "$path")"
      cp -a -- "$MANAGED_BACKUP/original-$index" "$path"
    fi
  done < "$MANAGED_BACKUP/paths"
  printf 'Removed files were archived in %s; original files restored.\n' "$current_dir"
)

xhttp_probe_config() {
  local port="$1"
  jq -ce --argjson port "$port" '
    def decode: if type=="string" then fromjson else . end;
    (.streamSettings|decode) as $s | (.settings|decode) as $v
    | [$v.clients[]? | select(.enable==true and ((.expiryTime//0)<=0 or .expiryTime>(now*1000)))] as $clients
    | if .enable!=true or (["xhttp","tcp","raw"]|index($s.network))==null or $s.security!="reality" or ($clients|length)==0
      then error("No enabled supported REALITY client available for a traffic probe") else . end
    | if $s.network=="xhttp" and (($clients[0].flow//"")!="")
      then error("XHTTP client flow must be empty")
      elif ($s.network=="tcp" or $s.network=="raw") and (($clients[0].flow//"")!="xtls-rprx-vision")
      then error("TCP/RAW client must use xtls-rprx-vision") else . end
    | {log:{loglevel:"warning"},
       inbounds:[{listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth",udp:false}}],
       outbounds:[{tag:"probe",protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:.port,
         users:[{id:$clients[0].id,encryption:($v.encryption//"none"),flow:($clients[0].flow//"")}]}]},
         streamSettings:({network:$s.network,security:"reality",
           realitySettings:{serverName:$s.realitySettings.serverNames[0],
             fingerprint:($s.realitySettings.settings.fingerprint//"chrome"),
             password:$s.realitySettings.settings.publicKey,shortId:$s.realitySettings.shortIds[0]}}
           + if $s.network=="xhttp" then {xhttpSettings:$s.xhttpSettings}
             else {tcpSettings:($s.tcpSettings//{header:{type:"none"}})} end)}]}
  '
}

xhttp_run_probe() (
  set -Eeuo pipefail
  umask 077
  local config="$1" expected="$2" probe_dir probe_pid='' port result attempt
  probe_dir="$(mktemp -d /root/xhttp-probe.XXXXXXXX)"
  trap 'if [[ -n "$probe_pid" ]]; then kill "$probe_pid" 2>/dev/null || true; wait "$probe_pid" 2>/dev/null || true; fi; rm -f "$probe_dir/config.json" "$probe_dir/log"; rmdir "$probe_dir"' EXIT
  printf '%s\n' "$config" > "$probe_dir/config.json"
  "$XRAY_BINARY" run -test -config "$probe_dir/config.json" > "$probe_dir/log" 2>&1
  "$XRAY_BINARY" run -config "$probe_dir/config.json" > "$probe_dir/log" 2>&1 &
  probe_pid=$!
  port="$(jq -r '.inbounds[0].port' <<<"$config")"
  for ((attempt=0; attempt<20; attempt++)); do
    kill -0 "$probe_pid" 2>/dev/null || return 1
    if port_busy "$port"; then break; fi
    sleep 0.2
  done
  # Disable environment proxy overrides and fail if the response is not a trace.
  result="$(curl --noproxy '' --proxy "socks5h://127.0.0.1:$port" -fsS \
    --connect-timeout 10 --max-time 30 https://www.cloudflare.com/cdn-cgi/trace)"
  kill -0 "$probe_pid" 2>/dev/null
  grep -Eq '^ip=.+' <<<"$result"
  if [[ "$expected" == warp ]]; then grep -Eq '^warp=(on|plus)$' <<<"$result"; fi
)

xhttp_verify_traffic() {
  local response inbound config port test_mode="${1:-all}"
  local -a binaries
  mapfile -t binaries < <(find /usr/local/x-ui/bin -maxdepth 1 -type f -name 'xray*' -executable)
  [[ ${#binaries[@]} == 1 ]] || return 1
  XRAY_BINARY="${binaries[0]}"
  port="$(random_port)" || return 1
  export XRAY_BINARY
  export -f xhttp_run_probe port_busy
  if [[ "$test_mode" != warp ]]; then
  response="$(xhttp_memory_api /panel/api/inbounds/list)" || return 1
  inbound="$(jq -ce --arg tag "${INBOUND_TAG:-in-443-xhttp-reality}" '.obj | if type=="string" then fromjson else . end | map(select(.tag==$tag)) | if length==1 then .[0] else error("Missing managed inbound") end' <<<"$response")" || return 1
  config="$(xhttp_probe_config "$port" <<<"$inbound")" || return 1
  # Invoke in a new Bash so callers may test failure without suppressing errexit.
  bash -c 'xhttp_run_probe "$(cat)" direct' <<<"$config" || return 1
  fi
  if [[ "${ENABLE_WARP:-0}" == 1 ]]; then
    response="$(xhttp_memory_api /panel/api/xray/ -X POST)" || return 1
    config="$(jq -ce --argjson p "$port" '
      def decode: if type=="string" then fromjson else . end;
      .obj|decode|.xraySetting|decode
      | [.outbounds[]|select(.tag=="warp")] as $w
      | if ($w|length)!=1 then error("Missing WARP outbound") else . end
      | {log:{loglevel:"warning"},inbounds:[{listen:"127.0.0.1",port:$p,protocol:"socks",settings:{auth:"noauth"}}],outbounds:$w}
    ' <<<"$response")" || return 1
    bash -c 'xhttp_run_probe "$(cat)" warp' <<<"$config" || return 1
  fi
}
