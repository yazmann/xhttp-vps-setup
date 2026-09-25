#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../optimize-xhttp-memory.sh
source ./optimize-xhttp-memory.sh

original='{"log":{"loglevel":"warning"},"policy":{"system":{"statsInboundUplink":true},"levels":{"0":{"bufferSize":256,"statsUserUplink":true,"handshake":4},"1":{"bufferSize":128}}},"routing":{"rules":[{"outboundTag":"blocked"}]}}'
fixture_updated="$(xhttp_memory_policy <<<"$original")"
jq -e '.policy.levels["0"].bufferSize==64 and .policy.levels["0"].connIdle==180 and .policy.levels["0"].statsUserUplink and .policy.levels["1"].bufferSize==128' <<<"$fixture_updated" >/dev/null
[[ "$(jq -Sc 'del(.policy.levels["0"].bufferSize,.policy.levels["0"].connIdle)' <<<"$original")" == "$(jq -Sc 'del(.policy.levels["0"].bufferSize,.policy.levels["0"].connIdle)' <<<"$fixture_updated")" ]]
[[ "$fixture_updated" == "$(xhttp_memory_policy <<<"$fixture_updated")" ]]
xhttp_memory_policy <<<'{}' | jq -e '.policy.levels["0"].bufferSize==64' >/dev/null
if xhttp_memory_policy <<<'[]' >/dev/null 2>&1; then exit 1; fi

original_inbound='{"id":7,"protocol":"vless","enable":false,"total":123456,"expiryTime":999999,"tag":"in-443-xhttp-reality","settings":"{\"clients\":[{\"id\":\"test-client\",\"enable\":false}]}","streamSettings":{"network":"xhttp","security":"reality","realitySettings":{"privateKey":"test-only","shortIds":["aa","bb"]},"xhttpSettings":{"path":"/custom","mode":"stream-up","xmux":{"maxConcurrency":"16-32"}}},"sniffing":"{\"enabled\":false}"}'
fixture_updated_inbound="$(xhttp_memory_inbound <<<"$original_inbound")"
jq -e '(.streamSettings|fromjson) as $s | $s.xhttpSettings.xmux.maxConcurrency=="0" and $s.xhttpSettings.xmux.maxConnections=="1" and $s.xhttpSettings.xmux.hMaxReusableSecs=="600-900"' <<<"$fixture_updated_inbound" >/dev/null
[[ "$(jq -Sc 'del(.streamSettings.xhttpSettings.xmux)' <<<"$original_inbound")" == "$(jq -Sc '.streamSettings|=fromjson | del(.streamSettings.xhttpSettings.xmux)' <<<"$fixture_updated_inbound")" ]]
[[ "$fixture_updated_inbound" == "$(xhttp_memory_inbound <<<"$fixture_updated_inbound")" ]]
if xhttp_memory_inbound <<< '{"protocol":"vless","streamSettings":{"network":"tcp"}}' >/dev/null 2>&1; then exit 1; fi

# No-op and refusal paths must never create backups, mutate APIs or restart.
API_BASE='https://127.0.0.1:12345/test'
xhttp_memory_api() {
  case "$1" in
    /panel/api/xray/) jq -nc --argjson x "$fixture_updated" '{success:true,obj:{xraySetting:$x}}' ;;
    /panel/api/inbounds/list) jq -nc --argjson i "$fixture_updated_inbound" '{success:true,obj:[$i]}' ;;
    *) printf 'Unexpected mutation: %s\n' "$1" >&2; return 1 ;;
  esac
}
xhttp_memory_apply
if (xhttp_memory_apply missing-tag) >/dev/null 2>&1; then exit 1; fi
vision_inbound='{"id":8,"protocol":"vless","tag":"in-443-vision-reality","streamSettings":{"network":"tcp","security":"reality","tcpSettings":{"header":{"type":"none"}}}}'
xhttp_memory_api() {
  case "$1" in
    /panel/api/xray/) jq -nc --argjson x "$fixture_updated" '{success:true,obj:{xraySetting:$x}}' ;;
    /panel/api/inbounds/list) jq -nc --argjson i "$vision_inbound" '{success:true,obj:[$i]}' ;;
    *) printf 'Unexpected Vision mutation: %s\n' "$1" >&2; return 1 ;;
  esac
}
xhttp_memory_apply in-443-vision-reality vision
export API_BASE='https://example.com:12345/test'
if (xhttp_memory_apply) >/dev/null 2>&1; then exit 1; fi

# Exercise successful writes and API failure against an isolated fake panel.
test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
export API_BASE='https://127.0.0.1:12345/test'
printf '%s\n' "$original" > "$test_dir/template"
printf '%s\n' "$original_inbound" > "$test_dir/inbound"
mktemp() { command mktemp -d "$test_dir/backup.XXXXXXXX"; }
sqlite3() { printf 'online backup\n' >> "$test_dir/calls"; }
xhttp_memory_api() {
  local path="$1" arg
  shift
  printf '%s\n' "$path" >> "$test_dir/calls"
  case "$path" in
    /panel/api/xray/)
      jq -nc --argjson x "$(cat "$test_dir/template")" '{success:true,obj:{xraySetting:($x|tojson),outboundTestUrl:"https://example.com/probe"}}';;
    /panel/api/inbounds/list)
      jq -nc --argjson i "$(cat "$test_dir/inbound")" '{success:true,obj:([$i]|tojson)}';;
    /panel/api/xray/update)
      for arg in "$@"; do
        if [[ "$arg" == xraySetting=* ]]; then printf '%s\n' "${arg#xraySetting=}" > "$test_dir/template"; fi
      done
      printf '{"success":true}\n';;
    /panel/api/inbounds/update/7)
      if [[ "${fail_update:-0}" == 1 && ! -e "$test_dir/fail-once" ]]; then
        touch "$test_dir/fail-once"
        return 1
      fi
      while (( $# )); do
        if [[ "$1" == --data-binary ]]; then printf '%s\n' "$2" > "$test_dir/inbound"; break; fi
        shift
      done
      printf '{"success":true}\n';;
    /panel/api/server/restartXrayService) printf '{"success":true}\n';;
    *) return 1;;
  esac
}
xhttp_memory_apply
[[ "$(jq -Sc . "$test_dir/inbound")" == "$(jq -Sc . <<<"$fixture_updated_inbound")" ]]
grep -q '/panel/api/server/restartXrayService' "$test_dir/calls"
[[ "$(find "$test_dir" -name xray.json | wc -l)" -eq 1 ]]
printf '%s\n' "$original" > "$test_dir/template"
printf '%s\n' "$original_inbound" > "$test_dir/inbound"
: > "$test_dir/calls"
# A new shell preserves errexit semantics (calling a function in `if` disables it).
export test_dir fail_update=1 API_BASE
export -f xhttp_memory_apply xhttp_memory_api xhttp_memory_policy xhttp_memory_inbound mktemp sqlite3
if bash -c 'xhttp_memory_apply' > "$test_dir/error" 2>&1; then exit 1; fi
[[ "$(jq -Sc . "$test_dir/template")" == "$(jq -Sc . <<<"$original")" ]]
[[ "$(jq -Sc . "$test_dir/inbound")" == "$(jq -Sc . <<<"$original_inbound")" ]]
grep -q '/panel/api/server/restartXrayService' "$test_dir/calls"
grep -q 'Rollback completed' "$test_dir/error"
printf 'Memory profile tests passed.\n'
