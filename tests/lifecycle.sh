#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-common.sh
source ./xhttp-vps-common.sh

xhttp_valid_ipv4 203.0.113.7
xhttp_valid_ipv4 0.0.0.0
if xhttp_valid_ipv4 256.1.1.1; then exit 1; fi
if xhttp_valid_ipv4 1.2.3; then exit 1; fi
if xhttp_valid_ipv4 '1.2.3.4 extra'; then exit 1; fi

[[ "$(xhttp_transport_flow vision)" == xtls-rprx-vision ]]
[[ -z "$(xhttp_transport_flow xhttp)" ]]
[[ "$(xhttp_inbound_tag_for vision)" == in-443-vision-reality ]]
[[ "$(xhttp_inbound_tag_for xhttp)" == in-443-xhttp-reality ]]
[[ "$(xhttp_ssh_access_label admin)" == *'root login disabled'* ]]
[[ "$(xhttp_ssh_access_label root-key)" == *'root login by SSH key only'* ]]
[[ "$(xhttp_ssh_access_label existing)" == *'not recommended'* ]]
admin_sshd="$(xhttp_render_sshd_hardening admin vpnadmin)"
grep -Fxq 'PermitRootLogin no' <<<"$admin_sshd"
grep -Fxq 'AllowUsers vpnadmin' <<<"$admin_sshd"
grep -Fxq 'AuthenticationMethods publickey' <<<"$admin_sshd"
root_sshd="$(xhttp_render_sshd_hardening root-key root)"
grep -Fxq 'PermitRootLogin prohibit-password' <<<"$root_sshd"
grep -Fxq 'AllowUsers root' <<<"$root_sshd"
if xhttp_render_sshd_hardening admin root >/dev/null; then exit 1; fi
vision_stream="$(xhttp_build_stream_settings vision example.com 127.0.0.1:9443 private public abcd)"
jq -e '.network=="tcp" and .security=="reality" and .tcpSettings.header.type=="none" and .realitySettings.target=="127.0.0.1:9443" and .realitySettings.serverNames==["example.com"]' <<<"$vision_stream" >/dev/null
xhttp_stream="$(xhttp_build_stream_settings xhttp example.com 127.0.0.1:9443 private public abcd)"
jq -e '.network=="xhttp" and .security=="reality" and .xhttpSettings.mode=="auto" and .xhttpSettings.host=="example.com"' <<<"$xhttp_stream" >/dev/null
export MAINTENANCE_TIMEZONE=Europe/Moscow
timer="$(xhttp_render_maintenance_timer)"
grep -Fq 'OnCalendar=Sun *-*-* 05:00:00 Europe/Moscow' <<<"$timer"
grep -Fq 'Persistent=false' <<<"$timer"

warp='{"tag":"warp","protocol":"wireguard","settings":{}}'
base='{"outbounds":[{"tag":"direct","protocol":"freedom"},{"tag":"blocked","protocol":"blackhole"}],"routing":{"rules":[{"inboundTag":["api"],"outboundTag":"api"},{"protocol":["bittorrent"],"outboundTag":"blocked"},{"ip":["geoip:private"],"outboundTag":"blocked"},{"outboundTag":"direct","network":"tcp,udp"}]}}'
result="$(xhttp_warp_config "$warp" <<<"$base")"
jq -e '.routing.rules[0].outboundTag=="api" and .routing.rules[1].protocol==["bittorrent"] and .routing.rules[2].ip==["geoip:private"] and .routing.rules[3].ruleTag=="xhttp-vps-warp-ru-domain" and .routing.rules[4].ip==["geoip:ru"] and .routing.rules[5].outboundTag=="direct" and ([.routing.rules[]|select(.outboundTag=="warp")]|length)==2 and .routing.rules[3].domain==["domain:ru","domain:su","domain:xn--p1ai","geosite:category-ru"] and .routing.domainStrategy=="IPOnDemand"' <<<"$result" >/dev/null
[[ "$result" == "$(xhttp_warp_config "$warp" <<<"$result")" ]]
legacy="$(jq '.routing.rules=[{ruleTag:"xhttp-vps-warp-ru-ip",ip:["geoip:ru"],outboundTag:"warp"}]+.routing.rules' <<<"$base")"
[[ "$result" == "$(xhttp_warp_config "$warp" <<<"$legacy")" ]]
if xhttp_warp_config "$warp" <<<'{"routing":{"rules":[{"outboundTag":"blocked"}]}}' >/dev/null 2>&1; then exit 1; fi
if xhttp_warp_config "$warp" <<<'{"routing":{"rules":[{"outboundTag":"direct"},{"protocol":["bittorrent"],"outboundTag":"blocked"}]}}' >/dev/null 2>&1; then exit 1; fi
xhttp_warp_config "$warp" <<<'{}' | jq -e '.routing.rules|length==2' >/dev/null

