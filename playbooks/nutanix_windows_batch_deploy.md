# Nutanix Windows Batch Deploy Playbook

## Overview

`nutanix_windows_batch_deploy.yml` is the master orchestration playbook for provisioning one or more Windows Server VMs on a Nutanix AHV cluster, assigning static IP addresses, configuring storage volumes, and installing SQL Server — all driven from a single AAP Job Template survey.

The playbook runs entirely on `localhost` and delegates work to the target VMs by launching downstream AAP Job Templates against a dynamically created inventory.

## Execution Flow

```
 1. Parse disk layout survey input
 2. Resolve Nutanix ext_ids (cluster, subnet, image)
 3. Build VM name list from prefix + count
 4. Generate sequential IP list from starting IP
 5. Validate IPs are not already in use (ping)
 6. Build disk specs (OS disk + data disks)
 7. Create VMs in parallel (async)
 8. Wait for all VM creates to finish
 9. Power on VMs
10. Register VMs into a new AAP inventory
11. Launch "Wait for WinRM on SQL Servers"
12. Launch "Configure Static IP"
13. Launch "Verify Static IP"
14. Launch "Configure SQL Server Volumes and Mount Points"
15. Launch "Install SQL Server"
```

## Survey Variables

These variables are expected to be provided via an AAP Job Template survey or `extra_vars`.

| Variable | Type | Example | Description |
|---|---|---|---|
| `vm_prefix` | string | `YOURVM` | Hostname prefix; VMs are named `<prefix>01`, `<prefix>02`, etc. |
| `vm_count` | integer | `3` | Number of VMs to create |
| `cluster_name` | string | `PHX-POC123` | Nutanix cluster name |
| `subnet_name` | string | `Primary` | Nutanix AHV subnet name |
| `template_name` | string | `Win2025-Template` | Nutanix image/template name to clone |
| `storage_container_uuid` | string | `abc-123-...` | UUID of the Nutanix storage container for data disks |
| `vm_sockets` | integer | `2` | Number of CPU sockets per VM |
| `vm_cpu` | integer | `2` | Cores per socket |
| `vm_memory_gb` | integer | `16` | RAM in GB |
| `disk_layout` | textarea | `1,50,E\n2,30,F` | Newline-separated disk entries: `index,size_gb,letter[,mount_point]` |
| `starting_ip` | string | `10.21.159.50` | First IP address in the sequential range |
| `domain_name` | string | `jvh.local` | Active Directory domain for join and FQDN |
| `domain_join_username` | string | `admin` | Domain join account |
| `sql_version` | string | `2022` | SQL Server version (`2019`, `2022`, or `2025`) |
| `sql_data_dir` | string | `E:\SQLData` | SQL Server data directory |
| `sql_userdb_dir` | string | `E:\SQLData` | User database file directory |
| `sql_userdb_log_dir` | string | `F:\SQLLogs` | User database log directory |
| `sql_temp_dir` | string | `E:\SQLTempDB` | TempDB data directory |
| `sql_tempdb_log_dir` | string | `F:\SQLTempDBLogs` | TempDB log directory |
| `aap_inventory_name` | string | `SQL-Batch` | Base name for the dynamically created AAP inventory |

## Hardcoded Defaults

These are set in the playbook `vars` section and can be overridden via survey or `extra_vars`:

| Variable | Default | Description |
|---|---|---|
| `subnet_mask` | `255.255.255.0` | Subnet mask applied to static IPs |
| `gateway` | `10.21.153.1` | Default gateway applied to static IPs |
| `dns_servers` | `10.21.159.11,10.21.159.12` | Comma-separated DNS server list |

## Credentials (injected via environment variables)

| Environment Variable | Source |
|---|---|
| `NUTANIX_PASSWORD` | Nutanix credential |
| `WIN_ADMIN_PASSWORD` | Windows local admin credential |
| `WIN_DOMAIN_JOIN_PASSWORD` | Domain join credential |
| `CONTROLLER_HOST` | AAP controller connection |
| `CONTROLLER_USERNAME` | AAP controller connection |
| `CONTROLLER_PASSWORD` | AAP controller connection |

## Downstream Job Templates

The playbook launches these AAP Job Templates in sequence. Each must exist before running the batch deploy.

### 1. Wait for WinRM on SQL Servers

Waits until WinRM (port 5985) is responsive on every VM in the inventory. Blocks until all VMs are reachable.

### 2. Configure Static IP

**Playbook:** `configure_static_ip.yml`

Schedules a static IP change on each VM via a Windows Scheduled Task. The task fires ~8 seconds after creation, which allows the WinRM call to return cleanly before the adapter address changes. This avoids the WinRM session drop that would otherwise cause a task failure.

**Extra vars passed:** `vm_ip_map`, `subnet_mask`, `gateway`, `dns_servers`

### 3. Verify Static IP

**Playbook:** `verify_static_ip.yml`

Runs on `localhost` and pings each VM's new static IP in a retry loop (up to 30 × 5 seconds = 2.5 minutes) to confirm the IP change took effect before proceeding.

**Extra vars passed:** `vm_ip_map`

### 4. Configure SQL Server Volumes and Mount Points

Partitions, formats, and mounts the data disks defined in `disk_layout` on each VM.

**Extra vars passed:** `parsed_disks`, `sql_userdb_dir`, `sql_userdb_log_dir`, `sql_temp_dir`, `sql_tempdb_log_dir`, `sql_data_dir`

### 5. Install SQL Server

Runs the SQL Server silent installer on each VM using the version specified by `sql_version`.

**Extra vars passed:** `sql_userdb_dir`, `sql_userdb_log_dir`, `sql_temp_dir`, `sql_tempdb_log_dir`, `sql_data_dir`

## Guest Customization

VMs are provisioned with a Sysprep unattend.xml (`unattend.xml.j2`) that handles:

- Setting the computer name from the VM name list
- Joining the Active Directory domain
- Setting the local Administrator password
- Copying and running `EnableWinRM.ps1` from a network share (`\\10.21.159.220\c$\scripts`)
- Disabling Windows Firewall (all profiles)

## Static IP Strategy

Generating and assigning IPs follows a three-phase approach:

1. **Generate** — sequential IPs are calculated from `starting_ip` using `vm_count` (e.g., `.50`, `.51`, `.52`)
2. **Validate** — each candidate IP is pinged before any VMs are created; the playbook fails immediately if any IP is already in use
3. **Apply** — after VMs are up and WinRM is ready, the IP change is scheduled via a delayed Windows Scheduled Task to avoid dropping the WinRM session
4. **Verify** — a separate localhost play pings the new IPs in a retry loop to confirm the change took effect
