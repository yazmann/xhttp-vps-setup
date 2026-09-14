#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Shared lifecycle and verification functions. No actions on source.

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
cat <<EOF
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
    "/root/cert/$DOMAIN" "$RESULT_FILE"
}

xhttp_validate_state() {
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]] || return 1
  [[ "$RESULT_FILE" =~ ^/root/xhttp-vps-result-[A-Za-z0-9_-]+\.txt$ ]] || return 1
  [[ "${MANAGED_BACKUP:-}" =~ ^/root/xhttp-managed\.[A-Za-z0-9]+$ ]] || return 1
  [[ -d "$MANAGED_BACKUP" && ! -L "$MANAGED_BACKUP" ]] || return 1
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
    | if .enable!=true or $s.network!="xhttp" or $s.security!="reality" or ($clients|length)==0
      then error("No enabled XHTTP REALITY client available for a traffic probe") else . end
    | {log:{loglevel:"warning"},
       inbounds:[{listen:"127.0.0.1",port:$port,protocol:"socks",settings:{auth:"noauth",udp:false}}],
       outbounds:[{tag:"probe",protocol:"vless",settings:{vnext:[{address:"127.0.0.1",port:.port,
         users:[{id:$clients[0].id,encryption:($v.encryption//"none"),flow:($clients[0].flow//"")}]}]},
         streamSettings:{network:"xhttp",security:"reality",xhttpSettings:$s.xhttpSettings,
           realitySettings:{serverName:$s.realitySettings.serverNames[0],
             fingerprint:($s.realitySettings.settings.fingerprint//"chrome"),
             password:$s.realitySettings.settings.publicKey,shortId:$s.realitySettings.shortIds[0]}}}]}
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
  inbound="$(jq -ce '.obj | if type=="string" then fromjson else . end | map(select(.tag=="in-443-xhttp-reality")) | if length==1 then .[0] else error("Missing managed inbound") end' <<<"$response")" || return 1
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
