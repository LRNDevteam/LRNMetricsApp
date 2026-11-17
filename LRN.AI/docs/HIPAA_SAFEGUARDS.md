# LRN AI — HIPAA Safeguards Map

How the LRN AI platform addresses the HIPAA Security Rule technical safeguards (45 CFR 164.312), plus the
administrative and organizational items it depends on. **Status** is as of 2026-11-07, the end of Phase 1 build.

This document maps engineering controls. It is not a compliance determination. The privacy/security officer
owns the risk analysis (164.308(a)(1)), policies and sign-off.

## Phase 1 data posture

Phase 1 processes **no PHI**: no claim data, EOBs or patient documents are connected. The compare endpoint takes
free text from evaluation users only, and it rejects prompts that look like they contain identifiers. Models run
in a local Ollama on the same machine, so no data leaves the host and no third-party business associate is
involved.

The controls below are built now so that they are already in place, and tested, when Phase 2 connects live data.

## Technical safeguards (164.312)

| Requirement | Control in LRN AI | Where | Status |
|---|---|---|---|
| **Access control: unique user identification** (a)(2)(i) | Every request is authenticated with the LRN workflow JWT. Tokens without `sub`/`name` are rejected. The user id is carried into every audit event | `Security/LrnJwtValidator.cs`, `LrnJwtAuthenticationHandler.cs` | Done |
| Access control: least privilege | Fallback policy requires an authenticated user on every endpoint. Model endpoints need an `AI:Security:ModelEvaluationRoles` role. No unrestricted prompt endpoint for ordinary users | `Extensions/SecurityServiceCollectionExtensions.cs`, `ModelsController` | Done |
| Access control: lab scope | Validate the requested lab against the token's `lab_id` claims or the user's lab list before any SQL, API, Blob or vector read. The lab database selected through the connection layer is the isolation boundary | Phase 2 `AuthorisedLabContext` resolver | Planned (P2) |
| Access control: emergency access (a)(2)(ii) | Not applicable to an assistive read-only AI service. Workflow systems keep their own procedure | — | N/A |
| Access control: automatic logoff (a)(2)(iii) | Short-lived JWTs (expiry enforced, 1-minute skew). Session lifetime is owned by LabMetricsDashboard | `LrnJwtValidator` | Done (inherits issuer policy) |
| Access control: encryption (a)(2)(iv) | At rest: LRNAI database with TDE, Blob SSE, no PHI in logs. Ollama model files contain no PHI | Phase 2/7 | Planned |
| **Audit controls** (b) | Structured audit event for every list/compare call: user, correlation id, action, outcome, model tags, prompt length, per-model result code and duration. Rejections (validation, likely PHI, not installed) and cancellations are audited too. No prompt or response text | `IAiAuditLogger`, `LoggerAuditLogger` (`LRN.AI.Audit` category) | Done (log sink); LRNAI table in P2 |
| Audit: retention | Define retention for audit records (6-year documentation retention, 164.316(b)(2)), prompts, outputs, extracted text and chunks | Governance G4 | Planned (P0) |
| **Integrity** (c) | Strict request validation. Model output is advisory text in Phase 1. From Phase 4, strict JSON-schema validation of model output, evidence references checked against the context actually retrieved, and amounts calculated only in SQL/C# | `ModelComparisonValidator`; Phase 4 validators | Partial |
| **Person or entity authentication** (d) | HS256 signature checked in constant time, algorithm pinned (`alg: none` and algorithm swaps rejected), issuer, audience, `exp` and `nbf` enforced. Startup fails if the signing key is missing. The Development bypass is refused outside Development and accepts loopback callers only | `LrnJwtValidator`, `AddLrnAiSecurity` | Done |
| **Transmission security** (e) | HSTS + HTTPS redirection outside Development. The Ollama base URL must be loopback or `https`, so a remote model host without TLS fails startup. Azure phase: private endpoints and TLS 1.2+ only | `Program.cs`, `OllamaOptionsValidator` | Done (local); Planned (P7) |

## Additional PHI-handling controls

| Control | Where | Status |
|---|---|---|
| Prompts, system prompts and model output are never written to logs. Ollama error bodies are not read (they can echo input). HttpClient logging is at Warning | `OllamaLLMProvider`, `appsettings.json` | Done |
| De-identified-only guard: prompts that look like they contain SSN, MRN, DOB, MBI, phone or email are rejected without echoing the match. Heuristic only; names and addresses are not detected | `LikelyPhiDetector` | Done |
| `Cache-Control: no-store` on all `/api` responses; `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy: no-referrer`; no `Server` header | `SecurityHeadersMiddleware`, Kestrel | Done |
| Errors return ProblemDetails with a trace id only, never exception text or stacks | `AiExceptionHandler`, `ModelsController` | Done |
| Abuse limits: per-user compare rate limit, 128 KB request body cap, prompt length cap, at most 3 models, per-call timeouts | `AddLrnAiSecurity`, `Program.cs`, `ComparisonOptions`, `OllamaOptions` | Done |
| Secrets: none in source. Local secrets in user-secrets, environment variables or gitignored `appsettings.Local.json`; Key Vault + managed identity in Azure | `.gitignore`, `Program.cs` | Done (local); Planned (P7) |
| Minimum necessary (164.502(b)): only the facts and excerpts an analysis needs go into model context. No full claim history or full documents | Phase 4 context builder | Planned (P4) |
| Prompt-injection defence: document text is treated as untrusted data, delimited, and never allowed to change tools or scope. The model has no SQL, Blob or workflow access | Phase 3/4 | Planned |
| Human review: recommendations are advisory (`RequiresHumanReview`). No automated workflow or financial actions | Architecture rule (CODEX §4.3) | By design |

## Administrative and organizational items (owners outside engineering)

| # | Item | Needed before |
|---|---|---|
| G1 | Security risk analysis update covering the AI platform, the local model host and (later) Azure GPU hosting | Phase 2 live data |
| G2 | Data classification: which claim/denial fields may enter model context. Minimum-necessary rules per analysis type | Phase 2 |
| G3 | De-identification method for the 100–300 case evaluation dataset (Safe Harbor or Expert Determination) and approval to use it | Phase 5 |
| G4 | Retention and deletion policy for prompts, outputs, extracted text, chunks, embeddings and audit records | Phase 2 |
| G5 | Confirm the Microsoft BAA covers every Azure service used (App Service / Container Apps, Azure SQL, Blob, AI Search, Key Vault, Azure ML if used). No model or API provider without a BAA may receive PHI | Phase 7 |
| G6 | Workforce access review and training for AI reviewers (assistive output, verify the evidence) | UAT |
| G7 | Incident response / breach notification runbook updated for AI data flows | Go-live |
| G8 | Model supply chain: pull models only from approved sources, record exact tag and digest, and re-evaluate on upgrade | Phase 5 |
