#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (C) 2026 yazmann
# Also sourced by the installer and repair script; no side effects when sourced.

xhttp_memory_policy() {
  jq -ce '
    if type != "object" then error("Invalid Xray template") else . end
    | .policy.levels["0"].bufferSize = 64
    | .policy.levels["0"].connIdle = 180
  '
}

xhttp_memory_inbound() {
  jq -ce '
    def decode: if type == "string" then fromjson else . end;
    (.streamSettings | decode) as $s
    | if .protocol != "vless" or $s.network != "xhttp" then
        error("Expected a VLESS XHTTP inbound")
      else . end
    | .streamSettings = ($s | .xhttpSettings.xmux = {
        maxConcurrency: "0", maxConnections: "1", cMaxReuseTimes: "0",
        hMaxRequestTimes: "300-600", hMaxReusableSecs: "600-900",
        hKeepAlivePeriod: 0
      } | tojson)
  '
}

xhttp_memory_api() {
  local path="$1"
  shift
  # Only the loopback panel is used. Do not put credentials in diagnostics.
  curl -kfsS --connect-timeout 3 --max-time 30 "${API_AUTH[@]}" \
    "$API_BASE$path" "$@" | jq -ce '
      if .success == true then . else error("Panel API rejected the operation") end
    '
}

xhttp_memory_create_api_header_file() {
  local token="$1" file
  [[ -n "$token" && "$token" != *$'\n'* && "$token" != *$'\r'* ]] || return 1
  file="$(mktemp /root/xhttp-api-headers.XXXXXXXX)"
  chmod 600 "$file"
  printf 'Authorization: Bearer %s\nX-Requested-With: XMLHttpRequest\n' "$token" > "$file"
  printf '%s' "$file"
}

