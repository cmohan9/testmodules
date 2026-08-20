# CyberArk Service Account Onboarding — Dependency Prerequisites Guide

**Purpose:** This document outlines the information and server-level configuration users must provide/complete before CyberArk can onboard a service account and its dependent accounts (Windows Service, Scheduled Task, or IIS Application Pool).

---

## 1. Base Onboarding Requirements (All Account Types)

Before any dependency configuration, the CyberArk team requires the following from the user:

| # | Requirement | Description |
|---|---|---|
| 1 | **Safe Details** | Existing safe name, or a new safe creation request. A Safe is a secure logical container in CyberArk that restricts access based on granular, role-based permissions. |
| 2 | **Username** | The ID of the privileged account being protected (e.g., Domain Admin, Root, System Administrator). |

Optionally, an account can be **tagged with a dependent account type**, enabling automatic password rotation without manual follow-up. There are **three supported dependency types**:

1. Windows Services
2. Scheduled Tasks
3. IIS Application Pool

---

## 2. Dependency Type Details & Required Fields

### 2.1 Windows Services

Represents services accessed from a target machine that require the same credentials as that machine.

| Field | Description | Acceptable Values |
|---|---|---|
| Service Name | Exact service name (not display name) whose password is updated | Valid service name |
| Address | IP or hostname of the target machine | IP / hostname |
| Restart Service | Whether to restart the service after password update | Yes / No |

### 2.2 Scheduled Task

CyberArk links the task as a dependent account. When the main account's password rotates, CPM updates the "Run as" credential in Task Scheduler so the task doesn't fail.

| Field | Description |
|---|---|
| Task Name | Name of the task running on the server |
| Address | IP or hostname of the target machine |
| Task Folder | Folder path, if applicable |

**Key benefit:** Prevents "broken task" service interruptions caused by password mismatches after rotation.

### 2.3 IIS Application Pool

Enables automatic management/rotation of passwords for service accounts running IIS web applications (supports IIS 10.0+ / Windows Server 2019, 2022, 2025).

| Field | Description |
|---|---|
| Platform Name | IIS Application Pool |
| Device Type | Confirmed by user |
| Safe | Assigned by CyberArk team based on request |
| Application Pool | Confirmed by user |
| Address | IP or hostname of the target machine |
| Restart Service | Yes / No |

**Access requirement:** The account used to access the remote machine must be a local or domain user in the **Administrators group**, with rights on the WMI `root\microsoftiisv2` namespace:
1. Open Computer Management → right-click **WMI Control** → **Properties**
2. **Security** tab → select **MicrosoftIISv2** namespace → **Security**
3. Select the user who will run the plugin → grant all permissions → **OK**

---

## 3. Target Machine — Server-Level Prerequisites (User Responsibility)

### 3.1 Windows Services — Server Configuration Checklist

**General connectivity**
- [ ] WinRM is enabled
- [ ] Firewall allows: WMI, SMB, Remote Service Management

**Account details**
- [ ] Service account exists (`domain\svc_account` or local account)
- [ ] Account is not locked or expired
- [ ] Password is known (required only for initial onboarding)

**Required rights**
- [ ] "Log on as a service" — *Local Security Policy → Local Policies → User Rights Assignment*
- [ ] Permission to run the service
- [ ] Access to required application folders / DB / network shares

**Required details to submit**
- Service Name (exact, not display name)
- Server hostname
- Current service logon account

**Configuration checks (via `services.msc`)**
- [ ] Service is running under the intended account
- [ ] Startup type set to **Automatic** (recommended)
- [ ] Service starts successfully when triggered manually

**Service dependency information to submit (per service)**
- Service Name
- Server Name
- Dependent type: Windows Service
- Whether restart is allowed after password change (Yes/No)

**Remote management enablement**
- [ ] WinRM enabled — run: `Enable-PSRemoting -Force`

**Firewall rules to allow**
- [ ] Remote Service Management
- [ ] Windows Management Instrumentation (WMI)
- [ ] File and Printer Sharing (SMB)

**Permissions for password rotation**
- If self-managed: account must be allowed to change its own password
- If admin-managed: provide local admin or domain privileged account with rights to update service configuration

