#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=../xhttp-vps-common.sh
source ./xhttp-vps-common.sh

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
xhttp_memory_api() {
  local path="$1"
  shift
  printf '%s\n' "$path" >> "$test_dir/calls"
  case "$path" in
    /panel/api/setting/apiTokens)
      printf '%s\n' '{"success":true,"obj":[{"id":5,"name":"xhttp-node-sync","scope":"node-sync"},{"id":6,"name":"other","scope":"admin"}]}'
      ;;
    /panel/api/setting/apiTokens/delete/5)
      [[ "$*" == *'{"expectedScope":"node-sync"}'* ]]
      printf '%s\n' '{"success":true}'
      ;;
    /panel/api/setting/apiTokens/create)
      local payload=''
      while (( $# )); do
        if [[ "$1" == --data-binary ]]; then payload="$2"; break; fi
        shift
      done
      jq -e '.name=="xhttp-node-sync" and .scope=="node-sync" and .expiresAt==0' <<<"$payload" >/dev/null
      printf '%s\n' '{"success":true,"obj":{"scope":"node-sync","enabled":true,"token":"0123456789abcdef0123456789abcdef"}}'
      ;;
    *) return 1 ;;
  esac
}

token="$(xhttp_rotate_node_sync_token xhttp-node-sync)"
[[ "$token" == '0123456789abcdef0123456789abcdef' ]]
grep -Fxq '/panel/api/setting/apiTokens/delete/5' "$test_dir/calls"
grep -Fxq '/panel/api/setting/apiTokens/create' "$test_dir/calls"

xhttp_memory_api() {
  case "$1" in
    /panel/api/setting/apiTokens) printf '%s\n' '{"success":true,"obj":[]}' ;;
    /panel/api/setting/apiTokens/create) printf '%s\n' '{"success":true,"obj":{"scope":"admin","enabled":true,"token":"0123456789abcdef0123456789abcdef"}}' ;;
    *) return 1 ;;
  esac
}
if xhttp_rotate_node_sync_token xhttp-node-sync >/dev/null 2>&1; then exit 1; fi
printf 'API token tests passed.\n'
