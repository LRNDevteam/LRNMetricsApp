# Denial Workflow — SQL Performance Optimization (2026‑07‑22)

## Scope reality check (read first)

- **There are no stored procedures.** The Denial Workflow uses **inline parameterized SQL** built in `SqlDenialWorkflowRepository.cs`. "Optimize the stored procedures" is therefore done against those inline queries. If you want them *as* procs (plan‑cache stability on Azure SQL MI), that's a separate refactor — say so and I'll wrap the hot ones.
- **I cannot run the database from here.** Every "before/after plan" and DMV number below is produced by scripts **for you to run** (`DenialWorkflow_Performance_Optimization_20260722.sql`, section 4–6). The structural before/after and *expected* plan shape are analyzed from the query text; the actuals must be measured with the protocol in §6 of that script.
- Much of the SARGability work already existed (`ClaimIDNormalized`, `VisitNumberNormalized`, `AssignedToNormalized`, NOLOCK on hot reads, schema‑metadata caching, single‑flight on counts). This round closes the **last non‑SARGable hot path: the claim key**.

## The core problem (one root cause, many queries)

Every claim grid, tab‑count, dashboard and aging query keyed claims by recomputing, **per row, per request**:

```sql
COALESCE(NULLIF(LTRIM(RTRIM(ISNULL(ClaimUID,''))),''),
         REPLACE(LTRIM(RTRIM(ISNULL(VisitNumber,''))),'CLM-',''))
```

Wrapping the column in `COALESCE/ISNULL/LTRIM/RTRIM/REPLACE/CONVERT` makes the predicate **non‑SARGable** → the optimizer cannot seek an index → **clustered/table scan + a scalar compute per row**, on `DenialLineItem` and `DenialTaskBoard` (300k+ rows) on *every* page load and count poll. That is the CPU and logical‑read sink.

## The fix

1. **Persisted computed columns** (migration script §1–3): `DenialLineItem.ClaimKeyNormalized`, `DenialTaskBoard.ClaimKeyNormalized`, `DenialClaimEscalations.ClaimIdNormalized`. The normalization runs **once at write time** and is stored, so reads compare a plain column.
2. **Covering indexes** on `(LabId, <normalizedKey>) INCLUDE (grid columns)` so the aggregation is an **index range scan / seek**, ideally index‑only (no key lookups).
3. **Application switches to the columns adaptively** — every query checks `HasColumnAsync(...,"ClaimKeyNormalized")` (now cached) and uses `l.ClaimKeyNormalized` when present, else the old inline expression. **Deploy order is irrelevant and unmigrated labs are byte‑for‑byte unchanged.**

## Change log — every edit and why