fixture='{"enable":true,"port":443,"settings":{"encryption":"none","clients":[{"id":"test-only","enable":true,"expiryTime":0}]},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/custom","mode":"auto"},"realitySettings":{"privateKey":"must-not-leak","serverNames":["example.com"],"shortIds":["abcd"],"settings":{"publicKey":"test-public","fingerprint":"chrome"}}}}'
probe="$(xhttp_probe_config 23456 <<<"$fixture")"
jq -e '.inbounds[0].listen=="127.0.0.1" and .inbounds[0].port==23456 and .outbounds[0].settings.vnext[0].users[0].id=="test-only" and .outbounds[0].streamSettings.xhttpSettings.path=="/custom" and .outbounds[0].streamSettings.realitySettings.password=="test-public"' <<<"$probe" >/dev/null
if grep -q must-not-leak <<<"$probe"; then exit 1; fi
if jq '.enable=false' <<<"$fixture" | xhttp_probe_config 23456 >/dev/null 2>&1; then exit 1; fi
if jq '.settings.clients=[]' <<<"$fixture" | xhttp_probe_config 23456 >/dev/null 2>&1; then exit 1; fi
if jq '.settings.clients[0].expiryTime=1' <<<"$fixture" | xhttp_probe_config 23456 >/dev/null 2>&1; then exit 1; fi
vision_fixture="$(jq -nc --argjson stream "$vision_stream" '{enable:true,port:443,settings:{encryption:"none",clients:[{id:"vision-client",flow:"xtls-rprx-vision",enable:true,expiryTime:0}]},streamSettings:$stream}')"
vision_probe="$(xhttp_probe_config 23457 <<<"$vision_fixture")"
jq -e '.outbounds[0].settings.vnext[0].users[0].flow=="xtls-rprx-vision" and .outbounds[0].streamSettings.network=="tcp" and .outbounds[0].streamSettings.tcpSettings.header.type=="none"' <<<"$vision_probe" >/dev/null
if jq '.settings.clients[0].flow=""' <<<"$vision_fixture" | xhttp_probe_config 23457 >/dev/null 2>&1; then exit 1; fi

# Test path validation before overriding filesystem roots for isolated fixtures.
export DOMAIN=example.com RESULT_FILE=/root/xhttp-vps-result-test.txt MANAGED_BACKUP=/
if xhttp_validate_state; then exit 1; fi
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/key"
key_b64="$(base64 -w0 "$test_dir/key.pub")"
xhttp_validate_authorized_keys_b64 "$key_b64"
if xhttp_validate_authorized_keys_b64 "$(printf 'no-port-forwarding %s\n' "$(cat "$test_dir/key.pub")" | base64 -w0)"; then exit 1; fi
MANAGED_BACKUP="$test_dir/journal"
mkdir "$MANAGED_BACKUP" "$test_dir/owned" "$test_dir/unrelated"
export SSH_ACCESS_MODE=root-key SSH_HARDENING=1 ADMIN_USER=root ADMIN_KEYS_B64="$key_b64"
xhttp_validate_ssh_access_state
export SSH_ACCESS_MODE=admin ADMIN_USER=root
if xhttp_validate_ssh_access_state; then exit 1; fi
export SSH_ACCESS_MODE=existing SSH_HARDENING=0 ADMIN_USER=root ADMIN_KEYS_B64=''
xhttp_validate_ssh_access_state
printf 'original\n' > "$test_dir/config"
printf 'user data\n' > "$test_dir/unrelated/keep"
printf 'original directory\n' > "$test_dir/owned/prior"
# These two test doubles confine all filesystem changes to the fixture.
xhttp_validate_state() { [[ "$MANAGED_BACKUP" == "$test_dir/journal" ]]; }
xhttp_managed_paths() { printf '%s\n' "$test_dir/config" "$test_dir/owned" "$test_dir/new"; }
xhttp_record_ownership
printf 'generated\n' > "$test_dir/config"
printf 'later user file\n' > "$test_dir/owned/later"
printf 'new generated file\n' > "$test_dir/new"
xhttp_record_ownership # Must not replace original backup with generated values.
xhttp_restore_owned_files
grep -qx original "$test_dir/config"
grep -qx 'original directory' "$test_dir/owned/prior"
grep -qx 'user data' "$test_dir/unrelated/keep"
[[ ! -e "$test_dir/new" ]]
find "$MANAGED_BACKUP" -name later -exec grep -qx 'later user file' {} \;
[[ "$(find "$MANAGED_BACKUP" -name later | wc -l)" == 1 ]]
# Reject a corrupted journal before moving even the first target.
printf '99\t%s\n' "$test_dir/config" > "$MANAGED_BACKUP/paths"
if xhttp_restore_owned_files >/dev/null 2>&1; then exit 1; fi
grep -qx original "$test_dir/config"

