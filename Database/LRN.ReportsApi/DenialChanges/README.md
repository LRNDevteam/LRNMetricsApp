# Denial changes — SQL run order

Everything here runs against **each lab database** (`CoveLRN`, `NWL_LRN`, `Certus_LRN`, …), never
against `LRNMaster`. All three scripts are idempotent and safe to re-run.

Run them in numeric order, in a maintenance window:

| # | Script | What it does |
| --- | --- | --- |
| 01 | `01_Denial_Spec_R31_Migration.sql` | Architecture spec Rev 3.1: creates `dbo.DenialClosureLog`, backfills `ClaimUID` / `UniqueTrackId`, normalizes legacy status spellings, registers the three system statuses, seeds the per-lab TaskID sequence, and migrates the `dbo.DenialVerification` backlog into `dbo.DenialVerificationTask`. |
| 02 | `02_Denial_TaskBoard_NewColumns.sql` | Forward-adds the task board and line item columns the worker writes (`ICDCodes`, `CoverageStatus`, `ClaimUID`, `WorkFlowStatus`, `Units`, `Modifier`, …). |
| 03 | `03_Denial_Performance_Indexes.sql` | Supporting indexes for the denial copy path. **Review before applying** — each index costs write throughput on the bulk copies. Sizing queries are at the bottom of the file. |

Script 01 leaves `dbo.DenialVerification` in place after migrating it. Verify the row counts with the
queries at the end of that file, then drop it manually.

## Reviewer closure behaviour

When a reviewer sets **New Line Status = Closed** in the Denial Workflow status modal:

1. `Status` becomes `Closed` on the affected task board rows and their line items.
2. `WorkFlowStatus` becomes the reviewer's **Actual Action / Outcome** (`Claim Paid`,
   `Appeal Submitted`, …) rather than the flat literal `Closed Claim`. Every open/closed filter in
   the API tests `Status`, so this changes what the closed-claims list and history *show* without
   changing what any query *counts*.
3. Once no open line remains on the claim, the claim is merged into `dbo.DenialClosedClaims`
   (claim-grain, one row per claim) carrying that same outcome as its workflow status.
4. On its next pass the worker archives each closed task to `dbo.DenialClosureLog`
   (denial-event grain, append-only) with `ClosureReason = 'Closed by Reviewer'`, preserving the
   outcome in `FinalWorkFlowStatus`, and removes it from the board.

`dbo.DenialClosedClaims` and `dbo.DenialClosureLog` are **different tables answering different
questions** — which claim a reviewer closed, versus what happened to each individual denial. See
`docs/denial-management/Denial_Database_Worker_Requirements.md` §12.1.
