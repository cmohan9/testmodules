<#
.SYNOPSIS
    Privilege Cloud License Capacity User Report

.DESCRIPTION
    This PowerShell script generates a comprehensive report of users consuming resources in the Privilege Cloud for a given tenant URL.
    The report includes information about users of different types and their last login dates.
    Additionally, it identifies users who have been inactive for more than a specified number of days.
    It also detects and reports users returned by the API without an assigned UserType.

.PARAMETER PortalURL
    Specifies the URL of the Privilege Cloud tenant.
    Example: https://<subdomain>.cyberark.cloud

.PARAMETER InactiveDays
    Specifies the number of days to consider users as inactive.
    Default value: 60

.PARAMETER ExportToCSV
    Specifies whether to export the results to a CSV file or print them in PowerShell.
    If this switch is specified, the results will be exported to CSV files.

.PARAMETER GetSpecificUserTypes
    Specifies the UserTypes you want to get a report on.
    Default values: EPVUser, EPVUserLite, BasicUser, ExtUser, BizUser, AIMAccount, AppProvider, CCP, CCPEndpoints, CPM, PSM

.PARAMETER ReportType
    Specifies the type of report to generate.
    Valid values are 'CapacityReport' and 'DetailedReport'.

.PARAMETER Credentials
    Specifies a user with the relevant permissions.

.PARAMETER ForceAuthType
    Specifies the authentication type.
    Valid values are 'cyberark' and 'identity'.

.EXAMPLE
    .\PrivilegeCloudConsumedUserReport.ps1 -PortalURL "https://<subdomain>.cyberark.cloud" -InactiveDays 90 -ExportToCSV -GetSpecificUserTypes EPVUser, BasicUser -ReportType DetailedReport
#>

param(
    [Parameter(Mandatory = $true, HelpMessage = "Specify the URL of the Privilege Cloud tenant (e.g., https://<subdomain>.cyberark.cloud)")]
    [string]$PortalURL,

    [Parameter(Mandatory = $false, HelpMessage = "Specify the number of days to consider users as inactive.")]
    [int]$InactiveDays = 60,

    [switch]$ExportToCSV,

    [Parameter(Mandatory = $false, HelpMessage = "Specify the UserTypes you want to get a report on.")]
    [ValidateSet("EPVUser", "EPVUserLite", "BasicUser", "ExtUser", "BizUser", "AIMAccount", "AppProvider", "CCP", "CCPEndpoints", "CPM", "PSM")]
    [string[]]$GetSpecificuserTypes = @("EPVUser", "EPVUserLite", "BasicUser", "ExtUser", "BizUser", "AIMAccount", "AppProvider", "CCP", "CCPEndpoints", "CPM", "PSM"),

    [Parameter(Mandatory = $false, HelpMessage = "Specify the type of report to generate. Valid values are 'CapacityReport' and 'DetailedReport'.")]
    [ValidateSet("DetailedReport", "CapacityReport")]
    [string]$ReportType,

    [Parameter(Mandatory = $true, HelpMessage = "Specify a User with the relevant permissions. See readme if you need help.")]
    [PSCredential]$Credentials,

    [ValidateSet("cyberark","identity")]
    [string]$ForceAuthType
)

$ScriptLocation = Split-Path -Parent $MyInvocation.MyCommand.Path

# Modules
# NOTE: paths are resolved relative to $ScriptLocation (the script's own folder),
# not the current working directory, so this works regardless of where the
# script is invoked from.
$mainModule = "Import_AllModules.psm1"

$modulePaths = @(
    (Join-Path $ScriptLocation "..\PS-Modules\$mainModule"),
    (Join-Path $ScriptLocation "..\..\PS-Modules\$mainModule"),
    (Join-Path $ScriptLocation "PS-Modules\$mainModule"),
    (Join-Path $ScriptLocation $mainModule),
    (Join-Path $ScriptLocation "..\$mainModule"),
    (Join-Path $ScriptLocation "..\..\$mainModule")
)

$moduleImported = $false
foreach ($modulePath in $modulePaths) {
    if (Test-Path $modulePath) {
        try {
            Import-Module $modulePath -ErrorAction Stop -DisableNameChecking -Force
            $moduleImported = $true
            break
        }
        catch {
            Write-Host "Failed to import module from $modulePath. Error: $_"
            Write-Host "check that you copied the PS-Modules folder correctly."
            Pause
            Exit
        }
    }
}

if (-not $moduleImported) {
    Write-Host "Could not find $mainModule under $ScriptLocation (or its parent folders)." -ForegroundColor Red
    Write-Host "Make sure the PS-Modules folder from the Cyberark PrivilegeCloud Tools package is present alongside (or one/two levels above) this script." -ForegroundColor Red
    Pause
    Exit
}

$global:LOG_FILE_PATH = "$ScriptLocation\_Get-UserTypesAndUsersLoginActivity.log"

[int]$scriptVersion = 10

# Track whether users with missing UserType were already handled/exported
$script:MissingUserTypeHandled = $false

# PS Window title
$Host.UI.RawUI.WindowTitle = "Privilege Cloud License Capacity User Report"

## Force Output to be UTF8 (for OS with different languages)
try {
    $OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding
}
catch {
    Write-Host "Note: Could not set console output encoding to UTF-8 (no valid console handle in this session, e.g. PSM/remote-brokered sessions). Continuing without changing encoding." -ForegroundColor Yellow
}

if ($ExportToCSV.IsPresent) {
    $global:ExportDir = "$ScriptLocation\$(Get-Date -Format 'yyyyMMdd_HH-mm')"
    if (!(Test-Path -Path $global:ExportDir)) {
        New-Item -ItemType Directory -Path $global:ExportDir | Out-Null
    }
}

function CalcLicenseInfo {
    param(
        [string]$licenseInfo
    )

    $formats = @(
        "M/d/yyyy h:mm:ss tt",    # NA
        "MM/dd/yyyy hh:mm:ss tt", # NA with leading zeros
        "d/M/yyyy HH:mm:ss",      # EU STD without leading zeros
        "dd/M/yyyy HH:mm:ss",     # EU STD with/without leading zeros
        "dd/MM/yyyy HH:mm:ss",    # EU STD with leading zeros
        "dd-MM-yyyy HH:mm:ss",    # India
        "yyyy/MM/dd HH:mm:ss",    # East Asia (Japan, China, Korea)
        "yyyy-MM-dd HH:mm:ss",    # ISO 8601
        "dd.MM.yyyy HH:mm:ss",    # Central Europe
        "d.M.yyyy H:mm:ss",       # Short format without leading zeros
        "dd/MM/yyyy h:mm:ss tt",  # UK, Ireland, Australia
        "MM-dd-yyyy HH:mm:ss",    # Philippines
        "yyyyMMdd HH:mm:ss",      # Compact form
        "d/M/yyyy h:mm:ss tt",    # Short format without leading zeros
        "M-d-yyyy hh:mm:ss tt",   # Variations with dash separator
        "d-M-yyyy HH:mm:ss",      # Variations with/without leading zeros and 24-hour format
        "d/MM/yyyy h:mm tt",      # Without seconds
        "M/dd/yyyy HH:mm:ss",     # Variations with/without leading zeros and 24-hour format
        "MM/dd/yyyy H:mm:ss",     # Variations with leading zeros and 24-hour format
        "d-M-yyyy hh:mm:ss tt",   # 12-hour format variations with/without leading zeros
        "MM-d-yyyy hh:mm:ss tt",  # 12-hour format variations with leading zeros
        "M.d.yyyy hh:mm:ss tt",   # Dot separator variations
        "dd.MM.yyyy h:mm:ss tt",  # Dot separator variations with leading zeros
        "MM.dd.yyyy HH:mm:ss",    # Dot separator variations with 24-hour format
        "d.M.yyyy HH:mm:ss",      # 24-hour format variations with/without leading zeros
        "yyyy.MM.dd HH:mm:ss",    # ISO variations with dot separator
        "yyyy-MM.dd HH:mm:ss tt", # ISO variations with mixed separators
        "yyyy/MM.dd hh:mm:ss tt"  # ISO variations with mixed separators and 12-hour format
    )

    $currentCulture = [System.Globalization.CultureInfo]::CurrentCulture

    if ($currentCulture.TwoLetterISOLanguageName -like "en*") {
        $provider = [System.Globalization.CultureInfo]::InvariantCulture
    }
    else {
        $provider = $currentCulture
    }

    $parsedSuccessfully = $false
    foreach ($format in $formats) {
        try {
            $licenseExpirationDate = [DateTime]::ParseExact($licenseInfo, $format, $provider)
            $parsedSuccessfully = $true
            break
        }
        catch {
        }
    }

    if (-not $parsedSuccessfully) {
        Write-Error "Failed to parse date: $licenseInfo"
        return
    }

    $global:licenseExpirationDateLocal = $licenseExpirationDate.ToLocalTime()

    $currentDate = Get-Date
    $daysToExpiration = ($licenseExpirationDateLocal - $currentDate).Days

    $global:lessThanXDays = ""
    $global:Alertcolor = "Green"

    if ($daysToExpiration -le 30) {
        $global:Alertcolor = "Yellow"
        $global:lessThanXDays = "Less than $daysToExpiration days remaining!"
    }
    if ($daysToExpiration -le 15) {
        $global:Alertcolor = "Red"
        $global:lessThanXDays = "Less than $daysToExpiration days remaining!"
    }
}

