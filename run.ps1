<#
.SYNOPSIS
    CyberArk Power BI Dashboard Data Exporter — Privilege Cloud + Secure Cloud
    Access (SCA)
.DESCRIPTION
    READ-ONLY script that authenticates once to CyberArk and exports
    both the Privilege Cloud (PAM) data and the Secure Cloud Access (SCA) data — into Latest\ folder.

    The script is organized into labeled MODULES
      MODULE 1 — Configuration           (Sections A-J)
      MODULE 2 — Shared helpers          (logging, auth, HTTP retry wrappers)
      MODULE 3 — Classification functions (region/tier/safe-type/team-tag parsing)
      MODULE 4 — PAM data collection      (Privilege Cloud: Safes/Users/Accounts/Vault/Onboarding)
      MODULE 5 — SCA data collection      (Secure Cloud Access: Policies)
      MODULE 6 — CSV export               (writes everything to Latest\)
      MODULE 7 — Run summary              (console report + run metadata JSON)

    Output Structure:
      Latest\   — Power BI data source (fixed filenames, overwritten each run)
      Archive\  — Historical snapshots (timestamped subfolders)
.NOTES
    Author   : Mohan C
    Requires : PowerShell 5.1+
               A CyberArk service account with:
                 - Privilege Cloud Administrator or Auditor role (for the PAM module)
                 - The SCA API role granted in Identity Administration
#>


#=========================================================================
# MODULE 1 : CONFIGURATION
#=========================================================================

# ── Section A: Credentials ──────────────────────────────────────────────
$IdentityTenantId  = "XXXXXXXXXXXXXXX"
$ServiceUserId     = "XXXXXXXXXXXXX"
$ServiceUserSecret = "XXXXXXXXXXXXXXXXXXXXXX"
$Subdomain         = "XXXXXXXXX"
$ScaSubdomain      = "XXXXXXXX"

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
# Personal Admin safes carry no tier in their own NAME -- but the accounts inside
# them often have a PlatformID that DOES end in a tier suffix (e.g. "...-T1").
# When present, that becomes the safe's (and its accounts') real Tier instead of
# the placeholder above -- see the correction pass in Module 4.3.
$PersonalAdminPlatformTierRegex = '-T([012])$'

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
# URLS & PATHS
# ==============================================================================
$IdentityUrl = "https://$IdentityTenantId.id.cyberark.cloud"
$PvwaBase    = "https://$Subdomain.privilegecloud.cyberark.cloud/PasswordVault/API"
$ScaBase     = "https://$ScaSubdomain.sca.cyberark.cloud/api"

$ScriptRoot   = $PSScriptRoot
$LatestDir    = "$ScriptRoot\Latest"
$ArchiveRoot  = "$ScriptRoot\Archive"
$RunTimestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$ArchiveDir   = "$ArchiveRoot\$RunTimestamp"
$LogFile      = "$LatestDir\DashboardExport.log"

if ([string]::IsNullOrWhiteSpace($SafeNameExpectedRegex)) {
    $prefixAlts = ($RegionPrefixes.Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $SafeNameExpectedRegex = "^($prefixAlts)[-_ ]"
}

try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}


# ==============================================================================
# MODULE 2 : HELPERS            
# Logging, authentication (ONE token, reused for both PAM and SCA calls)
# ==============================================================================

