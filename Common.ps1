Here's a case-ready summary you can paste into a CyberArk support ticket.

CyberArk Support Case — Summary
Subject: Custom OAuth2 Client (auth-code + PKCE, per-user) token rejected by Privilege Cloud REST API with CAJWT001E - Invalid JWT token
Environment

Identity tenant: abn4187.id.cyberark.cloud
Privilege Cloud tenant: olympustest.privilegecloud.cyberark.cloud
App: Custom OAuth2 Client, Web – Other Type, Application ID account_onboarding_cli, Status: Deployed
Flow: OIDC Authorization Code + PKCE, public client (no secret), loopback redirect http://127.0.0.1:8765/callback
Target API: GET https://olympustest.privilegecloud.cyberark.cloud/PasswordVault/api/Safes?limit=1

Goal
Obtain a per-user access token (tied to the engineer's own CyberArk/Azure AD identity, not a shared service account) that the Privilege Cloud REST API will accept — to preserve per-user accountability in audit logs.
What works

User authentication succeeds (Azure AD + MFA), authorization code returned, token exchange succeeds.
Access token is issued on every run.

The problem
Despite the access token containing the correct claims, the Privilege Cloud API returns:
UnknownHTTP 401
{"ErrorCode":"CAJWT001E","ErrorMessage":"Invalid JWT token."}

Troubleshooting performed (each item verified via decoded token)



Step
Change made
Result




1
Requested scope=openid
invalid_client


2
Set Authorized scope pcloud_api with filter https://olympustest.privilegecloud.cyberark.cloud/.*; requested -Scope 'pcloud_api'
Token issued; scope claim = pcloud_api ✅


3
aud claim was the app GUID 6349d9d3-3733-4ca4-98ce-630bc61fe26e → API 401
—


4
Advanced tab: setClaim('aud','https://olympustest.privilegecloud.cyberark.cloud')
aud corrected ✅ but still 401


5
iss claim was https://abn4187.id.cyberark.cloud/account_onboarding_cli/ (app-scoped)
—


6
Advanced tab: setClaim('iss','https://abn4187.id.cyberark.cloud')
iss corrected ✅ but still CAJWT001E



Current decoded access-token claims (all appear correct)
Unknownaud       : https://olympustest.privilegecloud.cyberark.cloud
scope     : pcloud_api
iss       : https://abn4187.id.cyberark.cloud
client_id : (empty)

→ Still HTTP 401 / CAJWT001E - Invalid JWT token.
Assessment / suspected root cause
With iss, aud, and scope all matching what the API expects and the token still rejected, the remaining causes appear to be cryptographic signature / JWKS trust and/or the empty client_id claim — i.e. the API gateway does not trust a token signed by the Custom OAuth2 Client app even when its claims are rewritten to look platform-level. Overriding iss via setClaim does not re-sign the token, so the gateway's JWKS lookup against the platform issuer cannot validate the signature.
Specific questions for CyberArk

Is the Custom OAuth2 Client authorization-code flow a supported token source for the Privilege Cloud REST API (/PasswordVault/api/Safes)? Our evidence suggests it is not.
If not, is there any supported path to obtain a per-user token accepted by the Privilege Cloud API, or is /oauth2/platformtoken (client_credentials with a service user) the only accepted source?
What are the exact iss, aud, signing key, and required claims the Privilege Cloud gateway validates for CAJWT001E?
Is the API path /PasswordVault/api/Safes correct for this ISPSS tenant, or should the /PasswordVault prefix be omitted?

Attachments to include

Screenshot: run output showing corrected claims + CAJWT001E
Screenshot: Scope tab (pcloud_api + filter)
Screenshot: Advanced tab JWT script (setClaim for aud and iss)


Want me to drop this into a downloadable Word or Markdown file so you can attach it directly to the case?
