<#
.SYNOPSIS
    CyberArk Power BI Dashboard Data Exporter — Privilege Cloud + Secure Cloud
    Access (SCA) — Azure Functions (Flex Consumption) Timer Trigger version.
.DESCRIPTION
    READ-ONLY script that authenticates once to CyberArk and exports both the
    Privilege Cloud (PAM) data and the Secure Cloud Access (SCA) data as CSVs
    into Azure Blob Storage, replacing the on-prem scheduled-task version
    (PAM_SCA_Dashboard_Final.ps1) which wrote to local Latest\/Archive\ folders.

    MODULES (same organization as the on-prem script):
      MODULE 1 — Configuration            (Sections A-J, unchanged business rules;
                                            Section A credentials now read from
                                            environment variables/App Settings)
      MODULE 2 — Shared helpers           (logging, auth, HTTP retry wrappers,
                                            + Blob Storage REST helper — new)
      MODULE 3 — Classification functions (region/tier/safe-type/team-tag parsing
                                            — byte-for-byte unchanged, pure functions)
      MODULE 4 — PAM data collection      (Privilege Cloud: Safes/Users/Accounts/
                                            Vault/Onboarding — unchanged logic)
      MODULE 5 — SCA data collection      (Secure Cloud Access: Policies —
                                            unchanged logic)
      MODULE 6 — CSV export               (writes to Blob Storage instead of a
                                            local folder; same column schemas)
      MODULE 7 — Run summary               (console/App Insights report + run
                                            metadata JSON, written to Blob Storage)

    WHAT CHANGED FROM THE ON-PREM SCRIPT (everything else is identical):
      - Section A credentials come from environment variables (Application
        Settings in the Function App), not hardcoded values.
      - All local file I/O (Export-Csv/Set-Content/Out-File to Latest\/Archive\,
        plus the local log file) is replaced with raw calls to the Azure Blob
        Storage REST API, signed with Shared Key (HMAC-SHA256) using only
        built-in .NET crypto (System.Security.Cryptography) — no Az.Storage or
        any other external module, since Flex Consumption does not support
        managed dependencies.
      - Output goes to a SEPARATE storage account (its connection string in
        the PamDataStorage app setting — distinct from the Function App's own
        AzureWebJobsStorage, which is only used for the platform's internal
        bookkeeping) with three top-level containers standing in for the old
        folder structure: "Latest" (current CSVs + run metadata, the Power BI
        source), "Archive" (one "<RunTimestamp>/" blob-name prefix per run,
        i.e. one "folder" per historical run), and "Logs" (one log blob per
        run, named "<RunTimestamp>.log").
      - Write-Log still writes via Write-Host (captured by Application
        Insights automatically) AND accumulates every line into $LogLines,
        uploaded as one blob to the Logs container at the end of the run —
        inside a try/finally so this still happens even if the run fails
        partway through.
      - Get-AuthToken now `throw`s instead of `exit 1` on failure to
        authenticate — inside an Azure Functions PowerShell worker, `exit`
        would kill the whole worker process; `throw` correctly fails just
        this invocation so the platform logs/retries it properly.
.MODE
    READ-ONLY (GET requests only to CyberArk; only Blob Storage PUT calls write
    data, and only to your own storage account — no changes are made to CyberArk)
.NOTES
    Author   : Mohan C
    Requires : Azure Functions PowerShell 7.4 worker, Flex Consumption plan
               A CyberArk service account with:
                 - Privilege Cloud Administrator or Auditor role (for the PAM module)
                 - The SCA API role granted in Identity Administration
#>

param($Timer)

if ($Timer -and $Timer.IsPastDue) {
    Write-Host "Timer is running late — a previous invocation may have overrun the schedule." -ForegroundColor Yellow
}

#=========================================================================
# MODULE 1 : CONFIGURATION
#=========================================================================

# ── Section A: Credentials (from environment variables / App Settings) ──────
$IdentityTenantId  = $env:IDENTITY_TENANT_ID
$ServiceUserId     = $env:SERVICE_USER_ID
$ServiceUserSecret = $env:SERVICE_USER_SECRET
$Subdomain         = $env:SUBDOMAIN
$ScaSubdomain      = $env:SCA_SUBDOMAIN

foreach ($required in @("IDENTITY_TENANT_ID","SERVICE_USER_ID","SERVICE_USER_SECRET","SUBDOMAIN","SCA_SUBDOMAIN")) {
    if ([string]::IsNullOrWhiteSpace((Get-Item "env:$required" -ErrorAction SilentlyContinue).Value)) {
        throw "Required app setting '$required' is missing or empty. Configure it in the Function App's Environment Variables."
    }
}

# ── Section B: Thresholds & Windows ──────────────────────────────────────────
$LoginWindowDays      = 30     # Users considered "active" if logged in within N days
$OnboardingWindowDays = 30     # Accounts/safes "recently onboarded" if created within N days
$StaleAccountDays     = 90     # No password change in N days = stale
$VerifyOverdueDays    = 7      # Verification must occur every N days
$TrendLookbackMonths  = 12     # Onboarding trend history depth

# ── Section C: Runtime Config ────────────────────────────────────────────────
$PageLimit          = 1000
$MaxRetries         = 4
$RetryWaitSeconds   = 5

# ── Section D: Default System Objects ────────────────────────────────────────
# Items listed here are filtered out of "business" metrics (they're CyberArk
# internal objects). Add new CPM/PSM safes when new CPM/PSM components Installed.

$DefaultSafes = @(
    "System","VaultInternal","Pinstore","Notification Engine","SharedAuth_Internal",
    "PVWAConfig","PVWAReports","PVWATaskDefinitions","PVWAPrivateUserPrefs","PVWAUserPrefs",
    "PVWATicketingSystem","PSM","PSMLiveSessions","PSMRecordings","PSMUniversalConnectors",
    "PSMNotifications","PSMSessionBackups","PasswordManager","PasswordManager_Pending",
    "PasswordManager_workspace","PasswordManager_ADInternal","PasswordManager_Info",
    "AccountsFeedADAccounts","AccountsFeedDiscoveryLogs","ConjurSync","TelemetryConfig",
    "APAC-CARK-EPM-1","APAC-CARK-EPM-1_Accounts","De2vs1275","De2vs1275_Accounts","EMEA-PSM",
    "OCA-PSM","APAC-PSM","OT-CARK-PAM1","OT-CARK-PAM1_Accounts","OT-PSM","ams-CArk-epam2",
    "ams-CArk-epam2_Accounts","PSM","PSMUniversalConnectors","PVWATicketingSystem","TelemetryConfig",
    "de2vs1287","de2vs1287_Accounts","EMEA-PSM-T0","SGAZCLPDVMCARK1","SGAZCLPDVMCARK1_Accounts",
    "APAC_PSM_T0","Test_Notifications-Deloitte"
)

$DefaultSafePrefixes = @("PVWA*","PSM*","PasswordManager*","AccountsFeed*","SharedAuth*")


$DefaultMembersPatterns = @(
    "Administrator","Auditor","Backup","Batch","Master","DR","PasswordManager*",
    "PVWAGWUser","PVWAAppUser","PVWAGWAccounts","PSMApp_*","PSMGw_*","PSMAppUsers",
    "PSMPTAAppUsers","PSM_*","PTAAppUser","GWUser","ConjurSync","TelemetryUser*",
    "CyberarkRotationService","CyberarkAccountsIntegration",
    "CyberarkAccessService","CyberarkDiscoveryService",
    "InstallerUser@*","PSMMaster","Privilege Cloud Session Admin",
    "Backup Users","Auditors","DR Users","Notification Engines","Operators",
    "*_admin", "ams-CArk-epam2", "APAC-CARK-EPM-1", "De2vs1275","OT-CARK-PAM1","de2vs1287",
    "CyberarkAccountsIntegration","CyberarkRotationService","CyberarkAccessService","NotificationEngine",
    "USER-PVWA-74DA3E79-2874-4057-98A1-1E396D9A2199","CyberarkDiscoveryService","PVWAAppUser","PSMApp_ams-CArk-epam3",
    "PSMGw_ams-CArk-epam3","ams-CArk-epam2","PSMApp_ams-CArk-epam2","PSMGw_ams-CArk-epam2","PSMApp_apac-CArk-epm-2",
    "PSMGw_apac-CArk-epm-2","APAC-CARK-EPM-1","PSMApp_apac-CArk-epm-1","PSMGw_apac-CArk-epm-1","De2vs1275","PSMApp_De2vs1275",
    "PSMGw_De2vs1275","PSMApp_de2vs1276","PSMGw_de2vs1276","OT-CARK-PAM1","PSMApp_OT-CARK-PAM1","PSMGw_OT-CARK-PAM1",
    "PSMApp_OT-CARK-PAM2","PSMGw_OT-CARK-PAM2","LS_SSU_74DA3E79-2874-4057-98A1-1E396D9A2199","de2vs1287","PSMApp_de2vs1287",
    "PSMGw_de2vs1287","test","SGAZCLPDVMCARK1","PSMApp_SGAZCLPDVMCARK1","PSMGw_SGAZCLPDVMCARK1","PVWAAppUser2","PVWAGWUser","TelemetryUser"

)

