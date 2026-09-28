<#

.\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892"

.\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892" -Month 2026-08


.\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892" -StartDate 2026-09-01 -EndDate 2026-09-30

.SYNOPSIS
    Downloads ALL EPM events for a specific computer, for a given month (or date
    range), from CyberArk EPM (cloud).

.DESCRIPTION
    Built against the OFFICIAL EPM REST API docs (docs.cyberark.com/epm/latest/en/content/webservices):

      1. EPM authentication
         POST https://<LoginServer>/EPM/API/Auth/EPM/Logon
         Docs: .../webservices/serverauthentication.htm
         -> Returns ManagerURL (the tenant's real API host) + EPMAuthenticationResult (token)

      2. Get sets list
         GET https://<ManagerURL>/EPM/API/Sets
         Docs: .../webservices/getsetslist.htm

      3. Get endpoints (resolve the computer name -> its stable agentId)
         POST https://<ManagerURL>/EPM/API/Sets/<SetId>/Endpoints/search
         Docs: .../webservices/endpoint-apis/get-endpoints.htm
         The endpoint object's "legacyId" is the same identifier the deprecated
         "Get computers" API called "AgentId" - it's what the events API's
         "agentId" filter expects.

      4. Get detailed raw events (per-occurrence, not aggregated), filtered
         server-side by agentId + date range (and optionally eventType)
         POST https://<ManagerURL>/EPM/API/Sets/<SetId>/Events/Search
         Docs: .../webservices/getdetailedrawevents.htm

    WHY agentId AND NOT computerName:
      Neither Events/Search nor Events/Aggregations/Search supports a
      "computerName" filter server-side. The documented filter fields are:
      aggregatedBy, eventType, fileName, fileLocation, sourceName, publisher,
      productName, policyName, hash, eventDate, justification,
      justificationEmail, justificationType, jitRequestInterval,
      applicationType, userIsAdmin, agentId, user, fileDescription.
      "agentId" (IN operator) IS documented and lets EPM do the filtering for
      us, which is far more efficient than pulling a whole set's events for a
      month and filtering client-side. If the account calling this script
      lacks permission to call Get Endpoints, the script automatically falls
      back to pulling all events in the date range and filtering client-side
      on the event's "lastEventComputerName" field instead.

    ALL EVENT TYPES BY DEFAULT:
      Leave -EventType unset to get everything (ThreatProtection, application
      events - ElevationRequest/ManualRequest/Trust/Installation/Launch/
      Block/RestrictAccess/DetectAccess/Ransomware -, and Skipped). Pass
      -EventType to narrow it down (e.g. -EventType ManualRequest,ElevationRequest).

.PARAMETER LoginServer
    The EPM dispatcher / login host you normally sign in through, e.g. login.epm.cyberark.com

.PARAMETER Credential
    PSCredential for the EPM user. If omitted, you'll be prompted securely.

.PARAMETER ApplicationID
    Free-text string identifying the caller to EPM (shows up in EPM's own logs).

.PARAMETER ComputerName
    Substring to match against the endpoint / computer name, e.g. "17892".

.PARAMETER Month
    Calendar month to pull, format "yyyy-MM" (e.g. "2026-09"). Ignored if
    -StartDate/-EndDate are supplied. Defaults to the CURRENT month if none
    of -Month, -StartDate, -EndDate are given.

.PARAMETER StartDate
.PARAMETER EndDate
    Optional explicit UTC date bounds (yyyy-MM-dd or full ISO-8601). Overrides
    -Month when both are supplied. Supply both together.

.PARAMETER EventType
    Optional. One or more EPM event types (ManualRequest, ElevationRequest,
    Trust, Installation, Launch, Block, RestrictAccess, DetectAccess,
    Ransomware, Skipped, AttackAttempt, AttackBlock,
    SuspiciousActivityAttempt, SuspiciousActivityBlock). Default: none
    specified = ALL event types are returned.

.PARAMETER JitOnly
    If set, additionally restricts results to justificationType EQ 1
    (JIT elevation requests only, vs. justificationType 2 = "other request").
    Only meaningful alongside ManualRequest / ElevationRequest events.

.PARAMETER SetId
    Optional. If you already know the Set ID, skip the interactive picker.

.PARAMETER OutCsv
    Optional path for the CSV export. If omitted, a file named
    EPM_AllEvents_<ComputerName>_<range>.csv is written to the current folder.

.EXAMPLE
    # All events for computer "17892" for the current month, auto-saved to CSV
    .\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892"

.EXAMPLE
    # All events for a specific month
    .\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892" -Month 2026-08

.EXAMPLE
    # Just JIT requests, explicit date range, explicit set, explicit CSV path
    .\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892" `
        -SetId "2195bd87-36ec-4ae0-8f35-661d0254e441" -StartDate 2026-09-01 -EndDate 2026-09-30 `
        -EventType ManualRequest,ElevationRequest -JitOnly -OutCsv .\jit_only.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LoginServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$ApplicationID = "PS-EPM-EventExport",

    [Parameter(Mandatory)]
    [string]$ComputerName,

    [Parameter()]
    [string]$Month,

    [Parameter()]
    [string]$StartDate,

    [Parameter()]
    [string]$EndDate,

    [Parameter()]
    [string[]]$EventType = @(),

    [Parameter()]
    [switch]$JitOnly,

    [Parameter()]
    [string]$SetId,

    [Parameter()]
    [string]$OutCsv
)

# Ensure TLS 1.2
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-HostOnly {
    # EPM sometimes returns ManagerURL WITH a scheme (e.g. "https://na206.epm.cyberark.com")
    # and callers might pass -LoginServer WITH a scheme too. Normalize to a bare host so we
    # never accidentally build "https://https://...".
    param([string]$UrlOrHost)
    $h = $UrlOrHost.Trim()
    $h = $h -replace '^https?://', ''
    $h = $h.TrimEnd('/')
    return $h
}

function Convert-ToIsoDate {
    param([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }
    $dt = [datetime]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    return $dt.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-MonthRange {
    param([string]$MonthString)
    $first = [datetime]::ParseExact("$MonthString-01", "yyyy-MM-dd", [System.Globalization.CultureInfo]::InvariantCulture)
    $first = [datetime]::SpecifyKind($first, [DateTimeKind]::Utc)
    $lastInstant = $first.AddMonths(1).AddSeconds(-1)
    return [PSCustomObject]@{
        Start = $first.ToString("yyyy-MM-ddTHH:mm:ssZ")
        End   = $lastInstant.ToString("yyyy-MM-ddTHH:mm:ssZ")
    }
}

# ---------------------------------------------------------------------------
# Resolve the date range (explicit Start/End wins; otherwise -Month;
# otherwise default to the current month)
# ---------------------------------------------------------------------------
if ($StartDate -or $EndDate) {
    if (-not ($StartDate -and $EndDate)) {
        throw "Please supply BOTH -StartDate and -EndDate together, or use -Month instead."
    }
    $startIso   = Convert-ToIsoDate $StartDate
    $endIso     = Convert-ToIsoDate $EndDate
    $rangeLabel = "$StartDate_to_$EndDate"
}
else {
    if (-not $Month) { $Month = (Get-Date).ToString("yyyy-MM") }
    $range      = Get-MonthRange -MonthString $Month
    $startIso   = $range.Start
    $endIso     = $range.End
    $rangeLabel = $Month
}

Write-Host "Date range: $startIso  to  $endIso" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# STEP 1 - Login and obtain the token + the real API host (ManagerURL)
# ---------------------------------------------------------------------------
$LoginServer = Get-HostOnly $LoginServer

if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter your EPM username and password"
}
$plainPassword = [System.Net.NetworkCredential]::new('', $Credential.Password).Password

$loginBody = @{
    Username      = $Credential.UserName
    Password      = $plainPassword
    ApplicationID = $ApplicationID
} | ConvertTo-Json

Write-Host "Logging on to EPM via $LoginServer ..." -ForegroundColor Cyan
try {
    $loginResponse = Invoke-RestMethod -Method Post `
        -Uri "https://$LoginServer/EPM/API/Auth/EPM/Logon" `
        -Headers @{ "Content-Type" = "application/json" } `
        -Body $loginBody
}
catch {
    throw "EPM logon failed: $($_.Exception.Message)"
}

if (-not $loginResponse.EPMAuthenticationResult) {
    throw "Logon call succeeded but no token was returned. Response: $($loginResponse | ConvertTo-Json -Depth 5)"
}

$token      = $loginResponse.EPMAuthenticationResult
$managerUrl = $loginResponse.ManagerURL
if (-not $managerUrl) {
    Write-Warning "No ManagerURL returned by the logon call - falling back to $LoginServer for API calls."
    $managerUrl = $LoginServer
}
$managerUrl = Get-HostOnly $managerUrl

if ($loginResponse.IsPasswordExpired) {
    Write-Warning "EPM reports this account's password is expired - the token may still work, but log in via the console soon."
}

$authHeaders = @{
    "Authorization" = "basic $token"
    "Content-Type"  = "application/json"
}

Write-Host "Logged on. Using API host: https://$managerUrl" -ForegroundColor Green

# ---------------------------------------------------------------------------
# STEP 2 - Get the list of Sets, resolve which Set(s) to query
# ---------------------------------------------------------------------------
try {
    $setsResponse = Invoke-RestMethod -Method Get `
        -Uri "https://$managerUrl/EPM/API/Sets" `
        -Headers $authHeaders
}
catch {
    throw "Failed to retrieve sets list: $($_.Exception.Message)"
}

$sets = $setsResponse.Sets
if (-not $sets -or $sets.Count -eq 0) {
    throw "No Sets were returned for this account. Check the account has 'Allow to manage Sets' / view permissions."
}

if ($SetId) {
    $targetSets = $sets | Where-Object { $_.Id -eq $SetId }
    if (-not $targetSets) {
        throw "SetId '$SetId' was not found among the sets this account can see."
    }
}
elseif ($sets.Count -eq 1) {
    $targetSets = $sets
}
else {
    Write-Host "`nMultiple sets are visible to this account:" -ForegroundColor Yellow
    for ($i = 0; $i -lt $sets.Count; $i++) {
        Write-Host ("  [{0}] {1}  (Id: {2})" -f $i, $sets[$i].Name, $sets[$i].Id)
    }
    Write-Host "  [A] Search ALL of the above sets"
    $choice = Read-Host "`nEnter a number to search one set, or 'A' for all"
    if ($choice -match '^[Aa]$') {
        $targetSets = $sets
    }
    else {
        $idx = [int]$choice
        $targetSets = @($sets[$idx])
    }
}

# ---------------------------------------------------------------------------
# Helper: resolve ComputerName -> agentId(s) via Get Endpoints (documented,
# efficient, server-side "name CONTAINS" filter), scoped to one Set.
# ---------------------------------------------------------------------------
function Resolve-EpmAgentIds {
    param($ManagerUrl, $Headers, $SetId, $ComputerName)

    $filter = 'name CONTAINS "' + $ComputerName + '"'
    $offset = 0
    $limit  = 1000
    $found  = New-Object System.Collections.Generic.List[object]

    do {
        $uri  = "https://$ManagerUrl/EPM/API/Sets/$SetId/Endpoints/search?offset=$offset&limit=$limit"
        $body = @{ filter = $filter } | ConvertTo-Json
        $resp = Invoke-RestMethod -Method Post -Uri $uri -Headers $Headers -Body $body
        foreach ($ep in $resp.endpoints) { $found.Add($ep) }
        $offset += $limit
    } while ($resp.filteredCount -gt $offset)

    return $found
}

# Build the common (non-agent) portion of the filter: date range + optional
# eventType / justificationType restrictions.
$commonFilterParts = @()
$commonFilterParts += "eventDate GE `"$startIso`""
$commonFilterParts += "eventDate LE `"$endIso`""
if ($EventType.Count -gt 0) {
    $commonFilterParts += ('eventType IN "' + ($EventType -join '","') + '"')
}
if ($JitOnly) {
    $commonFilterParts += "justificationType EQ 1"
}

$allMatches   = New-Object System.Collections.Generic.List[object]
$agentNameMap = @{}

foreach ($set in $targetSets) {

    Write-Host "`nSearching set '$($set.Name)' (Id: $($set.Id)) ..." -ForegroundColor Cyan

    $agentIds = @()
    try {
        $endpoints = Resolve-EpmAgentIds -ManagerUrl $managerUrl -Headers $authHeaders -SetId $set.Id -ComputerName $ComputerName
        if ($endpoints.Count -eq 0) {
            Write-Host "  No endpoint matching '*$ComputerName*' found in this set - skipping." -ForegroundColor DarkGray
            continue
        }
        foreach ($ep in $endpoints) {
            Write-Host "  Matched endpoint: $($ep.name)  (agentId/legacyId: $($ep.legacyId))" -ForegroundColor DarkGray
            $agentNameMap[$ep.legacyId] = $ep.name
        }
        $agentIds = $endpoints | Select-Object -ExpandProperty legacyId -Unique
    }
    catch {
        Write-Warning "Could not call Get Endpoints for set $($set.Id) ($($_.Exception.Message)). Falling back to client-side name filtering on this set (slower, pulls the full date range for the whole set)."
        $agentIds = @()
    }

    if ($agentIds.Count -gt 0) {
        $filterParts = @('agentId IN "' + ($agentIds -join '","') + '"') + $commonFilterParts
        $useClientSideFilter = $false
    }
    else {
        $filterParts = $commonFilterParts
        $useClientSideFilter = $true
    }
    $filter = $filterParts -join ' AND '
    Write-Host "  Filter: $filter" -ForegroundColor DarkGray

    $nextCursor = "start"
    $page       = 0

    do {
        $page++
        $uri  = "https://$managerUrl/EPM/API/Sets/$($set.Id)/Events/Search?limit=1000&nextCursor=$nextCursor"
        $body = @{ filter = $filter } | ConvertTo-Json

        try {
            $eventsResponse = Invoke-RestMethod -Method Post -Uri $uri -Headers $authHeaders -Body $body
        }
        catch {
            Write-Warning "Event search failed for set $($set.Id), page $page : $($_.Exception.Message)"
            break
        }

        $events = $eventsResponse.events
        Write-Host ("  page {0}: returned {1} of {2} total" -f $page, $eventsResponse.returnedCount, $eventsResponse.filteredCount)

        foreach ($evt in $events) {

            if ($useClientSideFilter -and -not ($evt.lastEventComputerName -and $evt.lastEventComputerName -like "*$ComputerName*")) {
                continue
            }

            $resolvedName = $evt.lastEventComputerName
            if (-not $resolvedName -and $agentNameMap.ContainsKey($evt.agentId)) {
                $resolvedName = $agentNameMap[$evt.agentId]
            }

            $allMatches.Add([PSCustomObject]@{
                SetName                = $set.Name
                ComputerName           = $resolvedName
                AgentId                = $evt.agentId
                UserName               = $evt.userName
                EventType              = $evt.eventType
                FileName               = $evt.fileName
                FileDescription        = $evt.fileDescription
                Publisher              = $evt.publisher
                Justification          = $evt.justification
                JustificationType      = $evt.justificationType   # 1 = JIT, 2 = Other request
                JitRequestInterval     = $evt.jitRequestInterval  # hours requested
                PolicyName             = $evt.policyName
                AccessTargetType       = $evt.accessTargetType
                AccessTargetName       = $evt.accessTargetName
                ThreatProtectionAction = $evt.threatProtectionAction
                FilePath               = $evt.filePath
                FirstEventDate         = $evt.firstEventDate
                LastEventDate          = $evt.lastEventDate
            })
        }

        $nextCursor = $eventsResponse.nextCursor
    } while ($nextCursor)
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($allMatches.Count -eq 0) {
    Write-Host "`nNo events found for computer '*$ComputerName*' in range $startIso to $endIso." -ForegroundColor Yellow
}
else {
    $sorted = $allMatches | Sort-Object LastEventDate -Descending

    Write-Host "`nFound $($allMatches.Count) event(s). Breakdown by event type:" -ForegroundColor Green
    $sorted | Group-Object EventType | Sort-Object Count -Descending |
        Select-Object @{N='EventType';E={$_.Name}}, Count | Format-Table -AutoSize

    Write-Host "`nMost recent 20 event(s):" -ForegroundColor Green
    $sorted | Select-Object -First 20 | Format-Table -AutoSize

    if (-not $OutCsv) {
        $safeComputer = ($ComputerName -replace '[\\/:*?"<>|]', '_')
        $safeRange    = ($rangeLabel  -replace '[\\/:*?"<>|]', '_')
        $OutCsv = ".\EPM_AllEvents_${safeComputer}_${safeRange}.csv"
    }
    $sorted | Export-Csv -Path $OutCsv -NoTypeInformation
    Write-Host "`nFull results ($($allMatches.Count) rows) exported to: $OutCsv" -ForegroundColor Green
}
