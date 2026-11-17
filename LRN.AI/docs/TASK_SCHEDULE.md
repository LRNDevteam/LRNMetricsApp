# LRN AI — Task Schedule

Plan for the LRN AI platform (Denial Analysis & AR Recommendations), from [CODEX.md](../CODEX.md) and
[HIPAA_SAFEGUARDS.md](HIPAA_SAFEGUARDS.md). Baseline set 2026-11-07. It assumes one full-time .NET developer,
plus part-time React, DBA and compliance support. Dates are week boundaries (Mon–Fri) and should be re-planned
at each phase gate.

**Status values:** Completed (built, compiling, tests passing) · In Progress · Not Started · Blocked.

## Summary

| Phase | Scope | Start | End | Gate to exit |
|---|---|---|---|---|
| P0 | Governance & HIPAA readiness (runs alongside P1–P2) | 2026-11-09 | 2026-12-11 | G1, G2, G4 signed off before live data |
| P1 | Local model comparison API (Ollama) | 2026-11-07 | 2026-11-13 | CODEX §20 acceptance criteria, verified against installed Qwen/Llama/DeepSeek tags |
| P2 | Hybrid LRN data access, lab authorisation, LRNAI database, audit persistence | 2026-11-16 | 2026-12-11 | Read-only, lab-scoped claim/denial context for one claim; audit rows in LRNAI |
| P3 | Document pipeline: Blob registration, extraction/OCR, chunking, embeddings, authorised retrieval | 2026-12-14 | 2027-01-22 | EOB excerpts retrieved with permission checks and page references |
| P4 | Denial analysis & AR recommendations (async, schema-validated, evidence-checked) | 2027-01-25 | 2027-02-26 | Structured recommendation with verified evidence; reviewer feedback saved |
| P5 | Model evaluation on 100–300 de-identified cases; model selection | 2027-03-01 | 2027-03-19 | Signed-off model choice by exact tag and runtime config |
| P6 | React integration in the denial/AR workflow apps | 2027-03-01 | 2027-03-26 | Reviewers can request, read, accept, edit or reject recommendations |
| P7 | Azure deployment & security hardening | 2027-03-29 | 2027-04-23 | Private networking, Key Vault/MI, GPU host, BAA confirmed, pen test closed |
| UAT | User acceptance & go-live readiness | 2027-04-26 | 2027-05-07 | UAT sign-off |
| Go-live | Production release (pilot lab first) | 2027-05-10 | 2027-05-10 | — |

## P1 — Local model comparison (CODEX §19 Tasks A–E)

| ID | Task | Est. | Start | End | Status | Notes |
|---|---|---|---|---|---|---|
| P1-01 | Task A: inspect repo, scaffold `LRN.AI.sln` (net8.0, nullable, implicit usings, dependency direction) | 0.5d | 2026-11-07 | 2026-11-07 | Completed | New `LRN.AI/` folder; `LabMetricsDashboard.sln` untouched |
| P1-02 | Task B: `ILLMProvider` + `OllamaLLMProvider` (`/api/tags`, non-streaming `/api/chat`, timeout / cancellation / error mapping) | 1d | 2026-11-07 | 2026-11-07 | Completed | |
| P1-03 | Task C: comparison use case (validation, installed-tag check, ≤3 concurrent, per-model timing, partial failure) | 1d | 2026-11-07 | 2026-11-07 | Completed | |
| P1-04 | Task D: API wiring (validated options, typed HttpClient, `/models`, `/models/compare`, `/health`, `/health/ollama`, OpenAPI in Dev, ProblemDetails, size limits) | 0.5d | 2026-11-07 | 2026-11-07 | Completed | |
| P1-05 | HIPAA baseline: LRN JWT auth, evaluation-role policy, fail-closed startup, audit events, PHI guard, no-store, rate limit, TLS rule for remote Ollama | 1d | 2026-11-07 | 2026-11-07 | Completed | See HIPAA_SAFEGUARDS.md |
| P1-06 | Task E: unit tests (69), opt-in integration/evaluation tests, README with curl examples | 0.5d | 2026-11-07 | 2026-11-07 | Completed | `dotnet build` 0 warnings; `dotnet test` 69 passed, 3 live tests skipped |
| P1-07 | Install Ollama on the dev machine and pull Qwen, Llama and DeepSeek tags sized for its hardware | 0.5d | 2026-11-09 | 2026-11-09 | Not Started | Ollama was not reachable on this box on 2026-11-07 |
| P1-08 | Verify against live Ollama: run `LRN_AI_OLLAMA_TESTS=1` integration tests and the curl examples with real tags | 0.5d | 2026-11-09 | 2026-11-10 | Not Started | Closes the acceptance criteria that need live Ollama |
| P1-09 | Baseline comparison run (`LRN_AI_EVAL_MODELS`), recording latency, output size and qualitative notes per tag | 1d | 2026-11-10 | 2026-11-11 | Not Started | PHI-free prompt set |
| P1-10 | Issue a token from LabMetricsDashboard and test the API with real auth (non-Development) | 0.5d | 2026-11-12 | 2026-11-12 | Not Started | Confirm audience/issuer values with the dashboard config |
| P1-11 | Phase 1 review and acceptance sign-off | 0.5d | 2026-11-13 | 2026-11-13 | Not Started | |