**Service restart behavior (critical — avoids outages)**
- [ ] Can the service be restarted after password change?
- [ ] Is downtime allowed?
- [ ] Are there dependent downstream services?
- Restart options: **Immediate restart / Scheduled restart / No restart (requires coordination)**

**Required ports**

| Purpose | Port |
|---|---|
| RPC | 445, 135 |
| WinRM | 5985 / 5986 |
| HTTPS access | 443 |
| Linux systems | 22 |

---

### 3.2 Scheduled Task — Server-Level Configuration Checklist

- [ ] Scheduled Task runs under the **CyberArk-managed service account** (not a personal/admin ID)
- [ ] "Log on as a batch job" right granted — *Local Security Policy → User Rights Assignment → Log on as a batch job*, add `DOMAIN\ServiceAccount`
  > Task **will fail** to run without this right.

**Password handling**
- [ ] Password is managed/rotated by CyberArk, and the scheduled task stays in sync
- [ ] Confirm sync method: automatic update from CyberArk, or manual update by the user

**Local server permissions for the account (minimum required)**
- [ ] Log on as a batch job
- [ ] Read/execute access to scripts or applications
- [ ] Access to required folders
- [ ] Local administrator rights (if needed)

**CyberArk component connectivity**
- [ ] Server can reach CyberArk Vault (credential retrieval)
- [ ] Server can reach CPM server
- [ ] Safe permissions are correctly assigned

**Other server checks**
- [ ] Server time is synchronized with the domain (prevents auth/task failures)
- [ ] Script/executable path used by the task exists on the server and is accessible/permissioned for the service account

> **Note:** Incorrect server-level configuration may cause task failure or desynchronization with CyberArk.

**Required ports**

| Purpose | Port |
|---|---|
| CyberArk Vault communication | 1858 |
| Windows password management | 445, 135 |
| Linux systems | 22 |
| Authentication services | 389 (LDAP), 53 (DNS) |
| HTTPS | 443 |

---

### 3.3 IIS Application Pool — Server-Level Configuration Checklist

**1. Application Pool Identity**
- [ ] IIS Manager → Application Pools → *Target Pool* → Advanced Settings → Process Model → Identity → set the account that runs the pool

**2. Website Authentication**
- [ ] Default Web Site → Authentication → enable **Windows Authentication**
- [ ] Providers → ensure **Negotiate** is present and moved to the top of the list

**3. useAppPoolCredentials**
- [ ] Default Web Site → Configuration Editor → `system.webServer/security/authentication/windowsAuthentication`
- [ ] Set `useAppPoolCredentials = True`

**4. WMI Control Settings (OS-level)**
- [ ] Computer Management → Services and Applications → WMI Control → Properties → Security tab
- [ ] Select **MicrosoftIISv2** → grant the Application Pool account **Full Permissions**
- [ ] If direct permission assignment isn't possible, add the account to the local **Administrators** group instead

**5. (Optional) Manual WMI connectivity test — performed by CyberArk team from the CPM server**
- [ ] Run `wbemtest` (Start → Run → wbemtest)
- [ ] Connect to namespace: `\\<Target Server>\root\microsoftiisv2`
- [ ] Enter credentials as `domain\username`
- [ ] Set Authentication Level to **Packet Privacy**
- [ ] Click Connect → Enum Classes → OK
- [ ] Success indicator: approximately **12 objects** returned

---

## 4. Summary — What the User Must Provide vs. Configure

| Category | Provide to CyberArk | Configure on Server |
|---|---|---|
| **All accounts** | Safe details, Username | — |
| **Windows Service** | Service Name, Address, Restart option | WinRM, firewall rules, "Log on as a service", startup type, folder/DB access |
| **Scheduled Task** | Task Name, Address, Task Folder | "Log on as a batch job", CyberArk Vault/CPM connectivity, script path access, time sync |
| **IIS App Pool** | Platform Name, Device Type, Application Pool, Address, Restart option | App Pool identity, Windows Auth + Negotiate, useAppPoolCredentials, WMI permissions |

---

*Document compiled from CyberArk service account onboarding process notes.*