# ── Section E: Naming Conventions — Region, Tier, Safe Type, Team Tagging ────
$RegionPrefixes = [ordered]@{
    "OCA"  = "OCA"
    "APAC" = "APAC"
    "EMEA" = "EMEA"
    "JP"   = "JP"
    "OT"   = "JP"
    "GLB"  = "Global"

}
$TierRegex = '(^|[-_ ])T([012])([-_ ]|$)'   # Captures T0/T1/T2 from the safe name.

# Safe type classification (admin vs business): not every safe carries a region
# prefix. Admin safes are identified by suffix:
#   *-ADM         => "Personal Admin"  (user-specific personal admin accounts)
#   *-T0/-T1/-T2  => "Shared Admin"    (shared admin accounts for that tier)
# Anything else non-default => "Standard Business". Default/system safes => "System/Default".

$PersonalAdminSuffixRegex = '-ADM$'
$SharedAdminSuffixRegex   = '-T[012]$'
$PersonalAdminTierLabel   = 'Personal/All-Tiers'   # used when no T0/T1/T2 token is present

# Safe name validation: business safe names SHOULD match this regex. Auto-builds
# from $RegionPrefixes keys if left empty; -ADM/-T0/-T1/-T2 admin safes are ALSO
# treated as naming-compliant (region optional for them).
$SafeNameExpectedRegex = ''


# Team/Application tag format (HLD):
#   REGION-ENV-TECHNOLOGY-ACCESSTYPE-TEAM
#   e.g. OCA-P-LIN-LA-SAN, APAC-P-WIN-DA-BKP
#
# Region must match $RegionPrefixes. Env, Technology, and AccessType use
# predefined valid codes. Team is free-form (e.g. SPLUNK).
#
# Matching is case-insensitive; aliases such as P, Prod, and PROD are treated alike.
#
# Shared Admin (-T0/-T1/-T2) and Personal Admin (-ADM) suffixes are removed
# before parsing. Purpose suffixes (-LOGON/-SCAN/-RECONCILE) are also removed.
#
# System/Default safes are tagged "N/A (Default)" and are not parsed.
# Unmatched names are tagged "Not Tagged".

$EnvironmentTokens = [ordered]@{
    "P" = "Production"; "PROD" = "Production"
    "D" = "Development"; "DEV" = "Development"
    "T" = "Testing"; "TEST" = "Testing"
    "Q" = "Q/A"; "QA" = "Q/A"
}
$TechnologyTokens = [ordered]@{
    "WIN" = "Windows"; "LIN" = "Linux"; "WKS" = "Workstation"; "NET" = "Network Device"
    "DB"  = "Database"; "SQL" = "SQL Database"; "ORC" = "Oracle Database"; "HTTP" = "Browser-Based Application"

}
$AccessTypeTokens = [ordered]@{
    "LA"  = "Local Account"; "LSA" = "Local Service Account"; "DSA" = "Domain Service Account"
    "ENA" = "Enable Account"; "DA"  = "Domain Account"

}
# Business Unit / Team codes -> friendly display names. Codes NOT on this list
# (e.g. an app name like "SPLUNK") pass through as the raw code — expected, not an error.
$TeamCodeMap = [ordered]@{
    "SEC"="Security Team"; "SOC"="Security Operations Center"; "DBA"="Database Administrators"
    "ENG"="Engineering Team"; "SUP"="Support Desk"; "NWR"="Network Team (Routers)"
    "NWS"="Network Team (Switches/Security)"; "ISD"="Infra & Service Delivery"
    "UAM"="User Access Management"; "SAN"="Storage Area Network"; "BKP"="Backup"
    "EPS"="Endpoint Security"; "CTX"="Citrix"; "SIEM"="SIEM"; "MDW"="Middleware"
    "SAP"="SAP"; "TLS"="Tools"; "CMDB"="CMDB"; "VAPT"="Vulnerability & Pen Testing"
    "NSG"="Network Security Group"; "VDI"="VDI"; "CLD"="Cloud"; "MSG"="Messaging"

}
# Trailing suffix => this safe holds a Cyberark Specific account type, checked
$SafePurposeSuffixes = [ordered]@{
    "LOGON" = "Logon Accounts"; "SCAN" = "Scan/Discovery Accounts"; "RECONCILE" = "Reconciliation Accounts"
}

# ── Section F: Platform Classification Patterns ──────────────────────────────
# Classifies accounts by OS/software category based on platformId.
$WindowsPlatformPatterns  = @("*Win*","*Windows*","*WinServer*","*WinDomain*","*NDC*")
$UnixPlatformPatterns     = @("*Unix*","*Linux*","*Lin*","*SSH*","*AIX*","*Solaris*","*HPUX*","*RHEL*")
$DatabasePlatformPatterns = @("*Oracle*","*MSSQL*","*MySQL*","*Postgres*","*DB2*","*Database*","*SQL*")
$CloudPlatformPatterns    = @("*AWS*","*Azure*","*GCP*","*Cloud*")
$NetworkPlatformPatterns  = @("*Cisco*","*F5*","*Palo*","*Firewall*","*Switch*","*Router*","*Network*")

# ── Section G: Rotation Policy Map ───────────────────────────────────────────
# Maps platformId patterns to expected rotation days.
$RotationPolicyDays = [ordered]@{
    "*365*" = 365; "*Oracle*" = 365; "*Service*" = 365
    "*Win*" = 45; "*Unix*" = 45; "*Linux*" = 45; "*SSH*" = 45
}
$DefaultRotationDays = 45

# ── Section H: Vault Component Types for Health Monitoring ───────────────────
$VaultComponentIDs = @("CPM","SessionManagement","AIM")

# ── Section I: Account Name & Address Validation (optional - for future reference)
# Leave empty ('') to disable.
$AccountNameExpectedRegex    = ''   # e.g. '^[a-zA-Z0-9_\-\.]+$'
$AccountAddressExpectedRegex = ''   # e.g. '^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'

# ── Section J: SCA Reference Data ────────────────────────────────────────────
$PolicyStatusMap = @{ 1 = "Active"; 3 = "Expired"; 4 = "Error"; 6 = "Validating" }
$CloudProviderMap = @{
    0 = "AWS (IAM)"; 1 = "Google Cloud"; 2 = "Azure (resource)"
    3 = "AWS (IAM Identity Center)"; 4 = "Azure (Microsoft Entra ID)"
}


# ==============================================================================
# URLS & STORAGE TARGETS
# ==============================================================================
$IdentityUrl = "https://$IdentityTenantId.id.cyberark.cloud"
$PvwaBase    = "https://$Subdomain.privilegecloud.cyberark.cloud/PasswordVault/API"
$ScaBase     = "https://$ScaSubdomain.sca.cyberark.cloud/api"

# Blob Storage output target -- a separate storage account (PamDataStorage app
# setting), NOT the Function App's own AzureWebJobsStorage. Container names
# are overridable via LATEST_CONTAINER/ARCHIVE_CONTAINER/LOGS_CONTAINER in
# case you ever want output to land somewhere other than the defaults below.
# Azure Blob Storage container names MUST be lowercase (a hard platform rule --
# 3-63 chars, lowercase letters/numbers/hyphens only), so these defaults are
# lowercase even though the Portal UI may display them with a capital first
# letter. If you set LATEST_CONTAINER/ARCHIVE_CONTAINER/LOGS_CONTAINER
# yourself, use the exact (lowercase) name Azure actually stored.
$LatestContainer  = if ([string]::IsNullOrWhiteSpace($env:LATEST_CONTAINER))  { "latest"  } else { $env:LATEST_CONTAINER }
$ArchiveContainer = if ([string]::IsNullOrWhiteSpace($env:ARCHIVE_CONTAINER)) { "archive" } else { $env:ARCHIVE_CONTAINER }
$LogsContainer    = if ([string]::IsNullOrWhiteSpace($env:LOGS_CONTAINER))   { "logs"    } else { $env:LOGS_CONTAINER }
$RunTimestamp      = Get-Date -Format "yyyyMMdd_HHmmss"
$ArchivePathPrefix = $RunTimestamp   # blob-name prefix within the Archive container -- its own "folder" per run

