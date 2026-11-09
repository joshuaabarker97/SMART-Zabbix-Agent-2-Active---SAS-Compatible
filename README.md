# SMART-Zabbix-Agent-2-Active---SAS-Compatible
A custom Zabbix 7.0 template built on the legacy SMART by Agent 2 template, adapted and designed to provide reliable SMART monitoring for SAS drives, while also supporting SATA and NVMe storage.

# Zabbix SMART Full

Automated host-side installation and collection support for the **SMART Zabbix Agent 2 Active - SAS Compatible** template.

This project installs a local collector and configures Zabbix Agent 2 to expose the complete `smartctl` JSON response through the item key:

```text
smart.full.get[/dev/disk/by-id/DEVICE]
```

The collector is designed for ATA/SATA, SCSI/SAS and NVMe devices supported by the installed `smartmontools` version. It retains the complete protocol-specific response under `raw` and exposes common normalized fields at the top level.

> **Template note:** The host-side installer does not import a template into the Zabbix server, create hosts, link templates, or configure discovery. Publish the matching template export in this repository (for example under `templates/`) or as a GitHub Release asset, and import/link it separately.

## Contents

- [Overview](#overview)
- [What the installer does](#what-the-installer-does)
- [Requirements and supported systems](#requirements-and-supported-systems)
- [Quick installation](#quick-installation)
- [Manual installation](#manual-installation)
- [How collection works](#how-collection-works)
- [Output format](#output-format)
- [Zabbix template setup](#zabbix-template-setup)
- [Testing and troubleshooting](#testing-and-troubleshooting)
- [Security considerations](#security-considerations)
- [Logging-backups-and-recovery](#logging-backups-and-recovery)
- [Uninstallation](#uninstallation)
- [Known limitations](#known-limitations)
- [Repository layout](#repository-layout)

## Overview

`smartctl` is the command-line utility supplied by `smartmontools`. It queries health and diagnostic information from supported storage devices. Zabbix Agent 2 normally runs as the unprivileged `zabbix` account, while access to some SMART information requires elevated privileges.

This project grants the `zabbix` account passwordless sudo permission for the installed `smartctl` executable, then calls it through a root-owned collection script. The collector:

1. Accepts one device path.
2. Checks that the path begins with `/dev/` and exists.
3. Executes `smartctl -x -j` using `sudo -n`.
4. Validates the returned JSON and `device.protocol` field.
5. Exposes normalized common fields.
6. Preserves the complete original response under `raw`.
7. Writes JSON to standard output and diagnostic errors to standard error.

The collector uses a read/query command. It does not start self-tests or perform disk writes, formatting, erasure, firmware updates or security operations.

## What the installer does

Run `install.sh` as root (normally using `sudo`). It:

1. Checks root privileges.
2. Detects the operating system. The current installer supports Debian and Ubuntu using `apt-get` and systemd.
3. Installs `sudo`, `smartmontools` and `jq`.
4. Checks that the operating-system account `zabbix` exists. It does not install Zabbix Agent 2 itself.
5. Detects the Agent 2 main configuration file. If it cannot find it, it prompts for the full path.
6. Installs `zabbix-smart-full.sh` to `/usr/local/bin/zabbix-smart-full.sh` as `root:root`, mode `0755`.
7. Creates `/etc/sudoers.d/zabbix-smartctl`, sets mode `0440`, and validates it with `visudo`.
8. Creates `/etc/zabbix/zabbix_agent2.d/smart-full.conf` containing the SMART plugin path and UserParameter.
9. Adds an explicit `Include=` for that fragment to the main Agent 2 config if needed.
10. Backs up existing managed files before replacing them.
11. Tests Agent 2 configuration when the `zabbix_agent2` binary is available.
12. Restarts `zabbix-agent2` and verifies that it is active.
13. Prints test commands and the installer log path.

The installer is intended to be safe to re-run. It does not alter disk contents. It does not automatically roll back every change after a late-stage failure; see [Logging, backups and recovery](#logging-backups-and-recovery).

## Requirements and supported systems

### Supported by this installer

- Debian or Ubuntu.
- `apt-get` and systemd.
- Zabbix Agent 2 already installed and configured.
- An operating-system `zabbix` account.
- Drives/controllers supported by the installed `smartmontools` version.

The installer does **not** install or register Zabbix Agent 2. The agent must already be installed and configured to communicate with the correct Zabbix server or proxy.

### Dependencies

| Package | Purpose |
|---|---|
| `smartmontools` | Supplies `smartctl` and protocol-specific SMART data |
| `sudo` | Allows the agent account to run the approved SMART query |
| `jq` | Validates and normalizes JSON |
| `git` | Clones this repository; install before cloning if necessary |

The installer installs `sudo`, `smartmontools` and `jq`. Git is needed before the installer can be downloaded via `git clone`.

## Quick installation

Install Git if it is not already installed:

```bash
sudo apt-get update
sudo apt-get install -y git
```

Clone the repository. Replace `OWNER/REPOSITORY` with the actual GitHub owner and repository name:

```bash
git clone https://github.com/OWNER/REPOSITORY.git
cd REPOSITORY
```

Run the installer:

```bash
sudo ./install.sh
```

If the installer cannot find the main Agent 2 configuration, it prompts:

```text
Enter full path to zabbix_agent2.conf:
```

Enter the real path, commonly `/etc/zabbix/zabbix_agent2.conf`.

The installer prints progress and errors to the terminal and logs them to:

```text
/var/log/zabbix-smart-full-install.log
```

### Verify installation

List stable device identifiers:

```bash
ls -l /dev/disk/by-id/
```

Test the collector directly as the Zabbix account:

```bash
sudo -u zabbix /usr/local/bin/zabbix-smart-full.sh /dev/disk/by-id/REPLACE_WITH_DEVICE_ID
```

It should return one compact JSON object. To test through Agent 2, install/use `zabbix_get` and run:

```bash
zabbix_get -s 127.0.0.1 -k 'smart.full.get[/dev/disk/by-id/REPLACE_WITH_DEVICE_ID]'
```

The direct collector test verifies the collection path even if `zabbix_get` is not installed.

## Manual installation

### 1. Install dependencies

```bash
sudo apt-get update
sudo apt-get install -y sudo smartmontools jq
```

### 2. Find smartctl

```bash
command -v smartctl
readlink -f "$(command -v smartctl)"
```

The usual Debian/Ubuntu path is `/usr/sbin/smartctl`.

### 3. Install the collector

Copy `zabbix-smart-full.sh` to `/usr/local/bin/zabbix-smart-full.sh`, then run:

```bash
sudo chown root:root /usr/local/bin/zabbix-smart-full.sh
sudo chmod 0755 /usr/local/bin/zabbix-smart-full.sh
```

### 4. Configure sudoers

Create `/etc/sudoers.d/zabbix-smartctl` with the actual resolved `smartctl` path:

```sudoers
zabbix ALL=(ALL) NOPASSWD: /usr/sbin/smartctl
```

Set permissions and validate:

```bash
sudo chown root:root /etc/sudoers.d/zabbix-smartctl
sudo chmod 0440 /etc/sudoers.d/zabbix-smartctl
sudo visudo -cf /etc/sudoers.d/zabbix-smartctl
sudo visudo -c
```

### 5. Configure Agent 2

Create `/etc/zabbix/zabbix_agent2.d/smart-full.conf`:

```ini
Plugins.Smart.Path=/usr/sbin/smartctl
UserParameter=smart.full.get[*],SMARTCTL_PATH=/usr/sbin/smartctl /usr/local/bin/zabbix-smart-full.sh "$1"
```

Ensure the main `/etc/zabbix/zabbix_agent2.conf` includes this fragment. Add the following if it is not already covered by an include:

```ini
Include=/etc/zabbix/zabbix_agent2.d/smart-full.conf
```

Validate and restart:

```bash
sudo zabbix_agent2 -T -c /etc/zabbix/zabbix_agent2.conf
sudo systemctl restart zabbix-agent2
sudo systemctl is-active zabbix-agent2
```

Substitute the actual main config path if different.

## How collection works

### Agent 2 UserParameter

The installer adds:

```ini
UserParameter=smart.full.get[*],SMARTCTL_PATH=/usr/sbin/smartctl /usr/local/bin/zabbix-smart-full.sh "$1"
```

The first parameter is the device path supplied in the Zabbix item key, for example:

```text
smart.full.get[/dev/disk/by-id/ata-DEVICE_SERIAL]
```

Use stable `/dev/disk/by-id/` paths where possible. Kernel names such as `/dev/sda` can change after hardware or boot-order changes.

### smartctl invocation

The collector runs:

```bash
sudo -n /usr/sbin/smartctl -x -j /dev/disk/by-id/DEVICE
```

- `-x` requests extended SMART/device information.
- `-j` requests JSON output.
- `sudo -n` prevents an interactive password prompt. If permissions are wrong, the query fails instead of hanging.

### smartctl exit status

`smartctl` uses a bitmask exit status. A non-zero status can mean the drive reports a health warning while still returning useful valid JSON. The collector therefore validates the JSON and protocol field independently of the command's exit code. This is deliberate: the monitoring system must still receive SMART data when the data reports a warning. The original code remains available as `raw.smartctl.exit_status`.

A missing response, invalid JSON or missing protocol field is treated as a collection failure.

### Protocol coverage

The original response is passed through under `raw`:

- **ATA/SATA:** ATA SMART attributes and device statistics where available.
- **SCSI/SAS:** grown defect list, error counter logs, SAS PHY details and other SCSI logs where available.
- **NVMe:** NVMe SMART/health log, critical warning bitmask, media/data integrity counters and other NVMe fields where available.

Not all drives, firmware versions, bridges or controllers expose every field. Missing protocol-specific fields must not be interpreted automatically as a fault.

## Output format

The collector returns a normalized object similar to this (illustrative values):

```json
{
  "protocol": "SCSI",
  "model": "Example drive model",
  "serial": "EXAMPLE123",
  "capacity_bytes": 8001563222016,
  "smart_available": true,
  "smart_enabled": true,
  "health": true,
  "temperature": 43,
  "power_on_hours": 42001,
  "raw": {
    "...": "complete original smartctl JSON response"
  }
}
```

| Field | Meaning |
|---|---|
| `protocol` | `ATA`, `SCSI`, `NVMe`, or the protocol reported by smartctl |
| `model` | Model name where reported |
| `serial` | Serial number where reported |
| `capacity_bytes` | Capacity in bytes where a recognized source field is available |
| `smart_available` | SMART support availability where reported |
| `smart_enabled` | SMART enabled state where reported |
| `health` | Overall SMART pass/fail state where provided |
| `temperature` | Temperature where a recognized field is available |
| `power_on_hours` | Power-on hours where a recognized field is available |
| `raw` | Complete original smartctl JSON response |

A normalized field can be `null` or unavailable if the drive/protocol does not provide a recognized field. Protocol-specific dependent items should read from `raw`.

Examples relevant to the template work:

- ATA reallocated sectors: `raw.ata_smart_attributes.table` → attribute ID `5` → `raw.value`.
- SCSI grown defect list: `raw.scsi_grown_defect_list`.
- NVMe critical warning: `raw.nvme_smart_health_information_log.critical_warning`.
- smartctl exit status: `raw.smartctl.exit_status`.
- Power-on hours: normalized `power_on_hours`, with protocol-specific fallback as needed.
- Capacity: normalized `capacity_bytes`.

The exact JSONPath/JavaScript preprocessing belongs in the Zabbix template. Do not assume ATA, SCSI and NVMe expose identical raw fields.

## Zabbix template setup

The intended template name is:

```text
SMART Zabbix Agent 2 Active - SAS Compatible
```

It is intended for Zabbix Agent 2 active checks and supports SATA/ATA, SAS/SCSI and NVMe devices where smartmontools can query them.

### Import and link

1. Obtain the matching template export from the project's GitHub repository or Releases.
2. In the Zabbix frontend, open **Data collection → Templates** (wording may vary by Zabbix version).
3. Select **Import** and choose the template export.
4. Review import options and complete the import.
5. Link the template to the host that has the installer deployed.
6. Confirm the host's Agent 2 active-check configuration and server/proxy connectivity.

### Discovery and master item

The template must discover the devices to monitor and pass the discovered device path to the master item key:

```text
smart.full.get[{#NAME}]
```

The discovery macro must resolve to a valid `/dev/...` path, preferably a stable `/dev/disk/by-id/...` path. The full JSON master item then feeds dependent items. This means one `smartctl` collection can supply multiple dependent metrics instead of launching a separate query for every metric.

### Protocol-aware dependent items

Protocol-specific items should check the top-level `protocol` field before reading protocol-specific paths. For example, an NVMe-only `critical_warning` item should discard/skip values for ATA and SCSI devices. ATA attribute IDs and SCSI log fields should likewise only be evaluated for the relevant protocol.

## Testing and troubleshooting

### Installer log

```bash
sudo less /var/log/zabbix-smart-full-install.log
```

### Agent service and journal

```bash
sudo systemctl status zabbix-agent2 --no-pager
sudo journalctl -u zabbix-agent2 -n 100 --no-pager
```

### Agent config syntax

```bash
sudo zabbix_agent2 -T -c /etc/zabbix/zabbix_agent2.conf
```

Use the actual config path if different.

### Sudoers check

```bash
sudo visudo -c
sudo -u zabbix sudo -n /usr/sbin/smartctl --version
```

The second command should run without prompting for a password. It checks permission to execute smartctl; it does not query a drive.

### Test smartctl directly

```bash
sudo /usr/sbin/smartctl -x -j /dev/disk/by-id/DEVICE | jq .
```

If this fails as root, investigate the device path, controller/bridge support, required smartctl device type/options or hardware access before troubleshooting Zabbix.

### Test collector output

```bash
sudo -u zabbix /usr/local/bin/zabbix-smart-full.sh /dev/disk/by-id/DEVICE | jq .
```

If it reports that sudo requires a password, inspect the sudoers file, its path, syntax, ownership and `0440` mode. If it reports invalid JSON, inspect the direct smartctl output and installed smartmontools version.

### Common issues

| Symptom | Checks |
|---|---|
| Agent config not found | Enter the full path when prompted; ensure it exists and is writable |
| `zabbix` user missing | Install/configure Zabbix Agent 2 first |
| `sudo: a password is required` | Check sudoers path, `visudo -c`, owner and mode |
| smartctl not found | Check `command -v smartctl` and plugin path |
| Device path not found | Use the current `/dev/disk/by-id/` path |
| Agent fails to restart | Run Agent 2 config test and inspect journal |
| JSON works but dependent item is unsupported | Check protocol-aware preprocessing and exact source JSON path |
| SMART attribute absent | Drive, firmware, bridge or controller may not expose it |

## Security considerations

SMART collection often requires elevated privileges. This project avoids running the whole Agent 2 service as root and instead uses a sudoers rule for the SMART utility.

### Privilege scope and sudoers

The installer creates a rule similar to:

```sudoers
zabbix ALL=(ALL) NOPASSWD: /usr/sbin/smartctl
```

The executable path is resolved on the host. The collector itself is installed as `root:root`, mode `0755`, so the `zabbix` user can execute it but cannot modify it.

**Important security trade-off:** this sudoers rule permits the `zabbix` account to execute that `smartctl` binary with arguments; it is not restricted to only the exact `-x -j` argument combination used by this collector. The collector only issues the read-only query and only accepts paths beginning `/dev/`, but an administrator should understand the broader permission. Do not grant interactive shell access to the `zabbix` account or expose arbitrary command execution through custom UserParameters.

For stricter command-level confinement, a separately reviewed root-owned wrapper and a sudoers rule restricted to that wrapper could be implemented. That hardened mode is not part of this initial installer.

### File permissions

| Path | Owner | Mode |
|---|---|---|
| `/usr/local/bin/zabbix-smart-full.sh` | `root:root` | `0755` |
| `/etc/sudoers.d/zabbix-smartctl` | `root:root` | `0440` |
| `/etc/zabbix/zabbix_agent2.d/smart-full.conf` | `root:root` | `0644` |
| `/var/log/zabbix-smart-full-install.log` | root | `0640` |

Do not make the sudoers file writable by the Zabbix user or other unprivileged accounts.

### Input validation

The collector accepts one device argument, requires it to start with `/dev/`, checks that the path exists and quotes it when invoking smartctl. It does not evaluate the path as shell code. Prefer stable device paths and do not pass untrusted input into the UserParameter.

### SMART data sensitivity

SMART output may contain model names, serial numbers, WWNs, capacity, power-on time, error counters and device identifiers. Restrict access to Zabbix data, dashboards, API tokens, exports and backups according to your organization's access policies.

### Network behavior

The collector does not open a listener or send SMART data to a third party. Zabbix Agent 2 communicates with the configured Zabbix server or proxy using the agent's existing network and security configuration.

### Trusting the installer

Review scripts before running them as root. Clone the official repository over HTTPS, verify release tags/checksums if supplied, and avoid running unreviewed branches or forks on production systems.

## Logging, backups and recovery

The installer writes to:

```text
/var/log/zabbix-smart-full-install.log
```

Before replacing existing managed files, it creates timestamped backups alongside them, for example:

```text
/etc/zabbix/zabbix_agent2.conf.bak.20261109-120000
```

If installation fails, inspect the log and backups before retrying. The installer reports the backup suffix in its error output. It does not automatically roll back every change after a late-stage service failure. Restore the relevant backups manually, remove the newly created include/fragment if appropriate, validate the configuration and restart Agent 2.

## Uninstallation

Review the files before removing them. The following removes the installed collector and managed configuration:

```bash
sudo rm -f /usr/local/bin/zabbix-smart-full.sh
sudo rm -f /etc/sudoers.d/zabbix-smartctl
sudo rm -f /etc/zabbix/zabbix_agent2.d/smart-full.conf
```

Remove this line from the main Agent 2 config if it was added by this installer:

```ini
Include=/etc/zabbix/zabbix_agent2.d/smart-full.conf
```

Then validate and restart:

```bash
sudo visudo -c
sudo zabbix_agent2 -T -c /etc/zabbix/zabbix_agent2.conf
sudo systemctl restart zabbix-agent2
```

Do not automatically remove `sudo`, `smartmontools` or `jq`; other services may depend on them.

## Known limitations

- Installer currently supports Debian and Ubuntu only.
- Zabbix Agent 2 must already be installed and configured.
- The installer configures the monitored host, not the Zabbix server/proxy, host objects, template links, discovery rules or monitoring intervals.
- The template export must be published with the project or as a release asset.
- SMART field availability varies by drive, firmware, controller, bridge and protocol.
- Some RAID controllers require controller-specific smartctl device arguments. This initial collector accepts a device path only and does not provide controller-specific argument mapping.
- A valid JSON response is returned even if smartctl's bitmask exit status is non-zero; the original value remains in `raw.smartctl.exit_status`.
- SMART monitoring does not replace backups, RAID monitoring, filesystem monitoring or regular drive health review.

## Repository layout

```text
.
├── README.md
├── install.sh
└── zabbix-smart-full.sh
```

## Contributing and issue reports

When reporting an issue, include the Linux distribution/version, Zabbix Agent 2 version, `smartctl --version`, drive protocol, relevant installer/journal error and a redacted sample of the JSON. Remove serial numbers, WWNs, hostnames and other identifying information before posting publicly.

## License

Add the project's chosen open-source license before publishing. No license is implied until a `LICENSE` file is included.