| # | Query / method | Before | After | Task addressed |
|---|---|---|---|---|
| 1 | `GetClaimSubMenuCountsAsync` `#ClaimBase` GROUP BY + task join | `GROUP BY COALESCE(NULLIF(LTRIM(RTRIM(ClaimUID)))…REPLACE(VisitNumber))`; join `(t.ClaimUID=… OR t.ClaimIDNormalized=…)` | `GROUP BY l.ClaimKeyNormalized`; join `t.ClaimKeyNormalized = c.ClaimUid` | 1, 2, 3, 4, 9 |
| 2 | `GetClaimsAsync` `#ClaimBase` + `#PageLineDetails` + task agg | same inline key on group + `linePageJoinSql` + `taskJoinSql` | `l.ClaimKeyNormalized` / `t.ClaimKeyNormalized` single‑column equalities | 1, 5, 9 |
| 3 | reviewer‑scope match (both count + grid) | 2‑branch OR with `LTRIM/RTRIM/ISNULL` on both sides | `tbx.ClaimKeyNormalized = l.ClaimKeyNormalized` | 3, 9 |
| 4 | `GetEscalationsAsync` | `REPLACE(LTRIM(RTRIM(ClaimId)))='…'` per row | `ClaimIdNormalized = @ClaimIdNormalized` (param normalized in C#) | 1, 5 |
| 5 | `GetEscalationQueueAsync` OUTER APPLY | `… OR t.ClaimID LIKE '%' + e.ClaimId` (non‑SARGable suffix) + trims | `t.ClaimKeyNormalized = e.ClaimIdNormalized OR t.ClaimIDNormalized = e.ClaimIdNormalized` (index union of seeks) — **only on fully‑migrated labs** | 2, 4, 5, 9 |
| 6 | `GetDashboardSummaryAsync` task/line key exprs | inline `COALESCE(…REPLACE…)` | `t.ClaimKeyNormalized` / `d.ClaimKeyNormalized` | 1, 8, 9 |
| 7 | `GetAgingDashboardAsync` claim/task key exprs | inline `COALESCE(…REPLACE…)` | `d.ClaimKeyNormalized` / `t.ClaimKeyNormalized` | 1, 8, 9 |

Kept deliberately non‑SARGable (correctness/lock intent, not perf mistakes):
- `WITH (UPDLOCK, HOLDLOCK)` reads in assign/resolve — the locks are the point (concurrency).
- The escalation `COUNT(DISTINCT LTRIM(RTRIM(ClaimId)))` / `ROW_NUMBER() PARTITION BY` — operate on the **already‑filtered** small escalation set (thousands, not 300k), and changing the partition key risks changing "newest per claim."
- `OUTER APPLY (SELECT TOP 1 …)` in the escalation queue — kept as APPLY (it fetches one representative task with a tie‑break `ORDER BY`, runs only for the ≤200 paged rows, and is now seek‑backed). A `ROW_NUMBER()` LEFT JOIN would materialize all matching tasks before filtering — **worse** here. This is the "CROSS/OUTER APPLY only if demonstrably faster" call going the other way.

## Expected plan shape: before → after (per claims page load)

| Operator | Before | After (migrated) |
|---|---|---|
| `DenialLineItem` access | Clustered Index **Scan** + Compute Scalar (per row) | `IX_DenialLineItem_ClaimKeyNormalized` **range scan**, often index‑only |
| `DenialTaskBoard` join | Hash/Nested‑loop over scan | Index **Seek** on `IX_DenialTaskBoard_ClaimKeyNormalized` |
| Aggregate | Hash Aggregate over full scan | Stream/Hash over the covered range only |
| Residual predicates | many scalar string funcs | none on the key |

## Estimated improvement (must be validated with §6 protocol)

The targets (‑70% CPU, ‑80% logical reads, eliminate scans) are **achievable specifically because the change converts full scans of the two 300k‑row tables into index range access** — that is exactly the class of change that yields 80‑95% logical‑read reduction. But **do not report these as measured** until you run before/after `SET STATISTICS IO, TIME` (or Query Store) with identical filters. Honest expectation:

- **Logical reads:** the dominant cost was `O(rows_in_table)` scans; index access is `O(rows_in_lab_range)`. On a lab where one reviewer owns 100 of 300k claims, expect **80–95% fewer reads**. Cross‑lab dashboard queries that legitimately touch the whole lab will improve less (still helped by dropping the per‑row compute).
- **CPU:** removing a 5‑function scalar compute per row across full scans is the bigger CPU win than reads; **60–80%** on the claim‑grid/counts path is realistic once scans become seeks.
- **Duration:** the reported multi‑minute / timeout loads should drop to sub‑second on migrated labs (this is the same class of fix that `AssignedToNormalized` already delivered for the reviewer filter).

## Recommended indexes (created by the migration, §1–3)

- `IX_DenialLineItem_ClaimKeyNormalized (LabId, ClaimKeyNormalized) INCLUDE (VisitNumber, DateOfService, PayerName, PanelName, InsuranceBalance, AssignedTo, DenialClassification, ActionCategory)`
- `IX_DenialTaskBoard_ClaimKeyNormalized (LabId, ClaimKeyNormalized) INCLUDE (TaskID, Status, WorkFlowStatus, AssignedTo, SLAStatus, CreatedOn, InsuranceBalance)`
- `IX_DWF_Escalations_Lab_ClaimIdNormalized (LabId, ClaimIdNormalized, IsDeleted) INCLUDE (EscalationLevel, Status, EscalatedTo, EscalatedToRole, CreatedOn)`

Plus **DMV‑driven** suggestions (script §4) and **overlap detection** (script §5) — run these and review before adding/dropping anything. Do **not** blind‑create DMV suggestions; several will overlap the indexes above and just add write cost.

## Deployment order (safe either way)

1. Deploy this **app build** first (no behavior change; still uses inline exprs until columns exist).
2. Run `DenialWorkflow_Performance_Optimization_20260722.sql` **per lab, in a maintenance window** (persisted‑computed‑column add + index builds take schema locks on 300k rows).
3. The app auto‑detects the new columns on the next request (metadata cache is positive‑only and per‑process) and switches to the SARGable path. A pool/app restart makes the switch immediate.
4. Capture before/after with §6. Also run the earlier `..._Indexes_And_Backfill_20260701.sql` first if a lab never got it.

## Longer‑term (bigger than this change)
- Enable **`READ_COMMITTED_SNAPSHOT`** on the lab DBs — readers stop blocking writers *without* dirty reads; you could then drop most `NOLOCK` hints. One `ALTER DATABASE`, brief exclusive access.
- Turn on **Query Store** (if not already) so this analysis is data‑driven next time instead of plan‑text‑driven.