function Write-Log {
    param([string]$Message,
          [ValidateSet("INFO","WARN","ERROR","SUCCESS","DEBUG","SECTION")][string]$Level="INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"),$Level,$Message
    Add-Content -Path $LogFile -Value $line
    $c = @{INFO="Cyan";WARN="Yellow";ERROR="Red";SUCCESS="Green";DEBUG="DarkGray";SECTION="Magenta"}[$Level]
    Write-Host $line -ForegroundColor $c
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
        Write-Log "Cannot continue without a valid token. Exiting." ERROR
        exit 1
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
    return "Personal"
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
New-Item -ItemType Directory -Path $LatestDir  -Force | Out-Null
New-Item -ItemType Directory -Path $ArchiveDir -Force | Out-Null
if (Test-Path $LogFile) { Remove-Item $LogFile -Force }

$ScriptStartTime = Get-Date
$ExtractDate     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
$RunErrors       = [System.Collections.Generic.List[string]]::new()
$RecordCounts    = [ordered]@{}

Write-Log "═══════════════════════════════════════════════════════════" SECTION
Write-Log " CyberArk Dashboard (PAM + SCA)" SECTION
Write-Log "═══════════════════════════════════════════════════════════" SECTION
Write-Log "Extract Date : $ExtractDate" INFO
Write-Log "Output       : $LatestDir" INFO

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

# Personal Admin safes only got the "Personal/All-Tiers" placeholder Tier above
# (their SAFE name has no T0/T1/T2 in it). If any account inside one of them has
# a PlatformID ending in a real tier suffix (e.g. "...-T1"), use that instead --
# corrected in place on both DIM_Safe and FACT_Accounts, same pattern as the
# NumberOfAccounts/IsEmpty fix above. Safes with no such account keep the
# placeholder unchanged.
$personalAdminSafes = @($DimSafe | Where-Object { $_.SafeType -eq "Personal Admin" -and $_.Tier -eq $PersonalAdminTierLabel })
if ($personalAdminSafes.Count -gt 0) {
    $acctsBySafeName = @{}
    foreach ($fa in $FactAccounts) {
        if (-not $acctsBySafeName.ContainsKey($fa.SafeName)) { $acctsBySafeName[$fa.SafeName] = [System.Collections.Generic.List[object]]::new() }
        $acctsBySafeName[$fa.SafeName].Add($fa)
    }
    foreach ($sf in $personalAdminSafes) {
        if (-not $acctsBySafeName.ContainsKey($sf.SafeName)) { continue }
        $platformTier = $null
        foreach ($acct in $acctsBySafeName[$sf.SafeName]) {
            if ($acct.PlatformID -match $PersonalAdminPlatformTierRegex) { $platformTier = "T$($matches[1])"; break }
        }
        if ($platformTier) {
            $sf.Tier = $platformTier
            foreach ($acct in $acctsBySafeName[$sf.SafeName]) { $acct.Tier = $platformTier }
        }
    }
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
$DimRegion.Add([pscustomobject]@{ RegionKey="Personal"; RegionName="Personal"; Prefixes="" })
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
# Writes csv files (PAM + SCA) to the Latest\ folder.
# ===============================================================================
Write-Log "=== 6: Exporting CSV Files ===" SECTION

$CsvExports = @(
    @{ Name="DIM_Region";            Data=$DimRegion;            File="$LatestDir\DIM_Region.csv";
       Cols=@("RegionKey","RegionName","Prefixes") },
    @{ Name="DIM_Safe";              Data=$DimSafe;              File="$LatestDir\DIM_Safe.csv";
       Cols=@("SafeName","SafeUrlId","SafeNumber","Description","Location","Creator","ManagingCPM","NumberOfAccounts","OLACEnabled","AutoPurge","RetentionVersions","RetentionDays","CreatedDate","CreatedDateTime","LastModifiedDateTime","IsDefault","SafeType","Region","Tier","Environment","NamingTechnology","AccessType","Team","TeamName","SafePurpose","HasCPM","IsEmpty","RecentlyCreated","NamingCompliant","ExtractDate") },
    @{ Name="FACT_Accounts";         Data=$FactAccounts;         File="$LatestDir\FACT_Accounts.csv";
       Cols=@("AccountID","Name","UserName","Address","SafeName","PlatformID","SecretType","IsDefaultSafe","SafeType","Region","Tier","Environment","NamingTechnology","AccessType","Team","TeamName","SafePurpose","OSCategory","AutoManaged","MgmtTechnique","ManualReason","ComplianceStatus","SecretStatus","LastChangeDate","LastChangeDateTime","DaysSinceChange","ExpectedRotationDays","RotationOverdue","LastVerifyDate","DaysSinceVerify","VerifyStatus","LastReconciledDate","IsStale","CreatedDate","CreatedMonth","AccountAgeDays","RecentlyOnboarded","NameCompliant","AddressCompliant","HasAddress","ExtractDate") },
    @{ Name="FACT_Users";            Data=$FactUsers;            File="$LatestDir\FACT_Users.csv";
       Cols=@("UserName","UserID","Source","UserType","ComponentUser","IsComponent","Enabled","Suspended","Location","FirstName","LastName","Email","VaultAuth","PasswordNeverExpires","LastLoginDate","LastLoginDateTime","DaysSinceLogin","LoginStatus","ExtractDate") },
    @{ Name="FACT_VaultConnectivity";Data=$VaultRows;            File="$LatestDir\FACT_VaultConnectivity.csv";
       Cols=@("ComponentType","InstanceIP","VaultUserName","ComponentVersion","IsLoggedOn","LastLogonDate","ExtractDate") },
    @{ Name="FACT_OnboardingTrend";  Data=$TrendRows;            File="$LatestDir\FACT_OnboardingTrend.csv";
       Cols=@("Month","Year","MonthNumber","MonthName","AccountsOnboarded","SafesCreated","ExtractDate") },
    @{ Name="SCA_Policies";          Data=$ScaPolicies;          File="$LatestDir\SCA_Policies.csv";
       Cols=@("PolicyId","Name","Description","Status","StatusLabel","PrimaryStatus","CloudProvider","CloudProviderLabel","CreationDate","LastChanged","StartDate","ExpirationDate","MaxSessionDurationHours","UserEntityCount","RoleEntityCount","FaultCode","StatusTooltipMessage","ExtractDate") }
)

foreach ($export in $CsvExports) {
    try {
        if ($export.Data.Count -gt 0) {
            $export.Data | Export-Csv -Path $export.File -NoTypeInformation -Encoding UTF8 -Force
            Write-Log "  [OK] $($export.Name) ($($export.Data.Count) rows)" SUCCESS
        } else {
            $headerLine = ($export.Cols | ForEach-Object { '"' + $_ + '"' }) -join ','
            Set-Content -Path $export.File -Value $headerLine -Encoding UTF8 -Force
            Write-Log "  [--] $($export.Name) (0 rows - header-only placeholder)" INFO
        }
    } catch {
        Write-Log "  [FAIL] $($export.Name): $($_.Exception.Message)" ERROR
        $RunErrors.Add("CSV Export ($($export.Name)): $($_.Exception.Message)")
    }
}

# =============================================================================
#  MODULE 7 : RUN SUMMARY                                                
#  Archives this run's output, writes run metadata, prints console report.
# =============================================================================

Write-Log "=== 7: Archive & Metadata ===" SECTION
try {
    Get-ChildItem -Path $LatestDir -File | ForEach-Object { Copy-Item -Path $_.FullName -Destination $ArchiveDir -Force }
    Write-Log "All files archived to: $ArchiveDir" SUCCESS
} catch {
    Write-Log "Failed to archive: $($_.Exception.Message)" ERROR
    $RunErrors.Add("Archive: $($_.Exception.Message)")
}

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
($RunInfo | ConvertTo-Json -Depth 4) | Out-File -FilePath "$LatestDir\_RunMetadata.json" -Encoding UTF8 -Force
Write-Log "Run metadata written: $LatestDir\_RunMetadata.json" SUCCESS

# ── Console summary ───────────────────────────────────────────────────────────
$Divider = "=" * 75; $SubDivider = "-" * 75
Write-Host ""
Write-Host $Divider -ForegroundColor White
Write-Host "  CYBERARK DASHBOARD (PAM + SCA)" -ForegroundColor White
Write-Host "  Generated : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  Duration  : $DurationSeconds seconds" -ForegroundColor White
Write-Host $Divider -ForegroundColor White

Write-Host ""
Write-Host "  PAM INVENTORY" -ForegroundColor Cyan
Write-Host $SubDivider -ForegroundColor DarkGray
Write-Host ("  Safes               : {0} total | {1} business | {2} default" -f $DimSafe.Count, $bizSafes.Count, ($DimSafe.Count - $bizSafes.Count)) -ForegroundColor White
Write-Host ("  Accounts            : {0} total | {1} business" -f $AcctRaw.Count, $biz.Count) -ForegroundColor White
Write-Host ("  Users               : {0} total | {1} real | {2} active" -f $UsersRaw.Count, $realUsers.Count, @($realUsers | Where-Object { $_.LoginStatus -like 'Active*' }).Count) -ForegroundColor White

Write-Host ""
Write-Host "  PAM COMPLIANCE" -ForegroundColor Cyan
Write-Host $SubDivider -ForegroundColor DarkGray
$compliant = @($biz | Where-Object { $_.ComplianceStatus -eq "Compliant" }).Count
$compRate  = if ($biz.Count -gt 0) { [math]::Round(($compliant / $biz.Count) * 100, 1) } else { 0 }
Write-Host ("  Compliance Rate     : {0}%" -f $compRate) -ForegroundColor $(if ($compRate -ge 90) { "Green" } elseif ($compRate -ge 70) { "Yellow" } else { "Red" })
Write-Host ("  Rotation Overdue    : {0}" -f @($biz | Where-Object { $_.RotationOverdue }).Count) -ForegroundColor White
Write-Host ("  Empty Safes         : {0}" -f @($bizSafes | Where-Object { $_.IsEmpty }).Count) -ForegroundColor White

Write-Host ""
Write-Host "  PAM VAULT CONNECTIVITY" -ForegroundColor Cyan
Write-Host $SubDivider -ForegroundColor DarkGray
foreach ($compType in $VaultComponentIDs) {
    $typeRows = @($VaultRows | Where-Object { $_.ComponentType -eq $compType })
    $loggedOn = @($typeRows | Where-Object { $_.IsLoggedOn -eq "TRUE" }).Count
    if ($typeRows.Count -gt 0) {
        Write-Host ("  {0,-20} : {1} total | {2} connected" -f $compType, $typeRows.Count, $loggedOn) -ForegroundColor $(if ($loggedOn -lt $typeRows.Count) { "Red" } else { "Green" })
    }
}

Write-Host ""
Write-Host "  SCA ACCESS POLICIES" -ForegroundColor Cyan
Write-Host $SubDivider -ForegroundColor DarkGray
Write-Host ("  Total Policies      : {0}" -f $ScaPolicies.Count) -ForegroundColor White
Write-Host ("  Active Policies     : {0}" -f @($ScaPolicies | Where-Object StatusLabel -eq "Active").Count) -ForegroundColor Green
Write-Host ("  Error Policies      : {0}" -f @($ScaPolicies | Where-Object StatusLabel -eq "Error").Count) -ForegroundColor $(if (@($ScaPolicies | Where-Object StatusLabel -eq "Error").Count -gt 0) { "Red" } else { "Green" })

Write-Host ""
Write-Host "  OUTPUT" -ForegroundColor Cyan
Write-Host $SubDivider -ForegroundColor DarkGray
Write-Host ("  CSV Files           : {0}" -f $CsvExports.Count) -ForegroundColor Green
Write-Host ("  Latest (Power BI)   : {0}" -f $LatestDir) -ForegroundColor Green
Write-Host ("  Archive (This Run)  : {0}" -f $ArchiveDir) -ForegroundColor Green
Write-Host ("  Duration            : {0}s" -f $DurationSeconds) -ForegroundColor White
Write-Host ("  Errors              : {0}" -f $RunErrors.Count) -ForegroundColor $(if ($RunErrors.Count -gt 0) { "Red" } else { "Green" })
if ($RunErrors.Count -gt 0) {
    Write-Host ""
    Write-Host "  Error Details:" -ForegroundColor Red
    foreach ($err in $RunErrors) { Write-Host "    * $err" -ForegroundColor Red }
}
Write-Host ""
Write-Host $Divider -ForegroundColor White
Write-Log "=== CyberArk Dashboard Complete ===" SECTION
