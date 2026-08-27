# LRN Metrics — documentation index

Every document in this folder, what it covers, and whether it is current. Documents are grouped into
one folder per module. Superseded material lives in [`archive/`](archive/) and is never the answer to
a question.

**Conventions**

* One folder per module. A document lives with the module it describes, not with documents of the
  same file type.
* A document's version and status live **inside** the file, in a line under the H1 — not in the
  filename. Filenames stay stable because several are referenced from source code and config.
* Filenames carry a version only when the version *is* the identity of the document
  (`Payer_Matching_Algorithm_Dev_Spec_v1.4.md`, `CVTPL-1.4_…`, `…Mockup_v2.0.html`).
* **Do not rename or move** the files listed under § Files referenced from code without updating
  their inbound references in the same commit.

```
docs/
├── beechtree-threepillar/   BeechTree three-pillar agent plan and costing
├── coding-validation/       Coding Validation output template and its deployment
├── cpt-panel-lookup/        Analytics > CPT & Panel Lookup
├── dashboard/               Revenue dashboard KPIs and Executive Summary drillthrough
├── denial-management/       Denial dashboard, workflow, and the denial agent
├── external-api/            Partner-facing API guide and internal onboarding
├── meeting-intelligence/    MeetingIQ prototype
├── operations/              Runbooks: Key Vault, Master Values import
├── payer-master/            Payer master and the matching algorithm
├── reimbursement-agent/     Reimbursement Insights agent and its DAB bridge
├── reports/                 Report queue, Production Summary, Report Control Board
└── archive/                 Superseded — provenance only
```

---

## CPT & Panel Lookup — [`cpt-panel-lookup/`](cpt-panel-lookup/)

The `Analytics > CPT & Panel Lookup` screen over `LRNMaster`: `CPTAverage`, `PanelAverage`,
`LabModes`, `LabMedians`.

| Document | Version | Status | Covers |
|---|---|---|---|
| [CptPanelLookup_BackgroundExport.md](cpt-panel-lookup/CptPanelLookup_BackgroundExport.md) | 1.0 | Implemented, deployment steps pending | Queued Excel export via the shared `LRNMaster` queue lab; the 1,000-row truncation fix |
| [CptPanelLookup_AgenticChat_Design.md](cpt-panel-lookup/CptPanelLookup_AgenticChat_Design.md) | 1.0 | Proposal | Conversational agent over the same four tables — requirements, tech stack, tool surface, guardrails |
| [CptPanelLookup_AgenticChat_Mockup.html](cpt-panel-lookup/CptPanelLookup_AgenticChat_Mockup.html) | 1.0 | Mockup | UI for the above |
| [LRNMaster.json](cpt-panel-lookup/LRNMaster.json) | — | Sample config | The shared queue-lab config the background export requires *(was `samples/LRNMaster.json`)* |

## Denial Dashboard & Denial Workflow — [`denial-management/`](denial-management/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [Denial_Dashboard_Workflow_Requirements_v2.0.pdf](denial-management/Denial_Dashboard_Workflow_Requirements_v2.0.pdf) | Rev 2.0 | **Baseline spec** | The requirements every other denial document builds on. Open items §11.1–§11.3 are live defects. |
| [Denial_Agentic_AI_Development_Plan.md](denial-management/Denial_Agentic_AI_Development_Plan.md) | 2.0 | Proposal — 19 decisions requested | Agent architecture, .NET/Python split, phases, cost, risks, and the PHI/privacy/security gate (§10) |
| [Agentic_AI_Implementation_Guideline_v1.0.docx](denial-management/Agentic_AI_Implementation_Guideline_v1.0.docx) | 1.0 | Reference | Microsoft Agent Framework build walkthrough (Python + .NET), SDK setup, Foundry wiring |
| [Denial_Dashboard_Screens_Captures.docx](denial-management/Denial_Dashboard_Screens_Captures.docx) | — | Reference | Screenshots of the real screens |
| [Denial_Dashboard_Screens_Mockup_v2.0.html](denial-management/Denial_Dashboard_Screens_Mockup_v2.0.html) | 2.0 | Mockup | Screen mockups under the Lab Revenue Navigator shell |
| [Denial_Agent_Mockup_v1.0.html](denial-management/Denial_Agent_Mockup_v1.0.html) | 1.0 | Mockup | Denial Agent review/approval UI |

## Payer Master & Matching — [`payer-master/`](payer-master/)

Maps a lab's raw payer names to the global Payer Policy Insurance Master. Read in this order.