export DOMAIN=example.com FALLBACK_PORT=12345 SUB_PORT=12346 SUB_PATH=sub
export SUB_JSON_PATH=json-restored SUB_CLASH_PATH=clash-restored CERT_DIR=/root/cert/example.com
export XHTTP_NGINX_VERSION_OVERRIDE=1.24.0
nginx="$(xhttp_render_nginx)"
grep -Fq '/json-restored/' <<<"$nginx"
grep -Fq '/clash-restored/' <<<"$nginx"
grep -Fq 'proxy_set_header X-Real-IP $remote_addr;' <<<"$nginx"
grep -Fq 'server_tokens off;' <<<"$nginx"
grep -Fq 'access_log off;' <<<"$nginx"
grep -Fq 'listen 127.0.0.1:12345 ssl http2;' <<<"$nginx"
grep -Fq 'location ^~ /.well-known/acme-challenge/' <<<"$nginx"
grep -Fq 'return 301 https://example.com$request_uri;' <<<"$nginx"
export XHTTP_NGINX_VERSION_OVERRIDE=1.26.0
nginx="$(xhttp_render_nginx)"
grep -Fq 'listen 127.0.0.1:12345 ssl;' <<<"$nginx"
grep -Fq 'http2 on;' <<<"$nginx"
unset XHTTP_NGINX_VERSION_OVERRIDE

# Exercise the subprocess success/failure paths without network or /root writes.
# shellcheck source=fake-xray.sh
source tests/fake-xray.sh
export -f fake_xray
export XRAY_BINARY=fake_xray test_dir
mktemp() { command mktemp -d "$test_dir/probe.XXXXXXXX"; }
port_busy() { return 0; }
curl() { printf 'ip=192.0.2.1\nwarp=%s\n' "${PROBE_WARP:-off}"; }
export -f xhttp_run_probe mktemp port_busy curl
bash -c 'xhttp_run_probe "$(cat)" direct' <<<"$probe"
if bash -c 'xhttp_run_probe "$(cat)" warp' <<<"$probe"; then exit 1; fi
PROBE_WARP=on bash -c 'xhttp_run_probe "$(cat)" warp' <<<"$probe"
if PROBE_VALIDATE_EXIT=1 bash -c 'xhttp_run_probe "$(cat)" direct' <<<"$probe"; then exit 1; fi
[[ "$(find "$test_dir" -maxdepth 1 -name 'probe.*' | wc -l)" == 0 ]]
printf 'Lifecycle tests passed.\n'
# An explicit direct domain/IP route must not bypass regional protection.
early_direct="$(jq '.routing.domainStrategy="AsIs" | .routing.rules=[{domain:["domain:ru"],outboundTag:"direct"},{ip:["geoip:ru"],outboundTag:"direct"}]+.routing.rules' <<<"$base")"
xhttp_warp_config "$warp" <<<"$early_direct" | jq -e '.routing.domainStrategy=="IPOnDemand" and .routing.rules[3].ruleTag=="xhttp-vps-warp-ru-domain" and .routing.rules[4].ruleTag=="xhttp-vps-warp-ru-ip" and .routing.rules[5].outboundTag=="direct" and .routing.rules[6].outboundTag=="direct"' >/dev/null
