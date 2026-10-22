# AR Workbench — Open Items and Build Phases

What is missing from the LRN Denial Workflow against the client's AR Workbench requirement
(`AR_Workbench_Build_Reference.pdf`, `AR_Workbench_Developer_Documentation.pdf`), and the order to
build it in. Sequencing only — no dates or effort.

Of the requirement's 28 areas, 11 are already delivered and need nothing. The 17 below are open:
7 with no equivalent today (**Gap**) and 10 that exist but differ in a rule, a scope or a bulk path
(**Partial**).

## Open items

| # | Item | Type | What has to be built |
|---|---|---|---|
| 1 | AR and recovery financials | Gap | Recovered, remaining AR, initial AR, expected against actual payment, variance, underpayment, appeal flag — and the point-in-time history they are derived from |
| 2 | AR queue classification | Gap | Twelve financial-state queues with collectible and non-collectible sub-queues, priority ordered, with badges and counts |
| 3 | Derived lifecycle rules | Gap | Financially closed, work complete, open insurance AR, days since last touch, re-follow-up due — one server-side implementation the screens read |
| 4 | Assignment management | Gap | 45-day untouched view, named assignment batches with a running log, reassign pool that includes completed claims still carrying a balance |
| 5 | CIP client-escalation lifecycle | Gap | Five states, round counter, client reply with up to three attachments, bulk approve or send back across mixed states, CSV response template |
| 6 | Access scoping below lab level | Gap | Viewer scoped to client, clinic or provider; cascading picker built from real claim values; scope badge; scoping applied to every claim-reading query |
| 7 | Table conveniences | Gap | Saved views on every queue, column show and hide, per-table CSV of exactly what is on screen |
| 8 | Roles | Partial | Team Lead and QA Reviewer as separate roles in the permission matrix and the queue definitions |
| 9 | QA verification | Partial | Bulk approve with row eligibility, self-approval guard, role guard on the decision endpoint |
| 10 | Escalation queue | Partial | Agent-initiated reassignment request; bulk resolve with one shared note across a mixed selection |
| 11 | Automatic adjustment | Partial | Non-collectible code master list, one-step and batch write-off from the work queue, system-attributed audit entry |
| 12 | Follow-up capture | Partial | The client's comments vocabulary, fix or resolution scoped by claim status, auto-submit to QA on save, next follow-up defaulted |
| 13 | Master File Maintenance | Partial | Five more lists, denial-code-to-category map, fix-by-status config, CSV download and upload on each |
| 14 | Claim workspace | Partial | Tabbed layout, four-stage stepper, named stage path per denial category |
| 15 | Analytics | Partial | Recovery by payer, panel and agent; agent workload; panel type summary |
| 16 | Data Processing screen | Partial | One operator screen: refresh date, source period, record count, ranked denial insights with drill-through |
| 17 | Client CIP view | Partial | Read-only CIP status for scoped client, clinic or provider viewers |

## Phases

Ordered by dependency: each phase needs the one before it, except phase 6, which is independent and
can run on a second track or be dropped without blocking anything.

| Phase | Items | What it delivers | Done when |
|---|---|---|---|
| 1. Data foundation | 1, 3, and the non-collectible code list from 11 | The AR and recovery fields, the history they are derived from, and the one server-side implementation of the lifecycle rules | Recovered and remaining AR populate for a pilot lab, and the derived rules match a hand calculation on a sample of claims |
| 2. Queues and assignment | 2, 4 | The twelve-queue classification with badges and counts, the 45-day untouched view, and named assignment batches | Every claim lands in exactly one queue, counts match the badges, and a batch can be created, logged and reassigned |
| 3. Master data and follow-up capture | 13, 12 | The five master lists with their map and fix-by-status config, then the follow-up note that reads its options from them | An agent's note captures the full vocabulary and submits to QA without a separate step |
| 4. Roles and work actions | 8, 9, 10, 11 | Team Lead and QA Reviewer roles, bulk QA approve with its guards, reassignment requests and bulk resolve, and no-touch write-off | Each bulk action applies to a mixed selection in one step, is role-gated, and writes the right actor to the audit trail |
| 5. Claim workspace and client escalation | 14, 5, 17 | The tabbed workspace with its stepper, the CIP case lifecycle, and the scoped read-only client view | A CIP case runs from opening through client reply to closure, including the CSV path, and the claim opens into the workspace from every queue |
| 6. Scoping, analytics and conveniences | 6, 15, 16, 7 | Clinic and provider access scoping, recovery analytics, the data-processing screen, and saved views with column visibility | A clinic-scoped viewer sees only their own claims, enforced server-side, and every queue has saved views and CSV parity |

Two decisions gate phase 1: whether we build the point-in-time history or the client's extract
supplies recovered and remaining AR, and whether Team Lead and QA Reviewer become real roles.
Phase 4 cannot start until the second one is answered.

## Note on item 1

Items 2, 3, 15 and part of 11 all read from the recovery figures in item 1, and those figures are a
delta against a previous refresh, not a value in the current one. Whatever the schedule, item 1
starts first or the phases behind it stall. Three planned reports (RPT-02, RPT-03, RPT-06) are
already parked on the same missing history.
