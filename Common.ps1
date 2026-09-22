<#
.SYNOPSIS
    Authenticates an individual engineer to CyberArk Privilege Cloud Shared Services using the
    OIDC Authorization Code flow with PKCE against a Custom OAuth2 Client web app — no shared
    service account, no browser automation. The resulting token is tied to that engineer's own
    CyberArk/Azure AD identity, preserving per-user accountability in audit logs.

.DESCRIPTION
    Flow:
      1. Generates a PKCE code_verifier/code_challenge pair.
      2. Opens the engineer's REAL system browser to the tenant's /oauth2/authorize/{AppId}
         endpoint. The engineer logs in completely normally — Azure AD redirect, password, MFA —
         nothing here is automated or scripted.
      3. A local loopback listener (http://127.0.0.1:<port>/callback) catches the redirect
         containing the authorization code.
      4. The script exchanges that code for tokens at /oauth2/token/{AppId} (PKCE, no client
         secret needed).
      5. The access token is tested against a Privilege Cloud endpoint, and the ID token is
         decoded (informationally) to show which identity the token is actually tied to.

.PARAMETER IdentityTenantSubdomain
    Subdomain of your Identity tenant, e.g. 'abc1234' for https://abc1234.id.cyberark.cloud

.PARAMETER PrivilegeCloudSubdomain
    Subdomain of your Privilege Cloud tenant, e.g. 'abc1234' for
    https://abc1234.privilegecloud.cyberark.cloud

.PARAMETER ApplicationId
    The Application ID your CyberArk Identity admin set when creating the Custom OAuth2 Client
    web app (this becomes part of the authorize/token URLs).

.PARAMETER ClientId
    The Client ID value shown on that web app's Trust/Tokens tab in Identity Administration.

.PARAMETER RedirectPort
    Local port for the loopback redirect listener. MUST exactly match the redirect URI your
    admin registered on the app (e.g. if they registered http://127.0.0.1:8765/callback, pass 8765).
    Default: 8765

.PARAMETER Scope
    OAuth scope(s) to request. Default: 'openid'. Ask your CyberArk admin if Privilege Cloud
    access requires an additional scope/audience to be added on the app's Advanced tab.

.EXAMPLE
    .\Test-PrivilegeCloud-OidcUserAuth.ps1 -IdentityTenantSubdomain 'abc1234' `
        -PrivilegeCloudSubdomain 'abc1234' -ApplicationId 'privcloud-onboarding-cli' `
        -ClientId '<client-id-from-portal>'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$IdentityTenantSubdomain,

    [Parameter(Mandatory)]
    [string]$PrivilegeCloudSubdomain,

    [Parameter(Mandatory)]
    [string]$ApplicationId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter()]
    [int]$RedirectPort = 8765,

    [Parameter()]
    [string]$Scope = 'openid',

    [Parameter()]
    [int]$TimeoutSeconds = 300
)

try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$identityBaseUrl = "https://$IdentityTenantSubdomain.id.cyberark.cloud"
$privilegeCloudBaseUrl = "https://$PrivilegeCloudSubdomain.privilegecloud.cyberark.cloud/PasswordVault"
$redirectUri = "http://127.0.0.1:$RedirectPort/callback"

# ---------- PKCE helpers ----------
function New-CodeVerifier {
    $bytes = New-Object byte[] 64
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    ConvertTo-Base64Url $bytes
}
function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}
function Get-CodeChallenge {
    param([string]$Verifier)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hash = $sha256.ComputeHash([Text.Encoding]::ASCII.GetBytes($Verifier))
    ConvertTo-Base64Url $hash
}
function ConvertFrom-JwtPayload {
    param([string]$Jwt)
    try {
        $payload = $Jwt.Split('.')[1]
        $payload = $payload.Replace('-', '+').Replace('_', '/')
        switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
        $json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))
        return $json | ConvertFrom-Json
    } catch {
        return $null
    }
}

# ---------- 1. Build the authorize request ----------
$codeVerifier = New-CodeVerifier
$codeChallenge = Get-CodeChallenge -Verifier $codeVerifier
$state = [guid]::NewGuid().ToString('N')

$authorizeUrl = "$identityBaseUrl/oauth2/authorize/$ApplicationId" +
    "?response_type=code" +
    "&client_id=$([uri]::EscapeDataString($ClientId))" +
    "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
    "&scope=$([uri]::EscapeDataString($Scope))" +
    "&code_challenge=$codeChallenge" +
    "&code_challenge_method=S256" +
    "&state=$state"

# ---------- 2. Start local loopback listener BEFORE opening the browser ----------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://127.0.0.1:$RedirectPort/")
try {
    $listener.Start()
}
catch {
    Write-Host "Could not bind to http://127.0.0.1:$RedirectPort/ — is another process using this port?" -ForegroundColor Red
    throw
}