if ([string]::IsNullOrWhiteSpace($SafeNameExpectedRegex)) {
    $prefixAlts = ($RegionPrefixes.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $SafeNameExpectedRegex = "^($prefixAlts)[-_ ]"
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}


# ==============================================================================
# MODULE 2 : HELPERS
# Logging, authentication (ONE token, reused for both PAM and SCA calls),
# and Blob Storage REST helper (replaces local file I/O).
# ==============================================================================

function Write-Log {
    param([string]$Message,
          [ValidateSet("INFO","WARN","ERROR","SUCCESS","DEBUG","SECTION")][string]$Level="INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Level,$Message
    # Write-Host is captured by Application Insights / the Functions log stream
    # automatically. Also accumulated into $LogLines (initialized in INITIALISE,
    # below) so the whole run's log can be uploaded as one blob to the Logs
    # container -- including on failure, via the try/finally around the run.
    Write-Host $line
    # Explicit null check, NOT `if ($LogLines)` -- an empty List[string] evaluates
    # to $false in a boolean context in PowerShell, which would make this check
    # permanently false for a list that starts empty (it can never become
    # non-empty if .Add() is gated behind its own emptiness).
    if ($null -ne $LogLines) { $LogLines.Add($line) }
}

# ── Auth (with auto-refresh). One token is used for BOTH Privilege Cloud and SCA
#    calls -- they share the same CyberArk Identity OAuth2 issuer
$Global:Token = $null; $Global:TokenExpiry = Get-Date

function Get-AuthToken {
    $body = @{ grant_type="client_credentials"; client_id=$ServiceUserId; client_secret=$ServiceUserSecret }
    try {
        $r = Invoke-RestMethod -Uri "$IdentityUrl/oauth2/platformtoken" -Method POST -Body $body `
            -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
        $Global:Token = $r.access_token
        $exp = if ($r.expires_in) { [int]$r.expires_in } else { 900 }
        $Global:TokenExpiry = (Get-Date).AddSeconds($exp - 60)
        Write-Log "Token acquired (valid ~${exp}s)." SUCCESS
    } catch {
        Write-Log "Authentication FAILED: $($_.Exception.Message)" ERROR
        # `throw` (not `exit`) -- exiting would kill the whole Functions worker
        # process; throwing fails just this invocation so the platform logs
        # and (per its retry policy) can retry it on the next schedule.
        throw "Cannot continue without a valid CyberArk token: $($_.Exception.Message)"
    }
}
function Get-Headers {
    if ((Get-Date) -ge $Global:TokenExpiry) { Write-Log "Refreshing token..." WARN; Get-AuthToken }
    return @{ Authorization = "Bearer $Global:Token"; "Content-Type" = "application/json" }
}

# GET (Privilege Cloud)
function Invoke-ApiGet {
    param([string]$Uri)
    $a = 0
    while ($a -le $MaxRetries) {
        $a++
        try { return Invoke-RestMethod -Uri $Uri -Method GET -Headers (Get-Headers) -ErrorAction Stop }
        catch {
            $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            $m = $_.Exception.Message
            if ($s -in @(400,403,404,501)) { Write-Log "GET $Uri -> $s $m (no retry)" ERROR; return $null }
            if ($s -eq 401) { Write-Log "401 - refreshing token" WARN; Get-AuthToken; continue }
            if ($a -le $MaxRetries) {
                $w = if ($s -eq 429) { $RetryWaitSeconds * $a } else { $RetryWaitSeconds }
                Write-Log "GET $Uri -> $s $m (retry $a in ${w}s)" WARN; Start-Sleep -Seconds $w
            } else { Write-Log "GET $Uri -> $s $m (exhausted)" ERROR; return $null }
        }
    }
    return $null
}
function Get-AllPaged {
    param([string]$BaseUri, [string]$ValueProp = "value")
    $all = @(); $off = 0
    do {
        $sep = if ($BaseUri -match '\?') { '&' } else { '?' }
        $resp = Invoke-ApiGet -Uri "$BaseUri${sep}limit=$PageLimit&offset=$off"
        if (-not $resp) { break }
        $batch = $resp.$ValueProp
        if (-not $batch) { break }
        $all += $batch; $off += $PageLimit
        Write-Log "  ...$($all.Count) records" DEBUG
    } while ($batch.Count -eq $PageLimit)
    return $all
}

# GET (SCA)
function Invoke-ScaGet {
    param([string]$Uri)
    $a = 0
    while ($a -le $MaxRetries) {
        $a++
        try { return Invoke-RestMethod -Uri $Uri -Method GET -Headers (Get-Headers) -ErrorAction Stop }
        catch {
            $statusCode = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($statusCode -in @(400,401,403,404)) { Write-Log "GET $Uri -> $statusCode $($_.Exception.Message) (no retry)" ERROR; return $null }
            if ($a -le $MaxRetries) {
                Write-Log "GET $Uri -> $statusCode (retry $a in ${RetryWaitSeconds}s)" WARN
                Start-Sleep -Seconds $RetryWaitSeconds
            } else { Write-Log "GET $Uri -> $statusCode (exhausted)" ERROR; return $null }
        }
    }
    return $null
}

# Timestamp converters & formatters
function ConvertFrom-Unix { param($v)
    if ($null -eq $v -or $v -eq 0 -or "$v" -eq "") { return $null }
    try { return [DateTimeOffset]::FromUnixTimeSeconds([long]$v).LocalDateTime } catch { return $null }
}
function ConvertFrom-UnixMicro { param($v)
    if ($null -eq $v -or $v -eq 0 -or "$v" -eq "") { return $null }
    try { return [DateTimeOffset]::FromUnixTimeMilliseconds([long]([long]$v / 1000)).LocalDateTime } catch { return $null }
}
function Format-DateTime { param($dt) if ($dt) { return $dt.ToString("yyyy-MM-dd HH:mm:ss") } else { return "" } }
function Format-DateOnly { param($dt) if ($dt) { return $dt.ToString("yyyy-MM-dd") } else { return "" } }
function Format-MonthOnly { param($dt) if ($dt) { return $dt.ToString("yyyy-MM") } else { return "" } }
function Safe-String { param($v, [string]$Default = "")
    if ($null -eq $v -or [string]::IsNullOrWhiteSpace("$v")) { return $Default }; return "$v"
}
function Safe-DateString { param($v, [string]$Default = "")
    if ($null -eq $v) { return $Default }
    if ($v -is [DateTime]) { return $v.ToString("yyyy-MM-ddTHH:mm:ssZ") }
    return Safe-String $v $Default
}

# ── Blob Storage (raw REST, Shared Key auth -- no Az.Storage module) ─────────
# Flex Consumption doesn't support managed dependencies, so this signs requests
# to the Azure Storage REST API itself using only built-in .NET crypto
# (System.Security.Cryptography.HMACSHA256). This is the same Shared Key
# signing algorithm the Az.Storage module would use internally -- just done
# by hand so no external module needs to be installed.
function Get-StorageAccountContext {
    # PamDataStorage is a SEPARATE storage account from AzureWebJobsStorage
    # (which the Function App still uses internally for its own bookkeeping) --
    # output goes to its own dedicated account/containers instead of sharing
    # the app's runtime storage. Expects the full connection string (as copied
    # from the storage account's Access keys -> Connection string field).
    $connStr = $env:PamDataStorage
    if ([string]::IsNullOrWhiteSpace($connStr)) {
        throw "PamDataStorage app setting is not configured -- cannot write output."
    }
    $parts = @{}
    foreach ($seg in $connStr -split ';') {
        if ($seg -match '^([^=]+)=(.*)$') { $parts[$matches[1]] = $matches[2] }
    }
    if (-not $parts.ContainsKey('AccountName') -or -not $parts.ContainsKey('AccountKey')) {
        throw "PamDataStorage connection string is missing AccountName/AccountKey (unexpected format)."
    }
    return [pscustomobject]@{ AccountName = $parts['AccountName']; AccountKey = $parts['AccountKey'] }
}

function New-BlobCanonicalizedHeaders {
    param([hashtable]$Headers)
    # Spec requires lower-cased header names, sorted lexicographically.
    ($Headers.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name.ToLowerInvariant()):$($_.Value)`n" }) -join ''
}

# Uploads (overwrites) one blob as UTF-8 text via the Blob Storage "Put Blob"
# REST operation. $BlobPath is the blob name including any "/" prefixes, e.g.
# "Latest/DIM_Region.csv" or "Archive/20260813_050000/DIM_Region.csv" -- Blob
# Storage has no real folders, "/" in a blob name just displays like one.
function Send-BlobText {
    param(
        [Parameter(Mandatory)][string]$Container,
        [Parameter(Mandatory)][string]$BlobPath,
        # AllowEmptyString: a Mandatory [string] parameter otherwise REJECTS ""
        # outright ("Cannot bind argument... because it is an empty string") --
        # a genuinely empty blob (e.g. a log with zero captured lines) is a
        # valid case, not a caller error.
        [Parameter(Mandatory)][AllowEmptyString()][string]$Content,
        [string]$ContentType = "text/csv; charset=utf-8"
    )
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $contentLength = $bytes.Length
    $apiVersion = "2021-08-06"

    $a = 0
    while ($a -le $MaxRetries) {
        $a++
        $dateRfc1123 = [DateTime]::UtcNow.ToString("R")
        $headers = @{
            "x-ms-date"      = $dateRfc1123
            "x-ms-version"   = $apiVersion
            "x-ms-blob-type" = "BlockBlob"
        }
        $canonicalizedHeaders  = New-BlobCanonicalizedHeaders -Headers $headers
        $canonicalizedResource = "/$($StorageContext.AccountName)/$Container/$BlobPath"

        # Shared Key string-to-sign: VERB, then 11 rarely-used HTTP headers left
        # blank (we authenticate via x-ms-date instead of Date, and don't use
        # Content-Encoding/Language/MD5/If-*/Range here), then the canonicalized
        # x-ms-* headers, then the canonicalized resource path.
        $stringToSign = (@(
            "PUT", "", "", "$contentLength", "", $ContentType, "", "", "", "", "", ""
        ) -join "`n") + "`n$canonicalizedHeaders$canonicalizedResource"

        $keyBytes = [Convert]::FromBase64String($StorageContext.AccountKey)
        $hmac = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $sigBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))
        $signature = [Convert]::ToBase64String($sigBytes)

        $reqHeaders = @{
            "x-ms-date"      = $dateRfc1123
            "x-ms-version"   = $apiVersion
            "x-ms-blob-type" = "BlockBlob"
            "Authorization"  = "SharedKey $($StorageContext.AccountName):$signature"
        }
        $uri = "https://$($StorageContext.AccountName).blob.core.windows.net/$Container/$BlobPath"

        try {
            Invoke-RestMethod -Uri $uri -Method PUT -Headers $reqHeaders -Body $bytes -ContentType $ContentType -ErrorAction Stop | Out-Null
            return
        } catch {
            $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
            if ($a -le $MaxRetries) {
                Write-Log "Blob PUT $Container/$BlobPath -> $s (retry $a in ${RetryWaitSeconds}s): $($_.Exception.Message)" WARN
                Start-Sleep -Seconds $RetryWaitSeconds
            } else {
                Write-Log "Blob PUT $Container/$BlobPath -> $s FAILED (exhausted): $($_.Exception.Message)" ERROR
                throw
            }
        }
    }
}

# Creates a container if it doesn't already exist (idempotent -- a 409
# "already exists" response is treated as success, not an error). Called once
# per container during INITIALISE so a deleted/mistyped container name fails
# fast with a clear message instead of every subsequent blob write 404'ing.
function New-BlobContainerIfMissing {
    param([Parameter(Mandatory)][string]$Container)

    $apiVersion = "2021-08-06"
    $dateRfc1123 = [DateTime]::UtcNow.ToString("R")
    $headers = @{ "x-ms-date" = $dateRfc1123; "x-ms-version" = $apiVersion }
    $canonicalizedHeaders  = New-BlobCanonicalizedHeaders -Headers $headers
    $canonicalizedResource = "/$($StorageContext.AccountName)/$Container`nrestype:container"

    $stringToSign = (@(
        "PUT", "", "", "", "", "", "", "", "", "", "", ""
    ) -join "`n") + "`n$canonicalizedHeaders$canonicalizedResource"

    $keyBytes = [Convert]::FromBase64String($StorageContext.AccountKey)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256
    $hmac.Key = $keyBytes
    $sigBytes = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($stringToSign))
    $signature = [Convert]::ToBase64String($sigBytes)

    $reqHeaders = @{
        "x-ms-date"     = $dateRfc1123
        "x-ms-version"  = $apiVersion
        "Authorization" = "SharedKey $($StorageContext.AccountName):$signature"
    }
    $uri = "https://$($StorageContext.AccountName).blob.core.windows.net/${Container}?restype=container"

    try {
        Invoke-RestMethod -Uri $uri -Method PUT -Headers $reqHeaders -ErrorAction Stop | Out-Null
        Write-Log "Container '$Container' did not exist -- created it." WARN
    } catch {
        $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($s -eq 409) {
            # Already exists -- expected on every run after the first, not an error.
            return
        }
        throw "Failed to ensure container '$Container' exists (HTTP $s): $($_.Exception.Message)"
    }
}


