[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$IdentityTenantSubdomain,
    [Parameter(Mandatory)][string]$PrivilegeCloudSubdomain,
    [Parameter(Mandatory)][string]$ApplicationId,
    [Parameter(Mandatory)][string]$ClientId,
    [int]$RedirectPort = 8765,
    [string]$Scope = 'openid',
    [int]$TimeoutSeconds = 300
)

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$identityBase = "https://$IdentityTenantSubdomain.id.cyberark.cloud"
$privilegeBase = "https://$PrivilegeCloudSubdomain.privilegecloud.cyberark.cloud/PasswordVault"
$redirectUri = "http://127.0.0.1:$RedirectPort/callback"

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+','-').Replace('/','_')
}

function New-CodeVerifier {
    $bytes = [byte[]]::new(64)
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    ConvertTo-Base64Url $bytes
}

function Get-CodeChallenge {
    param([string]$Verifier)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { ConvertTo-Base64Url $sha.ComputeHash([Text.Encoding]::ASCII.GetBytes($Verifier)) }
    finally { $sha.Dispose() }
}

function Get-JwtPayload {
    param([string]$Jwt)
    try {
        $payload = $Jwt.Split('.')[1].Replace('-','+').Replace('_','/')
        switch ($payload.Length % 4) {
            2 { $payload += '==' }
            3 { $payload += '=' }
        }
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json
    } catch {
        $null
    }
}

$verifier = New-CodeVerifier
$challenge = Get-CodeChallenge $verifier
$state = [guid]::NewGuid().ToString('N')

$authorizeUrl = "$identityBase/oauth2/authorize/$ApplicationId" +
    "?response_type=code&client_id=$([uri]::EscapeDataString($ClientId))" +
    "&redirect_uri=$([uri]::EscapeDataString($redirectUri))" +
    "&scope=$([uri]::EscapeDataString($Scope))" +
    "&code_challenge=$challenge&code_challenge_method=S256&state=$state"

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://127.0.0.1:$RedirectPort/")

try {
    $listener.Start()
    Start-Process $authorizeUrl

    $task = $listener.GetContextAsync()
    if (-not $task.Wait($TimeoutSeconds * 1000)) {
        throw "Timed out waiting for authentication."
    }

    $context = $task.Result
    $query = $context.Request.QueryString
    $html = [Text.Encoding]::UTF8.GetBytes('<html><body>You may close this window.</body></html>')
    $context.Response.ContentLength64 = $html.Length
    $context.Response.OutputStream.Write($html, 0, $html.Length)
    $context.Response.Close()

    if ($query['error']) {
        throw "Authorization failed: $($query['error']) $($query['error_description'])"
    }

    if ($query['state'] -ne $state) {
        throw 'State mismatch.'
    }

    $code = $query['code']
}
catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    return
}
finally {
    if ($listener.IsListening) { $listener.Stop() }
}

try {
    $token = Invoke-RestMethod -Method Post `
        -Uri "$identityBase/oauth2/token/$ApplicationId" `
        -ContentType 'application/x-www-form-urlencoded' `
        -Body @{
            grant_type    = 'authorization_code'
            code          = $code
            redirect_uri  = $redirectUri
            client_id     = $ClientId
            code_verifier = $verifier
        } `
        -ErrorAction Stop
}
catch {
    $message = if ($_.ErrorDetails.Message) { $_.ErrorDetails.Message } else { $_.Exception.Message }
    Write-Host "Token exchange failed: $message" -ForegroundColor Red
    return
}

if (-not $token.access_token) {
    Write-Host 'No access token was returned.' -ForegroundColor Red
    return
}

Write-Host 'Access token acquired.' -ForegroundColor Green

if ($token.id_token) {
    $claims = Get-JwtPayload $token.id_token
    if ($claims) {
        Write-Host "Identity: $($claims.email) [$($claims.sub)]" -ForegroundColor Cyan
    }
}

try {
    Invoke-RestMethod -Method Get `
        -Uri "$privilegeBase/api/Safes?limit=1" `
        -Headers @{ Authorization = "Bearer $($token.access_token)" } `
        -ErrorAction Stop | Out-Null

    Write-Host 'SUCCESS: Token authenticated against Privilege Cloud.' -ForegroundColor Green
}
catch {
    $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }

    switch ($status) {
        401 { Write-Host 'FAILED 401: Token rejected by Privilege Cloud.' -ForegroundColor Red }
        403 { Write-Host 'AUTHENTICATED: User lacks Safe-list permission.' -ForegroundColor Yellow }
        default { Write-Host "FAILED HTTP $status`: $($_.Exception.Message)" -ForegroundColor Red }
    }
}