Write-Host "`n[Diagnostic] ClientId as received by the script: |$ClientId|  (length: $($ClientId.Length))" -ForegroundColor DarkGray
Write-Host "[Diagnostic] Full authorize URL:`n$authorizeUrl" -ForegroundColor DarkGray
Write-Host "[Diagnostic] Compare the ClientId value above, char-for-char, against the exact entry" -ForegroundColor DarkGray
Write-Host "             under 'Allowed Clients' in the portal's General Usage tab.`n" -ForegroundColor DarkGray

Write-Host "Opening your browser to log in normally (Azure AD + MFA, exactly as today)..." -ForegroundColor Cyan
Start-Process $authorizeUrl

# ---------- 3. Wait for the redirect with the authorization code ----------
$code = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$contextTask = $listener.GetContextAsync()

while ((Get-Date) -lt $deadline) {
    if ($contextTask.Wait(1000)) {
        $context = $contextTask.Result
        $query = [System.Web.HttpUtility]::ParseQueryString($context.Request.Url.Query)

        $htmlResponse = "<html><body><h3>You can close this window and return to PowerShell.</h3></body></html>"
        $buffer = [Text.Encoding]::UTF8.GetBytes($htmlResponse)
        $context.Response.ContentLength64 = $buffer.Length
        $context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
        $context.Response.OutputStream.Close()

        if ($query['error']) {
            Write-Host "`nAuthorization failed: $($query['error']) - $($query['error_description'])" -ForegroundColor Red
            $listener.Stop()
            return
        }
        if ($query['state'] -ne $state) {
            Write-Host "`nState mismatch — possible tampering or stale request. Aborting." -ForegroundColor Red
            $listener.Stop()
            return
        }
        $code = $query['code']
        break
    }
}
$listener.Stop()

if (-not $code) {
    Write-Host "`nTimed out after $TimeoutSeconds seconds waiting for login to complete." -ForegroundColor Red
    return
}

Write-Host "Authorization code received. Exchanging for tokens..." -ForegroundColor Green

# ---------- 4. Exchange the code for tokens (PKCE, no client secret) ----------
$tokenBody = @{
    grant_type    = 'authorization_code'
    code          = $code
    redirect_uri  = $redirectUri
    client_id     = $ClientId
    code_verifier = $codeVerifier
}

try {
    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "$identityBaseUrl/oauth2/token/$ApplicationId" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body $tokenBody `
        -ErrorAction Stop
}
catch {
    Write-Host "`nToken exchange failed." -ForegroundColor Red
    if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
    throw
}

if (-not $tokenResponse.access_token) {
    Write-Host "Token endpoint returned success but no access_token was present." -ForegroundColor Red
    $tokenResponse | ConvertTo-Json -Depth 5 | Write-Host
    return
}

Write-Host "Access token acquired." -ForegroundColor Green

if ($tokenResponse.id_token) {
    $claims = ConvertFrom-JwtPayload -Jwt $tokenResponse.id_token
    if ($claims) {
        Write-Host "`nToken is tied to identity:" -ForegroundColor Cyan
        Write-Host "  sub   : $($claims.sub)"
        Write-Host "  email : $($claims.email)"
        Write-Host "  name  : $($claims.unique_name)"
    }
}

# ---------- 5. Prove the token works against Privilege Cloud ----------
Write-Host "`nTesting access token against:`n  $privilegeCloudBaseUrl/api/Safes" -ForegroundColor Cyan

try {
    $safesResponse = Invoke-RestMethod -Method Get `
        -Uri "$privilegeCloudBaseUrl/api/Safes?limit=1" `
        -Headers @{ Authorization = "Bearer $($tokenResponse.access_token)" } `
        -ErrorAction Stop

    Write-Host "`nSUCCESS — per-user token authenticated against Privilege Cloud." -ForegroundColor Green
    $safesResponse | ConvertTo-Json -Depth 5 | Write-Host
}
catch {
    $statusCode = $_.Exception.Response.StatusCode.value__
    switch ($statusCode) {
        401 {
            Write-Host "`nFAILED (401) — Privilege Cloud rejected this token." -ForegroundColor Red
            Write-Host "Ask your CyberArk admin whether this OAuth2 Client app needs an additional" -ForegroundColor Yellow
            Write-Host "scope/audience claim (Advanced tab) for Privilege Cloud API access." -ForegroundColor Yellow
        }
        403 {
            Write-Host "`nToken is VALID (401 was not the error) but this user's role has no permission" -ForegroundColor Yellow
            Write-Host "to list Safes (403 Forbidden). Authentication itself is confirmed working." -ForegroundColor Yellow
        }
        default {
            Write-Host "`nUnexpected error (HTTP $statusCode)." -ForegroundColor Red
            if ($_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message -ForegroundColor Red }
        }
    }
}