| Document | Version | Status | Covers |
|---|---|---|---|
| [Payer_Master_Requirements_v1.7.md](payer-master/Payer_Master_Requirements_v1.7.md) | 1.7 | Current | Functional requirements: roles, both masters, cross-master rules, audit, bulk actions |
| [Payer_Matching_Algorithm_Dev_Spec_v1.4.md](payer-master/Payer_Matching_Algorithm_Dev_Spec_v1.4.md) | 1.4 | Current | Step-by-step matching pipeline, C# libraries per step, data contracts |
| [Payer_Master_Reference_Tables_v1.1.md](payer-master/Payer_Master_Reference_Tables_v1.1.md) | 1.1 | Current | The five rules/alias tables the pipeline depends on and who maintains them |
| [Payer_Matching_Verification_Report_v1.0.md](payer-master/Payer_Matching_Verification_Report_v1.0.md) | 1.0 | Evidence | Proof the implementation matches the dev spec, on real rows |
| [Payer_Matching_Workflow.html](payer-master/Payer_Matching_Workflow.html) | — | Diagram | Workflow diagram referenced by the verification report |

Source data lives in the SharePoint folder **12.Insurance Masters** (`Masters`, `Requirements & Spec`,
`Supporting Master`). The Payer Policy Insurance Master carries a `Payer Family` column; the Lab
Insurance Master has had `Global Payer ID` cleared for payers absent from the policy master. The
supporting masters are the regex-rule tables above: payer family, product line (strips PPO/EPO/POS/HMO),
program type, state-brand mapping, and US state codes.

> **Broken link:** the dev spec §Companion cites `clarifications_log.md`, which is not in this
> repository. Either add it or drop the reference.

## Reimbursement Insights Agent — [`reimbursement-agent/`](reimbursement-agent/)

The Foundry agent behind `Analytics > Reimbursement Insights`, its private bridge
(`reimb-dab-api`, Data API Builder over `LRNMaster`), and the backend proxy that fronts it.

| Document | Version | Status | Covers |
|---|---|---|---|
| [Payer_Alias_Resolution_v1.0.pdf](reimbursement-agent/Payer_Alias_Resolution_v1.0.pdf) | 1.0 | Proposal | Where payer alias/short-name matching should live, the three options weighed, effort and risk |
| [Payer_Alias_Resolution_v1.0.html](reimbursement-agent/Payer_Alias_Resolution_v1.0.html) | 1.0 | Source | The PDF's source. Regenerate the PDF from this; never edit the PDF in isolation. |
| [Payer_Alias_Resolution_Deployment.md](reimbursement-agent/Payer_Alias_Resolution_Deployment.md) | 1.1 | Runbook — bridge deployed, agent instructions pending | Step-by-step update, deploy, verify, test and rollback for the bridge `:v3` change |
| [Reimbursement_Agent_Instructions.md](reimbursement-agent/Reimbursement_Agent_Instructions.md) | 2.0 | **Master copy** | The agent's system instructions. Edit here and paste into ai.azure.com — the Foundry UI is a deployment target, not the source of truth. |

The bridge's own configuration lives in [`bridge/`](../bridge/) at the repository root, not
here — `dab-config.json`, its `Dockerfile`, and a README covering the entity list and build
commands.

## Reports & report delivery — [`reports/`](reports/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [AsyncReportGeneration_Design.md](reports/AsyncReportGeneration_Design.md) | 1.0 | Implemented | The `UserReqReports` queue + `LRN.ReportWorker` architecture for **on-demand** reports |
| [ProductionReportPreGenerationPlan.md](reports/ProductionReportPreGenerationPlan.md) | 1.0 | Plan — not implemented | **Pre-generating** the no-filter Production Report workbook at ingestion time |
| [PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md](reports/PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md) | 1.0 | In progress | Production Summary Report rollout for Phi_Life and InHealthDTR |
| [PRODUCTION_SUMMARY_REPORT_STATUS.md](reports/PRODUCTION_SUMMARY_REPORT_STATUS.md) | — | Status | Where the Production Summary rollout stands *(was at the repository root)* |
| [DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md](reports/DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md) | — | Checklist | Step-by-step deployment for the above *(was at the repository root)* |
| [REPORT_CONTROL_BOARD.md](reports/REPORT_CONTROL_BOARD.md) | 1.0 | Implemented | The `/ReportBoard` landing page; how to add a report type |
| [CollectionReport_ClaimLine_Fields_Review.xlsx](reports/CollectionReport_ClaimLine_Fields_Review.xlsx) | — | Working data | Claim-line field review behind the Collection Report *(was at the repository root)* |

The first two are **not** duplicates — one is on-demand queued generation, the other is
pre-generation at ingestion. Both can coexist. The three Production Summary documents *do* overlap
and are candidates for a merge.

## Coding Validation — [`coding-validation/`](coding-validation/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [CVTPL-1.4_CodingValidation_Deployment.md](coding-validation/CVTPL-1.4_CodingValidation_Deployment.md) | 1.4 | Deployed | Coding Validation alignment to Output Template v1.4, with revert instructions |
| [DEPLOYMENT_TROUBLESHOOTING.md](coding-validation/DEPLOYMENT_TROUBLESHOOTING.md) | — | Troubleshooting | The Coding Summary loading overlay failing on production only. Its fix script is [`scripts/Deploy-LoadingOverlayFix.ps1`](../scripts/Deploy-LoadingOverlayFix.ps1). |

