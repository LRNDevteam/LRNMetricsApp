# LRN Metrics — documentation index

Every document in this folder, what it covers, and whether it is current. Superseded material lives
in [`archive/`](archive/) and is never the answer to a question.

**Conventions**

* A document's version and status live **inside** the file, in a line under the H1 — not in the
  filename. Filenames stay stable because several are referenced from source code and config.
* Filenames carry a version only when the version *is* the identity of the document
  (`Payer_Matching_Algorithm_Dev_Spec_v1.4.md`, `CVTPL-1.4_…`, `…Mockup_v2.0.html`).
* **Do not rename** `REPORT_CONTROL_BOARD.md`, `ExternalApiAccess_Guide.md`,
  `Payer_Master_Reference_Tables_v1.1.md` or `PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md` without
  updating their inbound references — see § Files referenced from code.

---

## CPT & Panel Lookup

The `Analytics > CPT & Panel Lookup` screen over `LRNMaster`: `CPTAverage`, `PanelAverage`,
`LabModes`, `LabMedians`.

| Document | Version | Status | Covers |
|---|---|---|---|
| [CptPanelLookup_BackgroundExport.md](CptPanelLookup_BackgroundExport.md) | 1.0 | Implemented, deployment steps pending | Queued Excel export via the shared `LRNMaster` queue lab; the 1,000-row truncation fix |
| [CptPanelLookup_AgenticChat_Design.md](CptPanelLookup_AgenticChat_Design.md) | 1.0 | Proposal | Conversational agent over the same four tables — requirements, tech stack, tool surface, guardrails |
| [CptPanelLookup_AgenticChat_Mockup.html](CptPanelLookup_AgenticChat_Mockup.html) | 1.0 | Mockup | UI for the above (was `…AgentChat_Mockup.html`) |

## Denial Dashboard & Denial Workflow

| Document | Version | Status | Covers |
|---|---|---|---|
| [Denial_Dashboard_Workflow_Requirements_v2.0.pdf](Denial_Dashboard_Workflow_Requirements_v2.0.pdf) | Rev 2.0 | **Baseline spec** | The requirements every other denial document builds on. Open items §11.1–§11.3 are live defects. |
| [Denial_Agentic_AI_Development_Plan.md](Denial_Agentic_AI_Development_Plan.md) | 2.0 | Proposal — 19 decisions requested | Agent architecture, .NET/Python split, phases, cost, risks, and the PHI/privacy/security gate (§10) |
| [Agentic_AI_Implementation_Guideline_v1.0.docx](Agentic_AI_Implementation_Guideline_v1.0.docx) | 1.0 | Reference | Microsoft Agent Framework build walkthrough (Python + .NET), SDK setup, Foundry wiring |
| [Denial_Dashboard_Screens_Captures.docx](Denial_Dashboard_Screens_Captures.docx) | — | Reference | Screenshots of the real screens |
| [Denial_Dashboard_Screens_Mockup_v2.0.html](Denial_Dashboard_Screens_Mockup_v2.0.html) | 2.0 | Mockup | Screen mockups under the Lab Revenue Navigator shell |
| [Denial_Agent_Mockup_v1.0.html](Denial_Agent_Mockup_v1.0.html) | 1.0 | Mockup | Denial Agent review/approval UI |

## Payer Master & Matching

Maps a lab's raw payer names to the global Payer Policy Insurance Master. Read in this order.

| Document | Version | Status | Covers |
|---|---|---|---|
| [Payer_Master_Requirements_v1.7.md](Payer_Master_Requirements_v1.7.md) | 1.7 | Current | Functional requirements: roles, both masters, cross-master rules, audit, bulk actions *(was `requirements_v1.7.md`)* |
| [Payer_Matching_Algorithm_Dev_Spec_v1.4.md](Payer_Matching_Algorithm_Dev_Spec_v1.4.md) | 1.4 | Current | Step-by-step matching pipeline, C# libraries per step, data contracts |
| [Payer_Master_Reference_Tables_v1.1.md](Payer_Master_Reference_Tables_v1.1.md) | 1.1 | Current | The five rules/alias tables the pipeline depends on and who maintains them |
| [Payer_Matching_Verification_Report_v1.0.md](Payer_Matching_Verification_Report_v1.0.md) | 1.0 | Evidence | Proof the implementation matches the dev spec, on real rows |
| [Payer_Matching_Workflow.html](Payer_Matching_Workflow.html) | — | Diagram | Workflow diagram referenced by the verification report |

