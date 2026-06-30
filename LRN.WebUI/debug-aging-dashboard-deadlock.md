# [OPEN] Aging Dashboard Deadlock

## Session
- session_id: `aging-dashboard-deadlock`
- started_at: `2026-06-30`
- symptom: `GET /api/denialworkflow/aging-dashboard` intermittently fails with SQL deadlock and returns DenialWorkflowIssueNotifier error output.

## Observed Runtime Evidence
- `SqlException`: `Transaction ... was deadlocked on lock | communication buffer resources`
- failing repository method: `EnsureDenialTaskBoardNormalizedClaimIdAsync(...)`
- stack references:
  - `SqlDenialWorkflowRepository.cs:255`
  - `SqlDenialWorkflowRepository.cs:636`
  - `SqlDenialWorkflowRepository.cs:972`
  - `DenialWorkflowController.cs:124`

## Initial Hypotheses
1. `EnsureDenialTaskBoardNormalizedClaimIdAsync(...)` performs a write/update during a read-path request and competes with another concurrent request, creating a deadlock.
2. The normalization routine runs on every aging-dashboard request instead of once or conditionally, multiplying lock contention under parallel traffic.
3. The normalization SQL acquires locks in an order that conflicts with other workflow queries or background updates touching the same tables.
4. Missing retry handling for SQL deadlock error `1205` allows a transient concurrency issue to surface as a user-visible 500 instead of auto-retrying.
5. A long-running query in `GetAgingDashboardAsync(...)` holds locks while normalization runs, making communication-buffer deadlocks more likely under high result volume.

## Next Steps
- Inspect the repository implementation around the failing lines.
- Add minimal instrumentation around normalization and aging dashboard query boundaries.
- Reproduce and compare pre-fix vs post-fix evidence before applying any logic fix.
