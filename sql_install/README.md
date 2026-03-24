# SQL Server Silent Install — AAP Automation

Ansible automation for silently installing SQL Server 2019, 2022, or 2025
on Windows Server 2025 targets, orchestrated through Ansible Automation Platform (AAP).

---

## Repository Structure

```
sql_install/
├── install_sqlserver.yml              # Master playbook — AAP Job Template entry point
├── vars/
│   ├── common.yml                     # Shared defaults + credential env var lookups
│   ├── sql2019.yml                    # SQL 2019 paths, flags, and version label
│   ├── sql2022.yml                    # SQL 2022 paths, flags, and version label
│   └── sql2025.yml                    # SQL 2025 paths, flags, and version label
├── tasks/
│   ├── pre_install.yml                # Disk check, ISO validation, dir creation, script copy
│   ├── install.yml                    # PowerShell execution, log fetch, reboot fact
│   ├── reboot.yml                     # Conditional reboot (exit code 3010)
│   └── post_install.yml               # Service check, sqlcmd version validation
├── files/
│   └── Install-SQLServer.ps1          # PowerShell silent install script
├── credentials/
│   └── custom_credential_type.yml     # AAP credential type definition (reference)
└── README.md
```

---

## Prerequisites

### On AAP
- Windows Machine credential configured for WinRM access to target servers
- Custom credential type created (see `credentials/custom_credential_type.yml`)
- Credential instance created and attached to the Job Template
- Inventory group named `sql_servers` containing your Windows Server 2025 targets

### On Target Servers
- WinRM configured and accessible from AAP
- SQL Server ISO accessible at the UNC path defined in the version vars file
- D:\ drive with at least 20 GB free (or update `sql_data_dir`, `sql_log_dir`, `sql_backup_dir` in `vars/common.yml`)

### WinRM Quick Setup (run once per target)
```powershell
winrm quickconfig -q
winrm set winrm/config/service/auth '@{Basic="true"}'
winrm set winrm/config/service '@{AllowUnencrypted="false"}'
```

---

## AAP Job Template Configuration

| Setting            | Value                                              |
|--------------------|----------------------------------------------------|
| Inventory          | Group containing `sql_servers` hosts               |
| Playbook           | `install_sqlserver.yml`                            |
| Credentials        | Windows Machine credential + SQL Install credential |
| Verbosity          | 1 (Normal) recommended                             |

### Survey Question
Add a survey with the following question:

| Field     | Value                            |
|-----------|----------------------------------|
| Question  | SQL Server Version to Install    |
| Variable  | `sql_version`                    |
| Type      | Multiple Choice (single select)  |
| Choices   | `2019` / `2022` / `2025`         |
| Required  | Yes                              |

---

## Custom Credential Type

See `credentials/custom_credential_type.yml` for full instructions.

The credential injects these environment variables into each job run:

| Env Var            | Description                              |
|--------------------|------------------------------------------|
| `SQL_SA_PASSWORD`  | SA account password (masked in logs)     |
| `SQL_INSTANCE_NAME`| Target SQL instance name                 |
| `SQL_SECURITY_MODE`| `Windows` or `SQL` (mixed mode)          |
| `SQL_SHARE_USER`   | Domain account for ISO share access      |
| `SQL_SHARE_PASSWORD`| Password for ISO share account (masked) |

---

## ISO Share Setup

ISO files should be hosted on a central file share:

```
\\fileserver\sqlmedia\
├── 2019\
│   └── SQLServer2019.iso
├── 2022\
│   └── SQLServer2022.iso
└── 2025\
│   └── SQLServer2025.iso
```

Update the `sql_iso_path` values in each version vars file if your share path differs.

The install script handles:
- Mapping a network drive (`Z:`) using provided share credentials
- Mounting the ISO
- Running setup.exe silently
- Dismounting the ISO and unmapping the drive on completion

---

## Adding a New SQL Version

1. Copy `vars/sql2025.yml` to `vars/sql2027.yml`
2. Update `sql_version`, `sql_version_label`, `sql_iso_path`, `sql_iso_filename`, and `sql_setup_log_path`
3. Add `'2027'` to the AAP Survey choices
4. Add `'2027'` to the assert list in `install_sqlserver.yml` pre_tasks

No other files need to change.

---

## Exit Codes

| Code   | Meaning                              |
|--------|--------------------------------------|
| `0`    | Success                              |
| `3010` | Success — reboot required            |
| Other  | Failure — check Setup Bootstrap logs |

Setup logs on target: `C:\Program Files\Microsoft SQL Server\<version>\Setup Bootstrap\Log\`

---

## Security Notes

- SA password and share password are injected as masked environment variables — never appear in job output or vars files
- `no_log: true` is set on the install task to prevent argument values from being logged
- Use separate credential instances per environment (DEV / UAT / PROD)
- Grant operators "Use" permission on credentials without "View" permission