# ==============================================================================
# MODULE 3 : CLASSIFICATION & NAMING-CONVENTION FUNCTIONS
# RAW safe/account date into Region/Tier/SafeType/Team/Environment/AccessType/SafePurpose tags (No API)
# ==============================================================================

function Test-IsDefaultSafe { param([string]$n)
    if ($DefaultSafes -contains $n) { return $true }
    foreach ($p in $DefaultSafePrefixes) { if ($n -like $p) { return $true } }; return $false
}
function Test-IsDefaultMember { param([string]$n)
    foreach ($p in $DefaultMembersPatterns) { if ($n -like $p) { return $true } }; return $false
}
function Get-Region { param([string]$s)
    # Match a region prefix only when it is followed by a delimiter (- _ space) or end-of-string,
    # so "OTHER-..." is not mis-tagged as the "OT" region and "JPMORGAN-..." not as "JP".
    foreach ($k in $RegionPrefixes.Keys) {
        if ($s -match "^$([regex]::Escape($k))([-_ ]|$)") { return $RegionPrefixes[$k] }
    }
    return "Non-standard"
}
function Get-Tier { param([string]$s)
    if ($s -match $TierRegex) { "T$($matches[2])" } else { "Untagged" }
}
function Get-SafeType { param([string]$s, [bool]$IsDefault)
    if ($IsDefault) { return "System/Default" }
    if ($s -match $PersonalAdminSuffixRegex) { return "Personal Admin" }
    if ($s -match $SharedAdminSuffixRegex)   { return "Shared Admin" }
    return "Standard Business"
}
function Get-SafeTier { param([string]$s, [string]$SafeType)
    $t = Get-Tier $s
    if ($t -eq "Untagged" -and $SafeType -eq "Personal Admin") { return $PersonalAdminTierLabel }
    return $t
}
function Get-MappedToken { param([string]$Token, $Map)
    # PowerShell's -eq is case-insensitive by default, so this matches "Prod"/"PROD"/"prod"
    # equally against a single "PROD" key. Unmapped tokens are returned upper-cased (raw
    # pass-through) so the same code always displays consistently regardless of source casing.
    foreach ($k in $Map.Keys) { if ($k -eq $Token) { return $Map[$k] } }
    return $Token.ToUpper()
}
function Test-TokenMapped { param([string]$Token, $Map)
    foreach ($k in $Map.Keys) { if ($k -eq $Token) { return $true } }
    return $false
}
function Get-SafePurpose { param([string]$s)
    # Strip a trailing tier/admin suffix FIRST so the purpose keyword underneath is visible —
    # e.g. "APAC-PROD-WIN-RECONCILE-T0" ends in "-T0", not "-RECONCILE", until this runs.
    $core = $s -replace $SharedAdminSuffixRegex, '' -replace $PersonalAdminSuffixRegex, ''
    foreach ($suf in $SafePurposeSuffixes.Keys) {
        if ($core -match ('-' + $suf + '$')) { return $SafePurposeSuffixes[$suf] }
    }
    return "Standard"
}
# Region-Env-Technology-AccessType-Team, parsed via token array (not regex) because the
# tail is variable-length in real data: AccessType and/or Team can be ENTIRELY ABSENT (a
# generic per-tier admin safe like "APAC-P-WIN-LA-T0" has no team code at all), and a
# purpose keyword (LOGON/SCAN/RECONCILE) can sit where AccessType would normally be
# ("APAC-PROD-WIN-RECONCILE-T0" — RECONCILE IS the 4th token, not a suffix after it).
function Get-SafeTeamTag { param([string]$s, [string]$SafeType)
    if ($SafeType -eq "System/Default") {
        return [pscustomobject]@{ Environment="N/A (Default)"; NamingTechnology="N/A (Default)"; AccessType="N/A (Default)"; Team="N/A (Default)"; TeamName="N/A (Default)" }
    }
    $core = $s
    if ($SafeType -eq "Shared Admin")        { $core = $core -replace $SharedAdminSuffixRegex, '' }
    elseif ($SafeType -eq "Personal Admin")  { $core = $core -replace $PersonalAdminSuffixRegex, '' }

    $tokens = @($core -split '-')
    $isValidRegion = $false
    foreach ($rk in $RegionPrefixes.Keys) { if ($rk -eq $tokens[0]) { $isValidRegion = $true; break } }

    # Environment/Technology/AccessType come from CLOSED code lists — unlike Team, which
    # is intentionally open-ended. A match is only accepted when Env/Technology are
    # recognised (and AccessType too, when present); otherwise this isn't really a
    # naming-convention name, just a region-prefixed string with enough dashes.
    $envTokCandidate  = if ($tokens.Count -ge 2) { $tokens[1] } else { $null }
    $techTokCandidate = if ($tokens.Count -ge 3) { $tokens[2] } else { $null }
    $envOk  = $envTokCandidate  -and (Test-TokenMapped $envTokCandidate  $EnvironmentTokens)
    $techOk = $techTokCandidate -and (Test-TokenMapped $techTokCandidate $TechnologyTokens)

    if ($tokens.Count -ge 3 -and $isValidRegion -and $envOk -and $techOk) {
        $envTok  = $tokens[1]
        $techTok = $tokens[2]
        $rest = @(if ($tokens.Count -gt 3) { $tokens[3..($tokens.Count-1)] })

        # A trailing purpose keyword (LOGON/SCAN/RECONCILE) is not part of AccessType/Team.
        if ($rest.Count -gt 0) {
            $lastRest = $rest[-1]
            foreach ($suf in $SafePurposeSuffixes.Keys) {
                if ($lastRest -eq $suf) {
                    $rest = @(if ($rest.Count -gt 1) { $rest[0..($rest.Count-2)] })
                    break
                }
            }
        }

        $accessTok = if ($rest.Count -ge 1) { $rest[0] } else { $null }
        if ($accessTok -and -not (Test-TokenMapped $accessTok $AccessTypeTokens)) {
            return [pscustomobject]@{ Environment="Unknown"; NamingTechnology="Unknown"; AccessType="Unknown"; Team="Not Tagged"; TeamName="Not Tagged" }
        }
        $teamParts = @(if ($rest.Count -ge 2) { $rest[1..($rest.Count-1)] })
        $team = if ($teamParts.Count -gt 0) { [string]$teamParts[-1] } else { "N/A (Not Present)" }
        if ($team -ne "N/A (Not Present)") { $team = $team.ToUpper() }

        return [pscustomobject]@{
            Environment      = Get-MappedToken $envTok  $EnvironmentTokens
            NamingTechnology = Get-MappedToken $techTok $TechnologyTokens
            AccessType       = if ($accessTok) { Get-MappedToken $accessTok $AccessTypeTokens } else { "N/A (Not Present)" }
            Team             = $team
            TeamName         = if ($team -eq "N/A (Not Present)") { $team } else { Get-MappedToken $team $TeamCodeMap }
        }
    }
    return [pscustomobject]@{ Environment="Unknown"; NamingTechnology="Unknown"; AccessType="Unknown"; Team="Not Tagged"; TeamName="Not Tagged" }
}
function Get-OSCategory { param([string]$p)
    foreach ($x in $WindowsPlatformPatterns)  { if ($p -like $x) { return "Windows" } }
    foreach ($x in $UnixPlatformPatterns)     { if ($p -like $x) { return "Unix/Linux" } }
    foreach ($x in $DatabasePlatformPatterns) { if ($p -like $x) { return "Database" } }
    foreach ($x in $CloudPlatformPatterns)    { if ($p -like $x) { return "Cloud" } }
    foreach ($x in $NetworkPlatformPatterns)  { if ($p -like $x) { return "Network" } }
    return "Other"
}
function Get-RotationDays { param([string]$p)
    foreach ($k in $RotationPolicyDays.Keys) { if ($p -like $k) { return $RotationPolicyDays[$k] } }
    return $DefaultRotationDays
}
function Test-SafeNaming { param([string]$s)
    if ([string]::IsNullOrWhiteSpace($SafeNameExpectedRegex)) { return $true }
    if ($s -match $SafeNameExpectedRegex)     { return $true }
    if ($s -match $PersonalAdminSuffixRegex)  { return $true }
    if ($s -match $SharedAdminSuffixRegex)    { return $true }
    return $false
}
function Test-AccountNaming { param([string]$n)
    if ([string]::IsNullOrWhiteSpace($AccountNameExpectedRegex)) { return $true }
    return ($n -match $AccountNameExpectedRegex)
}
function Test-AccountAddress { param([string]$a)
    if ([string]::IsNullOrWhiteSpace($AccountAddressExpectedRegex)) { return $true }
    return ($a -match $AccountAddressExpectedRegex)
}

