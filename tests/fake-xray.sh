#!/usr/bin/env bash
# Lifecycle test fixture; never used by the installer.
fake_xray() {
  if [[ "${2:-}" == -test ]]; then return "${PROBE_VALIDATE_EXIT:-0}"; fi
  exec sleep 30
}
