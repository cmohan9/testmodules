# CyberArk Unified Power BI Dashboard Guide (V13)

**Companion to:** `Antigravity_Dashboard_Script_V13.ps1`.

> **This consolidates and replaces two prior guides**: `Antigravity_Dashboard_Guide_V12.md`
> (PAM) and `SCA_Dashboard_Guide_V2.md` (SCA) — now that the dashboard is finalized and
> both data sources are produced by one script into one folder, they're documented in one
> place. This guide describes your **actual finalized dashboard** exactly as built, not a
> proposal.
>
> **What changed structurally**: `FACT_CPMFailed`, `FACT_MetricsSummary`, `DIM_Date`, and
> `SCA_PolicyAccounts` are gone — none were used by any visual in your finalized build.
> See the script's header comment for the full removal rationale. **7 CSVs total** now
> (down from 9 PAM + 2 SCA = 11 across the two prior scripts).
>
> **V13 update**: `SCA_Policies.csv` now carries every field the script can extract from
> the `/policies` API (18 columns), not just the 6 that feed a dashboard visual — useful
> to browse directly in the CSV even without a chart bound to it. `SCA_PolicyAccounts`
> and "Cloud Accounts Covered" are still removed (different table, separate decision).
> This also fixed a real bug caught during validation: `CreationDate`/`LastChanged`/
> `StartDate`/`ExpirationDate` could come back reformatted in the machine's local
> date/time style instead of the API's original format, because PowerShell's JSON
> parser silently converts ISO8601-looking strings into `DateTime` objects. They're now
> normalized to unambiguous ISO 8601 (`yyyy-MM-ddTHH:mm:ssZ`) regardless.

---

## Data Sources (7 CSVs, one folder)

| Table | Feeds |
|---|---|
| `DIM_Region` | RegionKey slicer, Region relationships |
| `DIM_Safe` | Business Safes / Empty Safes cards, Region×Tier matrix |
| `FACT_Accounts` | Business Accounts / Rotation Overdue / Compliance Rate % cards, OSCategory×ComplianceStatus chart, Region×Tier matrix, Team×AccessType chart, detail table, Tier/ComplianceStatus slicers |
| `FACT_Users` | Active Users card |
| `FACT_VaultConnectivity` | Vault Components Total / Vault Connectivity % cards |
| `FACT_OnboardingTrend` | Onboarding trend combo chart |
| `SCA_Policies` | SCA Active/Total Policies cards, CloudProvider×Status matrix. Also carries 12 additional browsable columns (Name, Description, PrimaryStatus, CreationDate, LastChanged, StartDate, ExpirationDate, MaxSessionDurationHours, UserEntityCount, RoleEntityCount, FaultCode, StatusTooltipMessage) not bound to any visual — open the CSV directly to inspect them, or build ad-hoc visuals/a detail table against them in Power BI. |

---

## Step 1: Import

**Get Data → Folder**, point at the script's `Latest\` folder, **Combine & Transform**. All 7 CSVs come from one folder now — no second folder source needed (that was only required when SCA had its own separate script/folder; it doesn't anymore).

