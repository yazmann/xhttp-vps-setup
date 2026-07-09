#!/usr/bin/env bash
set -Eeuo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
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
if [[ "$INSTALL_MODE" == "standalone" ]]; then
  : "${SUB_JSON_PATH:=json-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n')}"
  : "${SUB_CLASH_PATH:=mihomo-$(od -An -N 10 -tx1 /dev/urandom|tr -d ' \n')}"
fi
if [[ -r /etc/x-ui/install-result.env ]]; then
  # shellcheck disable=SC1091
  source /etc/x-ui/install-result.env
  PANEL_USERNAME="${XUI_USERNAME:-$PANEL_USERNAME}"
  PANEL_PASSWORD="${XUI_PASSWORD:-$PANEL_PASSWORD}"
  PANEL_PORT="${XUI_PANEL_PORT:-$PANEL_PORT}"
  PANEL_PATH="${XUI_WEB_BASE_PATH:-$PANEL_PATH}"
  PANEL_API_TOKEN="${XUI_API_TOKEN:-${PANEL_API_TOKEN:-}}"
  PANEL_PATH="${PANEL_PATH#/}"; PANEL_PATH="${PANEL_PATH%/}"
fi
for cmd in curl jq wg; do command -v "$cmd" >/dev/null || die "Missing command: $cmd"; done
[[ -n "${PANEL_API_TOKEN:-}" ]] || die "State/install-result does not contain the 3x-ui API token."

/usr/local/x-ui/x-ui setting -listenIP 127.0.0.1 -resetTwoFactor=true >/dev/null
API_BASE="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
API_AUTH=(-H "Authorization: Bearer ${PANEL_API_TOKEN}" -H 'X-Requested-With: XMLHttpRequest')
systemctl restart x-ui
READY=0; R=""
for _ in $(seq 1 15); do
  R="$(curl -kfsS "${API_AUTH[@]}" --connect-timeout 2 --max-time 5 "$API_BASE/panel/api/server/status" 2>&1 || true)"
  if jq -e '.success==true' <<<"$R" >/dev/null 2>&1; then READY=1; break; fi
  sleep 1
done
[[ "$READY" -eq 1 ]] || { systemctl status x-ui --no-pager || true; /usr/local/x-ui/x-ui setting -show true 2>/dev/null || true; die "Private bearer API failed after 15 attempts. Last response: ${R:-<empty>}"; }

echo "Configuring subscription service..."
R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/setting/all")"
S="$(jq -c '.obj|if type=="string" then fromjson else . end' <<<"$R")"
S="$(jq -c --arg d "$DOMAIN" --arg title "$VPN_NAME" --argjson p "$SUB_PORT" --arg path "/${SUB_PATH}/" \
  --arg cert "/root/cert/${DOMAIN}/fullchain.pem" --arg key "/root/cert/${DOMAIN}/privkey.pem" '
  .twoFactorEnable=false
  |.subEnable=true|.subEncrypt=true|.subListen="127.0.0.1"|.subDomain=$d|.subPort=$p|.subPath=$path
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

echo "Creating or repairing VLESS + XHTTP + REALITY inbound..."
R="$(curl -kfsS "${API_AUTH[@]}" "$API_BASE/panel/api/inbounds/list")"
EXISTING_INBOUND="$(jq -c '.obj|if type=="string" then fromjson else . end|map(select(.port==443 and .protocol=="vless"))|first // empty' <<<"$R")"
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

if [[ "${ENABLE_WARP:-0}" -eq 1 ]]; then
  echo "Configuring built-in WARP and RU routing..."
  R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/data")"
  if ! jq -e '.success==true and .obj!=null and .obj!=""' <<<"$R" >/dev/null; then
    PRIV="$(wg genkey)"; PUB="$(printf '%s' "$PRIV"|wg pubkey)"
    R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/reg" \
      --data-urlencode "privateKey=$PRIV" --data-urlencode "publicKey=$PUB")"
    jq -e '.success==true' <<<"$R" >/dev/null || die "WARP registration failed: $R"
  fi
  R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/warp/config")"
  W="$(jq -c '.obj|if type=="string" then fromjson else . end|.tag="warp"' <<<"$R")"
  R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/")"
  X="$(jq -c '.obj|if type=="string" then fromjson else . end|.xraySetting|if type=="string" then fromjson else . end' <<<"$R")"
  cp -a /etc/x-ui/x-ui.db "/etc/x-ui/x-ui.db.before-warp.$(date +%Y%m%d-%H%M%S)"
  X="$(jq -c --argjson w "$W" '.outbounds=((.outbounds//[])|map(select(.tag!="warp")))+[$w]
    |.routing=(.routing//{})|.routing.domainStrategy="IPIfNonMatch"
    |.routing.rules=[{"type":"field","domain":["regexp:.*\\.ru$"],"outboundTag":"warp","network":"tcp,udp"},{"type":"field","ip":["geoip:ru"],"outboundTag":"warp","network":"tcp,udp"}]+((.routing.rules//[])|map(select(.outboundTag!="warp")))' <<<"$X")"
  R="$(curl -kfsS "${API_AUTH[@]}" -X POST "$API_BASE/panel/api/xray/update" \
    --data-urlencode "xraySetting=$X" --data-urlencode 'outboundTestUrl=https://www.cloudflare.com/cdn-cgi/trace')"
  jq -e '.success==true' <<<"$R" >/dev/null || die "WARP routing failed: $R"
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
    MIHOMO_DATA="$(curl -kfsS --resolve "${DOMAIN}:443:127.0.0.1" --max-time 10 "https://${DOMAIN}/${SUB_CLASH_PATH}/${CLIENT_SUB_ID}" 2>/dev/null || true)"
    if grep -q '^proxies:' <<<"$MIHOMO_DATA" && grep -q 'type: vless' <<<"$MIHOMO_DATA"; then MIHOMO_OK=1; fi
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
echo
echo "==================== COMPLETION AUDIT ===================="
FAILED=0
report() { printf '%-32s %s\n' "$1" "$2"; [[ "$2" == ERROR ]] && FAILED=$((FAILED+1)) || true; }
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
if [[ "${ENABLE_WARP:-0}" -eq 1 ]]; then report "WARP RU routing" OK; else report "WARP RU routing" SKIP; fi
echo "=========================================================="
[[ "$FAILED" -eq 0 ]] && echo "RESULT: ALL CHECKS PASSED" || echo "RESULT: ${FAILED} CHECK(S) FAILED"
echo "PANEL URL: https://${DOMAIN}:${PANEL_PORT}/${PANEL_PATH}/"
echo "LOGIN:     ${PANEL_USERNAME}"
echo "PASSWORD:  ${PANEL_PASSWORD}"
if [[ "$INSTALL_MODE" == "standalone" && -n "${CLIENT_UUID:-}" && -n "${CLIENT_SUB_ID:-}" ]]; then
  echo "FIRST CLIENT: ${CLIENT_EMAIL}"
  echo "HAPP / INCY SUBSCRIPTION: https://${DOMAIN}/${SUB_PATH}/${CLIENT_SUB_ID}"
  echo "MIHOMO SUBSCRIPTION:      https://${DOMAIN}/${SUB_CLASH_PATH}/${CLIENT_SUB_ID}"
fi
if [[ "$INSTALL_MODE" == "node" && -n "${PANEL_API_TOKEN:-}" ]]; then echo "API TOKEN: ${PANEL_API_TOKEN}"; fi
echo "SAVED:     ${STATE_FILES[0]}"
[[ "$FAILED" -eq 0 ]] || exit 1