## P0 — Governance & HIPAA readiness (owners: compliance / security / data)

| ID | Task | Start | End | Status |
|---|---|---|---|---|
| P0-01 | G1 Security risk analysis update for the AI platform and model host | 2026-11-09 | 2026-11-27 | Not Started |
| P0-02 | G2 Data classification and minimum-necessary field list for model context | 2026-11-09 | 2026-11-20 | Not Started |
| P0-03 | G4 Retention/deletion policy for prompts, outputs, extracted text, chunks, embeddings, audit | 2026-11-16 | 2026-12-04 | Not Started |
| P0-04 | G3 De-identification method and approval for the evaluation dataset | 2026-11-16 | 2026-12-11 | Not Started |
| P0-05 | G5 BAA coverage check for the planned Azure services | 2026-11-23 | 2026-12-11 | Not Started |
| P0-06 | G8 Approved model sources; record tag + digest for every evaluated model | 2026-11-09 | 2026-11-13 | Not Started |

## P2 — Hybrid data access, lab authorisation & LRNAI database (2026-11-16 → 2026-12-11)

| ID | Task | Est. | Status |
|---|---|---|---|
| P2-01 | Inspect the LRN.ReportsApi endpoints and lab database schema for claim, denial, CPT and payer facts. Document what is available through the API vs SQL | 2d | Not Started |
| P2-02 | `AuthorisedLabContext` resolver: validate the requested lab against JWT `lab_id` claims or the user's lab list (same rules as `DenialMapperController.AuthorizedLab`) | 2d | Not Started |
| P2-03 | `ILRNClaimApiClient` over existing LRN APIs (typed HttpClient, token forwarding) | 2d | Not Started |
| P2-04 | `IClaimDataRepository`: read-only SQL login, parameterised bounded queries, query timeouts, paging. Keep ClaimID / VisitNumber / CPT / denial code distinct | 4d | Not Started |
| P2-05 | LRNAI database: create `AI_AnalysisRun`, `AI_ModelRegistry`, `AI_PromptVersion` and `AI_Audit` (TDE on, least-privilege login) | 3d | Not Started |
| P2-06 | Replace the log audit sink with an LRNAI audit writer (log sink kept as fallback) | 1d | Not Started |
| P2-07 | `GET` claim-context endpoint for diagnostics (role-restricted, minimum-necessary fields) | 1d | Not Started |
| P2-08 | Tests: lab-scope denial cases, SQL injection attempts, paging bounds, ClaimID ≠ VisitNumber | 3d | Not Started |

## P3 — Document pipeline (2026-12-14 → 2027-01-22, includes the holiday weeks)

| ID | Task | Est. | Status |
|---|---|---|---|
| P3-01 | `POST /documents/ingest`: register a Blob reference (container allow-list, no arbitrary paths), content hash, `AI_Document` | 3d | Not Started |
| P3-02 | Worker job: text extraction (digital PDF) and OCR for scanned EOBs. Store text only per the G4 policy | 5d | Not Started |
| P3-03 | Page-aware chunking into `AI_DocumentChunk` with lab, claim and document permission metadata | 3d | Not Started |
| P3-04 | Embeddings via a local Ollama embedding model. Choose the vector store: SQL vector or Azure AI Search later | 4d | Not Started |
| P3-05 | Authorised retrieval: filter on lab/claim/document permissions **before** ranking (vector search is not an authorisation boundary) | 3d | Not Started |
| P3-06 | Prompt-injection handling: delimit document text, strip instructions, tests with hostile EOB text | 2d | Not Started |
| P3-07 | `GET /documents/{id}` status endpoint and reprocessing job | 2d | Not Started |

## P4 — Denial analysis & AR recommendations (2027-01-25 → 2027-02-26)

