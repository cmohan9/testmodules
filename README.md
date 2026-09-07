# Cyberark_Auto_Account_Onboarding

Automates CyberArk Privileged Cloud account onboarding from a CSV intake: builds/validates
Safe and Platform names against the naming convention, previews everything it will create,
then creates/reuses the Platform (via duplication) and Safe, adds safe members, onboards the
account, and triggers Verify + Reconcile.

## Files

- `Common.ps1` — shared config, auth (OAuth client-credentials), API GET/POST/PUT helpers,
  naming-convention tables/builders/validators, and CyberArk object operations (Platform/Safe/
  Members/Account/Verify/Reconcile). Dot-sourced by `Onboard-Accounts.ps1`.
- `Onboard-Accounts.ps1` — reads the CSV, validates every row, groups rows into safes, shows a
  preview, asks for one confirmation, then executes.
- `Templates/AccountOnboarding_Template.csv` — CSV headers + example rows.
- `Auth_WorkingScript.ps1` — separate read-only PAM/SCA reporting/dashboard script (not part of
  the onboarding flow).

## Setup

1. Fill in the tenant values at the top of `Common.ps1` (`$IdentityTenantId`, `$ServiceUserId`,
   `$ServiceUserSecret`, `$Subdomain`). Never commit real values.
2. Replace `REPLACE_WITH_BG_GROUP_NAME` in `$DefaultSafeMembers` in `Common.ps1` with your
   actual default safe-member group name.
3. Copy `Templates/AccountOnboarding_Template.csv`, fill in your rows. Valid codes for each
   column are enforced by the tables in `Common.ps1` (`$Safe*Codes`, `$Platform*Codes`) — an
   invalid code is reported per-row before any API calls are made.

## Usage

```powershell
# Preview only — no changes, no prompt
.\Onboard-Accounts.ps1 -CsvPath .\myrequest.csv -WhatIf

# Preview, then one confirmation before creating/updating everything shown
.\Onboard-Accounts.ps1 -CsvPath .\myrequest.csv
```

Each run writes a timestamped log (`Onboarding_<timestamp>.log`, secrets/tokens redacted) and a
results CSV (`OnboardingResults_<timestamp>.csv`) with a per-row created/reused/failed status.

## Before running against a real tenant

The exact request/response field names for Platform duplication and Account creation follow the
documented Privilege Cloud REST API but can vary slightly by tenant/API version — validate the
API calls in `Common.ps1` against a test safe/platform before using this in production.
