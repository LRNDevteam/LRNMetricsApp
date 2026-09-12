# Antiforgery coverage in LabMetricsDashboard

Recorded as part of P0-B (HIPAA finding F2), which asked whether
`AutoValidateAntiforgeryTokenAttribute` should be registered globally.

## Recommendation

Yes, but not in Phase 0, and not without fixing the callers in the same change.

## Where things stand

| | Count |
|---|---|
| Mutating MVC actions (POST / PUT / DELETE / PATCH) | 67 |
| Validating the antiforgery token | 42 |
| Not validating | 25 |

AdminController is fully covered as of P0-B. All 25 remaining gaps are elsewhere.

## Why the global filter is not flipped on here

`AutoValidateAntiforgeryTokenAttribute` applies to every non-GET action at once. Registering it
today would make all 25 endpoints below start returning 400 the moment a user touched the screen
that calls them, because their JavaScript does not send the token.

That is not a reason to leave it off permanently. It is a reason to treat it as its own
workstream: turn the filter on and patch the 25 callers in one commit, so the change is atomic and
reviewable. Doing it inside P0-B would mean auditing six unrelated controllers and their views
under a change whose stated scope is AdminController.

`Program.cs` already sets `options.HeaderName = "RequestVerificationToken"`, so each caller needs
one header, not a redesign. The pattern is in `Views/Admin/_AdminScripts.cshtml`.

## The 25 endpoints

Every one needs its caller fixed, or a justified `[IgnoreAntiforgeryToken]`.

| Controller | Action | Line | Note |
|---|---|---|---|
| CodingSetupController | Create | 131 | |
| CodingSetupController | Edit | 236 | |
| CodingSetupController | Deactivate | 256 | |
| CodingSetupController | Clone | 277 | |
| CodingSetupController | Import | 401 | file upload |
| DashboardController | FirstPaintClient | 2449 | telemetry beacon, see below |
| HelpBotController | Ask | 18 | |
| MasterValuesController | SavePayerRule | 134 | |
| MasterValuesController | PayerRuleStatus | 150 | |
| MasterValuesController | ApproveMapping | 221 | |
| MasterValuesController | ManualMapping | 229 | |
| MasterValuesController | RejectMapping | 237 | |
| MasterValuesController | UnmapMapping | 245 | |
| MasterValuesController | TriggerPayerService | 283 | |
| MasterValuesController | SaveInsurancePayer | 351 | |
| MasterValuesController | SavePolicyPayer | 366 | |
| MasterValuesController | InsuranceStatus | 383 | |
| MasterValuesController | PolicyStatus | 393 | |
| MasterValuesController | ImportInsurance | 403 | file upload |
| MasterValuesController | ResolveInsuranceConflicts | 412 | |
| MasterValuesController | ImportPolicy | 419 | file upload |
| MasterValuesController | ApproveRequests | 471 | |
| MasterValuesController | RejectRequests | 479 | |
| UsageController | Heartbeat | 55 | beacon, see below |
| UserReportsController | Download | 283 | POST that only reads |

`MasterProcessorRerun` on MasterValuesController already carries the attribute and is not listed.

## The two that may genuinely need an exemption

**`UsageController.Heartbeat`** and **`DashboardController.FirstPaintClient`** are fire-and-forget
telemetry. If either is sent with `navigator.sendBeacon`, it cannot carry a custom header at all,
and `[IgnoreAntiforgeryToken]` is the honest answer. Check how each is called before deciding: if
it is a normal `fetch`, add the header instead. Neither writes clinical data, so the exposure from
exempting them is a forged page-view record, not a forged change.

**`UserReportsController.Download`** is a POST that performs a read. Cross-site forgery of a read
achieves nothing an attacker could use, because the response is not readable cross-origin. It
should still get the token rather than an exemption, since it is trivially achievable and the
reasoning above depends on the action never gaining a side effect.

## Regression guard

`tests/LabMetricsDashboard.Tests/AdminControllerAuthorizationTests.cs` reflects over
AdminController and fails when any mutating action lacks the attribute. Widening that test to
every controller is the natural companion to turning the global filter on: it turns "somebody
remembered" into "the build says so".