function Get-LicenseCapacityReport {
    param(
        [string]$vaultIp,
        [string[]]$GetSpecificuserTypes
    )

    $VaultOperationFolderInside = "$PSScriptRoot\VaultOperationsTester"
    $VaultOperationFolderOneUp = "$(Split-Path $PSScriptRoot)\VaultOperationsTester"
    $VaultOperationFolderTwoUp = "$(Split-Path (Split-Path $PSScriptRoot))\VaultOperationsTester"

    if (Test-Path -Path "$VaultOperationFolderInside\VaultOperationsTester.exe") {
        $VaultOperationFolder = $VaultOperationFolderInside
    }
    elseif (Test-Path -Path "$VaultOperationFolderOneUp\VaultOperationsTester.exe") {
        $VaultOperationFolder = $VaultOperationFolderOneUp
    }
    elseif (Test-Path -Path "$VaultOperationFolderTwoUp\VaultOperationsTester.exe") {
        $VaultOperationFolder = $VaultOperationFolderTwoUp
    }
    else {
        Write-Host "Required file 'VaultOperationsTester.exe' doesn't exist in expected folders: `n- `"$VaultOperationFolderInside`" `n- `"$VaultOperationFolderOneUp`" `n- `"$VaultOperationFolderTwoUp`". Make sure you get the latest version and extract it correctly from zip." -ForegroundColor Red
        Pause
        return
    }

    $stdoutFile = "$VaultOperationFolder\Log\stdout.log"
    $LOG_FILE_PATH_CasosArchive = "$VaultOperationFolder\Log\old"
    $specificUserTypesString = $GetSpecificuserTypes -join ','

    $redistributables = @(
        @{ Name = "Microsoft Visual C++ 2022 X86*"; Path = "$VaultOperationFolder\vc_redist.x86.exe" },
        @{ Name = "Microsoft Visual C++ 2022 X64*"; Path = "$VaultOperationFolder\vc_redist.x64.exe" }
    )

    foreach ($redis in $redistributables) {
        if ((Get-CimInstance -Class win32_product | Where-Object { $_.Name -like $redis.Name }) -eq $null) {
            Write-LogMessage -type Info -MSG "Installing Redis++ from $($redis.Path)..." -Early
            Start-Process -FilePath $redis.Path -ArgumentList "/install /passive /norestart" -Wait
        }
    }

    if (Test-Path $LOG_FILE_PATH_CasosArchive) {
        if (Get-ChildItem $LOG_FILE_PATH_CasosArchive | Measure-Object -Property length -Sum | Where-Object { $_.sum -gt 5MB }) {
            Write-Host "Archive log folder is getting too big, deleting it." -ForegroundColor Gray
            Write-Host "Deleting $LOG_FILE_PATH_CasosArchive" -ForegroundColor Gray
            Remove-Item $LOG_FILE_PATH_CasosArchive -Recurse -Force
        }
    }

    New-Item -Path $stdoutFile -Force | Out-Null

    $process = Start-Process -FilePath "$VaultOperationFolder\VaultOperationsTester.exe" -ArgumentList "$($Credentials.UserName) $($Credentials.GetNetworkCredential().Password) $VaultIP GetLicense $specificUserTypesString" -WorkingDirectory "$VaultOperationFolder" -NoNewWindow -PassThru -Wait -RedirectStandardOutput $stdoutFile
    $stdout = (Get-Content $stdoutFile)

    if ($process.ExitCode -ne 0) {
        Write-Host "-----------------------------------------"
        $stdout | Select-String -Pattern 'Extra details' -NotMatch | Write-Host -ForegroundColor Red
        Write-Host "$($stdout | Select-String -Pattern 'Extra details')" -ForegroundColor Red
        Write-Host "Failed" -ForegroundColor Red
        Write-Host "-----------------------------------------"
        Write-Host "More detailed log can be found here: $VaultOperationFolder\Log\Casos.Error.log"
    }
    else {
        $usersInfo = @()
        $currentUserInfo = $null

        foreach ($line in $stdout) {
            $trimmedLine = $line.Trim()

            if ($trimmedLine -eq "Connecting to the vault...") {
                $currentUserInfo = @{
                    "Name" = $null
                    "UserType Description" = $null
                    "Licensed Users" = $null
                    "Existing Users" = $null
                    "Currently Logged On Users" = $null
                }
            }
            elseif ($trimmedLine.StartsWith("Name: ")) {
                $currentUserInfo["Name"] = $trimmedLine -replace "Name: "
            }
            elseif ($trimmedLine.StartsWith("UserType Description: ")) {
                $currentUserInfo["UserType Description"] = $trimmedLine -replace "UserType Description: "
            }
            elseif ($trimmedLine.StartsWith("Licensed Users: ")) {
                $currentUserInfo["Licensed Users"] = $trimmedLine -replace "Licensed Users: "
            }
            elseif ($trimmedLine.StartsWith("Existing Users: ")) {
                $currentUserInfo["Existing Users"] = $trimmedLine -replace "Existing Users: "
            }
            elseif ($trimmedLine.StartsWith("Currently Logged On Users: ")) {
                $currentUserInfo["Currently Logged On Users"] = $trimmedLine -replace "Currently Logged On Users: "
                $usersInfo += New-Object PSObject -Property $currentUserInfo
            }
            elseif ($trimmedLine.StartsWith("License Expiration Date: ")) {
                $licenseInfo = $trimmedLine -replace "License Expiration Date: "
            }
        }

        CalcLicenseInfo -licenseInfo $licenseInfo
        Write-Host "License Expiration Date: $licenseExpirationDateLocal $lessThanXDays" -ForegroundColor $Alertcolor
        $usersInfo | Select-Object Name, "UserType Description", "Licensed Users", "Existing Users", "Currently Logged On Users" | Format-Table -AutoSize | Out-Host
        Write-Host "-------------------------------------------------------------"

        if (-not $ExportToCSV.IsPresent) {
            $ExportCSVChoice = Get-Choice -Title "Export Results to CSV" -Options "Yes","No" -DefaultChoice 2

            if ($ExportCSVChoice -eq "Yes") {
                $csvFilePath = "$ExportDir\LicenseCapacityReport.csv"
                $usersInfo | Select-Object Name, "UserType Description", "Licensed Users", "Existing Users", "Currently Logged On Users" | Export-Csv -Path $csvFilePath -NoTypeInformation -Force
                Write-Host "Results exported to $csvFilePath" -ForegroundColor Cyan

                $licenseFilePath = "$ExportDir\LicenseExpirationDate.txt"
                "License Expiration Date: $licenseExpirationDateLocal" | Out-File $licenseFilePath -Force
                Write-Host "License exported to $licenseFilePath" -ForegroundColor Cyan
            }
        }
        else {
            $csvFilePath = "$ExportDir\LicenseCapacityReport.csv"
            $usersInfo | Select-Object Name, "UserType Description", "Licensed Users", "Existing Users", "Currently Logged On Users" | Export-Csv -Path $csvFilePath -NoTypeInformation -Force
            Write-Host "Results exported to $csvFilePath" -ForegroundColor Cyan

            $licenseFilePath = "$ExportDir\LicenseExpirationDate.txt"
            "License Expiration Date: $licenseExpirationDateLocal" | Out-File $licenseFilePath -Force
            Write-Host "License exported to $licenseFilePath" -ForegroundColor Cyan
        }

        Write-Host "To get more detailed report rerun the script with '-ReportType DetailedReport' flag." -ForegroundColor Magenta
    }
}

function Get-UserReportObject {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$UserResponse,

        [Parameter(Mandatory = $true)]
        [string]$ReportedUserType,

        [Parameter(Mandatory = $true)]
        [int]$InactiveDays
    )

    $lastLoginDateString = "Never"
    $inactive = $true

    if ($UserResponse.PSObject.Properties.Name -contains 'lastSuccessfulLoginDate' -and
        $null -ne $UserResponse.lastSuccessfulLoginDate -and
        [string]$UserResponse.lastSuccessfulLoginDate -match '^\d+$' -and
        [int64]$UserResponse.lastSuccessfulLoginDate -gt 0) {

        $lastLoginDate = [DateTimeOffset]::FromUnixTimeSeconds([int64]$UserResponse.lastSuccessfulLoginDate).ToLocalTime()
        $lastLoginDateString = $lastLoginDate.ToString()
        $daysSinceLastLogin = (Get-Date) - $lastLoginDate.DateTime
        $inactive = $daysSinceLastLogin.TotalDays -gt $InactiveDays
    }

    return [PSCustomObject]@{
        UserName                           = $UserResponse.Username
        UserType                           = $ReportedUserType
        LastLoginDate                      = $lastLoginDateString
        "Inactive for $($InactiveDays) Days" = $inactive
    }
}

function Get-MissingUserTypeReportObject {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$UserResponse,

        [Parameter(Mandatory = $true)]
        [psobject]$ListUserObject,

        [Parameter(Mandatory = $true)]
        [int]$InactiveDays
    )

    $lastLoginDateString = "Never"
    $inactive = $true

    if ($UserResponse.PSObject.Properties.Name -contains 'lastSuccessfulLoginDate' -and
        $null -ne $UserResponse.lastSuccessfulLoginDate -and
        [string]$UserResponse.lastSuccessfulLoginDate -match '^\d+$' -and
        [int64]$UserResponse.lastSuccessfulLoginDate -gt 0) {

        $lastLoginDate = [DateTimeOffset]::FromUnixTimeSeconds([int64]$UserResponse.lastSuccessfulLoginDate).ToLocalTime()
        $lastLoginDateString = $lastLoginDate.ToString()
        $daysSinceLastLogin = (Get-Date) - $lastLoginDate.DateTime
        $inactive = $daysSinceLastLogin.TotalDays -gt $InactiveDays
    }

    return [PSCustomObject]@{
        ID                                 = $UserResponse.id
        UserName                           = $UserResponse.Username
        Source                             = $UserResponse.source
        UserType                           = $ListUserObject.userType
        ComponentUser                      = $ListUserObject.componentUser
        LastLoginDate                      = $lastLoginDateString
        "Inactive for $($InactiveDays) Days" = $inactive
        Finding                            = "Missing UserType (license may no longer support previous type)"
    }
}

function Get-UserType {
    param (
        [string]$UserType,
        [string]$URLAPI
    )

    $uri = "$URLAPI/Users?UserType=$UserType"
    $retryCount = 0
    $success = $false

    while (-not $success -and $retryCount -lt 3) {
        try {
            Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType

            $response = Invoke-RestMethod -Uri $uri -Headers $logonheader -Method GET -UseBasicParsing
            $success = $true

            $responseUsers = @($response.Users)

            # Keep only users whose actual returned userType matches the requested type
            $responseFiltered = @(
                $responseUsers | Where-Object {
                    -not [string]::IsNullOrWhiteSpace($_.userType) -and $_.userType -eq $UserType
                }
            )

            # Capture users returned by the API without a userType
            $missingUserTypeUsers = @(
                $responseUsers | Where-Object {
                    [string]::IsNullOrWhiteSpace($_.userType)
                }
            )

            Write-Host ""
            Write-Host "$UserType = $($responseFiltered.Count)" -ForegroundColor Green

            if ($responseFiltered.Count -ge 1) {
                Write-Host "----------Start $UserType-----------------"

                $userInformation = @()

                foreach ($user in $responseFiltered.id) {
                    $userSuccess = $false
                    $userRetryCount = 0

                    while (-not $userSuccess -and $userRetryCount -lt 3) {
                        try {
                            Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType
                            Start-Sleep -Milliseconds 70

                            $UserResponse = Invoke-RestMethod -Uri "$URLAPI/Users/$user" -Headers $logonheader

                            $userObject = Get-UserReportObject -UserResponse $UserResponse -ReportedUserType ([string]$UserType) -InactiveDays $InactiveDays
                            $userInformation += $userObject

                            if ($userObject."Inactive for $($InactiveDays) Days") {
                                Write-Host "UserName: $($UserResponse.Username) LastLoginDate: $($userObject.LastLoginDate)" -ForegroundColor Yellow
                            }
                            else {
                                Write-Host "UserName: $($UserResponse.Username) LastLoginDate: $($userObject.LastLoginDate)" -ForegroundColor Gray
                            }

                            $userSuccess = $true
                        }
                        catch {
                            if ($_.Exception.Response.StatusCode -eq 401) {
                                Write-Host "401 Unauthorized error encountered for userID $($user). Refreshing token and retrying..." -ForegroundColor Yellow
                                Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType
                                $userRetryCount++
                            }
                            else {
                                Write-Host "Error fetching details for userID $($user) $($_.Exception.Message) $($_.ErrorDetails.Message) $($_.Exception.Status)" -ForegroundColor Red
                                $userSuccess = $true
                            }
                        }
                    }

                    if (-not $userSuccess) {
                        Write-Host "Max retries reached for user $user. Moving to the next user..." -ForegroundColor Red
                    }
                }

                Write-Host "----------End $UserType-----------------"

                if ($ExportToCSV.IsPresent) {
                    $csvFilePath = "$ExportDir\$UserType-UsersReport.csv"
                    $userInformation | Export-Csv -Path $csvFilePath -NoTypeInformation -Force
                    Write-Host "Results exported to $csvFilePath" -ForegroundColor Cyan
                }
            }

            # Report users with missing UserType only once, preferably during EPVUser processing
            if ($UserType -eq "EPVUser" -and -not $script:MissingUserTypeHandled -and $missingUserTypeUsers.Count -gt 0) {
                Write-Host ""
                Write-Host "----------Users with Missing UserType-----------------" -ForegroundColor Yellow
                Write-Host "Note: These users may have been created under a previous license that supported additional user types." -ForegroundColor DarkYellow

                $missingUserTypeInformation = @()

                foreach ($missingUser in $missingUserTypeUsers) {
                    $missingUserSuccess = $false
                    $missingRetryCount = 0

                    while (-not $missingUserSuccess -and $missingRetryCount -lt 3) {
                        try {
                            Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType
                            Start-Sleep -Milliseconds 70

                            $MissingUserResponse = Invoke-RestMethod -Uri "$URLAPI/Users/$($missingUser.id)" -Headers $logonheader

                            $missingUserObject = Get-MissingUserTypeReportObject -UserResponse $MissingUserResponse -ListUserObject $missingUser -InactiveDays $InactiveDays
                            $missingUserTypeInformation += $missingUserObject

                            Write-Host "UserName: $($missingUserObject.UserName) | ComponentUser: $($missingUserObject.ComponentUser) | LastLoginDate: $($missingUserObject.LastLoginDate)" -ForegroundColor Yellow

                            $missingUserSuccess = $true
                        }
                        catch {
                            if ($_.Exception.Response.StatusCode -eq 401) {
                                Write-Host "401 Unauthorized error encountered for missing-userType userID $($missingUser.id). Refreshing token and retrying..." -ForegroundColor Yellow
                                Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType
                                $missingRetryCount++
                            }
                            else {
                                Write-Host "Error fetching details for missing-userType userID $($missingUser.id) $($_.Exception.Message) $($_.ErrorDetails.Message) $($_.Exception.Status)" -ForegroundColor Red
                                $missingUserSuccess = $true
                            }
                        }
                    }

                    if (-not $missingUserSuccess) {
                        Write-Host "Max retries reached for missing-userType user $($missingUser.id). Moving to the next user..." -ForegroundColor Red
                    }
                }

                Write-Host "Users with Missing UserType: $($missingUserTypeInformation.Count)" -ForegroundColor Yellow
                Write-Host "------------------------------------------------------" -ForegroundColor Yellow

                if ($ExportToCSV.IsPresent) {
                    $missingUserTypeCsvFilePath = "$ExportDir\MissingUserType-Users.csv"
                    $missingUserTypeInformation | Export-Csv -Path $missingUserTypeCsvFilePath -NoTypeInformation -Force
                    Write-Host "Users with Missing UserType exported to $missingUserTypeCsvFilePath" -ForegroundColor Cyan
                }

                $script:MissingUserTypeHandled = $true
            }
        }
        catch {
            if ($_.Exception.Message -like "*(400) Bad Request*") {
                $response = [PSCustomObject]@{ Total = 0 }
                $success = $true
            }
            elseif ($_.Exception.Response.StatusCode -eq 401) {
                Write-Host "401 Unauthorized error encountered. Refreshing token and retrying..." -ForegroundColor Yellow
                Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType
                $retryCount++
            }
            else {
                Write-Host "Error fetching user type details: $($_.Exception.Message) $($_.ErrorDetails.Message) $($_.Exception.Status)" -ForegroundColor Red
                $success = $true
            }
        }
    }

    if (-not $success) {
        Write-Host "Max retries reached for $UserType. Moving to the next user type..." -ForegroundColor Red
    }
}

# Main
try {
    Write-Host "Script Version: $scriptVersion" -ForegroundColor Gray

    # Build PVWA URLs
    $platformURLs = DetermineTenantTypeURLs -PortalURL $PortalURL
    $IdentityAPIURL = $platformURLs.IdentityURL
    $pvwaAPI = $platformURLs.PVWA_API_URLs.PVWAAPI
    $VaultURL = $platformURLs.vaultURL
    $global:AlreadyAnswered = $false

    if ([string]::IsNullOrEmpty($ReportType)) {
        $SelectOption = Get-Choice -Title "Choose Report Type" -Options "License Capacity Report","Detailed User Report" -DefaultChoice 1
        if ($SelectOption -like "*Detailed*") {
            $script:ReportType = "DetailedReport"
        }
        else {
            $script:ReportType = "CapacityReport"
        }
    }

    if ($ReportType -eq "DetailedReport") {
        Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType

        Write-Host ""
        Write-Host "Privilege Cloud consumed users report for tenant $PortalURL"
        Write-Host "-----------------------------------------------------------------------"
        Write-Host "Yellow Users = Inactive for more than $($InactiveDays) days" -ForegroundColor Black -BackgroundColor Yellow

        foreach ($userType in $GetSpecificuserTypes) {
            Get-UserType -UserType $userType -URLAPI $pvwaAPI
        }
    }
    else {
        $ForceAuthType = "cyberark"
        Refresh-Token -PlatformURLs $platformURLs -creds $Credentials -ForceAuthType $ForceAuthType

        Write-Host "Privilege Cloud Capacity report for tenant $PortalURL"
        Write-Host "-----------------------------------------------------------------------"

        Get-LicenseCapacityReport -vaultIp $VaultURL -GetSpecificuserTypes $GetSpecificuserTypes
    }
}
catch {
    Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "Error Details: $($_.ErrorDetails.Message)" -ForegroundColor Red
    Write-Host "Exiting..."
}
finally {
    $Credentials = $null
    try {
        Invoke-RestMethod -Uri $($platformURLs.PVWA_API_URLs.Logoff) -Method Post -Headers $logonHeader | Out-Null
    }
    catch {}
}
# SIG # Begin signature block
# MIIpLQYJKoZIhvcNAQcCoIIpHjCCKRoCAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCDpVci6IurbieNe
# PXszb9SIXkOUf25Pobmv8YobBj/hQKCCDq8wggboMIIE0KADAgECAhB3vQ4Ft1kL
# th1HYVMeP3XtMA0GCSqGSIb3DQEBCwUAMFMxCzAJBgNVBAYTAkJFMRkwFwYDVQQK
# ExBHbG9iYWxTaWduIG52LXNhMSkwJwYDVQQDEyBHbG9iYWxTaWduIENvZGUgU2ln
# bmluZyBSb290IFI0NTAeFw0yMDA3MjgwMDAwMDBaFw0zMDA3MjgwMDAwMDBaMFwx
# CzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNhMTIwMAYDVQQD
# EylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0EgMjAyMDCCAiIw
# DQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBAMsg75ceuQEyQ6BbqYoj/SBerjgS
# i8os1P9B2BpV1BlTt/2jF+d6OVzA984Ro/ml7QH6tbqT76+T3PjisxlMg7BKRFAE
# eIQQaqTWlpCOgfh8qy+1o1cz0lh7lA5tD6WRJiqzg09ysYp7ZJLQ8LRVX5YLEeWa
# tSyyEc8lG31RK5gfSaNf+BOeNbgDAtqkEy+FSu/EL3AOwdTMMxLsvUCV0xHK5s2z
# BZzIU+tS13hMUQGSgt4T8weOdLqEgJ/SpBUO6K/r94n233Hw0b6nskEzIHXMsdXt
# HQcZxOsmd/KrbReTSam35sOQnMa47MzJe5pexcUkk2NvfhCLYc+YVaMkoog28vmf
# vpMusgafJsAMAVYS4bKKnw4e3JiLLs/a4ok0ph8moKiueG3soYgVPMLq7rfYrWGl
# r3A2onmO3A1zwPHkLKuU7FgGOTZI1jta6CLOdA6vLPEV2tG0leis1Ult5a/dm2tj
# IF2OfjuyQ9hiOpTlzbSYszcZJBJyc6sEsAnchebUIgTvQCodLm3HadNutwFsDeCX
# pxbmJouI9wNEhl9iZ0y1pzeoVdwDNoxuz202JvEOj7A9ccDhMqeC5LYyAjIwfLWT
# yCH9PIjmaWP47nXJi8Kr77o6/elev7YR8b7wPcoyPm593g9+m5XEEofnGrhO7izB
# 36Fl6CSDySrC/blTAgMBAAGjggGtMIIBqTAOBgNVHQ8BAf8EBAMCAYYwEwYDVR0l
# BAwwCgYIKwYBBQUHAwMwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQUJZ3Q
# /FkJhmPF7POxEztXHAOSNhEwHwYDVR0jBBgwFoAUHwC/RoAK/Hg5t6W0Q9lWULvO
# ljswgZMGCCsGAQUFBwEBBIGGMIGDMDkGCCsGAQUFBzABhi1odHRwOi8vb2NzcC5n
# bG9iYWxzaWduLmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUwRgYIKwYBBQUHMAKGOmh0
# dHA6Ly9zZWN1cmUuZ2xvYmFsc2lnbi5jb20vY2FjZXJ0L2NvZGVzaWduaW5ncm9v
# dHI0NS5jcnQwQQYDVR0fBDowODA2oDSgMoYwaHR0cDovL2NybC5nbG9iYWxzaWdu
# LmNvbS9jb2Rlc2lnbmluZ3Jvb3RyNDUuY3JsMFUGA1UdIAROMEwwQQYJKwYBBAGg
# MgECMDQwMgYIKwYBBQUHAgEWJmh0dHBzOi8vd3d3Lmdsb2JhbHNpZ24uY29tL3Jl
# cG9zaXRvcnkvMAcGBWeBDAEDMA0GCSqGSIb3DQEBCwUAA4ICAQAldaAJyTm6t6E5
# iS8Yn6vW6x1L6JR8DQdomxyd73G2F2prAk+zP4ZFh8xlm0zjWAYCImbVYQLFY4/U
# ovG2XiULd5bpzXFAM4gp7O7zom28TbU+BkvJczPKCBQtPUzosLp1pnQtpFg6bBNJ
# +KUVChSWhbFqaDQlQq+WVvQQ+iR98StywRbha+vmqZjHPlr00Bid/XSXhndGKj0j
# fShziq7vKxuav2xTpxSePIdxwF6OyPvTKpIz6ldNXgdeysEYrIEtGiH6bs+XYXvf
# cXo6ymP31TBENzL+u0OF3Lr8psozGSt3bdvLBfB+X3Uuora/Nao2Y8nOZNm9/Lws
# 80lWAMgSK8YnuzevV+/Ezx4pxPTiLc4qYc9X7fUKQOL1GNYe6ZAvytOHX5OKSBoR
# HeU3hZ8uZmKaXoFOlaxVV0PcU4slfjxhD4oLuvU/pteO9wRWXiG7n9dqcYC/lt5y
# A9jYIivzJxZPOOhRQAyuku++PX33gMZMNleElaeEFUgwDlInCI2Oor0ixxnJpsoO
# qHo222q6YV8RJJWk4o5o7hmpSZle0LQ0vdb5QMcQlzFSOTUpEYck08T7qWPLd0jV
# +mL8JOAEek7Q5G7ezp44UCb0IXFl1wkl1MkHAHq4x/N36MXU4lXQ0x72f1LiSY25
# EXIMiEQmM2YBRN/kMw4h3mKJSAfa9TCCB78wggWnoAMCAQICDFvWkQMw/ZfAZpUM
# wDANBgkqhkiG9w0BAQsFADBcMQswCQYDVQQGEwJCRTEZMBcGA1UEChMQR2xvYmFs
# U2lnbiBudi1zYTEyMDAGA1UEAxMpR2xvYmFsU2lnbiBHQ0MgUjQ1IEVWIENvZGVT
# aWduaW5nIENBIDIwMjAwHhcNMjYwMzAyMjE1MjMzWhcNMjcwMjI3MTM0MDU2WjCC
# AQQxHTAbBgNVBA8MFFByaXZhdGUgT3JnYW5pemF0aW9uMRIwEAYDVQQFEwk1MTIy
# OTE2NDIxEzARBgsrBgEEAYI3PAIBAxMCSUwxCzAJBgNVBAYTAklMMRkwFwYDVQQI
# ExBDZW50cmFsIERpc3RyaWN0MRQwEgYDVQQHEwtQZXRhaCBUaWt2YTEXMBUGA1UE
# CRMOOSBIYXBzYWdvdCBTdC4xHzAdBgNVBAoTFkN5YmVyQXJrIFNvZnR3YXJlIEx0
# ZC4xHzAdBgNVBAMTFkN5YmVyQXJrIFNvZnR3YXJlIEx0ZC4xITAfBgkqhkiG9w0B
# CQEWEmFkbWluQGN5YmVyYXJrLmNvbTCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCC
# AgoCggIBAKtAr5PeV7TdJZDWUNp8j60tepBmgC2+9Dw8tUh+RsLhqaSNi0dUc7i9
# yznveSdnfE4l2U8ZXyEILjQsSJw3SaPaXMSOzR4wVnuTc1nTzKBOS3oa6Yil7rlu
# gNXVj8dmEEehcPuAkF4ciqt6YChi5a6DD/r8GYuHv+/75XDZCD1nTPesDLIN+RAU
# aqHWLF0XRDXwF/JgB6W+lzIuYeiXdM/jPxZqvg1d7WKZQCy0maucWE/n4N4/8nPT
# qLm3y8jhUdP6YGUlyJLbC4fxbVW1KrhDMY1DOOtItuBiOeBVAvVctbw/kAvEc32Y
# Iz3qIWTmcR0VzVVV6IlNWOrMqJZEvtHlqRVkekLJXB5pVw6b3PuelU92cb+VtUnB
# hewMxSkPj8094wN7urFk7wXxVtNVTYtkmT5ThcphO5Sha1bCfTgymePAfUJW2p2o
# FdNBDeMoSmVlTDDlffRpyMzFZpHpc6v0HzeLmkEcZk+HRf5dgeRMQZWt/Mgsizwe
# w0RuaCeQlphX7RgBRkC9rT57RCcBMtW3blk4Vz6qncCKCLBCJK1CIrC2frGX7vqt
# In+0zR1K0ec8tTH5im5QEE72MuMV+/4KbP+ISojaQ8JFZvqESxyAUbjpQcE2pfzv
# fwKiSXTyOCv9buuHDViUhoSc9oEKA3iuhc8Yz21F4CO0MTj014+FAgMBAAGjggHV
# MIIB0TAOBgNVHQ8BAf8EBAMCB4AwgZ8GCCsGAQUFBwEBBIGSMIGPMEwGCCsGAQUF
# BzAChkBodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2NhY2VydC9nc2djY3I0
# NWV2Y29kZXNpZ25jYTIwMjAuY3J0MD8GCCsGAQUFBzABhjNodHRwOi8vb2NzcC5n
# bG9iYWxzaWduLmNvbS9nc2djY3I0NWV2Y29kZXNpZ25jYTIwMjAwVQYDVR0gBE4w
# TDBBBgkrBgEEAaAyAQIwNDAyBggrBgEFBQcCARYmaHR0cHM6Ly93d3cuZ2xvYmFs
# c2lnbi5jb20vcmVwb3NpdG9yeS8wBwYFZ4EMAQMwCQYDVR0TBAIwADBHBgNVHR8E
# QDA+MDygOqA4hjZodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL2dzZ2NjcjQ1ZXZj
# b2Rlc2lnbmNhMjAyMC5jcmwwHQYDVR0RBBYwFIESYWRtaW5AY3liZXJhcmsuY29t
# MBMGA1UdJQQMMAoGCCsGAQUFBwMDMB8GA1UdIwQYMBaAFCWd0PxZCYZjxezzsRM7
# VxwDkjYRMB0GA1UdDgQWBBR/nObXnnoINvefWdWmW4iZSqmPAjANBgkqhkiG9w0B
# AQsFAAOCAgEAvpUZ9sMYv3kb7+v5CzJoUgOAtOF21kKgzqrgRmwH/xyuXkhs+tY9
# LCE3ldhZmAJIfgBKZuKUQL5eFmLHltBevBKfgmfaT6uoG0sJ3QyNu46m2hMr/gvm
# Kms2zfFGOZxG8wHeZUQ1v8imN80Frvvy1DIdA1QOW4hIJvt1GbCaS6TTC3eO9/fO
# r22hHk0IBt+LtmSeA/rdFsnwT4Y4SY4mebZZePHH9c+KreM64DAP61rLodKQCw14
# jbPTlQRSelbJpb+Vmo7q1sieuCY5US2KsXG/4P/ENEJFnwH+ib671IjN7L4AISzt
# BoKY81CNMBSziqMpdCwrAiXBQhBHdKUG28MhrxS1gB564h+fo9tMrV5pe6Jp60Sa
# Wn5aQzu/nWR6z+gUR9mk5SdjBow+Liykxd/2o5wT8AmJ6XE/vGd7lK8MnuoTeJ65
# WQOsMd7MyB4tP3CV9/r+JESfPExxK3ybfWp1cAigtzpGII2fUM0sx43Wd7w0Ugfp
# OjmGOUKpshp6zJAqG+NNbupqk5vHAiddvHHRrZGLF7qbc0jcdQyxygyxQLe5Quu3
# M/bZ5+b4T+4xT/b0hmU4WmiHV8h3OF6U6OvIU2+gJ8NtRSkl+Jz/nhhU5hhNh2Ad
# TB108wYNMYET2xxoxtEPL5Sb0rX07I4lEGPpbwAcP1jds2+pgeB1pYcxghnUMIIZ
# 0AIBATBsMFwxCzAJBgNVBAYTAkJFMRkwFwYDVQQKExBHbG9iYWxTaWduIG52LXNh
# MTIwMAYDVQQDEylHbG9iYWxTaWduIEdDQyBSNDUgRVYgQ29kZVNpZ25pbmcgQ0Eg
# MjAyMAIMW9aRAzD9l8BmlQzAMA0GCWCGSAFlAwQCAQUAoHwwEAYKKwYBBAGCNwIB
# DDECMAAwGQYJKoZIhvcNAQkDMQwGCisGAQQBgjcCAQQwHAYKKwYBBAGCNwIBCzEO
# MAwGCisGAQQBgjcCARUwLwYJKoZIhvcNAQkEMSIEIOCC1Ng/+1KXcFFDd3aLoI89
# KnbJr97009Nk7x/IzuJwMA0GCSqGSIb3DQEBAQUABIICAHm24f9tLMlRh4HYFgKz
# 9j99Ab2PSx/3yQULrox5C3Ok+nkoDoxYwiIOD5pY1PotHX59so/1F6yDcNx5G3HU
# yIY4Z7T1WzZBBDT9TA914n+P0zZk+GzByovwo/29r28zhcUUSpJkuHufmA1UbHmS
# gwd9LF/yBbzw72fyi6sZtC0HKu3oz7BEBq6bff63gQtUQR9JgDEpV6taGGrookVn
# IY5qYeYUWu/UKfuVxDC1FpPklFFCaVFXIwehS+DkharJYJuQcC9k890KSVxWD6dh
# TRTUNTL9af/k+7IDYYFedG6y0NKUbZn+ooUhVX1omEJ42h2WAIukQVuljqvDb8pL
# SMNFOl3+Bi9U6vK07rkQXbVlozwZroopMZtxGGr7CW9VwpOgCf+E4lbZQWJkh7Lt
# Ip0Qj+Dlp/ub9gXeNWwUepx/zrFx7gnP1tfdk2niexRg3IHS0GuOJOv9ZMVwurQr
# imzLXpWT5F/RbeQbJQkJkgcMzlr3P3z2AyPF7co01K9rvTXMGNdq5JIdMIjZ4BTS
# 82S0TXAAaBBqDFhyf7uyXlcMb0OMTr8EbQwTMBIDzv99kmnq8oM18ajaRH/DjFmL
# zw4ZGsMf3g8EuNK6r/wIMXirOpjy7fupGCUMRwEpTCFbjqKc+XUUKli3V/yBbatb
# HWAzdQUk04Tqc6OzEOczVJDQoYIWuzCCFrcGCisGAQQBgjcDAwExghanMIIWowYJ
# KoZIhvcNAQcCoIIWlDCCFpACAQMxDTALBglghkgBZQMEAgEwgd8GCyqGSIb3DQEJ
# EAEEoIHPBIHMMIHJAgEBBgsrBgEEAaAyAgMBAjAxMA0GCWCGSAFlAwQCAQUABCAN
# mKAxiFkvF4wYq4EC0Z6qC3XFJwEW5ytTLq8t0IDjBQIUBGI0/pk5aEcNgyhXd16b
# zS/umCMYDzIwMjYwMzI3MTIxNzE1WjADAgEBoFikVjBUMQswCQYDVQQGEwJCRTEZ
# MBcGA1UECgwQR2xvYmFsU2lnbiBudi1zYTEqMCgGA1UEAwwhR2xvYmFsc2lnbiBU
# U0EgZm9yIENvZGVTaWduMSAtIFI2oIISSzCCBmMwggRLoAMCAQICEAEACyAFs5QH
# Yts+NnmUm6kwDQYJKoZIhvcNAQEMBQAwWzELMAkGA1UEBhMCQkUxGTAXBgNVBAoT
# EEdsb2JhbFNpZ24gbnYtc2ExMTAvBgNVBAMTKEdsb2JhbFNpZ24gVGltZXN0YW1w
# aW5nIENBIC0gU0hBMzg0IC0gRzQwHhcNMjUwNDExMTQ0NzM5WhcNMzQxMjEwMDAw
# MDAwWjBUMQswCQYDVQQGEwJCRTEZMBcGA1UECgwQR2xvYmFsU2lnbiBudi1zYTEq
# MCgGA1UEAwwhR2xvYmFsc2lnbiBUU0EgZm9yIENvZGVTaWduMSAtIFI2MIIBojAN
# BgkqhkiG9w0BAQEFAAOCAY8AMIIBigKCAYEAolvEqk1J5SN4PuCF6+aqCj7V8qyo
# p0Rh94rLmY37Cn8er80SkfKzdJHJk3Tqa9QY4UwV6hedXfSb5gk0Xydy3MNEj1qE
# +ZomPEcjC7uRtGdfB/PtnieWJzjtPVUlmEPrUMsoFU7woJScRV1W6/6efi2BySHX
# shZ30V1EDZ2lKQ0DK3q3bI4sJE/5n/dQy8iL4hjTaS9v0YQy5RJY+o1NWhxP/HsN
# um67Or4rFDsGIE85hg5r4g3CXFuiqWvlNmPbCBWgdxp/PCqY0Lie04DuKbDwRd6n
# rm5AH5oIRJyFUjLvG4HO0L1UXYMuJ6J1JzO438RA0mJRvU2ZwbI6yiFHaS0x3SgF
# akvhELLn4tmwngYPj+FDX3LaWHnni/MGJXRxnN0pQdYJqEYhKUlrMH9+2Klndcz/
# 9yXYGEywTt88d3y+TUFvZlAA0BMOYMMrYFQEptlRg2DYrx5sWtX1qvCzk6sEBLRV
# PEbE0i+J01ILlBzRpcJusZUQyGK2RVSOFfXPAgMBAAGjggGoMIIBpDAOBgNVHQ8B
# Af8EBAMCB4AwFgYDVR0lAQH/BAwwCgYIKwYBBQUHAwgwHQYDVR0OBBYEFIBDTPy6
# bR0T0nUSiAl3b9vGT5VUMFYGA1UdIARPME0wCAYGZ4EMAQQCMEEGCSsGAQQBoDIB
# HjA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5nbG9iYWxzaWduLmNvbS9yZXBv
# c2l0b3J5LzAMBgNVHRMBAf8EAjAAMIGQBggrBgEFBQcBAQSBgzCBgDA5BggrBgEF
# BQcwAYYtaHR0cDovL29jc3AuZ2xvYmFsc2lnbi5jb20vY2EvZ3N0c2FjYXNoYTM4
# NGc0MEMGCCsGAQUFBzAChjdodHRwOi8vc2VjdXJlLmdsb2JhbHNpZ24uY29tL2Nh
# Y2VydC9nc3RzYWNhc2hhMzg0ZzQuY3J0MB8GA1UdIwQYMBaAFOoWxmnn48tXRTkz
# pPBAvtDDvWWWMEEGA1UdHwQ6MDgwNqA0oDKGMGh0dHA6Ly9jcmwuZ2xvYmFsc2ln
# bi5jb20vY2EvZ3N0c2FjYXNoYTM4NGc0LmNybDANBgkqhkiG9w0BAQwFAAOCAgEA
# t6bHSpl2dP0gYie9iXw3Bz5XzwsvmiYisEjboyRZin+jqH26IFq7fQMIrN5VdX8K
# Gl5pEe21b8skPfUctiroo6QS5oWESl4kzZow2iJ/qJn76TkvL+v2f4mHolGLBwyD
# m74fXr68W63xuiYSpnbf7NYPyBaHI7zJ/ErST4bA00TC+ftPttS+G/MhNUaKg34y
# aJ8Z6AENnPdCB8VIrt/sqd6R1k89Ojx1jL36QBEPUr2dtIIlS3Ki74CU15YTvG+X
# xt9cwE+0Gx/qRQv8YbF+UcsdgYU4jNRZB0kTV3Bsd3lyIWmt8DT4RQj9LQ1ILOpq
# G/Czwd9q9GJL6jSJeSq1AC4ZocVMuqcYd/D9JpIML9BQ/wk5lgJkgXEc1gRgPsDs
# U9zz36JymN1+Yhvx0Vr67jr0Qfqk3V0z6/xVmEAJKafTeIfD9hQchjiGkyw3EKNi
# yHyM37rdK/BsTSx0rB3MHdqE9/dHQX5NUOQCWUvhkWy10u71yzGKWnbAWQ6NNuq9
# ftcwYFTmcyo5YbFwzfkyS+Y78+O9utqgi6VoE2NzVJbucqGLZtJFJzGJD7xe/rqU
# LwYHeQ3HPSnNCagb6jqBeFSnXTx0GbuYuk3jA51dQNtsogVAGXCqHsh62QVAl/ga
# dTfcRaMpIWAc3CPup3x19dDApspmRyOVzXBUtsiCWsIwggZZMIIEQaADAgECAg0B
# 7BySQN79LkBdfEd0MA0GCSqGSIb3DQEBDAUAMEwxIDAeBgNVBAsTF0dsb2JhbFNp
# Z24gUm9vdCBDQSAtIFI2MRMwEQYDVQQKEwpHbG9iYWxTaWduMRMwEQYDVQQDEwpH
# bG9iYWxTaWduMB4XDTE4MDYyMDAwMDAwMFoXDTM0MTIxMDAwMDAwMFowWzELMAkG
# A1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMTAvBgNVBAMTKEds
# b2JhbFNpZ24gVGltZXN0YW1waW5nIENBIC0gU0hBMzg0IC0gRzQwggIiMA0GCSqG
# SIb3DQEBAQUAA4ICDwAwggIKAoICAQDwAuIwI/rgG+GadLOvdYNfqUdSx2E6Y3w5
# I3ltdPwx5HQSGZb6zidiW64HiifuV6PENe2zNMeswwzrgGZt0ShKwSy7uXDycq6M
# 95laXXauv0SofEEkjo+6xU//NkGrpy39eE5DiP6TGRfZ7jHPvIo7bmrEiPDul/bc
# 8xigS5kcDoenJuGIyaDlmeKe9JxMP11b7Lbv0mXPRQtUPbFUUweLmW64VJmKqDGS
# O/J6ffwOWN+BauGwbB5lgirUIceU/kKWO/ELsX9/RpgOhz16ZevRVqkuvftYPbWF
# +lOZTVt07XJLog2CNxkM0KvqWsHvD9WZuT/0TzXxnA/TNxNS2SU07Zbv+GfqCL6P
# SXr/kLHU9ykV1/kNXdaHQx50xHAotIB7vSqbu4ThDqxvDbm19m1W/oodCT4kDmcm
# x/yyDaCUsLKUzHvmZ/6mWLLU2EESwVX9bpHFu7FMCEue1EIGbxsY1TbqZK7O/fUF
# 5uJm0A4FIayxEQYjGeT7BTRE6giunUlnEYuC5a1ahqdm/TMDAd6ZJflxbumcXQJM
# YDzPAo8B/XLukvGnEt5CEk3sqSbldwKsDlcMCdFhniaI/MiyTdtk8EWfusE/VKPY
# dgKVbGqNyiJc9gwE4yn6S7Ac0zd0hNkdZqs0c48efXxeltY9GbCX6oxQkW2vV4Z+
# EDcdaxoU3wIDAQABo4IBKTCCASUwDgYDVR0PAQH/BAQDAgGGMBIGA1UdEwEB/wQI
# MAYBAf8CAQAwHQYDVR0OBBYEFOoWxmnn48tXRTkzpPBAvtDDvWWWMB8GA1UdIwQY
# MBaAFK5sBaOTE+Ki5+LXHNbH8H/IZ1OgMD4GCCsGAQUFBwEBBDIwMDAuBggrBgEF
# BQcwAYYiaHR0cDovL29jc3AyLmdsb2JhbHNpZ24uY29tL3Jvb3RyNjA2BgNVHR8E
# LzAtMCugKaAnhiVodHRwOi8vY3JsLmdsb2JhbHNpZ24uY29tL3Jvb3QtcjYuY3Js
# MEcGA1UdIARAMD4wPAYEVR0gADA0MDIGCCsGAQUFBwIBFiZodHRwczovL3d3dy5n
# bG9iYWxzaWduLmNvbS9yZXBvc2l0b3J5LzANBgkqhkiG9w0BAQwFAAOCAgEAf+KI
# 2VdnK0JfgacJC7rEuygYVtZMv9sbB3DG+wsJrQA6YDMfOcYWaxlASSUIHuSb99ak
# DY8elvKGohfeQb9P4byrze7AI4zGhf5LFST5GETsH8KkrNCyz+zCVmUdvX/23oLI
# t59h07VGSJiXAmd6FpVK22LG0LMCzDRIRVXd7OlKn14U7XIQcXZw0g+W8+o3V5SR
# GK/cjZk4GVjCqaF+om4VJuq0+X8q5+dIZGkv0pqhcvb3JEt0Wn1yhjWzAlcfi5z8
# u6xM3vreU0yD/RKxtklVT3WdrG9KyC5qucqIwxIwTrIIc59eodaZzul9S5YszBZr
# GM3kWTeGCSziRdayzW6CdaXajR63Wy+ILj198fKRMAWcznt8oMWsr1EG8BHHHTDF
# UVZg6HyVPSLj1QokUyeXgPpIiScseeI85Zse46qEgok+wEr1If5iEO0dMPz2zOpI
# J3yLdUJ/a8vzpWuVHwRYNAqJ7YJQ5NF7qMnmvkiqK1XZjbclIA4bUaDUY6qD6mxy
# YUrJ+kPExlfFnbY8sIuwuRwx773vFNgUQGwgHcIt6AvGjW2MtnHtUiH+Pvafnzka
# rqzSL3ogsfSsqh3iLRSd+pZqHcY8yvPZHL9TTaRHWXyVxENB+SXiLBB+gfkNlKd9
# 8rUJ9dhgckBQlSDUQ0S++qCV5yBZtnjGpGqqIpswggWDMIIDa6ADAgECAg5F5rsD
# gzPDhWVI5v9FUTANBgkqhkiG9w0BAQwFADBMMSAwHgYDVQQLExdHbG9iYWxTaWdu
# IFJvb3QgQ0EgLSBSNjETMBEGA1UEChMKR2xvYmFsU2lnbjETMBEGA1UEAxMKR2xv
# YmFsU2lnbjAeFw0xNDEyMTAwMDAwMDBaFw0zNDEyMTAwMDAwMDBaMEwxIDAeBgNV
# BAsTF0dsb2JhbFNpZ24gUm9vdCBDQSAtIFI2MRMwEQYDVQQKEwpHbG9iYWxTaWdu
# MRMwEQYDVQQDEwpHbG9iYWxTaWduMIICIjANBgkqhkiG9w0BAQEFAAOCAg8AMIIC
# CgKCAgEAlQfoc8pm+ewUyns89w0I8bRFCyyCtEjG61s8roO4QZIzFKRvf+kqzMaw
# iGvFtonRxrL/FM5RFCHsSt0bWsbWh+5NOhUG7WRmC5KAykTec5RO86eJf094YwjI
# ElBtQmYvTbl5KE1SGooagLcZgQ5+xIq8ZEwhHENo1z08isWyZtWQmrcxBsW+4m0y
# BqYe+bnrqqO4v76CY1DQ8BiJ3+QPefXqoh8q0nAue+e8k7ttU+JIfIwQBzj/ZrJ3
# YX7g6ow8qrSk9vOVShIHbf2MsonP0KBhd8hYdLDUIzr3XTrKotudCd5dRC2Q8YHN
# V5L6frxQBGM032uTGL5rNrI55KwkNrfw77YcE1eTtt6y+OKFt3OiuDWqRfLgnTah
# b1SK8XJWbi6IxVFCRBWU7qPFOJabTk5aC0fzBjZJdzC8cTflpuwhCHX85mEWP3fV
# 2ZGXhAps1AJNdMAU7f05+4PyXhShBLAL6f7uj+FuC7IIs2FmCWqxBjplllnA8DX9
# ydoojRoRh3CBCqiadR2eOoYFAJ7bgNYl+dwFnidZTHY5W+r5paHYgw/R/98wEfmF
# zzNI9cptZBQselhP00sIScWVZBpjDnk99bOMylitnEJFeW4OhxlcVLFltr+Mm9wT
# 6Q1vuC7cZ27JixG1hBSKABlwg3mRl5HUGie/Nx4yB9gUYzwoTK8CAwEAAaNjMGEw
# DgYDVR0PAQH/BAQDAgEGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0OBBYEFK5sBaOT
# E+Ki5+LXHNbH8H/IZ1OgMB8GA1UdIwQYMBaAFK5sBaOTE+Ki5+LXHNbH8H/IZ1Og
# MA0GCSqGSIb3DQEBDAUAA4ICAQCDJe3o0f2VUs2ewASgkWnmXNCE3tytok/oR3jW
# ZZipW6g8h3wCitFutxZz5l/AVJjVdL7BzeIRka0jGD3d4XJElrSVXsB7jpl4FkMT
# VlezorM7tXfcQHKso+ubNT6xCCGh58RDN3kyvrXnnCxMvEMpmY4w06wh4OMd+tgH
# M3ZUACIquU0gLnBo2uVT/INc053y/0QMRGby0uO9RgAabQK6JV2NoTFR3VRGHE3b
# mZbvGhwEXKYV73jgef5d2z6qTFX9mhWpb+Gm+99wMOnD7kJG7cKTBYn6fWN7P9Bx
# gXwA6JiuDng0wyX7rwqfIGvdOxOPEoziQRpIenOgd2nHtlx/gsge/lgbKCuobK1e
# bcAF0nu364D+JTf+AptorEJdw+71zNzwUHXSNmmc5nsE324GabbeCglIWYfrexRg
# emSqaUPvkcdM7BjdbO9TLYyZ4V7ycj7PVMi9Z+ykD0xF/9O5MCMHTI8Qv4aW2Zla
# tJlXHKTMuxWJU7osBQ/kxJ4ZsRg01Uyduu33H68klQR4qAO77oHl2l98i0qhkHQl
# p7M+S8gsVr3HyO844lyS8Hn3nIS6dC1hASB+ftHyTwdZX4stQ1LrRgyU4fVmR3l3
# 1VRbH60kN8tFWk6gREjI2LCZxRWECfbWSUnAZbjmGnFuoKjxguhFPmzWAtcKZ4MF
# WsmkEDGCA0kwggNFAgEBMG8wWzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2Jh
# bFNpZ24gbnYtc2ExMTAvBgNVBAMTKEdsb2JhbFNpZ24gVGltZXN0YW1waW5nIENB
# IC0gU0hBMzg0IC0gRzQCEAEACyAFs5QHYts+NnmUm6kwCwYJYIZIAWUDBAIBoIIB
# LTAaBgkqhkiG9w0BCQMxDQYLKoZIhvcNAQkQAQQwKwYJKoZIhvcNAQk0MR4wHDAL
# BglghkgBZQMEAgGhDQYJKoZIhvcNAQELBQAwLwYJKoZIhvcNAQkEMSIEIN/TyF63
# EnCprHLO+4Dc77Ai64EpxveiaSykxbTPgv1EMIGwBgsqhkiG9w0BCRACLzGBoDCB
# nTCBmjCBlwQgcl7yf0jhbmm5Y9hCaIxbygeojGkXBkLI/1ord69gXP0wczBfpF0w
# WzELMAkGA1UEBhMCQkUxGTAXBgNVBAoTEEdsb2JhbFNpZ24gbnYtc2ExMTAvBgNV
# BAMTKEdsb2JhbFNpZ24gVGltZXN0YW1waW5nIENBIC0gU0hBMzg0IC0gRzQCEAEA
# CyAFs5QHYts+NnmUm6kwDQYJKoZIhvcNAQELBQAEggGAnC8eyfedflV/gMWxF3vH
# tLSrMVsiHW5+P2hQfYqc2WskdP2RgHNcEWZtKZ/p8MdmocW9SbuxqBOH7i1L7aUZ
# 2uPOsZLCP/41oZKqIgJfSfWrf+8V9rAaUbfK5gFBcrJP93J56A//zps16sHy2igS
# +CmaaGXPXM7tZOsRcnJ4zeUKS8/d8EDkAyMv7E0AbHdYIGAiTGltiOFRt+jbWbBz
# GirlMGpFlrT606PRO2day+rzMocM2aHNjQNfvoQCf00qF17Kj85Fwr68X8uwdPJD
# 6TcLBxTZ2go7EjrGzLja3L2OE/Y4mLcQJjBC/2wEMfs1OdLpHh5HsD800BSgnMDx
# 3J3/0A58HZwF1Evvv6SS/4VUowx6IQ3NbTP80ozfFa5cjAXX/AcpZnH4FA/mlnFA
# vKsVDsUYzLURB7k03ba8S3X4mbvlFIzHbZ9NQI+qd7HBVELn240nk5B7pR+kE4uJ
# BzP/47Da+/aP367pPEhqEb2yA60ykV9mwr2LKm1LGPmA
# SIG # End signature block