Set column types: dates → **Date**; numeric columns → **Whole Number**/**Decimal**; boolean-like columns (`IsDefaultSafe`, `AutoManaged`, `HasCPM`, `IsEmpty`, `NamingCompliant`, `IsStale`, `RotationOverdue`, `IsComponent`, `IsLoggedOn`) → leave as **Text**.

> **TRUE/FALSE in DAX must be quoted** — these columns are stored as text (`True`/`False`). Compare as `= "TRUE"` / `= "FALSE"`, not `= TRUE` / `= FALSE`. DAX text comparison is case-insensitive.

## Step 2: Relationships

| # | From.Column | To.Column | Cardinality | Cross-filter |
|---|---|---|---|---|
| 1 | `FACT_Accounts.SafeName` | `DIM_Safe.SafeName` | Many → One | **Both** |
| 2 | `FACT_Accounts.Region` | `DIM_Region.RegionKey` | Many → One | **Both** |
| 3 | `DIM_Safe.Region` | `DIM_Region.RegionKey` | Many → One | Single |

`FACT_Users`, `FACT_VaultConnectivity`, `FACT_OnboardingTrend`, and `SCA_Policies` are intentionally **not** related to anything else — each is self-contained for the cards/charts it feeds.

## Step 3: DAX Measures

### PAM
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
-- KEEPFILTERS is required here: the ComplianceStatus slicer and this measure's
-- own filter both target FACT_Accounts[ComplianceStatus]. Without KEEPFILTERS,
-- CALCULATE's explicit filter argument OVERRIDES the slicer's filter on that same
-- column instead of intersecting with it -- so selecting "Non-Compliant" in the
-- slicer was silently ignored by this measure, returning the tenant-wide Compliant
-- count while [Business Accounts] correctly shrank to the tiny Non-Compliant
-- subset, producing rates like 1450% (shown by the card as "1.45K"). KEEPFILTERS
-- makes the filter intersect with the slicer, so selecting "Non-Compliant" now
-- correctly collapses this measure to 0 and the rate to 0%.

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

Cumulative Accounts =
CALCULATE(
    SUM(FACT_OnboardingTrend[AccountsOnboarded]),
    FILTER(ALL(FACT_OnboardingTrend),
        FACT_OnboardingTrend[Month] <= MAX(FACT_OnboardingTrend[Month])))
```

### SCA
```dax
SCA Total Policies = COUNTROWS(SCA_Policies)

SCA Active Policies =
CALCULATE(COUNTROWS(SCA_Policies), SCA_Policies[StatusLabel] = "Active")
```

## Step 4: The Dashboard

Matches your finalized layout exactly:

**Top card strip (8 cards, one row):** `[Business Accounts]`, `[Rotation Overdue]`, `[Compliance Rate %]`, `[Active Users]`, `[Business Safes]`, `[Empty Safes]`, `[Vault Components Total]`, `[Vault Connectivity %]`.

**Region × Tier Matrix:** *Rows* = `DIM_Region[RegionKey]`, *Columns* = `FACT_Accounts[Tier]`, *Values* = `AccountID` → Count, with a Total row/column enabled.

**"Count of AccountID by OSCategory and ComplianceStatus":** *X-axis* = `OSCategory`, *Y-axis* = `AccountID` → Count, *Legend* = `ComplianceStatus`.

**SCA block (2 cards + matrix):** `[SCA Active Policies]`, `[SCA Total Policies]`; Matrix — *Rows* = `SCA_Policies[CloudProviderLabel]`, *Columns* = `SCA_Policies[StatusLabel]`, *Values* = `PolicyId` → Count, with Total row/column.

**"Count of AccountID by TeamName and AccessType":** horizontal bar — *Y-axis* = `FACT_Accounts[TeamName]`, *X-axis* = `AccountID` → Count, *Legend* = `AccessType`.

**"Sum of AccountsOnboarded and Cumulative Accounts by Month":** combo chart — *X-axis* = `FACT_OnboardingTrend[Month]`, *Column* = `SUM(AccountsOnboarded)`, *Line* = `[Cumulative Accounts]`.

**Detail table:** `UserName`, `Address`, `SafeName`, `PlatformID`, `Region`, `ComplianceStatus`, `DaysSinceVerify`, `DaysSinceChange`, `RotationOverdue` (all from `FACT_Accounts`).

**Slicers:** `RegionKey` (`DIM_Region`), `Tier` (`FACT_Accounts`), `ComplianceStatus` (`FACT_Accounts`).

---

## Why was `DIM_Date` removed — and is it worth bringing back?

A `DIM_Date` (calendar) table is normally one of the highest-value tables in any Power BI
model, because it unlocks things a plain date *column* on a fact table can't do on its own:

- **Time-intelligence DAX** — `TOTALYTD`, `SAMEPERIODLASTYEAR`, `DATEADD`, `PARALLELPERIOD`,
  etc. all require filtering through a table marked as an official Date table.
- **"Mark as Date Table"** in Power BI unlocks the built-in Quick Measures time-intelligence
  menu and correct month/quarter/year sort order (so "Jan, Feb, Mar…" instead of alphabetical).
- **Continuous calendar even with sparse fact data** — if some months have zero onboarded
  accounts, a real calendar table still shows that month (with a 0), instead of the axis
  silently skipping gaps.
- **Slicing independent of any one fact table** — weekday/weekend, fiscal quarter, "is
  current month" flags, etc., reusable across every visual instead of recomputed per table.

**In this specific dashboard, none of that is currently exercised.** `FACT_OnboardingTrend`
already builds its own continuous month range directly (it doesn't rely on a calendar table
to avoid gaps), and no visual in the finalized layout uses YTD/prior-period comparisons or
weekday/fiscal slicing. That's why it was cut in the V12 trim — it was truly dead weight at
the time.

**When it would earn its place back**: the moment you want a YTD/MoM/QoQ comparison card,
a "vs. same month last year" line, or a fiscal-calendar view. If any of that is coming, say
so and it's a small, additive change — regenerate a `DIM_Date` CSV spanning your earliest
`CreatedDate`/`LastChangeDate` through today (or a fixed future date), relate it to
`FACT_Accounts[CreatedDate]` and `FACT_OnboardingTrend[Month]`, and mark it as the model's
official Date table. Not adding it back speculatively, per the "no unused clutter" trim
this script follows — but it's a five-minute add whenever you need it.

---

## Known Limitations (carried forward)

| Gap | Status |
|---|---|
| CPM failure detail / granular error codes | Removed with `FACT_CPMFailed` in this consolidation — not visualized in the finalized dashboard. The Privilege Cloud API also never exposed a granular error code for this, so nothing was lost that could have been shown anyway. |
| Non-compliance by regulatory framework (MAR/SOX/HIPAA) | Not covered — no such field exists in CyberArk for this tenant. |
| Discovered (not-yet-onboarded) accounts | Out of scope per earlier decision. |
| SCA Policies API deprecation | CyberArk's own docs flag this API for deprecation in favor of a newer "Access control policies API," not yet available to build against. Revisit `SCA_Policies.csv` when that's published. |
| Team/Environment/AccessType tagging accuracy | Parsed from the safe **name**, not validated against an authoritative source. A misnamed safe produces a wrong tag. |
