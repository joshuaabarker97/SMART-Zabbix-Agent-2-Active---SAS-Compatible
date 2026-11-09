#!/usr/bin/env bash
# Read-only SMART JSON collector for Zabbix Agent 2.
set -Eeuo pipefail
SMARTCTL="${SMARTCTL_PATH:-/usr/sbin/smartctl}"
DISK="${1:-}"
fail(){ printf 'zabbix-smart-full: %s\n' "$*" >&2; exit 1; }
[[ -n "$DISK" ]] || fail 'No device path supplied.'
[[ "$DISK" == /dev/* ]] || fail "Invalid device path '$DISK'; expected /dev/..."
[[ -e "$DISK" ]] || fail "Device does not exist: $DISK"
[[ -x "$SMARTCTL" ]] || fail "smartctl not executable: $SMARTCTL"
command -v sudo >/dev/null 2>&1 || fail 'sudo is not installed.'
command -v jq >/dev/null 2>&1 || fail 'jq is not installed.'
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT
# smartctl's exit status is a bitmask. Valid JSON can still contain useful
# health data when that status is non-zero, so validate the JSON separately.
set +e
SMART_JSON="$(sudo -n "$SMARTCTL" -x -j "$DISK" 2>"$ERR_FILE")"
SMARTCTL_RC=$?
set -e
[[ -n "$SMART_JSON" ]] || {
  if [[ -s "$ERR_FILE" ]]; then fail "smartctl returned no JSON (exit $SMARTCTL_RC): $(tr '\n' ' ' < "$ERR_FILE")"; fi
  fail "smartctl returned no JSON (exit $SMARTCTL_RC); check sudoers and device access."
}
printf '%s' "$SMART_JSON" | jq -e 'type == "object" and (.device.protocol? | type == "string")' >/dev/null 2>&1 || fail "Invalid smartctl JSON or missing device.protocol (exit $SMARTCTL_RC)."
# Stable common fields are exposed at the top level; the full source response
# is retained unchanged under raw for protocol-specific dependent items.
printf '%s' "$SMART_JSON" | jq -c '
  . as $raw | {
    protocol: ($raw.device.protocol // "UNKNOWN"),
    model: ($raw.model_name // $raw.scsi_model_name // "Unknown"),
    serial: ($raw.serial_number // "Unknown"),
    capacity_bytes: (if ($raw.user_capacity | type) == "object" then ($raw.user_capacity.bytes // null) else ($raw.user_capacity // $raw.nvme_total_capacity // null) end),
    smart_available: ($raw.smart_support.available // false),
    smart_enabled: ($raw.smart_support.enabled // false),
    health: ($raw.smart_status.passed // null),
    temperature: (if ($raw.temperature | type) == "object" then ($raw.temperature.current // null) else ($raw.temperature // $raw.nvme_smart_health_information_log.temperature // null) end),
    power_on_hours: ($raw.power_on_time.hours // $raw.nvme_smart_health_information_log.power_on_hours // $raw.power_on_hours // null),
    raw: $raw
  }
' || fail 'Could not normalize smartctl JSON.'
# Deliberately return success when valid JSON exists, irrespective of the
# smartctl bitmask. raw.smartctl.exit_status remains available to Zabbix.
exit 0
