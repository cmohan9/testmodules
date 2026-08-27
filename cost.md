# Expected Cost Estimation for Azure Resources — Daily Run Cadence

Companion to `Project_Documentation_V1.md` §6, recomputed for a **daily** schedule (vs. the current weekly schedule) using real observed figures from this project's own Function App run, rather than placeholder assumptions.

**Inputs used** (both supplied directly, not estimated):
- **Execution duration**: 118.2 seconds per run
- **File sizes** (from the `latest` container, one full run's output):

| File | Size |
|---|---|
| DIM_Region.csv | 201 B |
| DIM_Safe.csv | 120.59 KiB |
| FACT_Accounts.csv | 1.92 MiB |
| FACT_OnboardingTrend.csv | 877 B |
| FACT_Users.csv | 109.05 KiB |
| FACT_VaultConnectivity.csv | 2.08 KiB |
| SCA_Policies.csv | 17.7 KiB |
| _RunMetadata.json | 393 B |
| **Total per run** | **≈ 2.165 MiB (≈ 2,270,143 bytes)** |

---

## 1. Estimated Cost

**$0.00/month for the foreseeable future** — same conclusion as the weekly estimate, though daily runs use meaningfully more of the Function App's free compute grant (≈7.2% vs. ≈1.0% weekly) and grow Blob Storage roughly 7x faster. Even so, every cost dimension stays either fully inside its free tier or in the range of a few cents a month, for years.

| Assumption | Value / Frequency | Source |
|---|---|---|
| Run frequency | **Daily** (365 runs/year ≈ 30.44 runs/month) | Requested cadence for this estimate |
| Execution duration | **118.2 seconds** | Observed, supplied directly |
| Function instance size | 2048 MB (2 GB) | Function App configuration |
| Always-ready instances | 0 (pure on-demand, scales to zero when idle) | Not configured |
| Data written per run | **≈ 2.165 MiB** (7 CSVs + `_RunMetadata.json`) | Observed blob sizes, supplied directly |
| Log file per run | *Not directly observed* — assumed ≈10 KB (small relative to the CSV total either way; see note below) | Estimated |
| Write pattern | Every run overwrites `latest/` (~2.17 MiB, doesn't accumulate) and adds a new timestamped copy to `archive/` and `logs/` (accumulates every run) | |
| Region | East US, both storage accounts and the Function App co-located | Resource inventory |

> **Note on the log-file assumption**: the actual size of a `logs/<RunTimestamp>.log` blob wasn't supplied, so ≈10 KB/run is used as a placeholder (based on the script's own `Write-Log` call volume — mostly short section/status lines, not a line per record). At this data volume the log's contribution to total storage is under 0.5% of the per-run total regardless of whether it's 5 KB or 50 KB, so this assumption does not materially change the conclusion below. Supply a real observed size if you want this refined.

---

## 2. Azure Functions – Flex Consumption (compute)

Rates confirmed current as of this estimate ([Microsoft Azure Functions pricing](https://azure.microsoft.com/en-us/pricing/details/functions/), [Flex Consumption plan docs](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan)):

| Metric | Rate | Our usage (daily) | Cost |
|---|---|---|---|
| Execution time | $0.000026/GB-s (on-demand) | 2 GB × 118.2s × 30.44 runs/mo ≈ **7,196 GB-s/month** | Free grant covers it |
| Executions | $0.40 per million | ≈30.44 executions/month | Free grant covers it |
| Always-ready baseline | $0.000004/GB-s | Not used (0 always-ready instances) | $0 |
| Monthly free grant | 100,000 GB-s + 250,000 executions (per subscription, shared across all Function Apps in it) | 7,196 GB-s = **7.20% of grant**; 30.44 executions = 0.012% of grant | — |
| **Net compute cost** | | | **$0.00/month** |

**For context — weekly vs. daily**: the current weekly schedule uses ≈1,024 GB-s/month (≈1.02% of the free grant). Moving to daily increases that to ≈7,196 GB-s/month (≈7.20%) — a real 7x increase, but still comfortably inside the free monthly grant with no cost impact. Only if usage were to exceed 100,000 GB-s/month (roughly 13x today's daily-cadence usage, e.g. a much longer-running script, a much larger instance size, or hundreds of daily invocations) would this line item start actually billing.

---

## 3. Blob Storage

`latest/` is overwritten every run and stays a constant ≈2.165 MiB. `archive/` and `logs/` each add one new timestamped file set per run, so they grow linearly with the number of runs — this is the only cost component that meaningfully compounds over time, and it compounds roughly 7x faster on a daily schedule than on the current weekly one.

Rate used: **$0.018–$0.0208/GiB/month** (Hot tier, LRS, East US — published rates vary slightly by source/date; both ends of that range are shown below since the actual dollar amounts are small enough that the difference doesn't change the conclusion). ([Azure Blob Storage pricing overview](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/))

| Time horizon | Runs accumulated | Accumulated size | Monthly storage cost |
|---|---|---|---|
| Today (a single run) | 1 | ≈0.0042 GiB | < $0.001 (rounds to $0.00) |
| After 1 year of **daily** runs | 365 | ≈0.777 GiB | **≈ $0.014 – $0.016/month** |
| After 5 years of **daily** runs | 1,825 | ≈3.878 GiB | **≈ $0.070 – $0.081/month** |

For comparison, the equivalent weekly-cadence figures (52 runs/year) would be roughly 7x smaller at each horizon — about $0.002/month after 1 year and $0.010–$0.012/month after 5 years. Daily is a real, visible increase in this one line item, but it stays under a dime a month even five years out.

---

## 4. Application Insights (logging/monitoring)

| Metric | Rate | Our usage (daily) | Cost |
|---|---|---|---|
| Data ingestion | ~$2.30/GB after free tier | Not directly observed (same caveat as `Project_Documentation_V1.md` §4.3 — Application Insights isn't currently accessible for viewing logs on this project); if standard platform telemetry runs ~50–100 KB/run, that's ≈1.5–3.0 MB/month at daily cadence | Free tier covers it either way |
| Free tier | 5 GB/month | ≈0.03–0.06% of the free tier at the estimated volume | — |
| **Net cost** | | | **$0.00/month** |

---

## 5. Total Services and the Cost Estimate (Daily Cadence)

| Service | Monthly cost |
|---|---|
| Azure Functions (Flex Consumption) compute | $0.00 |
| Blob Storage | $0.00 today; **≈ $0.014–$0.016/month at 1 year; ≈ $0.070–$0.081/month at 5 years** |
| Application Insights | $0.00 |
| Data transfer | $0.00 |
| **Total** | **$0.00/month today, staying under $0.10/month even 5 years out** |

**Bottom line**: switching from weekly to daily runs is, from a cost perspective, a non-decision — compute stays fully free (using ~7% instead of ~1% of a monthly grant that resets every month regardless), and the only accumulating cost, Blob Storage archive/log growth, stays under a dime a month for the next five years. The cadence choice should be driven by how fresh the dashboard data needs to be, not by cost.

---

### Sources
- [Azure Functions pricing – Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/functions/)
- [Azure Functions Flex Consumption plan hosting – Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-functions/flex-consumption-plan)
- [Estimating consumption-based costs in Azure Functions – Microsoft Learn](https://learn.microsoft.com/en-us/azure/azure-functions/functions-consumption-costs)
- [Azure Blob Storage pricing – Microsoft Azure](https://azure.microsoft.com/en-us/pricing/details/storage/blobs/)
