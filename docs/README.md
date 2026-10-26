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
├── ar-workbench/            Denial & AR Workbench: requirements, plan, test reports, mockup (was Denial_WorkFlow/)
├── beechtree-threepillar/   BeechTree three-pillar agent plan and costing
├── coding-validation/       Coding Validation output template and its deployment
├── cpt-panel-lookup/        Analytics > CPT & Panel Lookup
├── dashboard/               Revenue dashboard KPIs and Executive Summary drillthrough
├── demo-lab/                LRNLabDemo de-identified demo lab
├── denial-management/       Denial dashboard, workflow, the denial agent, denial masters
├── external-api/            Partner-facing API guide and internal onboarding
├── master-file-processor/   Master file column / field mappings per lab
├── meeting-intelligence/    MeetingIQ prototype
├── operations/              Runbooks: Key Vault, Master Values import, Azure hosting, services audit
├── payer-master/            Payer master and the matching algorithm
├── payer-policy-mapper/     Payer Policy AI design
├── reimbursement-agent/     Reimbursement Insights agent and its DAB bridge
├── reports/                 Report queue, Production Summary, Report Control Board, report snapshots
├── security/                HIPAA implementation across all projects (PHI storage, access, audit)
└── archive/                 Superseded — provenance only
```

---

## Denial & AR Workbench — [`ar-workbench/`](ar-workbench/)

The React app `LRN.ARWorkbench`, its API `/api/ar-workbench` in `LRN.ReportsApi`, and the SQL in
[`Database/LRN.ReportsApi/ArWorkbench/`](../Database/LRN.ReportsApi/ArWorkbench/). Read the handoff first.

| Document | Version | Status | Covers |
|---|---|---|---|
| [AR_Workbench_Developer_Handoff_Requirements_v1.1.docx](ar-workbench/AR_Workbench_Developer_Handoff_Requirements_v1.1.docx) | 1.1 | **Requirement** | Session decisions (Part A), FR-xx functional requirements (Part B), mockup rules (Part C), NFRs (Part E). The `.pdf` beside it is a rendition. |
| [ARWorkflow_Redesign_Plan_v1.0_09.25.2026.xlsx](ar-workbench/ARWorkflow_Redesign_Plan_v1.0_09.25.2026.xlsx) | 1.0 | **Live tracker** | Task plan; sheet *Plan - Corrected Order* carries each task's Status. UAT fixes are module M29 (T083–T111). |
| [AR_Workbench_Retest_Report_v1.4_2026-10-19.xlsx](ar-workbench/AR_Workbench_Retest_Report_v1.4_2026-10-19.xlsx) | 1.4 | **Current test report** | 19 Oct retest: Part A/B/C/E traceability, role workflows, defect log (DEF-01 – DEF-31), observations. DEF-22 – DEF-31 fixed as T101 – T110 on 21 Oct. |
| [LRN_Denial_AR_Workbench_Demo_Account.html](ar-workbench/LRN_Denial_AR_Workbench_Demo_Account.html) | — | Approved mockup | The functional mockup the screens, icons and styles follow (referenced from code) |
| [AR_Workbench_Build_Reference.pdf](ar-workbench/AR_Workbench_Build_Reference.pdf) | 23 Sep 2026 | Reference — input to the handoff | What the mockup does, per role and screen |
| [AR_Workbench_Developer_Documentation.pdf](ar-workbench/AR_Workbench_Developer_Documentation.pdf) | 23 Sep 2026 (26 pp) | Reference | How the mockup's code is built (the full edition; the 19-page cut is archived) |
| [AR_Workbench_Open_Items_And_Phases.md](ar-workbench/AR_Workbench_Open_Items_And_Phases.md) | 29 Sep 2026 | Historical — superseded by the plan workbook | The original gap analysis and phase order (referenced from `navigation.js`, `PlannedPage.jsx`) |
| [ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls](ar-workbench/ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls) | 2026 Q1 | Source data | CMS fee schedule imported in LRN Metrics > Master Values > Fees Schedule Import; prices Revenue Expectation |

## Security & HIPAA — [`security/`](security/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [LRN_HIPAA_Platform_Implementation.md](security/LRN_HIPAA_Platform_Implementation.md) | 2.0 | **Plan + spec** — Wave 1 (AR Workbench) implemented, Waves 0, 2–6 open | Which projects hold PHI and where; HIPAA rule mapping; gaps G1–G20; the shared storage/audit standard; per-wave tasks, tests and rollout. Supersedes the AR Workbench-only v1.0. |

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
| [Denial_Dashboard_And_Workflow_Requirements.md](denial-management/Denial_Dashboard_And_Workflow_Requirements.md) | 1.0 | **As-built** | What the two screens do today: navigation, per-role tabs and queues, the four access-control layers, write permissions, and known gaps. Read alongside the Rev 2.0 baseline — that states intent, this states the current build. |
| [Denial_Agentic_AI_Development_Plan.md](denial-management/Denial_Agentic_AI_Development_Plan.md) | 2.0 | Proposal — 19 decisions requested | Agent architecture, .NET/Python split, phases, cost, risks, and the PHI/privacy/security gate (§10) |
| [Agentic_AI_Implementation_Guideline_v1.0.docx](denial-management/Agentic_AI_Implementation_Guideline_v1.0.docx) | 1.0 | Reference | Microsoft Agent Framework build walkthrough (Python + .NET), SDK setup, Foundry wiring |
| [Denial_Dashboard_Screens_Captures.docx](denial-management/Denial_Dashboard_Screens_Captures.docx) | — | Reference | Screenshots of the real screens |
| [Denial_Dashboard_Screens_Mockup_v2.0.html](denial-management/Denial_Dashboard_Screens_Mockup_v2.0.html) | 2.0 | Mockup | Screen mockups under the Lab Revenue Navigator shell |
| [Denial_Agent_Mockup_v1.0.html](denial-management/Denial_Agent_Mockup_v1.0.html) | 1.0 | Mockup | Denial Agent review/approval UI |
| [Denial_Workflow_AR_Reporting_Requirements_v1.0.pdf](denial-management/Denial_Workflow_AR_Reporting_Requirements_v1.0.pdf) | 1.0 | Spec | AR Follow-up Reporting requirements (RPT-01 – RPT-09) |
| [RPT01_Activity_Detail_Implementation.md](denial-management/RPT01_Activity_Detail_Implementation.md) | — | Implemented | RPT-01 AR Follow-up Activity Detail and the report catalog |
| [RPT01_Test_Report_v1.0.html](denial-management/RPT01_Test_Report_v1.0.html) | 1.0 | Evidence | RPT-01 test report |
| [Denial_AR_Reports_Data_Readiness_v1.0.html](denial-management/Denial_AR_Reports_Data_Readiness_v1.0.html) | 1.0 | Analysis | Data readiness of the denial AR reports |
| [Denial_Workflow_Benchmark_And_Screens_v1.0.html](denial-management/Denial_Workflow_Benchmark_And_Screens_v1.0.html) | 1.0 | Analysis | Denial workflow benchmark and screens |
| [Denial_Database_Worker_Requirements.md](denial-management/Denial_Database_Worker_Requirements.md) | — | As-built | `LRN.DenialDatabaseWorker` requirements, reverse-engineered from the code |
| [Denial_Codes_And_Categorization_Master.xlsx](denial-management/Denial_Codes_And_Categorization_Master.xlsx) | 13 Oct 2026 | **Master data** | Denial code → description → categorization, and the non-collectible codes. Read by Denial Category Master (LRN Metrics); the AR Workbench Denial Code Master was seeded from its 6 Oct predecessor (archived). |
| [DenialSummary_EditableColumns.xlsx](denial-management/DenialSummary_EditableColumns.xlsx) | — | Client sample | Which Denial Summary columns are editable, and the status banding |

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
| [LRN_Report_Snapshots–Parquet_Storage_Implementation.pdf](reports/LRN_Report_Snapshots–Parquet_Storage_Implementation.pdf) | — | Design | Report snapshots stored as Parquet |
| [LRN_Report_Snapshots_Implementation_Plan.xlsx](reports/LRN_Report_Snapshots_Implementation_Plan.xlsx) | — | Plan | Task split, test checklist and open questions for the above |
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
| [ExecutiveSummary_Drillthrough_Logic.xlsx](dashboard/ExecutiveSummary_Drillthrough_Logic.xlsx) | — | Working data | Executive Summary drillthrough row definitions *(was at the repository root)*. The SQL is in [`Database/Shared/ExecutiveSummaryDrill/`](../Database/Shared/ExecutiveSummaryDrill/). |

## Operations — [`operations/`](operations/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [MasterValuesImportProductionRemediation.md](operations/MasterValuesImportProductionRemediation.md) | 1.0 | Runbook | Teams webhook config; recovering a timed-out Master Values import |
| [KeyVault_Secrets.md](operations/KeyVault_Secrets.md) | — | Reference | Key Vault secret naming and which apps read which secret |
| [LRN Azure Hosting Guide.pdf](operations/LRN%20Azure%20Hosting%20Guide.pdf) | 23 Sep 2026 | Guide | Target Azure architecture and cost model |
| [LRN_Azure_Hosting_Implementation_Plan.md](operations/LRN_Azure_Hosting_Implementation_Plan.md) | — | Plan + checklist | What the codebase needs for that hosting, and how to verify it |
| [LRN_Services_Audit.docx](operations/LRN_Services_Audit.docx) | 2 | Audit | The Windows services on ReportEngine: usage, data flows, SharePoint folders, rationalisation |

## Master File Processor — [`master-file-processor/`](master-file-processor/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [AveragesTable_AllAccounts_Field Mapping_V1.19.xlsx](master-file-processor/AveragesTable_AllAccounts_Field%20Mapping_V1.19.xlsx) | 1.19 | **Mapping** | Line / claim level fact-table columns per lab and the SharePoint paths (cited by name in `LRN.MasterFileProcessorWorker/Schemas/*.schema.json`) |
| [VariantX_MasterFile_Column_Mapping.xlsx](master-file-processor/VariantX_MasterFile_Column_Mapping.xlsx) | — | Mapping | VariantX master file claim and line level columns |

## Payer Policy Mapper — [`payer-policy-mapper/`](payer-policy-mapper/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [LRN_Payer_Policy_AI_Design_v4_final.pdf](payer-policy-mapper/LRN_Payer_Policy_AI_Design_v4_final.pdf) | 4 (final) | Design | Payer policy AI design behind `LRN.PayerPolicyMapper` |

## Demo Lab — [`demo-lab/`](demo-lab/)

| Document | Version | Status | Covers |
|---|---|---|---|
| [DemoLab_Setup.md](demo-lab/DemoLab_Setup.md) | — | Runbook | `LRNLabDemo` (LabId 99): cloned from PCRLabsofAmerica and de-identified |
| [LRNLabDemo.json.template](demo-lab/LRNLabDemo.json.template) | — | Sample config | Lab config template for the above |

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
| `payer-master/Payer_Master_Reference_Tables_v1.1.md` | `Database/LRN.ReportsApi/Payer_Matching_Reference_Tables_DDL_and_Seed.sql`, `Database/LRN.ReportsApi/Payer_Policy_Mapper_Consolidated.sql` |
| `cpt-panel-lookup/LRNMaster.json` | `cpt-panel-lookup/CptPanelLookup_BackgroundExport.md` deployment steps |
| `ar-workbench/LRN_Denial_AR_Workbench_Demo_Account.html` | `LRN.ARWorkbench/src` (styles.css, Icon.jsx, navigation.js, DashboardPage.jsx, ClaimDetailPage.jsx), `LRN.ReportsApi/Models/ArWorkbench*Models.cs` |
| `ar-workbench/AR_Workbench_Open_Items_And_Phases.md` | `LRN.ARWorkbench/src/config/navigation.js`, `LRN.ARWorkbench/src/pages/PlannedPage.jsx`, `LRN.ARWorkbench/README.md` |
| `ar-workbench/ClinicalLaboratoryFeeSchedule_2026_Q1V1.xls` | `tests/LabMetricsDashboard.Tests/FeeScheduleWorkbookTests.cs` (**loads it** — the test skips silently if it moves), `LabMetricsDashboard/Services/FeeScheduleWorkbook.cs`, `Database/LabMetricsDashboard/FeeSchedule_Setup.sql` |
| `ar-workbench/ARWorkflow_Redesign_Plan_v1.0_09.25.2026.xlsx` | The AR Workbench task tracker kept up to date task by task |
| `denial-management/Denial_Codes_And_Categorization_Master.xlsx` | `LabMetricsDashboard` DenialCategoryMaster controller / workbook, `Database/LabMetricsDashboard/DenialCategoryMaster_Setup.sql` |
| `denial-management/DenialSummary_EditableColumns.xlsx` | `LabMetricsDashboard` DenialClaimReportController, DenialInsightStatus, `_DenialInsightPanel.cshtml`, `denial_claim_report.css` |
| `master-file-processor/AveragesTable_AllAccounts_Field Mapping_V1.19.xlsx` | `LRN.MasterFileProcessorWorker/Schemas/*.schema.json` (by file name) |

## Where non-document files went

The 2026-08-27 cleanup emptied the repository root. Nothing was deleted.

| Was at the root | Now |
|---|---|
| `usp_RefreshBT_ExecutiveSummary_*.sql`, `ExecSummary_*`, `*WriteOffReason_ExecSummary*` | `Database/Shared/BeechTree/ExecutiveSummary/` |
| `usp_RefreshBT_WOSummary_v2…v6.sql`, `FullyAdjusted_WOSummary_Tally.sql`, `Diag_MissingClaim_18960958.sql` | `Database/Shared/BeechTree/WOSummary/` |
| `usp_RefreshCove_ExecutiveSummary_LIS_Alt.sql` | `Database/Shared/Cove/` |
| `_drill_verify/repro_*.sql` | `Database/Shared/ExecutiveSummaryDrill/` |
| `Deploy-LoadingOverlayFix.ps1`, `xlcheck.py` | `scripts/` |
| `meetingiq_spec.js`, `docs/_gen_threepillar_*.py` | `scripts/doc-gen/` |
| `build-*.txt`, `_build_*.txt`, `_drill_deploy/`, `_drill_verify/`, `_extract_parts/` | `_artifacts/` — throwaway run output, now gitignored. Safe to delete. |

## 2026-10-21 reorganisation

`Denial_WorkFlow/` became `ar-workbench/`, and the loose files at the `docs/` root went to their module
folders (above). Superseded files went to `archive/` (see its README). Every inbound reference in code,
SQL comments and tests was updated in the same change.

## Known gaps

* The three Production Summary documents overlap and should be folded into one.
* `clarifications_log.md`, cited by the payer matching dev spec, does not exist here.
