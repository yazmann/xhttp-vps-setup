#!/usr/bin/env bash
set -Eeuo pipefail

green='\033[1;32m'; yellow='\033[1;33m'; red='\033[1;31m'; cyan='\033[1;36m'; blue='\033[1;34m'; plain='\033[0m'
CURRENT_STEP='repair startup'
die() {
  local reason="$1" solution="${2:-Fix the reason above, then run: /root/finish-xhttp-vps.sh}"
  printf '\n%b================================================================%b\n' "$red" "$plain" >&2
  printf '%bREPAIR STOPPED%b\n' "$red" "$plain" >&2
  printf '%bReason:%b %s\n%bCurrent step:%b %s\n' "$red" "$plain" "$reason" "$yellow" "$plain" "$CURRENT_STEP" >&2
  printf '%bSuggested solution:%b %s\n' "$yellow" "$plain" "$solution" >&2
  printf '%b================================================================%b\n' "$red" "$plain" >&2
  exit 1
}
unexpected_error() {
  local exit_code="$1" line="$2"
  printf '\n%bUNEXPECTED REPAIR ERROR:%b step "%s", line %s, exit code %s.\n' "$red" "$plain" "$CURRENT_STEP" "$line" "$exit_code" >&2
  printf '%bSuggested solution:%b Fix the cause, then run: /root/finish-xhttp-vps.sh\n' "$yellow" "$plain" >&2
}
trap 'unexpected_error "$?" "$LINENO"' ERR
[[ ${EUID} -eq 0 ]] || die "Run as root."
mapfile -t STATE_FILES < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
[[ ${#STATE_FILES[@]} -eq 1 ]] || die "Expected exactly one 3x-ui installer state file in /root; found ${#STATE_FILES[@]}."
# shellcheck disable=SC1090
source "${STATE_FILES[0]}"
: "${SUB_PATH:?State file does not contain SUB_PATH}"
: "${INSTALL_MODE:=node}"
: "${TLS_MODE:=production}"
: "${INSTANCE_NAME:=${NODE_NAME:-VPN}}"
: "${VPN_NAME:=$INSTANCE_NAME}"
STATE_PANEL_API_TOKEN="${PANEL_API_TOKEN:-}"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  : "${SUB_JSON_PATH:=json-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n')}"
  : "${SUB_CLASH_PATH:=mihomo-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n')}"
  : "${MIHOMO_ROUTING_PATH:=mihomo-routing-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n').yaml}"
fi
if [[ -r /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  PANEL_USERNAME="${XUI_USERNAME:-$PANEL_USERNAME}"
  PANEL_PASSWORD="${XUI_PASSWORD:-$PANEL_PASSWORD}"
  PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
  PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
  PANEL_API_TOKEN="${STATE_PANEL_API_TOKEN:-${XUI_API_TOKEN:-${PANEL_API_TOKEN:-}}}"
  PANEL_PATH="${PANEL_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}"
fi
for cmd in curl jq wg; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
[[ -n "${PANEL_API_TOKEN:-}" ]] || die "State/install-result does not contain the 3x-ui API token."

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

configure_warp_swap() {
  local memory_kib free_kib
  memory_kib="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
  if ! [[ "$memory_kib" =~ ^[0-9]+$ ]] || (( memory_kib > 1100000 )); then
    return 0
  fi
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    printf '%b[STEP]%b Keeping existing swap for low-memory WARP VPS\n' "$cyan" "$plain"
    return 0
  fi
  if [[ -e /swapfile ]]; then
    printf '%bWARNING:%b Low-memory WARP VPS has /swapfile, but it is not active. The repair script will not modify an existing file.\n' "$yellow" "$plain" >&2
    return 0
  fi
  free_kib="$(df -Pk / | awk 'NR==2 {print $4}')"
  if ! [[ "$free_kib" =~ ^[0-9]+$ ]] || (( free_kib < 1310720 )); then
    printf '%bWARNING:%b Low-memory WARP VPS has insufficient free disk space for the required 1 GiB swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  printf '%b[STEP]%b Adding 1 GiB swap for low-memory WARP VPS\n' "$cyan" "$plain"
  if ! fallocate -l 1G /swapfile; then
    printf '%bWARNING:%b Could not allocate /swapfile; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  chmod 600 /swapfile
  if ! mkswap /swapfile >/dev/null; then
    rm -f /swapfile
    printf '%bWARNING:%b Could not format /swapfile; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  if ! swapon /swapfile; then
    rm -f /swapfile
    printf '%bWARNING:%b Could not enable /swapfile; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  if ! printf '%s\n' '/swapfile none swap sw 0 0' >> /etc/fstab; then
    swapoff /swapfile >/dev/null 2>&1 || true
    rm -f /swapfile
    printf '%bWARNING:%b Could not persist /swapfile in /etc/fstab; continuing without managed swap.\n' "$yellow" "$plain" >&2
    return 0
  fi
  printf '\nSWAP_CREATED_BY_SCRIPT=1\n' >> "${STATE_FILES[0]}"
}

systemctl restart x-ui
READY=0; R=""
for _ in $(seq 1 15); do
  R="$(curl -kfsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
if [[ "$READY" -eq 0 && "$R" == *'error: 401'* ]]; then
  printf '%bAPI token required:%b the saved token was rejected by the panel. In the panel open Settings → API Tokens, create a token named xhttp-recovery, then paste it below.\n' "$yellow" "$plain" >&2
  read -r -s -p "New API token (input is hidden): " PANEL_API_TOKEN
  printf '\n' >&2
  if [[ -n "$PANEL_API_TOKEN" ]]; then
    API_AUTH=(-H "Authorization: Bearer ${PANEL_API_TOKEN}" -H 'X-Requested-With: XMLHttpRequest')
    printf '\nPANEL_API_TOKEN=%q\n' "$PANEL_API_TOKEN" >> "${STATE_FILES[0]}"
    READY=0
    for _ in $(seq 1 15); do
      R="$(curl -kfsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
      if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
      sleep 1
    done
  fi
fi
[[ "$READY" -eq 1 ]] || { systemctl status x-ui --no-pager || true; /usr/local/x-ui/x-ui setting -show true 2>/dev/null || true; die "Private bearer API failed after 15 attempts. Last response: ${R:-<empty>}"; }

CURRENT_STEP='configuring subscription service'
printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all")"
jq -e '.success==true and .obj!=null' <<<"$R" >/dev/null || die "Could not read panel settings: $R"
S="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$R")"
jq -e 'type=="object"' <<<"$S" >/dev/null || die "Panel settings have an unexpected format."
S="$(jq -c --arg d "$DOMAIN" --arg title "$VPN_NAME" --argjson p "$SUB_PORT" --arg path "/${SUB_PATH}/" \
  --arg cert "/root/cert/${DOMAIN}/fullchain.pem" --arg key "/root/cert/${DOMAIN}/privkey.pem" '
  .subEnable=true|.subEncrypt=true|.subListen="127.0.0.1"|.subDomain=$d|.subPort=$p|.subPath=$path
  |.subCertFile=$cert|.subKeyFile=$key|.subURI=("https://"+$d+$path)|.subTitle=$title' <<<"$S")"
ROUTING_CONFIGURED=0; MIHOMO_CONFIGURED=0
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  HAPP_ROUTING="$(curl -fsSL --retry 3 --max-time 30 https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/HAPP/DEFAULT.DEEPLINK 2>/dev/null || true)"
  INCY_ROUTING="$(curl -fsSL --retry 3 --max-time 30 https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/refs/heads/main/INCY/DEFAULT.DEEPLINK 2>/dev/null || true)"
  if [[ "$HAPP_ROUTING" == happ://routing/onadd/* && "$INCY_ROUTING" == incy://routing/onadd/* ]]; then
    S="$(jq -c --arg happ "$HAPP_ROUTING" --arg incy "$INCY_ROUTING" --arg jp "/${SUB_JSON_PATH}/" --arg cp "/${SUB_CLASH_PATH}/" --arg ju "https://${DOMAIN}/${SUB_JSON_PATH}/" --arg cu "https://${DOMAIN}/${SUB_CLASH_PATH}/" '.subEnableRouting=true|.subRoutingRules=$happ|.subIncyEnableRouting=true|.subIncyRoutingRules=$incy|.subJsonEnable=true|.subJsonPath=$jp|.subJsonURI=$ju|.subClashEnable=true|.subClashPath=$cp|.subClashURI=$cu|.subClashEnableRouting=false' <<<"$S")"
    ROUTING_CONFIGURED=1; MIHOMO_CONFIGURED=1
  fi
fi
R="$(curl -kfsS "${API_AUTH[@]}" -H 'Content-Type: application/json' \
  -X POST "$API_BASE/panel/api/setting/update" --data-binary "$S")"
jq -e '.success==true' <<<"$R" >/dev/null || die "Subscription setup failed: $R"
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  CURRENT_STEP='creating Mihomo subscription with RoscomVPN routing'
  printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
  MIHOMO_PROVIDER_URL="https://${DOMAIN}/${SUB_CLASH_PATH}/${CLIENT_SUB_ID}"
  MIHOMO_ROUTING_URL="https://${DOMAIN}/${MIHOMO_ROUTING_PATH}"
  MIHOMO_TEMPLATE="$(curl -fsSL --retry 3 --max-time 60 https://raw.githubusercontent.com/hydraponique/roscomvpn-routing/main/MIHOMO/default.yaml 2>/dev/null || true)"
  if grep -Fq '<ВВЕДИТЕ URL ПОДПИСКИ>' <<<"$MIHOMO_TEMPLATE"; then
    printf '%s\n' "$MIHOMO_TEMPLATE" | sed "s|<ВВЕДИТЕ URL ПОДПИСКИ>|${MIHOMO_PROVIDER_URL}|g" > "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    chmod 644 "/var/www/3xui-cover/${MIHOMO_ROUTING_PATH}"
    MIHOMO_CONFIGURED=1
    printf 'MIHOMO_ROUTING_PATH=%s\n' "$MIHOMO_ROUTING_PATH" >> "${STATE_FILES[0]}"
  else
    MIHOMO_CONFIGURED=0
    printf '%bWARNING:%b RoscomVPN Mihomo template could not be downloaded; the Mihomo routing subscription is unavailable.\n' "$yellow" "$plain" >&2
  fi
fi

CURRENT_STEP='creating or repairing VLESS + XHTTP + REALITY inbound'
printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
R="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list")"
jq -e '.success==true and .obj!=null' <<<"$R" >/dev/null || die "Could not read inbounds: $R"
INBOUNDS="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$R")"
jq -e 'type=="array"' <<<"$INBOUNDS" >/dev/null || die "Inbound list has an unexpected format."
EXISTING_INBOUND="$(jq -c 'map(select(.tag=="in-443-xhttp-reality"))|first // empty' <<<"$INBOUNDS")"
if [[ -z "$EXISTING_INBOUND" ]] && jq -e 'any(.port==443)' <<<"$INBOUNDS" >/dev/null; then
  die "TCP/443 is occupied by an unmanaged inbound; recovery will not overwrite it."
fi
if [[ -n "$EXISTING_INBOUND" ]]; then
  INBOUND_ID="$(jq -r '.id' <<<"$EXISTING_INBOUND")"
  IS="$(jq -c '.settings|if type=="string" then fromjson else . end' <<<"$EXISTING_INBOUND")"
  EXISTING_STREAM="$(jq -c '.streamSettings|if type=="string" then fromjson else . end' <<<"$EXISTING_INBOUND")"
  PRIV_R="$(jq -r '.realitySettings.privateKey // empty' <<<"$EXISTING_STREAM")"
  PUB_R="$(jq -r '.realitySettings.settings.publicKey // empty' <<<"$EXISTING_STREAM")"
  SID="$(jq -r '(.realitySettings.shortIds // [])[0] // empty' <<<"$EXISTING_STREAM")"
  if [[ -z "$PRIV_R" || -z "$PUB_R" ]]; then
    R="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/server/getNewX25519Cert")"
    PRIV_R="$(jq -r '.obj.privateKey//.obj.private//empty' <<<"$R")"; PUB_R="$(jq -r '.obj.publicKey//.obj.public//empty' <<<"$R")"
    [[ -n "$PRIV_R" && -n "$PUB_R" ]] || die "Reality key generation failed: $R"
  fi
  [[ -n "$SID" ]] || SID="$(od -An -N 8 -tx1 /dev/urandom|tr -d ' \n')"
  if [[ "$INSTALL_MODE" == "standalone" && -n "${CLIENT_UUID:-}" && -n "${CLIENT_SUB_ID:-}" ]]; then
    IS="$(jq -c --arg id "$CLIENT_UUID" --arg email "${CLIENT_EMAIL:-${INSTANCE_NAME}-primary}" --arg sub "$CLIENT_SUB_ID" '
      .clients = ((.clients // []) | if any(.id == $id or .subId == $sub) then . else . + [{id:$id,flow:"",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,reset:0}] end)
    ' <<<"$IS")"
  fi
  ST="$(jq -nc --arg d "$DOMAIN" --arg t "127.0.0.1:${FALLBACK_PORT}" --arg p "$PRIV_R" --arg q "$PUB_R" --arg s "$SID" '{network:"xhttp",security:"reality",externalProxy:[],realitySettings:{show:false,xver:0,dest:$t,privateKey:$p,minClientVer:"",maxClientVer:"",maxTimeDiff:0,serverNames:[$d],shortIds:[$s],settings:{publicKey:$q,fingerprint:"firefox",serverName:"",spiderX:"/"}},xhttpSettings:{host:$d,path:"/",mode:"auto",xPaddingBytes:"100-1000",noSSEHeader:false,scMaxEachPostBytes:"1000000",scMaxBufferedPosts:30,scStreamUpServerSecs:"20-80",headers:{}}}')"
  SN="$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')"
  IB="$(jq -nc --argjson id "$INBOUND_ID" --arg r "${VPN_NAME} — XHTTP Reality" --arg s "$IS" --arg t "$ST" --arg n "$SN" '{id:$id,up:0,down:0,total:0,remark:$r,enable:true,expiryTime:0,trafficReset:"never",listen:"",port:443,protocol:"vless",settings:$s,streamSettings:$t,tag:"in-443-xhttp-reality",sniffing:$n}')"
  R="$(curl -kfsS "${API_AUTH[@]}" -H 'Content-Type: application/json' -X POST "$API_BASE/panel/api/inbounds/update/${INBOUND_ID}" --data-binary "$IB")"
  jq -e '.success==true' <<<"$R" >/dev/null || die "Inbound repair failed: $R"
  REALITY_PUBLIC="$PUB_R"; SHORT_ID="$SID"
else
  R="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/server/getNewX25519Cert")"
  PRIV_R="$(jq -r '.obj.privateKey//.obj.private//empty' <<<"$R")"; PUB_R="$(jq -r '.obj.publicKey//.obj.public//empty' <<<"$R")"
  [[ -n "$PRIV_R" && -n "$PUB_R" ]] || die "Reality key generation failed: $R"
  SID="$(od -An -N 8 -tx1 /dev/urandom|tr -d ' \n')"
  if [[ "$INSTALL_MODE" == "standalone" ]]; then
    : "${CLIENT_UUID:=$(cat /proc/sys/kernel/random/uuid)}"
    : "${CLIENT_SUB_ID:=$(od -An -N 8 -tx1 /dev/urandom|tr -d ' \n')}"
    : "${CLIENT_EMAIL:=${INSTANCE_NAME}-primary}"
    IS="$(jq -nc --arg id "$CLIENT_UUID" --arg email "$CLIENT_EMAIL" --arg sub "$CLIENT_SUB_ID" '{clients:[{id:$id,flow:"",email:$email,limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:$sub,reset:0}],decryption:"none",encryption:"none",fallbacks:[]}')"
  else
    IS="$(jq -nc '{clients:[],decryption:"none",encryption:"none",fallbacks:[]}')"
  fi
  ST="$(jq -nc --arg d "$DOMAIN" --arg t "127.0.0.1:${FALLBACK_PORT}" --arg p "$PRIV_R" --arg q "$PUB_R" --arg s "$SID" '{network:"xhttp",security:"reality",externalProxy:[],realitySettings:{show:false,xver:0,dest:$t,privateKey:$p,minClientVer:"",maxClientVer:"",maxTimeDiff:0,serverNames:[$d],shortIds:[$s],settings:{publicKey:$q,fingerprint:"firefox",serverName:"",spiderX:"/"}},xhttpSettings:{host:$d,path:"/",mode:"auto",xPaddingBytes:"100-1000",noSSEHeader:false,scMaxEachPostBytes:"1000000",scMaxBufferedPosts:30,scStreamUpServerSecs:"20-80",headers:{}}}')"
  SN="$(jq -nc '{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:false}')"
  IB="$(jq -nc --arg r "${VPN_NAME} — XHTTP Reality" --arg s "$IS" --arg t "$ST" --arg n "$SN" '{up:0,down:0,total:0,remark:$r,enable:true,expiryTime:0,trafficReset:"never",listen:"",port:443,protocol:"vless",settings:$s,streamSettings:$t,tag:"in-443-xhttp-reality",sniffing:$n}')"
  R="$(curl -kfsS "${API_AUTH[@]}" -H 'Content-Type: application/json' -X POST "$API_BASE/panel/api/inbounds/add" --data-binary "$IB")"
  jq -e '.success==true' <<<"$R" >/dev/null || die "Inbound creation failed: $R"
  REALITY_PUBLIC="$PUB_R"; SHORT_ID="$SID"
  {
    printf 'CLIENT_UUID=%s\nCLIENT_SUB_ID=%s\nCLIENT_EMAIL=%s\n' "${CLIENT_UUID:-}" "${CLIENT_SUB_ID:-}" "${CLIENT_EMAIL:-}"
    printf 'REALITY_PUBLIC=%s\nSHORT_ID=%s\n' "$REALITY_PUBLIC" "$SHORT_ID"
  } >> "${STATE_FILES[0]}"
fi

WARP_CONFIGURED=0
if [[ "${ENABLE_WARP:-0}" -eq 1 ]]; then
  CURRENT_STEP='configuring built-in WARP and RU routing'
  printf '\n%b[STEP]%b %s\n' "$cyan" "$plain" "$CURRENT_STEP"
  R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
  if ! jq -e '.success==true and .obj!=null and .obj!=""' <<<"$R" >/dev/null; then
    PRIV="$(wg genkey)"; PUB="$(printf '%s' "$PRIV"|wg pubkey)"
    R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/reg" \
      --data-urlencode "privateKey=$PRIV" --data-urlencode "publicKey=$PUB")"
    if ! jq -e '.success==true' <<<"$R" >/dev/null; then
      die "WARP registration failed. WARP was requested, so repair cannot continue. Panel response: ${R}"
    fi
  fi
  if [[ "$ENABLE_WARP" -eq 1 ]]; then
    WARP_DATA_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
    WARP_CONFIG_RESPONSE="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/config")"
    WARP_DATA="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$WARP_DATA_RESPONSE")"
    WARP_CONFIG="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$WARP_CONFIG_RESPONSE")"
    if ! build_warp_outbound "$WARP_DATA" "$WARP_CONFIG"; then
      die "WARP account data is incomplete. WARP was requested, so repair cannot continue."
    else
      R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/")"
      jq -e '.success==true and .obj!=null' <<<"$R" >/dev/null || die "Could not read Xray configuration: $R"
      X="$(jq -c '.obj|if type=="string" then fromjson else . end|.xraySetting|if type=="string" then fromjson else . end' <<<"$R")"
      jq -e 'type=="object" and (.outbounds|type=="array")' <<<"$X" >/dev/null || die "Xray configuration has an unexpected format."
      cp -a /etc/x-ui/x-ui.db "/etc/x-ui/x-ui.db.before-warp.$(date +%Y%m%d-%H%M%S)"
      X="$(jq -c --argjson w "$WARP_OUT" '.outbounds=((.outbounds//[])|map(select(.tag!="warp")))+[$w]
        |.routing=(.routing//{})|.routing.domainStrategy="IPIfNonMatch"
        |.routing.rules=[
            {"type":"field","domain":["domain:ru"],"outboundTag":"warp","network":"tcp,udp","ruleTag":"xhttp-vps-warp-ru-domain"},
            {"type":"field","ip":["geoip:ru"],"outboundTag":"warp","network":"tcp,udp","ruleTag":"xhttp-vps-warp-ru-ip"}
          ]+((.routing.rules//[])|map(select(.ruleTag!="xhttp-vps-warp-ru-domain" and .ruleTag!="xhttp-vps-warp-ru-ip")))' <<<"$X")"
      R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/update" \
        --data-urlencode "xraySetting=$X" --data-urlencode 'outboundTestUrl=https://www.cloudflare.com/cdn-cgi/trace')"
      if ! jq -e '.success==true' <<<"$R" >/dev/null; then
        die "WARP routing could not be saved. WARP was requested, so repair cannot continue. Panel response: ${R}"
      fi
      WARP_CONFIGURED=1
      configure_warp_swap
    fi
  fi
fi

systemctl restart x-ui; sleep 2
READY=0; R=""
for _ in $(seq 1 40); do
  R="$(curl -kfsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
[[ "$READY" -eq 1 ]] || die "Private bearer API failed after the final restart. Last response: ${R:-<empty>}"
INBOUND_OK=0; CLIENT_OK=0; SUB_OK=0; SELF_STEAL_OK=0; ROUTING_OK=0; MIHOMO_OK=0
R="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list" || true)"
if jq -e --arg d "$DOMAIN" --arg t "127.0.0.1:${FALLBACK_PORT}" '.success==true and ((.obj|if type=="string" then fromjson else . end)|any(.port==443 and .protocol=="vless" and .enable==true and ((.streamSettings|if type=="string" then fromjson else . end) as $s|$s.network=="xhttp" and $s.security=="reality" and (($s.realitySettings.dest//$s.realitySettings.target)==$t) and (($s.realitySettings.serverNames//[])|index($d))!=null and $s.xhttpSettings.host==$d and $s.xhttpSettings.path=="/")))' <<<"$R" >/dev/null 2>&1; then INBOUND_OK=1; fi
for _ in $(seq 1 20); do
  COVER_DATA="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 "https://${DOMAIN}/" 2>/dev/null || true)"
  if grep -Fq "$DOMAIN" <<<"$COVER_DATA"; then SELF_STEAL_OK=1; break; fi
  sleep 1
done
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if jq -e --arg id "${CLIENT_UUID:-}" --arg sub "${CLIENT_SUB_ID:-}" '.success==true and ((.obj|if type=="string" then fromjson else . end)|any(.port==443 and .protocol=="vless" and ((.settings|if type=="string" then fromjson else . end).clients|any(.id==$id and .subId==$sub and .enable==true))))' <<<"$R" >/dev/null 2>&1; then CLIENT_OK=1; fi
  for _ in $(seq 1 20); do
    SUB_DATA="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    [[ -n "$SUB_DATA" ]] && { SUB_OK=1; break; }
    sleep 1
  done
  if [[ "$ROUTING_CONFIGURED" -eq 1 && "$SUB_OK" -eq 1 ]]; then
    SUB_HEADERS="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 5 -D - -o /dev/null "https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    SUB_DECODED="$(printf '%s' "$SUB_DATA" | base64 -d 2>/dev/null || true)"
    if grep -qi '^Routing-Enable:[[:space:]]*true' <<<"$SUB_HEADERS" && grep -qi '^Routing:[[:space:]]*happ://routing/onadd/' <<<"$SUB_HEADERS" && grep -q 'incy://routing/onadd/' <<<"$SUB_DECODED"; then ROUTING_OK=1; fi
  fi
  if [[ "$MIHOMO_CONFIGURED" -eq 1 ]]; then
    MIHOMO_DATA="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 10 "$MIHOMO_ROUTING_URL" 2>/dev/null || true)"
    if grep -q '^rule-providers:' <<<"$MIHOMO_DATA" && grep -Fq "$MIHOMO_PROVIDER_URL" <<<"$MIHOMO_DATA"; then MIHOMO_OK=1; fi
  fi
fi

/usr/local/x-ui/x-ui setting -listenIP 0.0.0.0 >/dev/null
systemctl restart x-ui
PANEL_WEB_OK=0
for _ in $(seq 1 20); do
  if curl -kfsS --resolve "${DOMAIN}:${PANEL_PORT}:127.0.0.1" --connect-timeout 2 --max-time 5 \
    -o /dev/null "https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/" 2>/dev/null; then PANEL_WEB_OK=1; break; fi
  sleep 1
done
CURRENT_STEP='running completion audit'
printf '\n%b==================== COMPLETION AUDIT ====================%b\n' "$blue" "$plain"
FAILED=0
report() {
  local label="$1" result="$2"
  if [[ "$result" == OK ]]; then
    printf '  %-32s %bOK%b\n' "$label" "$green" "$plain"
  elif [[ "$result" == SKIP ]]; then
    printf '  %-32s %bSKIP%b\n' "$label" "$yellow" "$plain"
  else
    printf '  %-32s %bERROR%b\n' "$label" "$red" "$plain"
    FAILED=$((FAILED+1))
  fi
}
if apt-get check >/dev/null 2>&1 && [[ -z "$(dpkg --audit)" ]]; then report "Package update/install" OK; else report "Package update/install" ERROR; fi
if systemctl is-active --quiet x-ui; then report "3x-ui panel" OK; else report "3x-ui panel" ERROR; fi
if systemctl is-active --quiet nginx && nginx -t >/dev/null 2>&1; then report "nginx self-steal" OK; else report "nginx self-steal" ERROR; fi
if [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == bbr && "$(sysctl -n net.core.default_qdisc)" == fq ]]; then report "BBR + fq" OK; else report "BBR + fq" ERROR; fi
if [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" == 1 ]]; then report "IPv6 disabled" OK; else report "IPv6 disabled" ERROR; fi
if ufw status | grep -q '^Status: active'; then report "UFW firewall" OK; else report "UFW firewall" ERROR; fi
if openssl x509 -in "/root/cert/${DOMAIN}/fullchain.pem" -checkend 86400 -noout >/dev/null 2>&1; then report "TLS certificate" OK; else report "TLS certificate" ERROR; fi
if [[ "$PANEL_WEB_OK" -eq 1 ]]; then report "Panel HTTPS response" OK; else report "Panel HTTPS response" ERROR; fi
if curl -kfsSI --resolve "$DOMAIN:$FALLBACK_PORT:127.0.0.1" "https://$DOMAIN:$FALLBACK_PORT/" >/dev/null; then report "Cover website" OK; else report "Cover website" ERROR; fi
if [[ "$SELF_STEAL_OK" -eq 1 ]]; then report "Public self-steal website" OK; else report "Public self-steal website" ERROR; fi
if ss -H -ltn "sport = :$SUB_PORT" | grep -q .; then report "Subscription service" OK; else report "Subscription service" ERROR; fi
if [[ "$INBOUND_OK" -eq 1 ]] && ss -H -ltn 'sport = :443' | grep -q .; then report "XHTTP Reality self-steal" OK; else report "XHTTP Reality self-steal" ERROR; fi
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  if [[ "$CLIENT_OK" -eq 1 ]]; then report "First VLESS client" OK; else report "First VLESS client" ERROR; fi
  if [[ "$SUB_OK" -eq 1 ]]; then report "Client subscription URL" OK; else report "Client subscription URL" ERROR; fi
  if [[ "$ROUTING_OK" -eq 1 ]]; then report "HAPP + INCY routing" OK; else report "HAPP + INCY routing" ERROR; fi
  if [[ "$MIHOMO_OK" -eq 1 ]]; then report "Mihomo subscription" OK; else report "Mihomo subscription" ERROR; fi
else
  report "First VLESS client" SKIP
  report "Client subscription URL" SKIP
  report "HAPP + INCY routing" SKIP
  report "Mihomo subscription" SKIP
fi
if command -v fail2ban-client >/dev/null; then if systemctl is-active --quiet fail2ban; then report "Fail2ban" OK; else report "Fail2ban" ERROR; fi; else report "Fail2ban" SKIP; fi
if [[ "${ENABLE_WARP:-0}" -eq 1 ]]; then
  if [[ "$WARP_CONFIGURED" -eq 1 ]]; then report "WARP RU routing" OK; else report "WARP RU routing" ERROR; fi
else
  report "WARP RU routing" SKIP
fi
MEMORY_KIB_FINAL="$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)"
if [[ "${ENABLE_WARP:-0}" -eq 1 && "$MEMORY_KIB_FINAL" =~ ^[0-9]+$ ]] && (( MEMORY_KIB_FINAL <= 1100000 )); then
  if swapon --noheadings --show 2>/dev/null | grep -q .; then
    report "Swap for low-memory WARP" OK
  else
    report "Swap for low-memory WARP" ERROR
  fi
else
  report "Swap for low-memory WARP" SKIP
fi
printf '%b==========================================================%b\n' "$blue" "$plain"
if [[ "$FAILED" -ne 0 ]]; then
  printf '%bRESULT: %s CHECK(S) FAILED%b\n' "$red" "$FAILED" "$plain"
  printf '%bFix every ERROR above before using the VPN or subscriptions.%b\n' "$yellow" "$plain"
  printf '%bSaved state:%b %s\n' "$yellow" "$plain" "${STATE_FILES[0]}"
  exit 1
fi

clear || true
printf '%b================================================================%b\n' "$green" "$plain"
printf '%b                    VPN REPAIR COMPLETED SUCCESSFULLY%b\n' "$green" "$plain"
printf '%b                     ALL CHECKS PASSED%b\n' "$green" "$plain"
printf '%b================================================================%b\n\n' "$green" "$plain"
printf '%bPANEL%b\n' "$cyan" "$plain"
printf '  %bURL:%b      https://%s:%s/%s/\n' "$yellow" "$plain" "$DOMAIN" "$PANEL_PORT" "$PANEL_PATH"
printf '  %bLogin:%b    %s\n' "$yellow" "$plain" "$PANEL_USERNAME"
printf '  %bPassword:%b %s\n\n' "$yellow" "$plain" "$PANEL_PASSWORD"
if [[ "$INSTALL_MODE" == "standalone" && -n "${CLIENT_UUID:-}" && -n "${CLIENT_SUB_ID:-}" ]]; then
  printf '%bCLIENT SUBSCRIPTIONS%b\n' "$cyan" "$plain"
  printf '  %bHAPP / INCY:%b https://%s/%s/%s\n' "$yellow" "$plain" "$DOMAIN" "$SUB_PATH" "$CLIENT_SUB_ID"
  printf '  %bMihomo:%b      %s\n' "$yellow" "$plain" "$MIHOMO_ROUTING_URL"
  printf '  %bRouting:%b     HAPP and INCY RoscomVPN routing profiles are included.\n\n' "$yellow" "$plain"
fi
if [[ "$INSTALL_MODE" == "node" && -n "${PANEL_API_TOKEN:-}" ]]; then printf '%bNODE API TOKEN:%b %s\n\n' "$cyan" "$plain" "$PANEL_API_TOKEN"; fi
printf '%bSaved state:%b %s\n' "$blue" "$plain" "${STATE_FILES[0]}"
printf '%b================================================================%b\n' "$green" "$plain"