| ID | Task | Est. | Status |
|---|---|---|---|
| P4-01 | `POST /denials/analyse` → 202 + analysis id; background execution; `GET /analyses/{id}` | 3d | Not Started |
| P4-02 | Context builder: bounded, structured facts, document excerpts and similar historical cases (minimum necessary) | 4d | Not Started |
| P4-03 | Versioned prompt templates (`AI_PromptVersion`), with each run recording prompt, model and retrieval versions | 2d | Not Started |
| P4-04 | Strict JSON-schema output validation, one retry on schema failure, then fail safely | 3d | Not Started |
| P4-05 | Evidence verification: every cited excerpt must belong to the context retrieved for this run | 2d | Not Started |
| P4-06 | Deterministic business checks: recovery amounts from SQL/C# only; model confidence shown as a band, not a probability | 3d | Not Started |
| P4-07 | `AI_Recommendation`, `AI_RecommendationEvidence`, `POST /recommendations/{id}/feedback` (`AI_ReviewerFeedback`) | 3d | Not Started |
| P4-08 | `POST /ar/recommendations` and `GET /claims/{ref}/recommendations` | 2d | Not Started |

## P5 — Model evaluation (2027-03-01 → 2027-03-19)

| ID | Task | Est. | Status |
|---|---|---|---|
| P5-01 | Build the 100–300 case de-identified dataset (per G3), stored outside source control | 4d | Not Started |
| P5-02 | Evaluation harness: root-cause accuracy, recommendation usefulness, evidence correctness, hallucinations, schema validity, latency, tokens, hardware use | 4d | Not Started |
| P5-03 | Run Qwen / Llama / DeepSeek with identical inputs. Store results by exact tag, digest and runtime config (`AI_ModelEvaluation`) | 3d | Not Started |
| P5-04 | Reviewer scoring session and model selection sign-off | 2d | Not Started |

## P6 — React integration (2027-03-01 → 2027-03-26)

| ID | Task | Est. | Status |
|---|---|---|---|
| P6-01 | AI API client in the denial/AR React apps (existing token, CORS origin configured) | 2d | Not Started |
| P6-02 | "Analyse denial" action with polling, plus recommendation panel showing evidence links and missing documents | 5d | Not Started |
| P6-03 | Accept / edit / reject with reasons → feedback endpoint. Clear "assistive, verify before acting" labelling | 3d | Not Started |
| P6-04 | Role gating and empty/error states (provider down, analysis failed) | 2d | Not Started |

## P7 — Azure deployment & security (2027-03-29 → 2027-04-23)

| ID | Task | Est. | Status |
|---|---|---|---|
| P7-01 | Choose the GPU hosting option (GPU VM, Container Apps GPU or Azure ML endpoint) after checking region quota, pricing and BAA coverage | 3d | Not Started |
| P7-02 | Container images in ACR; App Service / Container Apps for the API and Worker | 3d | Not Started |
| P7-03 | Key Vault (`DenialWorkflowAuth--JwtSigningKey`, connection strings) plus managed identity for SQL, Blob and Key Vault | 2d | Not Started |
| P7-04 | Private endpoints/VNet, TLS-only model endpoint, no public Ollama | 3d | Not Started |
| P7-05 | Application Insights with PHI-safe telemetry (no request/response bodies), plus alerts | 2d | Not Started |
| P7-06 | Security review / pen test of the AI API, then remediation | 4d | Not Started |

## UAT & go-live (2027-04-26 → 2027-05-10)

| ID | Task | Start | End | Status |
|---|---|---|---|---|
| U-01 | UAT with AR reviewers on a pilot lab; defect triage | 2027-04-26 | 2027-05-05 | Not Started |
| U-02 | G6 reviewer training; G7 incident runbook | 2027-04-26 | 2027-05-07 | Not Started |
| U-03 | Go-live on the pilot lab, then rollout lab by lab | 2027-05-10 | 2027-05-10 | Not Started |

## Key dependencies and risks

- **Hardware:** comparing 7–8B models needs about 16 GB RAM (CPU) or an 8 GB+ GPU per loaded model. On CPU only,
  compare at `MaxConcurrency = 1` and expect a minute or more per answer.
- **Schema access (P2-01):** P2 estimates assume read access to a lab database and the ReportsApi source. Unknown
  tables or columns get an interface and a marked integration point, never an invented name.
- **Dataset approval (P0-04 → P5-01):** if de-identification approval slips, P5 slips with it. P6 can continue on
  synthetic data.
- **GPU quota (P7-01):** Azure GPU quota requests can take weeks, so raise them during P5.
