<#


.\EPM_Raw_Support_Case_Steps.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892"

.SYNOPSIS
    Runs the exact 3-step EPM API flow the support team asked for, and prints/saves
    the RAW API responses (as-is) so they can be pasted straight into the support case.

.DESCRIPTION
    This is deliberately a thin, literal translation of the 3 curl steps support
    originally requested - it does NOT parse, reshape, or "fix" the filter logic.
    If a filter field (e.g. computerName) isn't accepted by the API, this script
    will show you the raw error response instead of silently working around it,
    which is exactly what support needs to see.

      Step 1 - Login and obtain the token
        POST https://<LoginServer>/EPM/API/Auth/EPM/Logon

      Step 2 - Get Set IDs
        GET https://<ManagerURL>/EPM/API/Sets

      Step 3 - Get the JIT / ManualRequest events for a Set
        POST https://<ManagerURL>/EPM/API/Sets/<SetId>/Events/Aggregations/Search
        Body filter (as requested):
          eventType EQ "ManualRequest" AND computerName CONTAINS "<ComputerName>"

    NOTE: The session token from Step 1 is redacted before it's printed or saved -
    it's a live bearer credential for your EPM session and shouldn't end up in a
    ticketing system in plaintext. Everything else is shown exactly as returned.

.PARAMETER LoginServer
    The EPM dispatcher / login host, e.g. login.epm.cyberark.com

.PARAMETER Credential
    PSCredential for the EPM user. If omitted, you'll be prompted securely.

.PARAMETER ApplicationID
    Free-text string identifying the caller to EPM.

.PARAMETER SetId
    The Set ID to query in Step 3. If omitted, the script prints Step 2's raw
    output and asks you to paste in the Set ID you want to use for Step 3.

.PARAMETER ComputerName
    Value used in the Step 3 filter's computerName CONTAINS clause.

.PARAMETER EventType
    Value used in the Step 3 filter's eventType EQ clause. Default: ManualRequest

.PARAMETER Endpoint
    "Aggregations" (default) hits Events/Aggregations/Search, matching the
    original request. "Raw" hits Events/Search instead, which returns one row
    per occurrence and supports more filter fields (e.g. agentId, user).

.PARAMETER TranscriptPath
    Optional path to save all 3 raw responses into one text file for easy
    pasting into the ticket. Defaults to .\EPM_Support_Case_RawOutput_<timestamp>.txt

.EXAMPLE
    .\EPM_Raw_Support_Case_Steps.ps1 -LoginServer login.epm.cyberark.com -ComputerName "17892"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LoginServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$ApplicationID = "PS-EPM-SupportCase",

    [Parameter()]
    [string]$SetId,

    [Parameter()]
    [string]$ComputerName = "17892",

    [Parameter()]
    [string]$EventType = "ManualRequest",

    [Parameter()]
    [ValidateSet("Aggregations", "Raw")]
    [string]$Endpoint = "Aggregations",

    [Parameter()]
    [string]$TranscriptPath
)

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

function Get-HostOnly {
    param([string]$UrlOrHost)
    $h = $UrlOrHost.Trim()
    $h = $h -replace '^https?://', ''
    return $h.TrimEnd('/')
}

# Calls the API and returns the RAW response body as text, whether the call
# succeeded or failed, plus the HTTP status code.
function Invoke-EpmRaw {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [string]$Body
    )

    $statusCode = $null
    $rawBody    = $null

    try {
        if ($Body) {
            $resp = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $Headers -Body $Body -UseBasicParsing -ErrorAction Stop
        }
        else {
            $resp = Invoke-WebRequest -Method $Method -Uri $Uri -Headers $Headers -UseBasicParsing -ErrorAction Stop
        }
        $statusCode = [int]$resp.StatusCode
        $rawBody    = $resp.Content
    }
    catch {
        $ex = $_.Exception
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $rawBody = $_.ErrorDetails.Message
        }
        elseif ($ex.Response -and ($ex.Response.PSObject.Methods.Name -contains 'GetResponseStream')) {
            try {
                $stream = $ex.Response.GetResponseStream()
                $reader = New-Object System.IO.StreamReader($stream)
                $rawBody = $reader.ReadToEnd()
            }
            catch { $rawBody = $ex.Message }
        }
        else {
            $rawBody = $ex.Message
        }

        if ($ex.Response -and $ex.Response.StatusCode) {
            $statusCode = [int]$ex.Response.StatusCode
        }
        else {
            $statusCode = "ERROR"
        }
    }

    return [PSCustomObject]@{
        StatusCode = $statusCode
        RawBody    = $rawBody
    }
}

function Format-Pretty {
    param([string]$Text)
    try { return ($Text | ConvertFrom-Json | ConvertTo-Json -Depth 10) }
    catch { return $Text }
}

$transcript = New-Object System.Collections.Generic.List[string]
function Add-Transcript {
    param([string]$Title, [string]$Text)
    $transcript.Add("===== $Title =====")
    $transcript.Add($Text)
    $transcript.Add("")
}

