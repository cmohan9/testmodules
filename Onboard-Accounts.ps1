<#

.\EPM_Filter_Isolation_Tests.ps1 -LoginServer login.epm.cyberark.com -ComputerName "OLY-17892" -SetId "<the set id from before>"

.SYNOPSIS
    Runs 4 isolated test calls against CyberArk EPM's Events/Aggregations/Search (or
    Events/Search) endpoint to prove exactly which part of the originally-requested
    filter causes the EPM00000BE "Operation Failed" error - the EQ operator on
    eventType, the undocumented computerName field, or both.

.DESCRIPTION
    Per CyberArk's own docs, on this endpoint:
      - eventType only supports the IN operator (not EQ)
      - computerName is not a documented filter field at all (only:
        aggregatedBy, eventType, fileName, fileLocation, sourceName, publisher,
        productName, policyName, hash, eventDate, justification, justificationType,
        jitRequestInterval, applicationType, userIsAdmin, agentId, user, fileDescription)

    This script isolates those two variables so you can hand CyberArk support
    definitive proof of which one (or both) their API rejects:

      Test A - eventType IN "ManualRequest"                                    (known-good baseline)
      Test B - eventType EQ "ManualRequest"                                    (isolates: wrong operator)
      Test C - eventType IN "ManualRequest" AND computerName CONTAINS "<CN>"   (isolates: undocumented field)
      Test D - eventType EQ "ManualRequest" AND computerName CONTAINS "<CN>"   (both - the original filter)

    Steps 1 (login) and 2 (get sets) are the same as the other scripts. Step 3
    runs all four tests back-to-back and saves every raw response to one
    transcript file for the support ticket. The session token from Step 1 is
    redacted before printing/saving.

.PARAMETER LoginServer
    The EPM dispatcher / login host, e.g. login.epm.cyberark.com

.PARAMETER Credential
    PSCredential for the EPM user. If omitted, you'll be prompted securely.

.PARAMETER ApplicationID
    Free-text string identifying the caller to EPM.

.PARAMETER SetId
    The Set ID to query. If omitted, the script prints Step 2's raw output and
    asks you to paste in the Set ID to use.

.PARAMETER ComputerName
    Value used in the computerName CONTAINS clause for Tests C and D.

.PARAMETER EventType
    Value used in the eventType clause for all 4 tests. Default: ManualRequest

.PARAMETER Endpoint
    "Aggregations" (default) hits Events/Aggregations/Search, matching the
    original request. "Raw" hits Events/Search instead.

.PARAMETER TranscriptPath
    Optional path to save all raw responses into one text file. Defaults to
    .\EPM_Filter_Isolation_RawOutput_<timestamp>.txt

.EXAMPLE
    .\EPM_Filter_Isolation_Tests.ps1 -LoginServer login.epm.cyberark.com -ComputerName "OLY-17892"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$LoginServer,

    [Parameter()]
    [System.Management.Automation.PSCredential]$Credential,

    [Parameter()]
    [string]$ApplicationID = "PS-EPM-FilterIsolation",

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
$loginPrettyRedacted = $loginPretty -replace '("EPMAuthenticationResult"\s*:\s*")[^"]*(")', '$1<REDACTED>$2'

Write-Host "HTTP Status: $($loginResult.StatusCode)"
Write-Host $loginPrettyRedacted
Add-Transcript -Title "STEP 1: POST /EPM/API/Auth/EPM/Logon  (HTTP $($loginResult.StatusCode))" -Text $loginPrettyRedacted

try {
    $loginObj = $loginResult.RawBody | ConvertFrom-Json
}
catch {
    throw "Step 1 did not return valid JSON - see the raw output above. Cannot continue."
}

if (-not $loginObj.EPMAuthenticationResult) {
    throw "Step 1 succeeded but no token was returned - see the raw output above. Cannot continue."
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
    $SetId = Read-Host "`nPaste the Set ID to use for the filter isolation tests"
}

if ($Endpoint -eq "Aggregations") {
    $path3 = "/EPM/API/Sets/$SetId/events/aggregations/search"
}
else {
    $path3 = "/EPM/API/Sets/$SetId/Events/Search"
}

# ---------------------------------------------------------------------------
# step3 - four isolated test cases
# ---------------------------------------------------------------------------
$tests = @(
    [PSCustomObject]@{
        Id     = "Test A"
        Label  = "eventType IN (correct operator), NO computerName - known-good baseline"
        Filter = "eventType IN `"$EventType`""
    },
    [PSCustomObject]@{
        Id     = "Test B"
        Label  = "eventType EQ (WRONG operator - docs require IN), NO computerName - isolates the operator issue"
        Filter = "eventType EQ `"$EventType`""
    },
    [PSCustomObject]@{
        Id     = "Test C"
        Label  = "eventType IN (correct operator) AND computerName CONTAINS (UNDOCUMENTED field) - isolates the field issue"
        Filter = "eventType IN `"$EventType`" AND computerName CONTAINS `"$ComputerName`""
    },
    [PSCustomObject]@{
        Id     = "Test D"
        Label  = "eventType EQ (wrong operator) AND computerName CONTAINS (undocumented field) - the ORIGINAL filter as requested"
        Filter = "eventType EQ `"$EventType`" AND computerName CONTAINS `"$ComputerName`""
    }
)

foreach ($t in $tests) {
    Write-Host "`n=== STEP 3 [$($t.Id)]: $($t.Label) ===" -ForegroundColor Cyan
    Write-Host "Filter sent: $($t.Filter)" -ForegroundColor DarkGray

    $body3   = @{ filter = $t.Filter } | ConvertTo-Json
    $result3 = Invoke-EpmRaw -Method Post -Uri "https://$managerUrl$path3" -Headers $authHeaders -Body $body3
    $pretty3 = Format-Pretty $result3.RawBody

    $color = if ($result3.StatusCode -eq 200) { "Green" } else { "Red" }
    Write-Host "HTTP Status: $($result3.StatusCode)" -ForegroundColor $color
    Write-Host $pretty3

    Add-Transcript -Title "STEP 3 [$($t.Id)]: $($t.Label)  |  POST $path3  |  Filter: $($t.Filter)  |  HTTP $($result3.StatusCode)" -Text $pretty3

    Start-Sleep -Milliseconds 500
}

# ---------------------------------------------------------------------------
# save everything to one file, ready to hand to CyberArk support
# ---------------------------------------------------------------------------
if (-not $TranscriptPath) {
    $TranscriptPath = ".\EPM_Filter_Isolation_RawOutput_$(Get-Date -Format 'yyyyMMdd_HHmmss').txt"
}
$transcript -join "`r`n" | Out-File -FilePath $TranscriptPath -Encoding UTF8
Write-Host "`nAll raw output saved to: $TranscriptPath" -ForegroundColor Green
Write-Host "Compare Test A (works) against B/C/D to see exactly which change breaks it." -ForegroundColor Green
