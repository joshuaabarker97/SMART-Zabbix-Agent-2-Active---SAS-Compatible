#!/usr/bin/env bash
# Zabbix SMART Full installer. Debian/Ubuntu + systemd + existing Zabbix Agent 2.
set -Eeuo pipefail
APP='Zabbix SMART Full'
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
COLLECTOR_SRC="$ROOT/zabbix-smart-full.sh"
COLLECTOR_DST=/usr/local/bin/zabbix-smart-full.sh
SUDOERS_FILE=/etc/sudoers.d/zabbix-smartctl
FRAGMENT_DIR=/etc/zabbix/zabbix_agent2.d
FRAGMENT="$FRAGMENT_DIR/smart-full.conf"
LOG=/var/log/zabbix-smart-full-install.log
AGENT_CONFIG="${ZABBIX_AGENT2_CONFIG:-}"
STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP_SUFFIX=".bak.$STAMP"
mkdir -p "$(dirname "$LOG")"; touch "$LOG"; chmod 0640 "$LOG"
exec > >(tee -a "$LOG") 2>&1

info(){ printf '[INFO] %s\n' "$*"; }
ok(){ printf '[ OK ] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*"; }
die(){ printf '[FAIL] %s\n' "$*" >&2; exit 1; }
backup(){ [[ ! -e "$1" ]] || { cp -a -- "$1" "$1$BACKUP_SUFFIX"; info "Backup: $1$BACKUP_SUFFIX"; }; }
on_error(){ rc=$?; printf '\n[FAIL] Installation failed near line %s (exit %s).\n' "$1" "$rc" >&2; printf '[FAIL] Review %s. Existing-file backups use suffix %s.\n' "$LOG" "$BACKUP_SUFFIX" >&2; exit "$rc"; }
trap 'on_error "$LINENO"' ERR

[[ $EUID -eq 0 ]] || die 'Run as root: sudo ./install.sh'
[[ -r /etc/os-release ]] || die 'Cannot read /etc/os-release.'
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ok "Supported OS: ${PRETTY_NAME:-$ID}";; *) die "Unsupported OS ${PRETTY_NAME:-${ID:-unknown}}. Debian/Ubuntu only.";; esac
command -v apt-get >/dev/null || die 'apt-get not found.'

info 'Updating package indexes and installing sudo, smartmontools and jq...'
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y sudo smartmontools jq
SMARTCTL_PATH="$(readlink -f "$(command -v smartctl)")"
[[ -x "$SMARTCTL_PATH" ]] || die "smartctl not executable: $SMARTCTL_PATH"
ok "Dependencies ready; smartctl is $SMARTCTL_PATH"

id zabbix >/dev/null 2>&1 || die "The zabbix account does not exist. Install/configure Zabbix Agent 2 first."
if [[ -z "$AGENT_CONFIG" ]]; then
  for candidate in /etc/zabbix/zabbix_agent2.conf /usr/local/etc/zabbix_agent2.conf; do
    if [[ -f "$candidate" ]]; then AGENT_CONFIG="$candidate"; break; fi
  done
fi
if [[ -z "$AGENT_CONFIG" || ! -f "$AGENT_CONFIG" ]]; then
  warn 'Could not locate the Zabbix Agent 2 main configuration file.'
  read -r -p 'Enter full path to zabbix_agent2.conf: ' AGENT_CONFIG
fi
[[ -n "$AGENT_CONFIG" && -f "$AGENT_CONFIG" ]] || die 'The specified Agent 2 configuration file does not exist.'
[[ -r "$AGENT_CONFIG" && -w "$AGENT_CONFIG" ]] || die "Cannot read/write $AGENT_CONFIG."
ok "Using Agent 2 config: $AGENT_CONFIG"

[[ -f "$COLLECTOR_SRC" ]] || die "Collector missing from repository: $COLLECTOR_SRC"
bash -n "$COLLECTOR_SRC" || die 'Collector script has a shell syntax error.'
backup "$COLLECTOR_DST"
install -o root -g root -m 0755 "$COLLECTOR_SRC" "$COLLECTOR_DST"
ok "Installed collector at $COLLECTOR_DST"

backup "$SUDOERS_FILE"
printf 'zabbix ALL=(ALL) NOPASSWD: %s\n' "$SMARTCTL_PATH" > "$SUDOERS_FILE"
chown root:root "$SUDOERS_FILE"; chmod 0440 "$SUDOERS_FILE"
visudo -cf "$SUDOERS_FILE" || die 'Sudoers validation failed.'
visudo -c || die 'Global sudoers validation failed.'
ok 'Passwordless smartctl sudo permission configured and validated.'

mkdir -p "$FRAGMENT_DIR"
backup "$FRAGMENT"
backup "$AGENT_CONFIG"
cat > "$FRAGMENT" <<EOF2
# Managed by Zabbix SMART Full installer.
Plugins.Smart.Path=$SMARTCTL_PATH
UserParameter=smart.full.get[*],SMARTCTL_PATH=$SMARTCTL_PATH $COLLECTOR_DST "\$1"
EOF2
chown root:root "$FRAGMENT"; chmod 0644 "$FRAGMENT"
INCLUDE_LINE="Include=$FRAGMENT"
if ! grep -Fqx "$INCLUDE_LINE" "$AGENT_CONFIG"; then
  printf '\n# Include installed by Zabbix SMART Full\n%s\n' "$INCLUDE_LINE" >> "$AGENT_CONFIG"
fi
ok 'Agent 2 plugin path and UserParameter configured.'

if command -v zabbix_agent2 >/dev/null 2>&1; then
  info 'Validating Zabbix Agent 2 configuration...'
  zabbix_agent2 -T -c "$AGENT_CONFIG"
  ok 'Agent 2 configuration test passed.'
else
  warn 'zabbix_agent2 binary not found; skipped configuration test.'
fi
command -v systemctl >/dev/null || die 'systemctl not found; cannot restart Agent 2.'
systemctl list-unit-files zabbix-agent2.service --no-legend 2>/dev/null | grep -q zabbix-agent2 || die 'zabbix-agent2.service not found.'
systemctl restart zabbix-agent2
systemctl is-active --quiet zabbix-agent2 || die 'zabbix-agent2 did not become active.'
ok 'Zabbix Agent 2 restarted and is active.'
cat <<EOF3

============================================================
$APP installation completed
============================================================
Collector:      $COLLECTOR_DST
Agent config:   $AGENT_CONFIG
Agent fragment: $FRAGMENT
Sudoers:        $SUDOERS_FILE
smartctl:       $SMARTCTL_PATH
Install log:    $LOG

Test directly (replace the device path):
  sudo -u zabbix $COLLECTOR_DST /dev/disk/by-id/YOUR-DEVICE-ID

Test through Agent 2 (requires zabbix_get):
  zabbix_get -s 127.0.0.1 -k 'smart.full.get[/dev/disk/by-id/YOUR-DEVICE-ID]'

Import/link the matching Zabbix template separately; this installer
only configures the monitored host.
============================================================
EOF3
