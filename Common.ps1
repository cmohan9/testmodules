Here's a ready-to-submit support case.

---

**Short Description:**
Custom OAuth2 Client app (Authorization Code + PKCE) returns `invalid_client - invalid client creds` at `/oauth2/authorize` for Non-Prod tenant

**Description:**

We are configuring a Custom OAuth2 Client web app in Identity Administration to support an Authorization Code + PKCE login flow for a PowerShell-based automation tool, so that individual engineers can authenticate with their own CyberArk identity (rather than a shared service account) and obtain a token to call Privilege Cloud REST APIs.

The `/oauth2/authorize` request consistently fails with `error=invalid_client&error_description=invalid client creds`, returned in the redirect to our registered callback URL — before the flow ever reaches the token exchange step.

**Tenant:** `abn4187.id.cyberark.cloud` (Non-Prod)
**Privilege Cloud tenant:** `olympustest.privilegecloud.cyberark.cloud`
**App type:** Custom OAuth2 Client
**Application ID:** `account_onboarding_cli`
**Test user:** Local CyberArk Cloud Directory user (`mohan.c@cyberark.cloud.25603`), authenticated via username + password + email OTP

**Request being sent:**
```
GET https://abn4187.id.cyberark.cloud/oauth2/authorize/account_onboarding_cli
    ?response_type=code
    &client_id=account_onboarding_cli
    &redirect_uri=http%3A%2F%2F127.0.0.1%3A8765%2Fcallback
    &scope=openid
    &code_challenge=<generated per attempt>
    &code_challenge_method=S256
    &state=<generated per attempt>
```

**Observed behavior:**
The user completes the full login (password + email OTP) successfully, but the final redirect back to `http://127.0.0.1:8765/callback` already contains `error=invalid_client&error_description=invalid%20client%20creds`. This occurs regardless of the following configuration changes, each tested individually and saved:

- Client ID Type: tested both `List` (with the client_id value added under Allowed Clients) and `Anything`
- Token Type: tested both `JwtRS256` and `opaque`
- Auth Methods (Tokens tab): `Auth Code` and `Implicit` both enabled
- Redirect URI: confirmed as `http://127.0.0.1:8765/callback` under Allowed Redirects, matching the `redirect_uri` sent in the request
- Permissions tab: test user `mohan.c@cyberark.cloud.25603` has **Run** explicitly granted (not inherited)
- App Status: `Deployed`

**Question for CyberArk Support:**
What server-side condition specifically produces `invalid_client / invalid client creds` at the `/oauth2/authorize` endpoint (as distinct from `/oauth2/token`) for a Custom OAuth2 Client app, given the above configuration matches CyberArk's own documented setup steps? Is there an additional required field or setting (e.g., under Advanced, Scope, or Issuer/Audience) not covered in the public "Custom OAuth2 Client" documentation page that governs this validation?

---

**Attachments to include:**

1. Screenshot of the **Settings** tab (Application ID, Application Owner)
2. Screenshot of the **General Usage** tab, scrolled to show the *entire* page including Client ID Type, Issuer, Allowed Redirects, and any Save/Update button state at the bottom
3. Screenshot of the **Tokens** tab (Token Type, Auth Methods)
4. Screenshot of the **Scope** tab
5. Screenshot of the **Permissions** tab showing `mohan.c`'s Run permission
6. Screenshot of the final browser address bar showing the `error=invalid_client` redirect
7. If your CyberArk admin can pull it: the relevant entries from the tenant's **Activity/System Log** around the timestamp of a failed attempt — this is the one thing that will likely contain the real, non-generic server-side reason, and support will almost certainly ask for it anyway
8. The exact request/response if you have browser DevTools Network tab output saved (Preserve Log) from a fresh attempt — include the full authorize URL and any response body

Also worth including your CyberArk Identity Administration **portal version/build** if visible (sometimes shown in account/tenant settings) — since this may end up being version-specific behavior.
