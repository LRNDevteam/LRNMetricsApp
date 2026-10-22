# Archived documents

Superseded documents, kept for provenance. **Nothing here is current** — do not cite these in a
decision, a spec, or a code comment. Each entry names what replaced it.

Archived 2026-08-16 as part of a docs consolidation pass.

| Archived file | What it was | Replaced by | Why archived |
|---|---|---|---|
| `Denial_Agentic_AI_Manager_Report_v1.0.docx` | *Manager Review — Development Plan, Architecture, Technology and Cost*, 12 Aug 2026 | [`../Denial_Agentic_AI_Development_Plan.md`](../denial-management/Denial_Agentic_AI_Development_Plan.md) v2.0 | **Strict subset** of the v1.1 PHI/Security revision below — a text diff shows zero unique content. |
| `Denial_Agentic_AI_Manager_Report_v1.1_PHI_Security.docx` | Same report plus PHI/Privacy/Security sections §26–32 | [`../Denial_Agentic_AI_Development_Plan.md`](../denial-management/Denial_Agentic_AI_Development_Plan.md) §10 | Same proposal, same date, as the development plan. Its unique PHI material was merged into §10 of the plan; the rest was already duplicated. |
| `Python_AI_Denial_Management_Proposal_v0.1.docx` | The original one-page "We propose developing a Python…" proposal | [`../Denial_Agentic_AI_Development_Plan.md`](../denial-management/Denial_Agentic_AI_Development_Plan.md) | Source input that both later documents consumed and superseded. Its tool list survives in §7 of the plan. |
| `Denial_Dashboard_Screens_Mockup_v1.0.html` | First HTML screen mockup (was `denial-screens (1).html`) | [`../denial-management/Denial_Dashboard_Screens_Mockup_v2.0.html`](../denial-management/Denial_Dashboard_Screens_Mockup_v2.0.html) | v2 is a full redesign under the Lab Revenue Navigator shell and covers every v1 screen. |
| `LRN_Analytics_API_Guide_v1.0.docx` | Word rendition of the external API guide | [`../external-api/ExternalApiAccess_Guide.md`](../external-api/ExternalApiAccess_Guide.md) (source) and `../external-api/LRN_Analytics_API_Guide.pdf` (distributable) | Documents the identical endpoint set as the markdown — verified by comparing every path in both. An intermediate format with no unique content; keeping it invites the three copies to drift. |
| `GlobalPayerID_Mapping_Manifest_v1.0.docx` | SharePoint folder manifest for *12.Insurance Masters* | [`../README.md`](../README.md) § Payer Master & Matching | It was an index of other documents rather than a document. Its content is now the payer section of the docs index. |

Archived 2026-10-21 with the move of `Denial_WorkFlow/` to `ar-workbench/` (plain moves, as the 2026-08-27 pass):

| Archived file | What it was | Replaced by | Why archived |
|---|---|---|---|
| `AR_Workbench_Test_Report_2026-10-15.xlsx` | First AR Workbench requirements test report (15 Oct, defects DEF-01 – DEF-20) | [`../ar-workbench/AR_Workbench_Retest_Report_v1.4_2026-10-19.xlsx`](../ar-workbench/AR_Workbench_Retest_Report_v1.4_2026-10-19.xlsx) | The retest re-runs every case and carries the 15 Oct status beside the new one. |
| `AR_Workbench_Developer_Documentation_v2026-09-23_19p.pdf` | 19-page cut of the mockup's developer documentation (was `Denial_WorkFlow/AR_Workbench_Developer_Documentation.pdf`) | [`../ar-workbench/AR_Workbench_Developer_Documentation.pdf`](../ar-workbench/AR_Workbench_Developer_Documentation.pdf) (26 pp, was `…Documentation[1].pdf`) | Text comparison: every line of the 19-page cut is in the 26-page edition, which adds the claim detail, CIP lifecycle and remaining modules. |
| `AR_Workbench_Open_Items_And_Phases.docx` | Word rendition of the open-items gap analysis | [`../ar-workbench/AR_Workbench_Open_Items_And_Phases.md`](../ar-workbench/AR_Workbench_Open_Items_And_Phases.md) | Same content as the markdown, which code comments cite. |
| `DenialCodes&Categorization_Master_2026-10-06.xlsx` | Denial code categorization master as of 6 Oct (seed of the AR Workbench Denial Code Master, `LRNMaster_02`) | [`../denial-management/Denial_Codes_And_Categorization_Master.xlsx`](../denial-management/Denial_Codes_And_Categorization_Master.xlsx) (13 Oct) | Same sheets and rows; the 13 Oct copy fills the `#N/A` descriptions and corrects 22 rows. |
| `Demo Tool - HTML Code.txt` | An e-mail attachment placeholder: "This attachment was removed because it contains data that could pose a security risk." | [`../ar-workbench/LRN_Denial_AR_Workbench_Demo_Account.html`](../ar-workbench/LRN_Denial_AR_Workbench_Demo_Account.html) | No content; the mockup itself is in `ar-workbench/`. |

Removed, not archived: `Denial_WorkFlow/AR_Workbench_Developer_Handoff_Requirements_v1.1 1.docx` — a byte-identical
(SHA-256) copy of `ar-workbench/AR_Workbench_Developer_Handoff_Requirements_v1.1.docx`.

## Recovering one

These were moved with `git mv`, so full history follows the file (the 2026-08-27 and 2026-10-21 passes
used plain moves — `--follow` still traces them):

```sh
git log --follow -- docs/archive/<file>
```

To delete the archive outright once you're satisfied nothing here is needed:

```sh
git rm -r docs/archive
```
