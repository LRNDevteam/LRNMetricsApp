# External API access — internal onboarding

Internal companion to [ExternalApiAccess_Guide.md](ExternalApiAccess_Guide.md) (the document
shared with the external party). This one is **not** for external distribution.

## What changed and why

`LRN.ReportsApi` could only *validate* JWTs; it could not *issue* them. Tokens were minted by
`LabMetricsDashboard`'s `WorkflowJwtIssuer` when a signed-in user opened a workflow, which needs
a browser session. An external system has no session, so there was no way for one to authenticate
at all.

Added `POST /api/auth/token` — a client-credentials grant that issues a token signed with the
**same** key, issuer and audience, so `WorkflowJwt.TryValidate` accepts it with no special case
and the existing `PayerMasterRoles` checks apply unchanged.

| File | Role |
|---|---|
| [LRN.ReportsApi/Controllers/AuthController.cs](../LRN.ReportsApi/Controllers/AuthController.cs) | The token endpoint |
| [LRN.ReportsApi/Security/ExternalApiClients.cs](../LRN.ReportsApi/Security/ExternalApiClients.cs) | Client config + PBKDF2 secret hashing |
| [tests/LRN.ReportsApi.Tests/ExternalApiTokenTests.cs](../tests/LRN.ReportsApi.Tests/ExternalApiTokenTests.cs) | 18 tests, incl. a token round-trip through `WorkflowJwt` |

## Provisioning a client

**1. Generate a secret** (32+ random chars) and hash it. The API binary does this using the same
hasher it verifies with, so the value cannot drift:

```
LRN.ReportsApi.exe --hash-secret "<the-secret>"
```

Output looks like `pbkdf2$210000$wji0lzlZ…==$us2nQM8y…=`.

**2. Add the client** to `appsettings.Local.json` on the API server (gitignored — never the
tracked `appsettings.json`):

```json
"ExternalApiClients": {
  "TokenMinutes": 60,
  "MaxFailedAttempts": 10,
  "LockoutMinutes": 15,
  "Clients": [
    {
      "ClientId": "acme-analytics",
      "DisplayName": "Acme Analytics",
      "SecretHash": "pbkdf2$210000$…$…",
      "Roles": [ "ETL" ],
      "Labs": [ { "labId": 4, "labName": "Cove" } ],
      "Enabled": true
    }
  ]
}
```

**3. Restart the API**, then send the external party the client id, the plaintext secret (over a
secure channel — it is not recoverable afterwards) and the shareable guide.

To revoke: set `"Enabled": false` or delete the entry, then restart. Tokens already issued stay
valid until they expire, so keep `TokenMinutes` short.

## Choosing roles

`PayerMasterRoles` decides what a token can do. **`ETL` is the read-only role** and the correct
default for external clients:

| Role | View policy master | View lab master | Write either |
|---|---|---|---|
| `ETL` | yes | yes | **no** |
| `Reports Analyst` | yes | yes | yes (needs approval) |
| `Reports Manager` | no | yes | yes |
| `Payer Policy Admin` | yes | no | yes (policy) |
| `Admin` | yes | yes | yes, plus approve |

Never give an external client `Admin`. Note that `/api/analytics/*` has **no** role checks — any
valid token reads it — so role choice only constrains the master-value endpoints.

`Labs` becomes `lab_id` / `lab_name` claims. Today the CPT lookup and master-value endpoints do
**not** filter by those claims; a token scoped to one lab can still read every lab's rows via the
`labId` query parameter. If per-client lab isolation is required, that enforcement has to be added
to the repositories first — do not promise it on the strength of the claim alone.

## Security issues to resolve

**1. Production credentials are committed to git.**
[LRN.ReportsApi/appsettings.json](../LRN.ReportsApi/appsettings.json) is tracked and contains live
SQL passwords (`sqladmin`, `sa`), the `DenialWorkflowAuth:JwtSigningKey`, the `ImportApiKey` and a
Teams webhook URL — despite the comment at the top of `Program.cs` stating that tracked
`appsettings*.json` must never contain credentials.

This matters directly for external access: that signing key is what signs external tokens. Anyone
with repository access — including past clones and forks — can mint a valid token for **any** role,
including `Admin`, without touching the token endpoint. Opening the API to third parties raises the
value of that key considerably.

Recommended: move these to `appsettings.Local.json` or environment variables, rotate the SQL
passwords, the signing key, the import key and the Teams webhook, and purge them from git history.
Rotating the signing key invalidates every live session and token, so schedule it.

**2. No transport enforcement in the app.** HSTS is set outside Development, but the API does not
redirect HTTP→HTTPS itself. Terminate TLS at the reverse proxy and block plain HTTP there — the
client secret is sent in a request body.

**3. Rate limiting is per-process and in-memory.** The lockout in `AuthController` uses
`IMemoryCache`. Behind multiple instances or an app-pool recycle, the counter resets. Fine as
defence-in-depth; not a substitute for a WAF rule if the endpoint is internet-facing.

**4. The token endpoint is unauthenticated by design.** In `Program.cs` the auth middleware only
challenges paths matching `isWorkflowApi`; `/api/auth` is not among them, which is what lets a
caller obtain a token. Anything else added outside that list is also public — check the list when
adding controllers.

## Verified

* `dotnet test` — 88 pass in `LRN.ReportsApi.Tests` (18 new).
* Live run on `127.0.0.1:5399`: valid credentials → `200` + token; wrong secret → `401`;
  `/api/analytics/cpt-lookup` with no token → `401`; with the issued token → reached the
  repository (failed only on the deliberately fake DB connection), confirming the token passes
  the real auth gate.
* `--hash-secret` output verified against `ApiSecretHasher.Verify`.

> Side effect of that live test: two unhandled-exception notifications were posted to the
> configured Teams webhook (the DB was intentionally unreachable). Nothing was written to any
> database.