#  ===============================================================================
#  INITIALISE
#  ===============================================================================
# $StorageContext is acquired OUTSIDE the try/finally below: if PamDataStorage
# itself is missing/malformed, there is no way to upload a log blob anyway (the
# very thing that would upload it needs this context) -- that one failure mode
# is only visible in Application Insights, not the Logs container.
$StorageContext  = Get-StorageAccountContext

# Ensure all three containers exist before anything else runs -- self-heals a
# deleted/never-created container, and fails fast with a clear message rather
# than every subsequent blob write 404'ing partway through the run.
foreach ($c in @($LatestContainer, $ArchiveContainer, $LogsContainer)) {
    New-BlobContainerIfMissing -Container $c
}

# Accumulates every Write-Log line so the whole run's log can be uploaded as
# ONE blob to the Logs container at the end -- inside a try/finally so this
# still happens even if the run fails partway through (exactly the runs you
# most want a log for).
$LogLines = [System.Collections.Generic.List[string]]::new()

try {

$ScriptStartTime = Get-Date
$ExtractDate     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$RunErrors       = [System.Collections.Generic.List[string]]::new()
$RecordCounts    = [ordered]@{}

Write-Log "═══════════════════════════════════════════════════════════" SECTION
Write-Log " CyberArk Dashboard (PAM + SCA) — Azure Function" SECTION
Write-Log "═══════════════════════════════════════════════════════════" SECTION
Write-Log "Extract Date : $ExtractDate" INFO
Write-Log "Output       : $LatestContainer (+ $ArchiveContainer/$ArchivePathPrefix, $LogsContainer/$RunTimestamp.log)" INFO

#  ===============================================================================
#  AUTHENTICATE
#  ===============================================================================
Write-Log "=== Authenticate ===" SECTION
Get-AuthToken

# ===============================================================================
#  MODULE 4 : PAM DATA COLLECTION (Privilege Cloud)
#  Creates - DIM_Safe, FACT_Users, FACT_Accounts, FACT_VaultConnectivity, FACT_OnboardingTrend, DIM_Region
# ===============================================================================

# ── 4.1 Safes → DIM_Safe ──────────────────────────────────────────────────────
Write-Log "=== 4.1: Collecting Safes ===" SECTION
$SafesRaw = Get-AllPaged -BaseUri "$PvwaBase/Safes" -ValueProp "value"

$DimSafe = @(foreach ($s in $SafesRaw) {
    $def = Test-IsDefaultSafe $s.safeName
    $created = ConvertFrom-Unix $s.creationTime
    $lastMod = ConvertFrom-UnixMicro $s.lastModificationTime
    $namingOk = if ($def) { $true } else { Test-SafeNaming $s.safeName }
    $safeType = Get-SafeType $s.safeName $def
    $teamTag  = Get-SafeTeamTag $s.safeName $safeType
    [pscustomobject]@{
        SafeName      = $s.safeName
        SafeUrlId     = $s.safeUrlId
        SafeNumber    = $s.safeNumber
        Description   = Safe-String $s.description
        Location      = Safe-String $s.location
        Creator       = Safe-String $s.creator.name
        ManagingCPM   = Safe-String $s.managingCPM
        NumberOfAccounts = [int]$s.numberOfAccounts
        OLACEnabled   = $s.olacEnabled
        AutoPurge     = $s.autoPurgeEnabled
        RetentionVersions = $s.numberOfVersionsRetention
        RetentionDays = $s.numberOfDaysRetention
        CreatedDate   = Format-DateOnly $created
        CreatedDateTime = Format-DateTime $created
        LastModifiedDateTime = Format-DateTime $lastMod
        IsDefault     = $def
        SafeType      = $safeType
        Region        = if ($def) { "N/A-Default" } else { Get-Region $s.safeName }
        Tier          = if ($def) { "N/A-Default" } else { Get-SafeTier $s.safeName $safeType }
        Environment   = $teamTag.Environment
        NamingTechnology = $teamTag.NamingTechnology
        AccessType    = $teamTag.AccessType
        Team          = $teamTag.Team
        TeamName      = $teamTag.TeamName
        SafePurpose   = Get-SafePurpose $s.safeName
        HasCPM        = -not [string]::IsNullOrWhiteSpace($s.managingCPM)
        IsEmpty       = ([int]$s.numberOfAccounts -eq 0)   # corrected below in 4.3
        RecentlyCreated = ($created -and (New-TimeSpan -Start $created -End (Get-Date)).Days -le $OnboardingWindowDays)
        NamingCompliant = $namingOk
        ExtractDate   = $ExtractDate
    }
})

$SafeLookup = @{}; foreach ($f in $DimSafe) { $SafeLookup[$f.SafeName] = $f }
$bizSafes = @($DimSafe | Where-Object { -not $_.IsDefault })
Write-Log "Safes: total=$($SafesRaw.Count) business=$($bizSafes.Count) default=$($DimSafe.Count - $bizSafes.Count)" SUCCESS
$RecordCounts["DIM_Safe"] = $DimSafe.Count

# ── 4.2 Users → FACT_Users ────────────────────────────────────────────────────
Write-Log "=== 4.2: Collecting Users ===" SECTION
$UsersResp = Invoke-ApiGet -Uri "$PvwaBase/Users?ExtendedDetails=True"
$UsersRaw  = if ($UsersResp.Users) { $UsersResp.Users } else { @() }

$FactUsers = @(foreach ($u in $UsersRaw) {
    $isComp = ($u.componentUser -eq $true) -or (Test-IsDefaultMember $u.username) -or ($u.userType -ne "EPVUser")
    $lastLogin = ConvertFrom-Unix $u.lastSuccessfulLoginDate
    $days = if ($lastLogin) { (New-TimeSpan -Start $lastLogin -End (Get-Date)).Days } else { $null }
    [pscustomobject]@{
        UserName       = $u.username
        UserID         = $u.id
        Source         = Safe-String $u.source
        UserType       = $u.userType
        ComponentUser  = $u.componentUser
        IsComponent    = $isComp
        Enabled        = $u.enableUser
        Suspended      = $u.suspended
        Location       = Safe-String $u.location
        FirstName      = Safe-String $u.personalDetails.firstName
        LastName       = Safe-String $u.personalDetails.lastName
        Email          = Safe-String $u.internet.businessEmail
        VaultAuth      = (($u.vaultAuthorization) -join "; ")
        PasswordNeverExpires = $u.passwordNeverExpires
        LastLoginDate  = Format-DateOnly $lastLogin
        LastLoginDateTime = Format-DateTime $lastLogin
        DaysSinceLogin = $days
        LoginStatus    = if (-not $lastLogin) { "Never Logged In" }
                         elseif ($days -le $LoginWindowDays) { "Active (<= $LoginWindowDays d)" }
                         else { "Dormant (> $LoginWindowDays d)" }
        ExtractDate    = $ExtractDate
    }
})

$realUsers = @($FactUsers | Where-Object { -not $_.IsComponent })
Write-Log "Users: total=$($UsersRaw.Count) real=$($realUsers.Count) active=$(@($realUsers | Where-Object { $_.LoginStatus -like 'Active*' }).Count)" SUCCESS
$RecordCounts["FACT_Users"] = $FactUsers.Count

# ── 4.3 Accounts → FACT_Accounts ──────────────────────────────────────────────
Write-Log "=== 4.3: Collecting Accounts ===" SECTION
$AcctRaw = Get-AllPaged -BaseUri "$PvwaBase/Accounts" -ValueProp "value"

$FactAccounts = @(foreach ($a in $AcctRaw) {
    $sfi      = $SafeLookup[$a.safeName]
    $defSafe  = if ($sfi) { $sfi.IsDefault } else { Test-IsDefaultSafe $a.safeName }
    $sm       = $a.secretManagement
    $auto     = ($sm.automaticManagementEnabled -eq $true)
    $lastChg  = ConvertFrom-Unix $sm.lastModifiedTime
    $lastVer  = ConvertFrom-Unix $sm.lastVerifiedTime
    $lastRec  = ConvertFrom-Unix $sm.lastReconciledTime
    $created  = ConvertFrom-Unix $a.createdTime
    $dChg     = if ($lastChg) { (New-TimeSpan -Start $lastChg -End (Get-Date)).Days } else { $null }
    $dVer     = if ($lastVer) { (New-TimeSpan -Start $lastVer -End (Get-Date)).Days } else { $null }
    $dAge     = if ($created) { (New-TimeSpan -Start $created -End (Get-Date)).Days } else { $null }
    $rot      = Get-RotationDays $a.platformId
    $cpmStat  = Safe-String $sm.status
    $comp     = switch ($cpmStat) { "success" { "Compliant" } "failure" { "Non-Compliant" } default { "Pending/Unknown" } }
    $safeType = if ($sfi) { $sfi.SafeType } else { Get-SafeType $a.safeName $defSafe }
    $region   = if ($sfi) { $sfi.Region } else { Get-Region $a.safeName }
    $tier     = if ($sfi) { $sfi.Tier }   else { Get-SafeTier $a.safeName $safeType }
    $teamTag  = if ($sfi) { [pscustomobject]@{ Environment=$sfi.Environment; NamingTechnology=$sfi.NamingTechnology; AccessType=$sfi.AccessType; Team=$sfi.Team; TeamName=$sfi.TeamName } } else { Get-SafeTeamTag $a.safeName $safeType }
    $safePurpose = if ($sfi) { $sfi.SafePurpose } else { Get-SafePurpose $a.safeName }
    $platId   = Safe-String $a.platformId "Unknown"
    $nameOk   = Test-AccountNaming (Safe-String $a.name)
    $addrOk   = Test-AccountAddress (Safe-String $a.address)

    [pscustomobject]@{
        AccountID         = Safe-String $a.id
        Name              = Safe-String $a.name
        UserName          = Safe-String $a.userName
        Address           = Safe-String $a.address
        SafeName          = Safe-String $a.safeName
        PlatformID        = $platId
        SecretType        = Safe-String $a.secretType
        IsDefaultSafe     = $defSafe
        SafeType          = $safeType
        Region            = $region
        Tier              = $tier
        Environment       = $teamTag.Environment
        NamingTechnology  = $teamTag.NamingTechnology
        AccessType        = $teamTag.AccessType
        Team              = $teamTag.Team
        TeamName          = $teamTag.TeamName
        SafePurpose       = $safePurpose
        OSCategory        = Get-OSCategory $platId
        AutoManaged       = $auto
        MgmtTechnique     = if ($auto) { "Automatic (APM)" } else { "Manual (MPM)" }
        ManualReason      = Safe-String $sm.manualManagementReason
        ComplianceStatus  = $comp
        SecretStatus      = $cpmStat
        LastChangeDate    = Format-DateOnly $lastChg
        LastChangeDateTime = Format-DateTime $lastChg
        DaysSinceChange   = $dChg
        ExpectedRotationDays = $rot
        RotationOverdue   = if ($null -ne $dChg) { $dChg -gt $rot } else { $false }
        LastVerifyDate    = Format-DateOnly $lastVer
        DaysSinceVerify   = $dVer
        VerifyStatus      = if (-not $auto) { "N/A (Manual)" }
                            elseif (-not $lastVer) { "Never Verified" }
                            elseif ($dVer -gt $VerifyOverdueDays) { "Overdue (> $VerifyOverdueDays d)" }
                            else { "Verified" }
        LastReconciledDate = Format-DateOnly $lastRec
        IsStale           = if ($null -ne $dChg) { $dChg -ge $StaleAccountDays } else { $false }
        CreatedDate       = Format-DateOnly $created
        CreatedMonth      = Format-MonthOnly $created
        AccountAgeDays    = $dAge
        RecentlyOnboarded = ($created -and (New-TimeSpan -Start $created -End (Get-Date)).Days -le $OnboardingWindowDays)
        NameCompliant     = $nameOk
        AddressCompliant  = $addrOk
        HasAddress        = -not [string]::IsNullOrWhiteSpace($a.address)
        ExtractDate       = $ExtractDate
    }
})

$biz = @($FactAccounts | Where-Object { -not $_.IsDefaultSafe })
Write-Log "Accounts: total=$($AcctRaw.Count) business=$($biz.Count)" SUCCESS
$RecordCounts["FACT_Accounts"] = $FactAccounts.Count


$acctCountBySafe = @{}
foreach ($fa in $FactAccounts) {
    if (-not $acctCountBySafe.ContainsKey($fa.SafeName)) { $acctCountBySafe[$fa.SafeName] = 0 }
    $acctCountBySafe[$fa.SafeName]++
}
foreach ($sf in $DimSafe) {
    $realCount = if ($acctCountBySafe.ContainsKey($sf.SafeName)) { $acctCountBySafe[$sf.SafeName] } else { 0 }
    $sf.NumberOfAccounts = $realCount
    $sf.IsEmpty = ($realCount -eq 0)
}

# ── 4.4 Vault Connectivity → FACT_VaultConnectivity ──────────────────────────
Write-Log "=== 4.4: Fetching Vault Connectivity ===" SECTION
$VaultRows = [System.Collections.Generic.List[PSCustomObject]]::new()
foreach ($compType in $VaultComponentIDs) {
    try {
        $vResp = Invoke-ApiGet -Uri "$PvwaBase/ComponentsMonitoringDetails/$compType/"
        if ($null -ne $vResp -and $null -ne $vResp.ComponentsDetails) {
            foreach ($d in $vResp.ComponentsDetails) {
                $VaultRows.Add([pscustomobject]@{
                    ComponentType    = $compType
                    InstanceIP       = Safe-String $d.ComponentIP
                    VaultUserName    = Safe-String $d.ComponentUserName
                    ComponentVersion = Safe-String $d.ComponentVersion
                    IsLoggedOn       = if ($d.IsLoggedOn -eq $true) { "TRUE" } else { "FALSE" }
                    LastLogonDate    = Format-DateTime (ConvertFrom-Unix $d.LastLogonDate)
                    ExtractDate      = $ExtractDate
                })
            }
            Write-Log "  $compType instances: $($vResp.ComponentsDetails.Count)" INFO
        }
    } catch {
        Write-Log "Failed vault details for ${compType}: $($_.Exception.Message)" ERROR
        $RunErrors.Add("VaultConnectivity ($compType): $($_.Exception.Message)")
    }
}
Write-Log "Vault connectivity records: $($VaultRows.Count)" SUCCESS
$RecordCounts["FACT_VaultConnectivity"] = $VaultRows.Count

# ── 4.5 Onboarding Trend → FACT_OnboardingTrend ──────────────────────────────
Write-Log "=== 4.5: Building Onboarding Trend Table ===" SECTION
$trendCutoff = [datetime]::new((Get-Date).AddMonths(-1 * $TrendLookbackMonths).Year, (Get-Date).AddMonths(-1 * $TrendLookbackMonths).Month, 1)

$acctTrend = $biz | Where-Object { $_.CreatedMonth -and ([datetime]::ParseExact("$($_.CreatedMonth)-01","yyyy-MM-dd",$null) -ge $trendCutoff) } |
    Group-Object CreatedMonth | Sort-Object Name
$safeTrend = $bizSafes | Where-Object { $_.CreatedDate -and ([datetime]$_.CreatedDate -ge $trendCutoff) } |
    ForEach-Object { [pscustomobject]@{ Month = ([datetime]$_.CreatedDate).ToString("yyyy-MM") } } |
    Group-Object Month | Sort-Object Name

$TrendRows = [System.Collections.Generic.List[PSCustomObject]]::new()
$mStart = $trendCutoff
while ($mStart -le (Get-Date)) {
    $mKey = $mStart.ToString("yyyy-MM")
    $acctCount = 0; $safeCount = 0
    $ag = $acctTrend | Where-Object { $_.Name -eq $mKey }; if ($ag) { $acctCount = $ag.Count }
    $sg = $safeTrend | Where-Object { $_.Name -eq $mKey }; if ($sg) { $safeCount = $sg.Count }
    $TrendRows.Add([pscustomobject]@{
        Month = $mKey; Year = $mStart.Year; MonthNumber = $mStart.Month; MonthName = $mStart.ToString("MMM")
        AccountsOnboarded = $acctCount; SafesCreated = $safeCount; ExtractDate = $ExtractDate
    })
    $mStart = $mStart.AddMonths(1)
}
Write-Log "Onboarding trend rows: $($TrendRows.Count)" SUCCESS
$RecordCounts["FACT_OnboardingTrend"] = $TrendRows.Count

# ── 4.6 Dimension: DIM_Region ─────────────────────────────────────────────────
Write-Log "=== 4.6: Generating DIM_Region ===" SECTION
$DimRegion = [System.Collections.Generic.List[PSCustomObject]]::new()
$seenRegions = @{}
foreach ($k in $RegionPrefixes.Keys) {
    $rn = $RegionPrefixes[$k]
    if (-not $seenRegions.ContainsKey($rn)) {
        $seenRegions[$rn] = $true
        $prefixes = @($RegionPrefixes.Keys | Where-Object { $RegionPrefixes[$_] -eq $rn }) -join ", "
        $DimRegion.Add([pscustomobject]@{ RegionKey=$rn; RegionName=$rn; Prefixes=$prefixes })
    }
}
$DimRegion.Add([pscustomobject]@{ RegionKey="Non-standard"; RegionName="Non-standard"; Prefixes="" })
$DimRegion.Add([pscustomobject]@{ RegionKey="N/A-Default"; RegionName="N/A-Default"; Prefixes="" })
$RecordCounts["DIM_Region"] = $DimRegion.Count

# ==============================================================================
# MODULE 5 : SCA DATA COLLECTION (Secure Cloud Access)
# Creates : SCA_Policies — every field the /policies API returns fields
# ==============================================================================
Write-Log "=== 5.1: Collecting SCA Access Policies ===" SECTION
$policiesResp = Invoke-ScaGet -Uri "$ScaBase/policies"
$policyHits = @($policiesResp.hits)


if ($policiesResp -and $policiesResp.total -gt $policyHits.Count) {
    Write-Log "WARNING: SCA /policies reports total=$($policiesResp.total) but only $($policyHits.Count) hits returned. This export may be INCOMPLETE." WARN
}
if ($policiesResp -and $policiesResp.PSObject.Properties.Name -contains "last_evaluated_key" -and $policiesResp.last_evaluated_key) {
    Write-Log "WARNING: SCA /policies response includes a populated 'last_evaluated_key' -- a second page likely exists. This export may be INCOMPLETE." WARN
}

$ScaPolicies = @(foreach ($p in $policyHits) {
    $statusCode = [int]$p.status
    $cloudCode  = [int]$p.cloudProvider
    $entities     = @($p.entities)
    $userEntities = @($entities | Where-Object { $_.entityType -eq 1 })
    $roleEntities = @($entities | Where-Object { $_.entityType -eq 0 })
    [pscustomobject]@{
        PolicyId               = Safe-String $p.policyId
        Name                   = Safe-String $p.name
        Description            = Safe-String $p.description
        Status                 = $statusCode
        StatusLabel            = if ($PolicyStatusMap.ContainsKey($statusCode)) { $PolicyStatusMap[$statusCode] } else { "Unknown ($statusCode)" }

        PrimaryStatus          = Safe-String $p.primaryStatus
        CloudProvider          = $cloudCode
        CloudProviderLabel     = if ($CloudProviderMap.ContainsKey($cloudCode)) { $CloudProviderMap[$cloudCode] } else { "Unknown ($cloudCode)" }
        CreationDate           = Safe-DateString $p.creationDate
        LastChanged            = Safe-DateString $p.lastChanged
        StartDate              = Safe-DateString $p.startDate
        ExpirationDate         = Safe-DateString $p.expirationDate
        MaxSessionDurationHours = if ($p.accessRules -and $p.accessRules.maxSessionDuration) { $p.accessRules.maxSessionDuration } else { $null }
        UserEntityCount        = $userEntities.Count
        RoleEntityCount        = $roleEntities.Count
        FaultCode              = Safe-String $p.faultCode
        StatusTooltipMessage   = Safe-String $p.statusTooltipMessage
        ExtractDate            = $ExtractDate
    }
})
Write-Log "SCA Policies: $($ScaPolicies.Count)" SUCCESS
$RecordCounts["SCA_Policies"] = $ScaPolicies.Count

# ===============================================================================
# MODULE 6 : CSV EXPORT
# Writes CSVs (PAM + SCA) to Blob Storage -- "Latest/<name>.csv" (overwritten
# each run, the Power BI data source) AND "Archive/<RunTimestamp>/<name>.csv"
# (historical snapshot), same as the on-prem Latest\/Archive\ folders.
# ===============================================================================
Write-Log "=== 6: Exporting CSV Files to Blob Storage ===" SECTION

$CsvExports = @(
    @{ Name="DIM_Region";            Data=$DimRegion;
       Cols=@("RegionKey","RegionName","Prefixes") },
    @{ Name="DIM_Safe";              Data=$DimSafe;
       Cols=@("SafeName","SafeUrlId","SafeNumber","Description","Location","Creator","ManagingCPM","NumberOfAccounts","OLACEnabled","AutoPurge","RetentionVersions","RetentionDays","CreatedDate","CreatedDateTime","LastModifiedDateTime","IsDefault","SafeType","Region","Tier","Environment","NamingTechnology","AccessType","Team","TeamName","SafePurpose","HasCPM","IsEmpty","RecentlyCreated","NamingCompliant","ExtractDate") },
    @{ Name="FACT_Accounts";         Data=$FactAccounts;
       Cols=@("AccountID","Name","UserName","Address","SafeName","PlatformID","SecretType","IsDefaultSafe","SafeType","Region","Tier","Environment","NamingTechnology","AccessType","Team","TeamName","SafePurpose","OSCategory","AutoManaged","MgmtTechnique","ManualReason","ComplianceStatus","SecretStatus","LastChangeDate","LastChangeDateTime","DaysSinceChange","ExpectedRotationDays","RotationOverdue","LastVerifyDate","DaysSinceVerify","VerifyStatus","LastReconciledDate","IsStale","CreatedDate","CreatedMonth","AccountAgeDays","RecentlyOnboarded","NameCompliant","AddressCompliant","HasAddress","ExtractDate") },
    @{ Name="FACT_Users";            Data=$FactUsers;
       Cols=@("UserName","UserID","Source","UserType","ComponentUser","IsComponent","Enabled","Suspended","Location","FirstName","LastName","Email","VaultAuth","PasswordNeverExpires","LastLoginDate","LastLoginDateTime","DaysSinceLogin","LoginStatus","ExtractDate") },
    @{ Name="FACT_VaultConnectivity";Data=$VaultRows;
       Cols=@("ComponentType","InstanceIP","VaultUserName","ComponentVersion","IsLoggedOn","LastLogonDate","ExtractDate") },
    @{ Name="FACT_OnboardingTrend";  Data=$TrendRows;
       Cols=@("Month","Year","MonthNumber","MonthName","AccountsOnboarded","SafesCreated","ExtractDate") },
    @{ Name="SCA_Policies";          Data=$ScaPolicies;
       Cols=@("PolicyId","Name","Description","Status","StatusLabel","PrimaryStatus","CloudProvider","CloudProviderLabel","CreationDate","LastChanged","StartDate","ExpirationDate","MaxSessionDurationHours","UserEntityCount","RoleEntityCount","FaultCode","StatusTooltipMessage","ExtractDate") }
)

foreach ($export in $CsvExports) {
    try {
        if ($export.Data.Count -gt 0) {
            $csvText = ($export.Data | Select-Object -Property $export.Cols | ConvertTo-Csv -NoTypeInformation) -join "`r`n"
        } else {
            $csvText = ($export.Cols | ForEach-Object { '"' + $_ + '"' }) -join ','
        }
        Send-BlobText -Container $LatestContainer  -BlobPath "$($export.Name).csv"                         -Content $csvText
        Send-BlobText -Container $ArchiveContainer -BlobPath "$ArchivePathPrefix/$($export.Name).csv"      -Content $csvText
        Write-Log "  [OK] $($export.Name) ($($export.Data.Count) rows)" SUCCESS
    } catch {
        Write-Log "  [FAIL] $($export.Name): $($_.Exception.Message)" ERROR
        $RunErrors.Add("CSV Export ($($export.Name)): $($_.Exception.Message)")
    }
}

# =============================================================================
#  MODULE 7 : RUN SUMMARY
#  Writes run metadata to Blob Storage, prints console/App Insights report.
# =============================================================================

$ScriptEndTime   = Get-Date
$DurationSeconds = [math]::Round(($ScriptEndTime - $ScriptStartTime).TotalSeconds, 1)
$RunInfo = [ordered]@{
    RunTimestamp      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssK")
    DurationSeconds   = $DurationSeconds
    Status            = if ($RunErrors.Count -eq 0) { "Success" } else { "CompletedWithErrors" }
    ExtractDate       = $ExtractDate
    PowerShellVersion = "$($PSVersionTable.PSVersion)"
    RecordCounts      = $RecordCounts
    Errors            = $RunErrors
}
$runInfoJson = ($RunInfo | ConvertTo-Json -Depth 4)
try {
    Send-BlobText -Container $LatestContainer  -BlobPath "_RunMetadata.json"                         -Content $runInfoJson -ContentType "application/json"
    Send-BlobText -Container $ArchiveContainer -BlobPath "$ArchivePathPrefix/_RunMetadata.json"      -Content $runInfoJson -ContentType "application/json"
    Write-Log "Run metadata written to Blob Storage." SUCCESS
} catch {
    Write-Log "Failed to write run metadata: $($_.Exception.Message)" ERROR
    $RunErrors.Add("RunMetadata: $($_.Exception.Message)")
}

# ── Console summary (Application Insights / Functions log stream) ───────────
$Divider = "=" * 75; $SubDivider = "-" * 75
Write-Host ""
Write-Host $Divider
Write-Host "  CYBERARK DASHBOARD (PAM + SCA) — AZURE FUNCTION"
Write-Host "  Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Write-Host "  Duration  : $DurationSeconds seconds"
Write-Host $Divider

Write-Host ""
Write-Host "  PAM INVENTORY"
Write-Host $SubDivider
Write-Host ("  Safes               : {0} total | {1} business | {2} default" -f $DimSafe.Count, $bizSafes.Count, ($DimSafe.Count - $bizSafes.Count))
Write-Host ("  Accounts            : {0} total | {1} business" -f $AcctRaw.Count, $biz.Count)
Write-Host ("  Users               : {0} total | {1} real | {2} active" -f $UsersRaw.Count, $realUsers.Count, @($realUsers | Where-Object { $_.LoginStatus -like 'Active*' }).Count)

Write-Host ""
Write-Host "  PAM COMPLIANCE"
Write-Host $SubDivider
$compliant = @($biz | Where-Object { $_.ComplianceStatus -eq "Compliant" }).Count
$compRate  = if ($biz.Count -gt 0) { [math]::Round(($compliant / $biz.Count) * 100, 1) } else { 0 }
Write-Host ("  Compliance Rate     : {0}%" -f $compRate)
Write-Host ("  Rotation Overdue    : {0}" -f @($biz | Where-Object { $_.RotationOverdue }).Count)
Write-Host ("  Empty Safes         : {0}" -f @($bizSafes | Where-Object { $_.IsEmpty }).Count)

Write-Host ""
Write-Host "  PAM VAULT CONNECTIVITY"
Write-Host $SubDivider
foreach ($compType in $VaultComponentIDs) {
    $typeRows = @($VaultRows | Where-Object { $_.ComponentType -eq $compType })
    $loggedOn = @($typeRows | Where-Object { $_.IsLoggedOn -eq "TRUE" }).Count
    if ($typeRows.Count -gt 0) {
        Write-Host ("  {0,-20} : {1} total | {2} connected" -f $compType, $typeRows.Count, $loggedOn)
    }
}

Write-Host ""
Write-Host "  SCA ACCESS POLICIES"
Write-Host $SubDivider
Write-Host ("  Total Policies      : {0}" -f $ScaPolicies.Count)
Write-Host ("  Active Policies     : {0}" -f @($ScaPolicies | Where-Object StatusLabel -eq "Active").Count)
Write-Host ("  Error Policies      : {0}" -f @($ScaPolicies | Where-Object StatusLabel -eq "Error").Count)

Write-Host ""
Write-Host "  OUTPUT"
Write-Host $SubDivider
Write-Host ("  CSV Files           : {0}" -f $CsvExports.Count)
Write-Host ("  Latest (Power BI)   : {0}" -f $LatestContainer)
Write-Host ("  Archive (This Run)  : {0}/{1}" -f $ArchiveContainer, $ArchivePathPrefix)
Write-Host ("  Log (This Run)      : {0}/{1}.log" -f $LogsContainer, $RunTimestamp)
Write-Host ("  Duration            : {0}s" -f $DurationSeconds)
Write-Host ("  Errors              : {0}" -f $RunErrors.Count)
if ($RunErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  Error Details:"
    foreach ($err in $RunErrors) { Write-Host "    * $err" }
}
Write-Host ""
Write-Host $Divider
Write-Log "=== CyberArk Dashboard Complete ===" SECTION

} catch {
    Write-Log "FATAL: $($_.Exception.Message)" ERROR
    $FatalError = $_
} finally {
    # Upload the accumulated log as one blob, named by run timestamp, regardless
    # of whether the run above succeeded or threw -- a failed run's log is the
    # one you most need to see.
    try {
        $logText = ($LogLines -join "`r`n")
        Send-BlobText -Container $LogsContainer -BlobPath "$RunTimestamp.log" -Content $logText -ContentType "text/plain; charset=utf-8"
    } catch {
        $uploadErrMsg = "Failed to upload log blob to '$LogsContainer/$RunTimestamp.log': $($_.Exception.Message)"
        Write-Host $uploadErrMsg
        # Fallback so this is visible WITHOUT Application Insights access: write
        # the caught error itself into the Latest container, which by this point
        # in the run has already proven to accept writes successfully.
        try {
            Send-BlobText -Container $LatestContainer -BlobPath "_LastLogUploadError.txt" -Content $uploadErrMsg -ContentType "text/plain; charset=utf-8"
        } catch {
            # Nothing more we can do to surface this -- both the intended log
            # write and this fallback failed. Falls through to Write-Host only.
        }
    }
}

if ($FatalError) {
    # Re-throw after the log is safely uploaded, so Azure Functions still marks
    # this invocation as Failed (for retry policy / monitoring) rather than
    # silently swallowing the error.
    throw $FatalError
}
