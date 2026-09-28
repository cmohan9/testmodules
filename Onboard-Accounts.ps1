<#

.\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892" -StartDate 2026-09-20
.SYNOPSIS
    Queries CyberArk EPM (cloud) for JIT / Manual elevation request events on a specific
    computer, for troubleshooting purposes.

.DESCRIPTION
    Implements the 3-step flow requested by CyberArk support, built against the OFFICIAL
    EPM REST API docs (docs.cyberark.com/epm/latest/en/content/webservices):

      1. EPM authentication
         POST https://<LoginServer>/EPM/API/Auth/EPM/Logon
         Docs: .../webservices/serverauthentication.htm
         -> Returns ManagerURL (the tenant's real API host) + EPMAuthenticationResult (token)

      2. Get sets list
         GET https://<ManagerURL>/EPM/API/Sets
         Docs: .../webservices/getsetslist.htm

      3. Get detailed raw events (per-occurrence, not aggregated)
         POST https://<ManagerURL>/EPM/API/Sets/<SetId>/Events/Search
         Docs: .../webservices/getdetailedrawevents.htm

    IMPORTANT — corrections vs. the original draft this replaces:
      - The login call returns "ManagerURL". All subsequent calls MUST use that host,
        not a hardcoded region host, because the dispatcher/login host and the tenant's
        real API host can differ.
      - The Authorization header value is literally "basic <token>" (lowercase "basic"),
        per CyberArk's own examples.
      - Neither the raw events endpoint (Events/Search) nor the aggregated events endpoint
        (Events/Aggregations/Search) supports filtering by "computerName" server-side.
        The documented filter fields are: aggregatedBy, eventType, fileName, fileLocation,
        sourceName, publisher, productName, policyName, hash, eventDate, justification,
        justificationEmail, justificationType, jitRequestInterval, applicationType,
        userIsAdmin, agentId, user, fileDescription.
        There is NO computerName filter. The raw event objects DO return a
        "lastEventComputerName" field, so this script filters on that field
        client-side, after pulling events server-side filtered by eventType
        (and optionally justificationType for JIT-only).

.PARAMETER LoginServer
    The EPM dispatcher / login host you normally sign in through, e.g. login.epm.cyberark.com

.PARAMETER Credential
    PSCredential for the EPM user (must have "Allow to manage Sets" / view access to the
    relevant set(s)). If omitted, you'll be prompted securely.

.PARAMETER ApplicationID
    Free-text string identifying the caller to EPM (shows up in EPM's own logs).

.PARAMETER ComputerName
    Substring to match against the event's computer name (case-insensitive, partial match),
    e.g. "17892".

.PARAMETER EventType
    One or more EPM event types to search for. Default: ManualRequest (what CyberArk support
    typically means by "JIT user request"). You can add ElevationRequest too if needed.

.PARAMETER JitOnly
    If set, additionally restricts results to justificationType EQ 1 (JIT requests only,
    as opposed to "other request" = 2).

.PARAMETER StartDate / EndDate
    Optional UTC date bounds (yyyy-MM-dd or full ISO-8601) to narrow the search window.
    Strongly recommended on busy tenants — narrows the result set and avoids hitting the
    1000-record-per-call ceiling before pagination kicks in.

.PARAMETER SetId
    Optional. If you already know the Set ID, skip the interactive picker.

.PARAMETER OutCsv
    Optional path to also export matching results as CSV.

.EXAMPLE
    .\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com `
        -ComputerName "17892" -StartDate 2026-09-20 -JitOnly

.EXAMPLE
    .\Get-EpmJitRequestEvents.ps1 -LoginServer login.epm.cyberark.com `
        -ComputerName "17892" -SetId "2195bd87-36ec-4ae0-8f35-661d0254e441" `
        -EventType ManualRequest,ElevationRequest -OutCsv .\jit_results.csv
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LoginServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$ApplicationID = "PS-JIT-Troubleshoot",

    [Parameter(Mandatory)]
    [string]$ComputerName,

    [Parameter()]
    [string[]]$EventType = @("ManualRequest"),

    [Parameter()]
    [switch]$JitOnly,

    [Parameter()]
    [string]$StartDate,

    [Parameter()]
    [string]$EndDate,

    [Parameter()]
    [string]$SetId,

    [Parameter()]
    [string]$OutCsv
)

# Ensure TLS 1.2 (some older PowerShell hosts default to older protocols)
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Convert-ToIsoDate {
    param([string]$DateString)
    if ([string]::IsNullOrWhiteSpace($DateString)) { return $null }
    $dt = [datetime]::Parse($DateString, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    return $dt.ToString("yyyy-MM-ddTHH:mm:ssZ")
}

function Get-HostOnly {
    # EPM sometimes returns ManagerURL WITH a scheme (e.g. "https://na206.epm.cyberark.com")
    # and sometimes callers pass -LoginServer WITH a scheme too. Normalize to a bare host
    # so we never accidentally build "https://https://...".
    param([string]$UrlOrHost)
    $h = $UrlOrHost.Trim()
    $h = $h -replace '^https?://', ''
    $h = $h.TrimEnd('/')
    return $h
}

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
# STEP 2 - Get the list of Sets, resolve which Set to query
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
# STEP 3 - Get detailed raw events (per-occurrence), filtered server-side by
#          eventType (and optionally justificationType), then filtered
#          client-side by computer name.
# ---------------------------------------------------------------------------

# Build the EPM query-language filter string
$filterParts = @()
$filterParts += ('eventType IN "{0}"' -f ($EventType -join '","'))

if ($JitOnly) {
    $filterParts += "justificationType EQ 1"
}

$startIso = Convert-ToIsoDate $StartDate
$endIso   = Convert-ToIsoDate $EndDate
if ($startIso) { $filterParts += "eventDate GE `"$startIso`"" }
if ($endIso)   { $filterParts += "eventDate LE `"$endIso`"" }

$filter = $filterParts -join ' AND '
Write-Host "`nUsing filter: $filter" -ForegroundColor DarkGray

$allMatches = New-Object System.Collections.Generic.List[object]

foreach ($set in $targetSets) {

    Write-Host "`nSearching set '$($set.Name)' (Id: $($set.Id)) ..." -ForegroundColor Cyan

    $nextCursor = "start"
    $page       = 0

    do {
        $page++
        $uri = "https://$managerUrl/EPM/API/Sets/$($set.Id)/Events/Search?limit=1000&nextCursor=$nextCursor"

        $body = @{ filter = $filter } | ConvertTo-Json

        try {
            $eventsResponse = Invoke-RestMethod -Method Post -Uri $uri -Headers $authHeaders -Body $body
        }
        catch {
            Write-Warning "Event search failed for set $($set.Id), page $page : $($_.Exception.Message)"
            break
        }

        $events = $eventsResponse.events
        Write-Host ("  page {0}: returned {1} of {2} total matching '{3}'" -f $page, $eventsResponse.returnedCount, $eventsResponse.filteredCount, $filter)

        foreach ($evt in $events) {
            if ($evt.lastEventComputerName -and $evt.lastEventComputerName -like "*$ComputerName*") {
                $allMatches.Add([PSCustomObject]@{
                    SetName            = $set.Name
                    ComputerName       = $evt.lastEventComputerName
                    UserName           = $evt.userName
                    EventType          = $evt.eventType
                    FileName           = $evt.fileName
                    FileDescription    = $evt.fileDescription
                    Justification      = $evt.justification
                    JustificationType  = $evt.justificationType   # 1 = JIT, 2 = Other request
                    JitRequestInterval = $evt.jitRequestInterval  # hours requested
                    PolicyName         = $evt.policyName
                    FirstEventDate     = $evt.firstEventDate
                    LastEventDate      = $evt.lastEventDate
                    AgentId            = $evt.agentId
                    FilePath           = $evt.filePath
                })
            }
        }

        $nextCursor = $eventsResponse.nextCursor
    } while ($nextCursor)
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($allMatches.Count -eq 0) {
    Write-Host "`nNo events found matching computer name '*$ComputerName*' with filter: $filter" -ForegroundColor Yellow
}
else {
    Write-Host "`nFound $($allMatches.Count) matching event(s):" -ForegroundColor Green
    $allMatches | Sort-Object LastEventDate -Descending | Format-Table -AutoSize

    if ($OutCsv) {
        $allMatches | Sort-Object LastEventDate -Descending | Export-Csv -Path $OutCsv -NoTypeInformation
        Write-Host "`nExported results to $OutCsv" -ForegroundColor Green
    }
}
