Issue: OIDC Authorization Code + PKCE flow against a Custom OAuth2 Client app fails at /oauth2/authorize/{appId} with error=invalid_client&error_description=invalid client creds, before ever reaching the token exchange step.

App config: Type = Custom OAuth2 Client, Application ID = account_onboarding_cli, Client ID Type tested = both List and Anything, Auth Methods = Auth Code + Implicit enabled, Token Type tested = both JwtRS256 and opaque, Redirect URI = http://127.0.0.1:8765/callback (confirmed correct), Permissions = tested user (mohan.c@...) has explicit Run granted.

Request tested: GET https://abn4187.id.cyberark.cloud/oauth2/authorize/account_onboarding_cli?response_type=code&client_id=account_onboarding_cli&redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback&scope=openid&code_challenge=...&code_challenge_method=S256&state=...

Observed: Local CyberArk Cloud Directory user completes username/password/email OTP successfully, but the final redirect back from CyberArk already carries error=invalid_client — meaning the failure appears to occur at the authorize step for this specific client/app, not during credential validation itself.

Question for CyberArk Support: What does invalid client creds specifically mean at the /oauth2/authorize endpoint (as opposed to /oauth2/token) for this app type, and what server-side condition triggers it beyond what's covered in the Custom OAuth2 Client documentation?