## External API — [`external-api/`](external-api/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [ExternalApiAccess_Guide.md](external-api/ExternalApiAccess_Guide.md) | 1.0 | Current — **source of truth** | The partner-facing integration guide: auth, conventions, every endpoint |
| [LRN_Analytics_API_Guide.pdf](external-api/LRN_Analytics_API_Guide.pdf) | 1.0 | Distributable | Formatted export of the above. Regenerate from the markdown; never edit in isolation. |
| [ExternalApiAccess_Onboarding.md](external-api/ExternalApiAccess_Onboarding.md) | 1.0 | Current — **internal only** | Provisioning a client, choosing roles, open security issues |

## Dashboard — [`dashboard/`](dashboard/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [DASHBOARD_DATA_FLOW.md](dashboard/DASHBOARD_DATA_FLOW.md) | — | Reference | End-to-end KPI data flow, CSV capture worker through to the displayed tile *(was at the repository root)* |
| [ExecutiveSummary_Drillthrough_Logic.xlsx](dashboard/ExecutiveSummary_Drillthrough_Logic.xlsx) | — | Working data | Executive Summary drillthrough row definitions *(was at the repository root)*. The SQL is in [`SQL_Scripts/ExecutiveSummaryDrill/`](../SQL_Scripts/ExecutiveSummaryDrill/). |

## Operations — [`operations/`](operations/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [MasterValuesImportProductionRemediation.md](operations/MasterValuesImportProductionRemediation.md) | 1.0 | Runbook | Teams webhook config; recovering a timed-out Master Values import |
| [KeyVault_Secrets.md](operations/KeyVault_Secrets.md) | — | Reference | Key Vault secret naming and which apps read which secret |

## BeechTree Three-Pillar — [`beechtree-threepillar/`](beechtree-threepillar/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [BeechTree_ThreePillar_Foundry_Agents_Plan.pdf](beechtree-threepillar/BeechTree_ThreePillar_Foundry_Agents_Plan.pdf) | — | Proposal | The three-pillar Foundry agent plan |
| [BeechTree_ThreePillar_Cost_Analysis.pdf](beechtree-threepillar/BeechTree_ThreePillar_Cost_Analysis.pdf) | — | Proposal | Costing for the above |

Both PDFs are generated — the reportlab sources are in
[`scripts/doc-gen/`](../scripts/doc-gen/). Regenerate; never edit the PDFs in isolation.

## Meeting Intelligence — [`meeting-intelligence/`](meeting-intelligence/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [MeetingIntelligence_Prototype.html](meeting-intelligence/MeetingIntelligence_Prototype.html) | — | Prototype | MeetingIQ UI prototype *(was at the repository root)* |

Its spec generator, `meetingiq_spec.js`, is in [`scripts/doc-gen/`](../scripts/doc-gen/).

---

## Files referenced from code

Renaming or moving any of these silently breaks a comment or a config note. Update the reference in
the same commit.

| Document | Referenced from |
|---|---|
| `reports/REPORT_CONTROL_BOARD.md` | `LabMetricsDashboard/Services/ReportCatalog.cs` |
| `external-api/ExternalApiAccess_Guide.md` | `LRN.ReportsApi/Program.cs`, `LRN.ReportsApi/appsettings.json` |
| `payer-master/Payer_Master_Reference_Tables_v1.1.md` | `LRN.ReportsApi/Sql/Payer_Matching_Reference_Tables_DDL_and_Seed.sql`, `LRN.ReportsApi/Sql/Payer_Policy_Mapper_Consolidated.sql` |
| `cpt-panel-lookup/LRNMaster.json` | `cpt-panel-lookup/CptPanelLookup_BackgroundExport.md` deployment steps |

## Where non-document files went

The 2026-08-27 cleanup emptied the repository root. Nothing was deleted.

| Was at the root | Now |
|---|---|
| `usp_RefreshBT_ExecutiveSummary_*.sql`, `ExecSummary_*`, `*WriteOffReason_ExecSummary*` | `SQL_Scripts/BeechTree/ExecutiveSummary/` |
| `usp_RefreshBT_WOSummary_v2…v6.sql`, `FullyAdjusted_WOSummary_Tally.sql`, `Diag_MissingClaim_18960958.sql` | `SQL_Scripts/BeechTree/WOSummary/` |
| `usp_RefreshCove_ExecutiveSummary_LIS_Alt.sql` | `SQL_Scripts/Cove/` |
| `_drill_verify/repro_*.sql` | `SQL_Scripts/ExecutiveSummaryDrill/` |
| `Deploy-LoadingOverlayFix.ps1`, `xlcheck.py` | `scripts/` |
| `meetingiq_spec.js`, `docs/_gen_threepillar_*.py` | `scripts/doc-gen/` |
| `build-*.txt`, `_build_*.txt`, `_drill_deploy/`, `_drill_verify/`, `_extract_parts/` | `_artifacts/` — throwaway run output, now gitignored. Safe to delete. |

## Known gaps

* The three Production Summary documents overlap and should be folded into one.
* `clarifications_log.md`, cited by the payer matching dev spec, does not exist here.