$LoginServer = Get-HostOnly $LoginServer
if (-not $Credential) {
    $Credential = Get-Credential -Message "Enter your EPM username and password"
}
$plainPassword = [System.Net.NetworkCredential]::new('', $Credential.Password).Password

# ---------------------------------------------------------------------------
# step1 - login and obtain the token
# ---------------------------------------------------------------------------
$loginBody = @{
    Username      = $Credential.UserName
    Password      = $plainPassword
    ApplicationID = $ApplicationID
} | ConvertTo-Json

Write-Host "`n=== STEP 1: Login ===" -ForegroundColor Cyan
$loginResult = Invoke-EpmRaw -Method Post `
    -Uri "https://$LoginServer/EPM/API/Auth/EPM/Logon" `
    -Headers @{ "Content-Type" = "application/json" } `
    -Body $loginBody

$loginPretty = Format-Pretty $loginResult.RawBody

# Redact the token before printing/saving
$loginPrettyRedacted = $loginPretty -replace '("EPMAuthenticationResult"\s*:\s*")[^"]*(")', '$1<REDACTED>$2'

Write-Host "HTTP Status: $($loginResult.StatusCode)"
Write-Host $loginPrettyRedacted
Add-Transcript -Title "STEP 1: POST /EPM/API/Auth/EPM/Logon  (HTTP $($loginResult.StatusCode))" -Text $loginPrettyRedacted

# Parse quietly (not printed) just enough to make Steps 2 & 3 work
try {
    $loginObj = $loginResult.RawBody | ConvertFrom-Json
}
catch {
    throw "Step 1 did not return valid JSON - see the raw output above. Cannot continue to Step 2/3."
}

if (-not $loginObj.EPMAuthenticationResult) {
    throw "Step 1 succeeded but no token was returned - see the raw output above. Cannot continue to Step 2/3."
}

$token      = $loginObj.EPMAuthenticationResult
$managerUrl = Get-HostOnly ($loginObj.ManagerURL)
if (-not $managerUrl) { $managerUrl = $LoginServer }

$authHeaders = @{
    "Authorization" = "basic $token"
    "Content-Type"  = "application/json"
}

# ---------------------------------------------------------------------------
# step2 - get set ids
# ---------------------------------------------------------------------------
Write-Host "`n=== STEP 2: Get Set IDs ===" -ForegroundColor Cyan
$setsResult = Invoke-EpmRaw -Method Get -Uri "https://$managerUrl/EPM/API/Sets" -Headers $authHeaders
$setsPretty = Format-Pretty $setsResult.RawBody

Write-Host "HTTP Status: $($setsResult.StatusCode)"
Write-Host $setsPretty
Add-Transcript -Title "STEP 2: GET /EPM/API/Sets  (HTTP $($setsResult.StatusCode))" -Text $setsPretty

if (-not $SetId) {
    try {
        $setsObj = $setsResult.RawBody | ConvertFrom-Json
        if ($setsObj.Sets -and $setsObj.Sets.Count -gt 0) {
            Write-Host "`nAvailable Set IDs:" -ForegroundColor Yellow
            foreach ($s in $setsObj.Sets) { Write-Host "  $($s.Name)  ->  $($s.Id)" }
        }
    }
    catch { }
    $SetId = Read-Host "`nPaste the Set ID to use for Step 3"
}

# ---------------------------------------------------------------------------
# step3 - get the jit request events for that set, using the filter support asked for
# ---------------------------------------------------------------------------
$filter = "eventType EQ `"$EventType`" AND computerName CONTAINS `"$ComputerName`""
$body3  = @{ filter = $filter } | ConvertTo-Json

if ($Endpoint -eq "Aggregations") {
    $path3 = "/EPM/API/Sets/$SetId/events/aggregations/search"
}
else {
    $path3 = "/EPM/API/Sets/$SetId/Events/Search"
}

Write-Host "`n=== STEP 3: Get JIT/ManualRequest events ($Endpoint) ===" -ForegroundColor Cyan
Write-Host "Filter sent: $filter" -ForegroundColor DarkGray

$eventsResult = Invoke-EpmRaw -Method Post -Uri "https://$managerUrl$path3" -Headers $authHeaders -Body $body3
$eventsPretty = Format-Pretty $eventsResult.RawBody

Write-Host "HTTP Status: $($eventsResult.StatusCode)"
Write-Host $eventsPretty
Add-Transcript -Title "STEP 3: POST $path3  (HTTP $($eventsResult.StatusCode))  Filter: $filter" -Text $eventsPretty

# ---------------------------------------------------------------------------
# save everything to one file, ready to paste into the ticket
# ---------------------------------------------------------------------------
if (-not $TranscriptPath) {
    $TranscriptPath = ".\EPM_Support_Case_RawOutput_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
}
$transcript -join "`r`n" | Out-File -FilePath $TranscriptPath -Encoding UTF8
Write-Host "`nAll raw output saved to: $TranscriptPath" -ForegroundColor Green