xhttp_memory_apply() (
  # Subshell confines umask and traps; callers keep their error handlers.
  set -Eeuo pipefail
  umask 077
  local response template inbound updated_template updated_inbound backup_dir id test_url transport
  local target_tag="${1:-in-443-xhttp-reality}"
  transport="${2:-xhttp}"
  [[ "$transport" == xhttp || "$transport" == vision ]] || {
    printf 'Unsupported transport for memory profile: %s\n' "$transport" >&2; return 1;
  }
  [[ "$API_BASE" =~ ^https://127\.0\.0\.1:[0-9]+/ ]] || {
    printf 'Memory update requires a loopback HTTPS panel URL.\n' >&2; return 1;
  }
  response="$(xhttp_memory_api /panel/api/xray/ -X POST)" || return 1
  template="$(jq -ce '.obj | if type=="string" then fromjson else . end' <<<"$response")" || return 1
  test_url="$(jq -r '.outboundTestUrl // "https://www.cloudflare.com/cdn-cgi/trace"' <<<"$template")"
  template="$(jq -ce '.xraySetting | if type=="string" then fromjson else . end' <<<"$template")" || return 1
  response="$(xhttp_memory_api /panel/api/inbounds/list)" || return 1
  inbound="$(jq -ce --arg tag "$target_tag" '
    .obj | if type=="string" then fromjson else . end
    | map(select(.tag == $tag))
    | if length == 1 then .[0] else error("Expected exactly one matching inbound tag") end
  ' <<<"$response")" || return 1
  id="$(jq -er '.id | select(type=="number" and .>0 and floor==.)' <<<"$inbound")" || return 1
  updated_template="$(xhttp_memory_policy <<<"$template")" || return 1
  if [[ "$transport" == xhttp ]]; then
    updated_inbound="$(xhttp_memory_inbound <<<"$inbound")" || return 1
  else
    jq -e '
      (.streamSettings | if type=="string" then fromjson else . end) as $s
      | .protocol=="vless" and ($s.network=="tcp" or $s.network=="raw")
    ' <<<"$inbound" >/dev/null || return 1
    updated_inbound="$inbound"
  fi
  if [[ "$(jq -Sc . <<<"$template")" == "$(jq -Sc . <<<"$updated_template")" &&
        "$(jq -Sc . <<<"$inbound")" == "$(jq -Sc . <<<"$updated_inbound")" ]]; then
    printf 'Memory profile already applied; no restart needed.\n'
    return 0
  fi
  backup_dir="$(mktemp -d /root/xhttp-memory-backup.XXXXXXXX)"
  printf '%s\n' "$template" > "$backup_dir/xray.json"
  printf '%s\n' "$inbound" > "$backup_dir/inbound.json"
  printf '%s\n' "$test_url" > "$backup_dir/outbound-test-url.txt"
  # SQLite online backup includes committed WAL data, unlike cp of x-ui.db.
  sqlite3 /etc/x-ui/x-ui.db ".timeout 5000" ".backup '$backup_dir/x-ui.db'"
  printf 'Backup: %s\nApplying memory profile; active connections may reconnect.\n' "$backup_dir"
  trap 'printf "Memory update failed. Original API payloads and database: %s\n" "$backup_dir" >&2' ERR
  xhttp_memory_api /panel/api/xray/update -X POST \
    --data-urlencode "xraySetting=$updated_template" \
    --data-urlencode "outboundTestUrl=$test_url" >/dev/null
  # Sending the complete original row preserves quotas, enable/expiry, clients,
  # REALITY keys, all short IDs, paths, sniffing and other transport settings.
  if [[ "$transport" == xhttp && "$(jq -Sc . <<<"$inbound")" != "$(jq -Sc . <<<"$updated_inbound")" ]]; then
    xhttp_memory_api "/panel/api/inbounds/update/$id" -X POST \
      -H 'Content-Type: application/json' --data-binary "$updated_inbound" >/dev/null
  fi
  response="$(xhttp_memory_api /panel/api/xray/ -X POST)"
  jq -e '
    .obj | if type=="string" then fromjson else . end
    | .xraySetting | if type=="string" then fromjson else . end
    | .policy.levels["0"] | .bufferSize==64 and .connIdle==180
  ' <<<"$response" >/dev/null
  if [[ "$transport" == xhttp ]]; then
    response="$(xhttp_memory_api /panel/api/inbounds/list)"
    jq -e --argjson id "$id" --argjson expected "$updated_inbound" '
      def decode: if type=="string" then fromjson else . end;
      .obj | decode | map(select(.id==$id))
      | length==1 and ((.[0].streamSettings|decode) == ($expected.streamSettings|decode))
    ' <<<"$response" >/dev/null
  fi
  xhttp_memory_api /panel/api/server/restartXrayService -X POST >/dev/null
  if [[ "$transport" == xhttp ]]; then
    printf 'Saved and verified: bufferSize=64 KiB, connIdle=180 s, XMUX pool=1.\n'
    printf 'Refresh subscriptions and reconnect clients. This mitigates memory pressure; it does not prove an upstream leak is fixed.\n'
  else
    printf 'Saved and verified: bufferSize=64 KiB and connIdle=180 s; Vision transport was preserved.\n'
  fi
)

xhttp_memory_main() (
  [[ ${EUID} -eq 0 ]] || { printf 'Run as root.\n' >&2; return 1; }
  local cmd
  for cmd in curl jq sqlite3; do command -v "$cmd" >/dev/null || return 1; done
  local -a states
  mapfile -t states < <(find /root -maxdepth 1 -type f \( -name '3xui-vps-*.env' -o -name '3xui-node-*.env' \) -print)
  [[ ${#states[@]} -eq 1 ]] || { printf 'Expected one installer state file in /root.\n' >&2; return 1; }
  # shellcheck disable=SC1090
  source "${states[0]}"
  : "${PANEL_PORT:?}" "${PANEL_PATH:?}" "${PANEL_API_TOKEN:?}"
  : "${TRANSPORT:=xhttp}"
  : "${INBOUND_TAG:=$(printf 'in-443-%s-reality' "$TRANSPORT")}"
  API_BASE="https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
  API_HEADER_FILE="$(xhttp_memory_create_api_header_file "$PANEL_API_TOKEN")" \
    || { printf 'The panel API token contains invalid control characters.\n' >&2; return 1; }
  trap 'rm -f "${API_HEADER_FILE:-}"' EXIT
  API_AUTH=(-H "@${API_HEADER_FILE}")
  xhttp_memory_apply "$INBOUND_TAG" "$TRANSPORT"
)

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -Eeuo pipefail
  xhttp_memory_main "$@"
fi
