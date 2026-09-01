# CONFIG
$EpmAuthServer   = ""
$AppId           = ""
$Username        = ""
$Password        = ""

$Region          = ""
$SetId           = ""

$EventFilterBase = "eventType IN ManualRequest"
$ArrivalTimeGE   = "2026-05-01T16:30:00Z"

function Write-Log {
    param($Message, $Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# AUTHENTICATE
Write-Log "[Auth] Authenticating as $Username..." "Cyan"
$LogonBody = @{ ApplicationID = $AppId; Username = $Username; Password = $Password } | ConvertTo-Json

try {
    $AuthResponse = Invoke-RestMethod -Uri "https://$EpmAuthServer/EPM/API/Auth/EPM/Logon" `
        -Method Post -Headers @{ "Content-Type" = "application/json" } -Body $LogonBody
    $Token = $AuthResponse.EPMAuthenticationResult
    Write-Log "[Auth] Success." "Green"
}
catch { Write-Log "[Auth] FAILED: $_" "Red"; exit 1 }

$Headers = @{ "Authorization" = "Basic $Token"; "Content-Type" = "application/json" }

# GET TENANT URL
Write-Log "[TenantUrl] Resolving for region '$Region'..." "Cyan"
try {
    $TenantUrlResponse = Invoke-RestMethod -Uri "https://api-$Region.epm.cyberark.cloud/epm/api/accounts/tenanturl" `
        -Method Get -Headers $Headers
    $TenantUrl = $TenantUrlResponse.tenantUrl
    Write-Log "[TenantUrl] $TenantUrl" "Green"
}
catch { Write-Log "[TenantUrl] FAILED: $_" "Red"; exit 1 }

# GET SETS / SEARCH EVENTS
if ($SetId) {
    $Filter = $EventFilterBase
    if ($ArrivalTimeGE) { $Filter = "$Filter AND arrivalTime GE $ArrivalTimeGE" }

    Write-Log "[Events] Searching Set '$SetId' with filter: $Filter" "Cyan"
    $Body = @{ filter = $Filter } | ConvertTo-Json

    try {
        $Events = Invoke-RestMethod -Uri "https://$TenantUrl/EPM/API/Sets/$SetId/Events/Search" `
            -Method Post -Headers $Headers -Body $Body
        Write-Log "[Events] Success." "Green"
        $Events | ConvertTo-Json -Depth 8
    }
    catch { Write-Log "[Events] FAILED: $_" "Red"; exit 1 }
}
else {
    Write-Log "[Sets] No SetId configured, fetching list of Sets..." "Cyan"
    try {
        $Sets = Invoke-RestMethod -Uri "https://$TenantUrl/EPM/API/Sets" -Method Get -Headers $Headers
        Write-Log "[Sets] Success." "Green"
        $Sets | ConvertTo-Json -Depth 8
    }
    catch { Write-Log "[Sets] FAILED: $_" "Red"; exit 1 }
}
