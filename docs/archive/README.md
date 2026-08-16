# Archived documents

Superseded documents, kept for provenance. **Nothing here is current** — do not cite these in a
decision, a spec, or a code comment. Each entry names what replaced it.

Archived 2026-08-16 as part of a docs consolidation pass.

| Archived file | What it was | Replaced by | Why archived |
|---|---|---|---|
| `Denial_Agentic_AI_Manager_Report_v1.0.docx` | *Manager Review — Development Plan, Architecture, Technology and Cost*, 12 Aug 2026 | [`../Denial_Agentic_AI_Development_Plan.md`](../Denial_Agentic_AI_Development_Plan.md) v2.0 | **Strict subset** of the v1.1 PHI/Security revision below — a text diff shows zero unique content. |
| `Denial_Agentic_AI_Manager_Report_v1.1_PHI_Security.docx` | Same report plus PHI/Privacy/Security sections §26–32 | [`../Denial_Agentic_AI_Development_Plan.md`](../Denial_Agentic_AI_Development_Plan.md) §10 | Same proposal, same date, as the development plan. Its unique PHI material was merged into §10 of the plan; the rest was already duplicated. |
| `Python_AI_Denial_Management_Proposal_v0.1.docx` | The original one-page "We propose developing a Python…" proposal | [`../Denial_Agentic_AI_Development_Plan.md`](../Denial_Agentic_AI_Development_Plan.md) | Source input that both later documents consumed and superseded. Its tool list survives in §7 of the plan. |
| `Denial_Dashboard_Screens_Mockup_v1.0.html` | First HTML screen mockup (was `denial-screens (1).html`) | [`../Denial_Dashboard_Screens_Mockup_v2.0.html`](../Denial_Dashboard_Screens_Mockup_v2.0.html) | v2 is a full redesign under the Lab Revenue Navigator shell and covers every v1 screen. |
| `LRN_Analytics_API_Guide_v1.0.docx` | Word rendition of the external API guide | [`../ExternalApiAccess_Guide.md`](../ExternalApiAccess_Guide.md) (source) and `../LRN_Analytics_API_Guide.pdf` (distributable) | Documents the identical endpoint set as the markdown — verified by comparing every path in both. An intermediate format with no unique content; keeping it invites the three copies to drift. |
| `GlobalPayerID_Mapping_Manifest_v1.0.docx` | SharePoint folder manifest for *12.Insurance Masters* | [`../README.md`](../README.md) § Payer Master & Matching | It was an index of other documents rather than a document. Its content is now the payer section of the docs index. |

## Recovering one

These were moved with `git mv`, so full history follows the file:

```sh
git log --follow -- docs/archive/<file>
```

To delete the archive outright once you're satisfied nothing here is needed:

```sh
git rm -r docs/archive
```