Source data lives in the SharePoint folder **12.Insurance Masters** (`Masters`, `Requirements & Spec`,
`Supporting Master`). The Payer Policy Insurance Master carries a `Payer Family` column; the Lab
Insurance Master has had `Global Payer ID` cleared for payers absent from the policy master. The
supporting masters are the regex-rule tables above: payer family, product line (strips PPO/EPO/POS/HMO),
program type, state-brand mapping, and US state codes.

> **Broken link:** the dev spec §Companion cites `clarifications_log.md`, which is not in this
> repository. Either add it or drop the reference.

## Reports & report delivery

| Document | Version | Status | Covers |
|---|---|---|---|
| [AsyncReportGeneration_Design.md](AsyncReportGeneration_Design.md) | 1.0 | Implemented | The `UserReqReports` queue + `LRN.ReportWorker` architecture for **on-demand** reports |
| [ProductionReportPreGenerationPlan.md](ProductionReportPreGenerationPlan.md) | 1.0 | Plan — not implemented | **Pre-generating** the no-filter Production Report workbook at ingestion time |
| [PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md](PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md) | 1.0 | In progress | Production Summary Report rollout for Phi_Life and InHealthDTR |
| [REPORT_CONTROL_BOARD.md](REPORT_CONTROL_BOARD.md) | 1.0 | Implemented | The `/ReportBoard` landing page; how to add a report type |
| [CVTPL-1.4_CodingValidation_Deployment.md](CVTPL-1.4_CodingValidation_Deployment.md) | 1.4 | Deployed | Coding Validation alignment to Output Template v1.4, with revert instructions |

The first two are **not** duplicates — one is on-demand queued generation, the other is
pre-generation at ingestion. Both can coexist.

## External API

| Document | Version | Status | Covers |
|---|---|---|---|
| [ExternalApiAccess_Guide.md](ExternalApiAccess_Guide.md) | 1.0 | Current — **source of truth** | The partner-facing integration guide: auth, conventions, every endpoint |
| [LRN_Analytics_API_Guide.pdf](LRN_Analytics_API_Guide.pdf) | 1.0 | Distributable | Formatted export of the above. Regenerate from the markdown; never edit in isolation. |
| [ExternalApiAccess_Onboarding.md](ExternalApiAccess_Onboarding.md) | 1.0 | Current — **internal only** | Provisioning a client, choosing roles, open security issues |

## Operations

| Document | Version | Status | Covers |
|---|---|---|---|
| [MasterValuesImportProductionRemediation.md](MasterValuesImportProductionRemediation.md) | 1.0 | Runbook | Teams webhook config; recovering a timed-out Master Values import |
| [samples/LRNMaster.json](samples/LRNMaster.json) | — | Sample config | The shared queue-lab config required by the CPT/Panel background export |

---

## Files referenced from code

Renaming any of these silently breaks a comment or a config note. Update the reference in the same
commit if you must rename.

| Document | Referenced from |
|---|---|
| `REPORT_CONTROL_BOARD.md` | `LabMetricsDashboard/Services/ReportCatalog.cs` |
| `ExternalApiAccess_Guide.md` | `LRN.ReportsApi/Program.cs`, `LRN.ReportsApi/appsettings.json` |
| `Payer_Master_Reference_Tables_v1.1.md` | `LRN.ReportsApi/Sql/Payer_Matching_Reference_Tables_DDL_and_Seed.sql`, `LRN.ReportsApi/Sql/Payer_Policy_Mapper_Consolidated.sql` |
| `PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md` | `PRODUCTION_SUMMARY_REPORT_STATUS.md`, `DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md` (both at repo root) |

## Known gaps

* **Documentation outside `docs/`.** The repository root holds `DASHBOARD_DATA_FLOW.md`,
  `DEPLOYMENT_CHECKLIST_PRODUCTION_SUMMARY.md`, `DEPLOYMENT_TROUBLESHOOTING.md` and
  `PRODUCTION_SUMMARY_REPORT_STATUS.md`. The last two overlap
  `PRODUCTION_SUMMARY_REPORT_IMPLEMENTATION.md`. They were out of scope for this pass and were left
  where they are.
* `clarifications_log.md`, cited by the payer matching dev spec, does not exist here.
