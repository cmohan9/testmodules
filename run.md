# CyberArk Privileged Cloud & Secure Cloud Access Dashboard

**Prepared for:** [TBD]
**Prepared by:** [TBD]
**Author(s):** [TBD]
**Version:** v1.0
**Date:** 26th Aug 2026

---

## Version Control

| Version | Date | Author | Change Description | Approver |
|---|---|---|---|---|
| 1.0 | 26th Aug 2026 | [TBD] | Initial Draft | |
| | | | | |
| | | | | |

---

## Contents

1. [Executive Summary](#1-executive-summary)
2. [The PowerShell Export Script](#2-the-powershell-export-script)
   - 2.1 Purpose
   - 2.2 Output data set
   - 2.3 Key classification flags computed by the script
   - 2.4 How the script is structured (for maintaining it)
   - 2.5 The Archive folder and historical snapshots
3. [The Power BI Dashboard](#3-the-power-bi-dashboard)
   - 3.1 Columns required in the data model, per source file
   - 3.2 Reference DAX for the core KPIs
4. [Migration to Azure Function App](#4-migration-to-azure-function-app)
   - 4.1 Problem statement: why the original process needed to change
   - 4.2 The solution: Azure Function App
   - 4.3 Azure resources provisioned
   - 4.4 Configuration — Application Settings (Environment Variables)
   - 4.5 Build status
5. [Access to Azure Resources](#5-access-to-azure-resources)
6. [Expected Cost Estimation for Azure Resources](#6-expected-cost-estimation-for-azure-resources)
   - 6.1 Estimated cost
   - 6.2 Azure Functions – Flex Consumption (compute)
   - 6.3 Blob Storage
   - 6.4 Application Insights (logging/monitoring)
   - 6.5 Total Services and the cost estimates
7. [References](#7-references)

---

## 1. Executive Summary

This implementation delivers automated, scheduled reporting on CyberArk Privileged Cloud (PAM) safe/account inventory, compliance, and Secure Cloud Access (SCA) policy status through a Power BI dashboard. The solution has gone through two complete implementation stages:

- A standalone PowerShell script (`PAM_SCA_Dashboard_Final.ps1`) was developed to authenticate to CyberArk and collect data from both the Privilege Cloud API and the Secure Cloud Access API. The script generates the CSV dataset used by the Power BI dashboard.
- To enhance automation, reliability, and maintainability, the same functionality was subsequently implemented as a serverless Azure Function App. This approach removes the dependency on a dedicated server and local scheduled tasks while retaining the existing Power BI dashboard, including its data model, measures, and visualizations. The Azure Function App has been successfully validated against live CyberArk data, with only the backend data pipeline being modernized.

This document provides a comprehensive reference for both stages, detailing what was delivered and its current operational model.

**Related documents:**

| Document | Covers |
|---|---|
| `PAM_SCA_Dashboard_Final.ps1` (repo root) | The original on-prem PowerShell export script |
| `AzureFunction/DashboardExport/run.ps1` (repo) | The Azure Function version of the same script |
| `Antigravity_Dashboard_Guide_V13.md` | Power BI DAX measures, relationships, and visual configuration |
| `Technical_Documentation_V1.md` | Full line-by-line technical walkthrough of both script versions, module by module |

---

## 2. The PowerShell Export Script

### 2.1 Purpose

The script (`PAM_SCA_Dashboard_Final.ps1`) authenticates once to CyberArk — a single OAuth2 token, reused for both the Privilege Cloud API and the Secure Cloud Access API, since they share the same Identity tenant — pulls the full Safe, Account, User, and Vault Component inventory plus Secure Cloud Access policies, and produces **seven CSV files** that together form the data source for the Power BI dashboard.

### 2.2 Output Data set

| File | Grain | Purpose |
|---|---|---|
| `DIM_Region.csv` | One row per region (7 rows, incl. catch-alls) | Region dimension feeding relationships and slicers |
| `DIM_Safe.csv` | One row per Privilege Cloud safe (30 columns) | Safe inventory — classification, compliance-naming, empty-safe detection |
| `FACT_Accounts.csv` | One row per privileged account (41 columns) | The core fact table — compliance, rotation, verification, staleness, classification |
| `FACT_Users.csv` | One row per Privilege Cloud user (18 columns) | User inventory — active/dormant/component classification |
| `FACT_VaultConnectivity.csv` | One row per vault component instance (7 columns) | CPM/PSM/AIM connectivity health |
| `FACT_OnboardingTrend.csv` | One row per calendar month, last 12 months (7 columns) | Account/safe onboarding trend, built as a continuous month range (no gaps, even for a month with zero onboarding) |
| `SCA_Policies.csv` | One row per Secure Cloud Access policy (18 columns) | SCA policy inventory, status, and cloud-provider breakdown |

A `_RunMetadata.json` is also written alongside the CSVs on every run — not a dashboard data source, but a run-status record (duration, per-table record counts, and any errors).

### 2.3 Key classification flags computed by the script

Unlike a design where the script pre-computes final KPI percentages, this pipeline deliberately keeps that math in Power BI DAX (see 3.2) — the script's job is to compute the **per-row classification flags** those DAX measures are built on:

| Flag | Table | Meaning |
|---|---|---|
| `ComplianceStatus` | FACT_Accounts | Compliant / Non-Compliant / Pending-Unknown, from the CPM's own status |
| `RotationOverdue` | FACT_Accounts | Days since last password change exceeds the platform's expected rotation policy |
| `VerifyStatus` | FACT_Accounts | Verified / Overdue / Never Verified / N/A (Manual), from the account's verification history |
| `IsStale` | FACT_Accounts | No password change within the configured staleness window (default 90 days) |
| `LoginStatus` | FACT_Users | Active / Dormant / Never Logged In, from days since last successful login |
| `IsEmpty` | DIM_Safe | Safe has zero accounts (corrected from the real account count, not the Safes API's own field — see Technical_Documentation_V1.md §6.1) |

These thresholds (30-day login/onboarding window, 90-day staleness, 7-day verification window) are configurable at the top of the script, not hard-coded into the logic.

### 2.4 How the script is structured (for maintaining it)

1. **Module 1 (Configuration)**: CyberArk credentials, thresholds (login/onboarding/staleness/verification windows), default/system-object exclusion lists, naming-convention code maps (region, environment, technology, access type, team), platform classification patterns, rotation policy map, vault component list, SCA status/cloud-provider reference maps.
2. **Module 2 (Helpers)**: authentication (one token, shared by both PAM and SCA calls, auto-refreshed on expiry), logging, and paginated/retrying HTTP GET wrappers for both APIs.
3. **Module 3 (Classification functions)**: pure functions that turn a safe or account **name** into Region/Tier/SafeType/Environment/Technology/AccessType/Team/SafePurpose tags — no API calls, fully unit-testable in isolation.
4. **Module 4 (PAM data collection)**: Safes → `DIM_Safe`, Users → `FACT_Users`, Accounts → `FACT_Accounts`, Vault Connectivity → `FACT_VaultConnectivity`, Onboarding Trend → `FACT_OnboardingTrend`, plus the static `DIM_Region` dimension.
5. **Module 5 (SCA data collection)**: Access Policies → `SCA_Policies`.
6. **Module 6 (CSV export)**: writes all 7 files to a `Latest\` folder — table-driven, so adding a new table is a one-entry change, not a copy-pasted block.
7. **Module 7 (Run summary)**: archives this run's output into a timestamped `Archive\` folder, writes `_RunMetadata.json`, and prints a console summary; the run log is written to `DashboardExport.log`.

This structure keeps the business logic, classification rules, and the 7-file output contract each in one clearly labeled place.

### 2.5 The Archive folder and historical snapshots

Every run overwrites the 7 files in `Latest\` with the current data, **and** writes an identical, timestamped copy of all 7 files into `Archive\<yyyyMMdd_HHmmss>\`. `Latest\` always reflects only the most recent run; `Archive\` accumulates one full set of files per run, forever — it is the complete run history of the pipeline, not just a backup of the last one.

Unlike a design where a trend metric is computed by *diffing* two archived snapshots, `FACT_OnboardingTrend` in this pipeline is built directly from each account's creation date within the **current** run alone — it does not depend on any prior archived snapshot to compute correctly. `Archive\` exists purely so a specific prior day's full data set can be looked back at if needed; no current dashboard metric depends on it.

In the Azure Function version, `Archive` is a Blob Storage container (same name, same one-timestamped-folder-per-run pattern) instead of a local folder. One operational note for the Azure version specifically: nothing currently prunes old archive blobs, so the container's size grows indefinitely with every run — worth a periodic review, though not a problem at current data volumes (see §6.3).

---

## 3. The Power BI Dashboard

The dashboard's full DAX measure library, table relationships, and visual layout are documented in detail separately in `Antigravity_Dashboard_Guide_V13.md`.

This section summarizes, at a project level, the columns each CSV needs to expose to the data model and the reference DAX for the core KPIs.

### 3.1 Columns required in the data model, per source file

Each CSV becomes one table in the Power BI data model. The full column set should be loaded for each, since the DAX measures in 3.2 and the dashboard's visuals draw on all of them — see `Technical_Documentation_V1.md`, Appendix A for the complete list per table. Join keys: `SafeName` links `FACT_Accounts` ↔ `DIM_Safe`; `Region` links `FACT_Accounts`/`DIM_Safe` ↔ `DIM_Region`. `FACT_Users`, `FACT_VaultConnectivity`, `FACT_OnboardingTrend`, and `SCA_Policies` are intentionally self-contained, with no relationships to the other tables.

### 3.2 Reference DAX for the core KPIs

```dax
Business Accounts =
CALCULATE(COUNTROWS(FACT_Accounts), FACT_Accounts[IsDefaultSafe] = "FALSE")

Business Safes =
CALCULATE(COUNTROWS(DIM_Safe), DIM_Safe[IsDefault] = "FALSE")

Rotation Overdue =
CALCULATE(COUNTROWS(FACT_Accounts),
    FACT_Accounts[RotationOverdue] = "TRUE",
    FACT_Accounts[IsDefaultSafe] = "FALSE")

Compliant Accounts =
CALCULATE(COUNTROWS(FACT_Accounts),
    KEEPFILTERS(FACT_Accounts[ComplianceStatus] = "Compliant"),
    FACT_Accounts[IsDefaultSafe] = "FALSE")

Compliance Rate % = DIVIDE([Compliant Accounts], [Business Accounts], 0) * 100

Active Users =
CALCULATE(COUNTROWS(FACT_Users),
    FACT_Users[IsComponent] = "FALSE",
    CONTAINSSTRING(FACT_Users[LoginStatus], "Active"))

Empty Safes =
CALCULATE(COUNTROWS(DIM_Safe), DIM_Safe[IsEmpty] = "TRUE", DIM_Safe[IsDefault] = "FALSE")

Vault Components Total = COUNTROWS(FACT_VaultConnectivity)

Vault Connectivity % =
DIVIDE(
    CALCULATE(COUNTROWS(FACT_VaultConnectivity), FACT_VaultConnectivity[IsLoggedOn] = "TRUE"),
    [Vault Components Total], 0) * 100

SCA Total Policies = COUNTROWS(SCA_Policies)

SCA Active Policies =
CALCULATE(COUNTROWS(SCA_Policies), SCA_Policies[StatusLabel] = "Active")
```

---

## 4. Migration to Azure Function App

### 4.1 Problem statement: why the original process needed to change

The original operational process was:

1. The PowerShell script ran on a server, fired by a locally-configured scheduled task.
2. The script wrote its CSV output to that server's local disk (`Latest\`/`Archive\`).
3. Power BI connected to that local folder to pick up the files for refresh.

This worked, but carried real operational overhead:

- A dedicated server to keep running, patched, and accessible.
- A scheduled cloud refresh in the Power BI Service against a local folder requires an on-premises data gateway tied to that specific server — another moving part to keep online.
- No centralized monitoring or logging — diagnosing a failed run meant checking that server's local log file directly.
- Credentials and script logic living on that server, with the usual access-management and change-tracking overhead that implies.

### 4.2 The solution: Azure Function App

The Azure Function App is the migrated version: the same business logic (module-for-module identical — verified directly against the on-prem script's own test suite during migration), running on a schedule as an Azure Function, writing the same 7 CSVs to Blob Storage instead of a local disk. The original on-prem script is kept as-is for reference/fallback.

Power BI connects to Blob Storage natively — this also means a scheduled refresh in the Power BI Service no longer needs an on-premises data gateway.

### 4.3 Azure resources provisioned

| Resource | Name | Purpose |
|---|---|---|
| Resource Group | [TBD] | Contains all resources for this project |
| Region | East US | |
| Function App | `pam-dashboard-func01` | Hosts and runs the export on schedule (Flex Consumption plan, PowerShell 7.4) |
| Function App's own storage | [TBD — auto-provisioned by Azure] | Platform-internal use only — not used for dashboard data |
| Dedicated data storage account | `pamdashboarddata01` | Holds the CSV output (`latest`, `archive`, `logs` containers) — this is what Power BI connects to |

**Function App configuration:**
- Hosting plan: Flex Consumption
- Runtime: PowerShell 7.4
- Function timeout: 30 minutes
- Instance size: 2048 MB
- Application Insights: provisioned at Function App creation, but **not currently accessible to the project team** for viewing logs — this is why the pipeline also writes its own per-run log directly to Blob Storage (the `logs` container) as the primary operational visibility mechanism; see §7's quick-reference table.
- System-assigned Managed Identity: not used — credentials and storage access are both handled via Application Settings (a connection string), not identity-based permissions.

### 4.4 Configuration — Application Settings (Environment Variables)

All configuration (CyberArk credentials, tenant subdomains, storage location) is externalized into the Function App's Environment Variables, rather than hard-coded in the script — this is what allows the identical script logic to run in any environment without code changes.

| Setting | Purpose |
|---|---|
| `IDENTITY_TENANT_ID` | CyberArk Identity tenant ID |
| `SERVICE_USER_ID` | Service account client ID for the OAuth2 grant |
| `SERVICE_USER_SECRET` | Service account secret |
| `SUBDOMAIN` | Privilege Cloud tenant subdomain |
| `SCA_SUBDOMAIN` | Secure Cloud Access tenant subdomain |
| `PamDataStorage` | Connection string for the dedicated data storage account (`pamdashboarddata01`) — this is how the Function writes the CSV output |
| `LATEST_CONTAINER` / `ARCHIVE_CONTAINER` / `LOGS_CONTAINER` | Optional overrides for the Blob container names (default: `latest`, `archive`, `logs`) |

```
AzureFunction/                     # Open THIS folder in VS Code for deployment
├── host.json                      # functionTimeout set to 30 minutes
├── profile.ps1                    # Sets TLS 1.2 once per instance start
├── requirements.psd1              # Empty {} (no external modules)
└── DashboardExport/
    ├── function.json              # Timer trigger config
    └── run.ps1                    # The entire export script, self-contained
```

### 4.5 Build status

| Item | Status |
|---|---|
| Azure Function App built, deployed, and validated against live CyberArk data | Complete |
| Automated weekly schedule | Configured — runs every Monday 5:00 AM |
| Blob container naming and log-upload issues found during validation | Resolved (see `Technical_Documentation_V1.md` §6 for the full list) |

---

## 5. Access to Azure Resources

To obtain access to the Azure resources, including the Function App and Storage Accounts, an SCA access request must be submitted for the following Entra ID group:

**[TBD]**

---

## 6. Expected Cost Estimation for Azure Resources

> **This section is structured to match a completed cost analysis but is awaiting two real inputs before the numbers can be filled in:**
> 1. **Actual execution duration per run** — read the `DurationSeconds` field from any `_RunMetadata.json` in the `latest` container.
> 2. **Actual total size of the 7 CSVs** — check blob properties for each file in the `latest` container via the Portal (or Storage Explorer).
>
> Once those two figures are available, the tables below can be completed the same way the equivalent EPM cost analysis was — by running each number through Azure's published Flex Consumption / Blob Storage / Application Insights rates and comparing against the standing monthly free-tier allowances.

### 6.1 Estimated cost

*[Pending real usage figures — see note above. Based on the assumptions structure below, this is very likely to land at or near $0.00/month given a weekly run cadence, matching the pattern seen on the comparable EPM pipeline.]*

| Assumption | Value / Frequency | Source |
|---|---|---|
| Run frequency | Weekly (52 runs/year ≈ 4.33 runs/month) | Current `function.json` schedule |
| Execution duration | *[TBD — from `_RunMetadata.json`]* | |
| Function instance size | 2048 MB (2 GB) | Function App configuration |
| Always-ready instances | 0 (pure on-demand, scales to zero when idle) | Not configured |
| Data written per run | *[TBD — sum of the 7 CSV blob sizes + log + metadata]* | |
| Write pattern | Every run overwrites `latest/` (doesn't accumulate) and adds a new timestamped copy to `archive/` and `logs/` (accumulates every run) | |
| Region | East US, both storage accounts and the Function App co-located | Resource inventory |

### 6.2 Azure Functions – Flex Consumption (compute)

| Metric | Rates defined by Microsoft | Our usage | Cost |
|---|---|---|---|
| Execution time | $0.000026/GB-s (on-demand) | 2 GB × *[TBD]*s × 4.33 runs/mo | *[TBD]* |
| Executions | $0.40 per million | ~4.33 executions/month | Free grant covers it |
| Always-ready baseline | $0.000004/GB-s | Not used (0 always-ready instances) | $0 |
| Monthly free grant | 100,000 GB-s + 250,000 executions (per subscription, shared across all Function Apps in it) | *[TBD]* GB-s = *[TBD]*% of grant | — |
| **Net compute cost** | | | ***[TBD]*** |

### 6.3 Blob Storage

| Time horizon | Accumulated size | Monthly storage cost |
|---|---|---|
| Today | *[TBD]* (latest) + whatever archive history already exists | *[TBD]* |
| After 1 year of weekly runs | *[TBD]* (latest, steady) + *[TBD]* (archive/logs, cumulative) | *[TBD]* |
| After 5 years | *[TBD]* | *[TBD]* |

### 6.4 Application Insights (logging/monitoring)

| Metric | Rate | Our usage | Cost |
|---|---|---|---|
| Data ingestion | ~$2.30/GB after free tier | *[TBD]* GB/month | Likely covered by free tier |
| Free tier | 5 GB/month | *[TBD]*% of the free tier | — |
| **Net cost** | | | ***[TBD]*** |

> Note: as flagged in §4.3, Application Insights is not currently accessible for viewing logs on this project, so its actual ingestion volume hasn't been directly observed — the per-run Blob Storage log (`logs` container) is the primary log source in practice.

### 6.5 Total Services and the cost estimates

| Service | Monthly cost |
|---|---|
| Azure Functions (Flex Consumption) compute | *[TBD]* |
| Blob Storage | *[TBD]* |
| Application Insights | *[TBD]* |
| Data transfer | *[TBD]* |
| **Total** | ***[TBD — expected to be $0.00 or a few cents/month]*** |

---

## 7. References

- CyberArk PAM/SCA Dashboard web view — [TBD]
- Teams folder link for the Script/App files — [TBD]
- Approval documentation — [TBD]

| Question | Where |
|---|---|
| Is the function running/succeeding? | Portal → Function App → Functions → `DashboardExport` → Monitor tab (if accessible) — otherwise, check for a fresh `<RunTimestamp>.log` blob in the `logs` container and current CSV timestamps in `latest` |
| What did a specific run log? | `logs` container → `<RunTimestamp>.log` (primary log source — Application Insights access isn't currently available; see §4.3) |
| What are the current CSV outputs? | Storage account `pamdashboarddata01` → Containers → `latest` |
| Historical snapshots | Storage account `pamdashboarddata01` → Containers → `archive/<RunTimestamp>/` |
| Per-run text logs | Storage account `pamdashboarddata01` → Containers → `logs` |
| Is credential/storage config correct? | Function App → Settings → Environment variables |
| Did the last run have any errors? | `_RunMetadata.json` in `latest` → `Errors` array (empty on a clean run) |
