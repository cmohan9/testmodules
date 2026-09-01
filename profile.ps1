$Username      = "YourUsername"
$Password      = "YourPassword"
$AppId         = "EPM_PowerShell_Script"
$EpmAuthServer = "login.epm.cyberark.com"

$SetId           = ""
$EventFilterBase = "eventType IN ManualRequest"
$ArrivalTimeGE   = "2026-05-01T16:30:00Z"

# Build authentication payload
$LogonBody = @{
    ApplicationID = $AppId
    Username      = $Username
    Password      = $Password
} | ConvertTo-Json

# Authenticate and get token
$AuthResponse = Invoke-RestMethod `
    -Uri "https://$EpmAuthServer/EPM/API/Auth/EPM/Logon" `
    -Method Post `
    -Headers @{ "Content-Type" = "application/json" } `
    -Body $LogonBody

# Extract authentication token
$Token = $AuthResponse.EPMAuthenticationResult

$Headers = @{
    "Authorization" = "Basic $Token"
    "Content-Type"  = "application/json"
}

if ($SetId) {
    $Filter = $EventFilterBase
    if ($ArrivalTimeGE) { $Filter = "$Filter AND arrivalTime GE $ArrivalTimeGE" }

    $Body = @{ filter = $Filter } | ConvertTo-Json

    $Events = Invoke-RestMethod `
        -Uri "https://$EpmAuthServer/EPM/API/Sets/$SetId/Events/Search" `
        -Method Post `
        -Headers $Headers `
        -Body $Body

    $CsvPath = "EPM_Events_$(Get-Date -Format 'yyyyMMdd_HHmmss').csv"

    $FlatEvents = $Events.events | ForEach-Object {
        $Row = [ordered]@{}
        foreach ($Prop in $_.PSObject.Properties) {
            if ($Prop.Value -is [System.Array] -or $Prop.Value -is [System.Management.Automation.PSCustomObject]) {
                $Row[$Prop.Name] = ($Prop.Value | ConvertTo-Json -Depth 5 -Compress)
            }
            else {
                $Row[$Prop.Name] = $Prop.Value
            }
        }
        [PSCustomObject]$Row
    }

    $FlatEvents | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8

    Write-Host "Exported $($FlatEvents.Count) events to $CsvPath"
}
else {
    $Sets = Invoke-RestMethod `
        -Uri "https://$EpmAuthServer/EPM/API/Sets" `
        -Method Get `
        -Headers $Headers

    $Sets | ConvertTo-Json -Depth 8
}
