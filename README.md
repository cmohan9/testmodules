# CyberArk Dashboard Exporter — Azure Function (Flex Consumption)

Azure Functions port of `PAM_SCA_Dashboard_Final.ps1` (the on-prem scheduled-task
version). Same business logic and CSV schemas; only the trigger, config
source, and output destination changed. See `DashboardExport/run.ps1`'s header
comment for the full list of what changed and why.

## Layout

```
AzureFunction/
├── host.json               Function App runtime config (timeout, App Insights sampling)
├── profile.ps1              Runs once per cold start (just sets TLS 1.2 — no Az module boilerplate)
├── requirements.psd1         Deliberately empty — Flex Consumption doesn't support
│                             managed dependencies, and this app uses no external modules
├── local.settings.json       LOCAL TESTING ONLY — real secrets go here, never committed (.gitignore'd)
├── .funcignore
└── DashboardExport/
    ├── function.json         Timer trigger binding (the schedule — see below)
    └── run.ps1                The entire script — one file, same as the on-prem version
```

## Environment Variables (Function App → Environment variables → App settings)

| Name | Purpose |
|---|---|
| `IDENTITY_TENANT_ID` | CyberArk Identity tenant ID — builds the OAuth2 issuer URL (`https://<id>.id.cyberark.cloud`) |
| `SERVICE_USER_ID` | Service account client ID for the `client_credentials` OAuth2 grant |
| `SERVICE_USER_SECRET` | Service account secret — **treat as sensitive**, this is a password |
| `SUBDOMAIN` | Privilege Cloud tenant subdomain (builds `https://<subdomain>.privilegecloud.cyberark.cloud`) |
| `SCA_SUBDOMAIN` | Secure Cloud Access tenant subdomain (builds `https://<subdomain>.sca.cyberark.cloud`) |
| `PamDataStorage` | Full connection string (from that storage account's **Access keys** page, **Connection string** field — not just the raw key) for the **separate** storage account this app writes output to. Parsed to get the account name/key used to sign Blob Storage REST calls. |
| `LATEST_CONTAINER` | *(optional)* Defaults to `Latest` if not set. |
| `ARCHIVE_CONTAINER` | *(optional)* Defaults to `Archive` if not set. |
| `LOGS_CONTAINER` | *(optional)* Defaults to `Logs` if not set. |

Two more are **already set automatically** by Azure when you create the Function App — you don't add these yourself, but should know what they're for:

| Name | Purpose |
|---|---|
| `AzureWebJobsStorage` | Connection string to the Function App's OWN storage account, used only for the platform's internal bookkeeping (locks, triggers). This is **not** where CSV output goes — that's `PamDataStorage`, a deliberately separate account. |
| `FUNCTIONS_WORKER_RUNTIME` | Set to `powershell` — tells the platform which language worker to run. |

No CyberArk value is ever hardcoded in `run.ps1` — the script `throw`s immediately on startup if any of the five required CyberArk settings above are missing or empty, rather than failing confusingly partway through a run.

## Output location

CSVs land in Blob Storage, not a local folder, split across three top-level containers in the `PamDataStorage` account:
- `Latest/<TableName>.csv` and `Latest/_RunMetadata.json` — overwritten every run; this is what Power BI points at
- `Archive/<RunTimestamp>/<TableName>.csv` and `Archive/<RunTimestamp>/_RunMetadata.json` — one historical snapshot per run, same as the old `Archive\` folder
- `Logs/<RunTimestamp>.log` — the full log for that run, uploaded even if the run fails partway through (via a try/finally around the whole script body)

## Schedule

Set in `DashboardExport/function.json`'s `"schedule"` field (6-field NCRONTAB:
`{second} {minute} {hour} {day} {month} {day-of-week}`, day-of-week 0=Sunday):

| Cadence | Expression |
|---|---|
| **Current: Weekly, Monday 5:00 AM** | `0 0 5 * * 1` |
| Daily, 2:00 AM | `0 0 2 * * *` |
| Every 6 hours | `0 0 */6 * * *` |

To change it, edit the `"schedule"` value and redeploy — no other file needs to change.

## Local testing

See the main migration walkthrough for how to run this locally with Azure
Functions Core Tools before deploying, and how to manually trigger it once
deployed (without waiting for the schedule to fire).
