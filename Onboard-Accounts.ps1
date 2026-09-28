<#
.SYNOPSIS
    CyberArk EPM support diagnostic - checks for duplicate Manual/JIT request
    events for a specific computer, per support's troubleshooting steps.
.DESCRIPTION
    Mirrors the 3 curl steps support provided:
      1. Login (Auth/EPM/Logon) -> get token
      2. Fetch all Sets (or set $SetId below if you already know it)
      3. Search each Set's event aggregations for ManualRequest events
         matching the target computer name

    Saves the raw JSON response from each Set's search (unparsed, to avoid
    guessing at the response schema and losing/misrepresenting data) plus a
    console summary of how many Sets returned a non-empty result -- useful
    for eyeballing whether the same event shows up more than once.

    Edit the variables in the "USER-CONFIGURABLE VARIABLES" section below,
    then run the script -- no command-line arguments needed.
#>

# ============================================================
# USER-CONFIGURABLE VARIABLES
# ============================================================
$Username      = "svc@corp.com"                   # EPM login username
$Password      = "XXXXXXXXXXXXXXXXXXX"             # EPM login password
$ApplicationID = "testing"                          # Support's example used "testing"
$AuthServer    = "login.epm.cyberark.com"           # EPM auth server hostname (no https://)
$DataServer    = "na206.epm.cyberark.com"           # YOUR tenant's data server hostname (no https://) -- support's example was na206, yours may differ
$ComputerName  = "17892"                            # Computer name to search for
$SetId         = ""                                 # Optional: if you already know the Set, put its Id here to skip searching every Set
$OutputDir     = (Get-Location).Path                # Where to save the results file

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
# STEP 1 - Login, obtain token
# ============================================================
Write-Host "[1/3] Logging in as $Username..." -ForegroundColor Cyan
$logonBody = @{ Username = $Username; Password = $Password; ApplicationID = $ApplicationID } | ConvertTo-Json

try {
    $authResponse = Invoke-RestMethod -Uri "https://$AuthServer/EPM/API/Auth/EPM/Logon" `
        -Method Post -ContentType "application/json" -Body $logonBody
}
catch {
    Write-Host "Login failed: $_" -ForegroundColor Red
    exit 1
}

$token = $authResponse.EPMAuthenticationResult
if ([string]::IsNullOrWhiteSpace($token)) {
    Write-Host "Login did not return a token - check credentials/ApplicationID." -ForegroundColor Red
    exit 1
}
Write-Host "      Login successful." -ForegroundColor Green

$headers = @{ Authorization = "basic $token"; "Content-Type" = "application/json" }

# ============================================================
# STEP 2 - Get Set IDs (skipped if -SetId was supplied directly)
# ============================================================
$setsToSearch = @()

if ($SetId) {
    Write-Host "[2/3] Using supplied SetId: $SetId (skipping Set lookup)" -ForegroundColor Cyan
    $setsToSearch = @([PSCustomObject]@{ Id = $SetId; Name = "(specified directly)" })
}
else {
    Write-Host "[2/3] Fetching Sets..." -ForegroundColor Cyan
    try {
        $setsResponse = Invoke-RestMethod -Uri "https://$DataServer/EPM/API/Sets" -Method Get -Headers $headers
    }
    catch {
        Write-Host "Failed to fetch Sets: $_" -ForegroundColor Red
        exit 1
    }
    $setsToSearch = $setsResponse.Sets
    Write-Host "      Found $($setsToSearch.Count) Sets." -ForegroundColor Green
}

# ============================================================
# STEP 3 - Search each Set for ManualRequest events matching the computer
# ============================================================
Write-Host "[3/3] Searching for ManualRequest events on computer '$ComputerName'..." -ForegroundColor Cyan

$timestamp  = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$filter     = "eventType EQ `"ManualRequest`" AND computerName CONTAINS `"$ComputerName`""
$searchBody = @{ filter = $filter } | ConvertTo-Json

$summary = [System.Collections.Generic.List[object]]::new()
$combinedRaw = [System.Collections.Generic.List[string]]::new()

foreach ($set in $setsToSearch) {
    Write-Host "  -> Set '$($set.Name)' (Id: $($set.Id))..." -NoNewline

    try {
        $rawResponse = Invoke-RestMethod -Uri "https://$DataServer/EPM/API/Sets/$($set.Id)/events/aggregations/search" `
            -Method Post -Headers $headers -Body $searchBody
    }
    catch {
        Write-Host " ERROR: $_" -ForegroundColor Red
        continue
    }

    $rawJson = $rawResponse | ConvertTo-Json -Depth 10
    $isEmpty = [string]::IsNullOrWhiteSpace($rawJson) -or $rawJson -eq "{}" -or $rawJson -eq "[]" -or $rawJson -eq "null"

    if ($isEmpty) {
        Write-Host " no results." -ForegroundColor Gray
    } else {
        Write-Host " got a result - see saved output." -ForegroundColor Green
    }

    $summary.Add([PSCustomObject]@{
        SetName  = $set.Name
        SetId    = $set.Id
        HasData  = -not $isEmpty
    })

    $combinedRaw.Add("===== Set: $($set.Name) (Id: $($set.Id)) =====")
    $combinedRaw.Add($rawJson)
    $combinedRaw.Add("")
}

# ============================================================
# OUTPUT
# ============================================================
$outFile = Join-Path $OutputDir "EPM_ManualRequest_$($ComputerName)_$timestamp.json"
$combinedRaw -join "`r`n" | Out-File -FilePath $outFile -Encoding UTF8

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " Sets with a non-empty result:" -ForegroundColor Cyan
$summary | Where-Object HasData | Format-Table -AutoSize
$hitCount = ($summary | Where-Object HasData).Count
Write-Host " Total Sets returning data: $hitCount (out of $($summary.Count) searched)" -ForegroundColor $(if ($hitCount -gt 1) { "Yellow" } else { "Green" })
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Raw output saved to: $outFile" -ForegroundColor Green
Write-Host "Send this file to support along with the summary above." -ForegroundColor Green
