# Agentic AI for Denial Management — Development Plan & Budget Request

**Prepared for:** Engineering Management
**Prepared by:** Development Team (Lab Revenue Navigator / DWMS)
**Date:** 12 August 2026
**Version:** 2.0
**Status:** Proposal — decisions requested in §11

**Related documents**
- *Denial Dashboard & Denial Workflow — Requirements and Specification*, Rev 2.0 (11 Aug 2026) — [`Denial_Dashboard_Workflow_Requirements_v2.0.pdf`](Denial_Dashboard_Workflow_Requirements_v2.0.pdf)
- *Agentic AI Implementation Guideline — Python & .NET* (10 Aug 2026) — [`Agentic_AI_Implementation_Guideline_v1.0.docx`](Agentic_AI_Implementation_Guideline_v1.0.docx)
- *Denial Database Screens* — [`Denial_Dashboard_Screens_Captures.docx`](Denial_Dashboard_Screens_Captures.docx) (screenshots), [`Denial_Dashboard_Screens_Mockup_v2.0.html`](Denial_Dashboard_Screens_Mockup_v2.0.html) (mockup)
- *Denial Agent UI mockup* — [`Denial_Agent_Mockup_v1.0.html`](Denial_Agent_Mockup_v1.0.html)

**Supersedes** (in [`archive/`](../archive/)): *Manager Review — Development Plan, Architecture, Technology and Cost* (both the plain and PHI/Security revisions) and the original *Python AI-Assisted AR Denial Management Proposal*. §10 of this document carries forward the PHI/Security material from the PHI/Security revision.

---

## 1. Executive summary

We are proposing an AI agent that sits **on top of** the existing Denial Workflow, not beside it. The agent reads a denial that the existing pipeline has already produced, retrieves the relevant payer policy and supporting documents, and returns a **structured recommendation** — appeal, rebill, write-off, or escalate — with a cited reason. A human approves or overrides it. Deterministic code, not the model, decides anything with a legal or financial consequence: filing deadlines, duplicate-submission guards, dollar thresholds, and the final submission.

Three things are worth stating up front, because they shape the whole plan:

1. **The largest part of this project is not AI work.** Roughly 60% of the effort is ordinary .NET engineering — a tool layer, new tables, an approval UI, and an audit trail. That work is testable without a model and is where the risk actually lives.
2. **We should not build two orchestrators.** The two source proposals imply one agent in Python and one in .NET. We recommend a single .NET agent host that consumes a Python retrieval/extraction service over MCP. Rationale and the exact split are in §4.
3. **The infrastructure cost is small; the governance cost is not.** Azure spend for a pilot lands in the **$300–$700/month** range (§8). What needs management attention is the HIPAA BAA, PHI minimisation, and who is allowed to approve a machine-recommended write-off.

**Proposed timeline:** first demonstrable value (shadow-mode recommendations measured against human decisions) at **~10–12 weeks**; first controlled production submission at **~24–28 weeks**.

---

## 2. Where the agent plugs into what we already have

The existing estate, per the Rev 2.0 specification:

| Component | Role today | Change required |
|---|---|---|
| `LRN.DenialDatabaseWorker` | Turns `PayerValidationReport` into `DenialLineItem` / `DenialTaskBoard` / `DenialInsight` | None in Phases 0–4. Optionally emits a queue message when a run completes. |
| `LabMetricsDashboard` | Denial Dashboard + Denial Workflow UI | **New tab** — AI Recommendations; new columns on Task Board |
| `LRN.ReportsApi` | Reads/writes denial tables over direct SQL | New endpoints, or a sibling API (§5.3) |
| `LRN.ReportWorker` | Queued exports | Unchanged |
| `DenialTaskHistory` | Audit of every workflow action | **Extended** with actor type + agent run id |
| *New* `LRN.DenialAgent.*` | — | The agent host, tools, and approval service |

**The agent's input is a `DenialTaskBoard` row.** The agent's output is a recommendation record plus, on approval, exactly the same writes a human reviewer would have made. This is deliberate: it means the agent inherits the existing role model, the existing audit trail, and the existing claim-level propagation rules (`DenialActionCategoryMaster.ActionScope`) without us re-implementing any of them.

### 2.1 Three pre-existing defects that must be closed first

These are already logged in the specification as open items. An agent built on top of them will silently inherit them and will be blamed for them:

- **Spec §11.1 — verification table naming.** The worker writes to `dbo.DenialVerification`; the API and dashboard read `dbo.DenialVerificationTask`. Pipeline-raised verifications may never surface. The agent's escalation path would land in the same hole.
- **Spec §11.2 — empty task board for some labs (NorthWest).** If `DenialTaskBoard` is empty for a lab, the agent has no input at all and will report "nothing to do" rather than failing.
- **Spec §11.3 — unmapped labs on the Report Control Board.** Blocks per-lab enablement and the kill switch.

**Recommendation: treat these as Phase 0 blockers.** They are small fixes and they are prerequisites, not nice-to-haves.

---

## 3. What the agent is, and is not, allowed to decide

This table is the single most important design artifact in the proposal. It is what makes the system auditable and defensible.

| Decision | Owner | Why |
|---|---|---|
| Is this denial valid? | **Deterministic rules** (existing Denial–Action Classifier) | Already encoded, already tested, must be reproducible |
| Which action category applies? | **Deterministic rules** | Same |
| Timely-filing deadline | **Deterministic code** | Date arithmetic with legal consequence. A model must never compute this. |
| Has this claim already been appealed? | **Deterministic guard** | Duplicate submission is a payer-relationship and compliance risk |
| Which policy clause supports the action? | **Agent** (retrieval), verified against the returned citation | Retrieval + judgement; but the citation is checked before use |
| Does the AR note change the picture? | **Agent** | Unstructured text — this is genuinely where a model earns its place |
| Appeal letter wording | **Agent** (draft only) | Drafting, always human-reviewed |
| Which action to take | **Agent proposes, code constrains, human approves** | Agent may only propose an action the classification supports |
| Submit to payer / clearinghouse | **Human approval + deterministic code** | Never the agent directly |
| Write-off above threshold | **Manager approval, always** | Financial control |

**Design rule for the whole build:** *if the answer can be derived by a rule, it must be derived by a rule.* The model is used for retrieval, reading unstructured text, and drafting — nothing else.

---

## 4. Python and .NET — recommended split

Both source documents propose building in both languages. Microsoft Agent Framework reached 1.0 GA on 2–3 April 2026 with genuinely equivalent .NET and Python surfaces, so either would work. Building the *same* thing twice would not.

**Recommended boundary:**

| Layer | Language | Reasoning |
|---|---|---|
| Agent host, orchestration, tool definitions | **.NET** | The entire estate is ASP.NET MVC + SQL Server. Keeping the agent in-process with the domain code means no duplicate business logic, no second deployment story, and the existing team can review it. |
| Deterministic rule engine, deadline calc, duplicate guard | **.NET** | Must live next to the data it validates |
| Approval UI + audit | **.NET** | Extends `LabMetricsDashboard` directly |
| PMS / clearinghouse client | **.NET** | Owns transactions and retry semantics |
| Payer-policy ingestion, chunking, embedding, index build | **Python** | Best library ecosystem; the indexing job is a batch pipeline, not a request path |
| Medical-record extraction (Document Intelligence post-processing) | **Python** | Same |
| Evaluation harness, golden-set scoring, prompt regression tests | **Python** | Data-science workflow, iterated by a different cadence than the app |

**The seam is MCP.** The Python side is packaged as one **MCP server** exposing two tools — `search_payer_policy` and `extract_document_fields`. The .NET agent registers it as an MCP tool. MAF 1.0 supports MCP natively on both runtimes, and A2A is available later if we ever want a Python agent to participate as a peer.

**Why this is better than "both teams build an agent":** one system of record for a decision, one audit trail, one place a defect can be. The Python developers still own a real, independently deployable service.

**Correction to the existing guideline document:** it instructs `dotnet add package Microsoft.Agents.AI.Foundry --prerelease`. Since the April 2026 GA, the stable packages ship under `Microsoft.Agents.AI` without the prerelease flag (.NET releases were at 1.16/1.17 by July 2026). Package names and versions should be re-confirmed at build time.

---

## 5. What is needed from the .NET side

This section is the concrete engineering ask.

### 5.1 New solution structure

```
LRN.DenialAgent.sln
├─ LRN.DenialAgent.Core        (class lib)  agent definition, prompts, tool contracts
├─ LRN.DenialAgent.Tools       (class lib)  the deterministic functions the agent may call
├─ LRN.DenialAgent.Data        (class lib)  EF/Dapper access to the new agent tables
├─ LRN.DenialAgent.Api         (ASP.NET)    minimal API consumed by LabMetricsDashboard
├─ LRN.DenialAgent.Worker      (worker svc) batch/queued analysis, same host pattern as
│                                            LRN.DenialDatabaseWorker
└─ LRN.DenialAgent.Tests       (xUnit)      tool tests + golden-set harness
```

**Runtime:** .NET 8 LTS minimum; .NET 10 preferred if the hosting estate supports it (MAF's own repo builds on the .NET 10 SDK).

**Packages:** `Microsoft.Agents.AI`, `Microsoft.Agents.AI.Workflows` (Phase 6), `Azure.AI.Projects`, `Azure.Identity`, `ModelContextProtocol` client, `Azure.Monitor.OpenTelemetry.Exporter`, `Azure.Security.KeyVault.Secrets`.

### 5.2 The tool layer — ten deterministic C# functions

Each is an ordinary, unit-testable method. The agent may call them; it cannot bypass them.

| # | Tool | Approval | Notes |
|---|---|---|---|
| 1 | `GetDenialContext(claimId, cpt, denialCode)` | No | Reads `DenialLineItem` + `DenialTaskBoard`. **Must normalise the `CLM` prefix** and join on claim + CPT + denial code — the two tables share no surrogate key (spec §3.1). Keyed by `UniqueTrackId`. |
| 2 | `GetDenialClassification(denialCode, coverageStatus, icdComplianceStatus)` | No | The existing Denial–Action Classifier, lifted into a pure function. **No LLM.** |
| 3 | `GetPayerPolicy(payerId, cptCode, denialCode)` | No | Proxies to the Python MCP server. Returns text **plus document id, version, effective date, page**. A recommendation with no citation is rejected. |
| 4 | `GetTimelyFilingDeadline(payerId, denialDate, firstBilledDate)` | No | Per-payer table + date arithmetic. Returns days remaining and a hard `IsExpired` flag. |
| 5 | `GetRequiredDocuments(actionCode, payerId)` | No | Checklist lookup |
| 6 | `CheckDuplicateSubmission(uniqueTrackId)` | No | Blocks a second appeal on the same track id |
| 7 | `DraftAppealLetter(claimId, reason, citations)` | **Required** | Renders our template; returns draft only |
| 8 | `RebillClaim(claimId, primaryIcd)` | **Required** | PMS write |
| 9 | `WriteOffClaim(claimId, amount)` | **Required + manager above threshold** | Financial control |
| 10 | `EscalateToHuman(taskId, reason)` | No | The agent's only unconstrained exit. Should be cheap for it to choose. |

Tools 7–9 are wrapped in `ApprovalRequiredAIFunction` so the agent pauses and returns an approval request rather than executing. **This wrapping must not be removable by configuration** in Phases 0–5.

### 5.3 API surface

Hosted in `LRN.DenialAgent.Api`, called by `LabMetricsDashboard`.

| Endpoint | Method | Role |
|---|---|---|
| `/agent/analyze` | POST | System / AR Manager — queue one denial or a batch |
| `/agent/recommendations` | GET | Admin, AR Manager, AR Reviewer (own only) |
| `/agent/recommendations/{id}/approve` | POST | AR Reviewer or Admin; **Manager for write-off > threshold** |
| `/agent/recommendations/{id}/reject` | POST | Same, **reason mandatory** |
| `/agent/recommendations/{id}/modify` | POST | Approve with an edited payload — captures the correction |
| `/agent/runs/{id}/trace` | GET | Admin — full tool-call trace for audit |
| `/agent/health` | GET | Ops |

**Auth note carried from the spec (§2):** the API mints its JWT from the signed-in `HttpContext`. The agent worker has no such context and must reach the data by direct SQL under a managed identity, exactly as `LRN.DenialDatabaseWorker` does today. Both paths must return the same rows; this is the same trap described in spec §11.2 and needs an integration test.

### 5.4 New database objects

All in the lab database, alongside the existing denial tables, scoped by `LabId` + `RunId`.

| Table | Grain | Purpose |
|---|---|---|
| `DenialAgentRun` | One per agent invocation | Model name, prompt version, started/ended, status, tokens in/out, estimated cost, OpenTelemetry trace id |
| `DenialAgentRecommendation` | One per denial analysed | `UniqueTrackId`, proposed action code, confidence, rationale text, proposed payload JSON, deadline days remaining |
| `DenialAgentCitation` | One per policy source cited | Document id, version, effective date, page/section, excerpt hash |
| `DenialAgentToolCall` | One per tool invocation | Tool name, argument hash, duration, outcome, error |
| `DenialAgentApproval` | One per human decision | Approver id, decision, decision time, override reason, final action code |
| `DenialAgentPromptVersion` | Reference | Versioned instructions so any run can be replayed |
| `DenialAgentConfig` | Per lab | Enabled flag, shadow-mode flag, confidence threshold, write-off dollar cap, kill switch |

**Extension to an existing table:** add `ActorType` (`Human` \| `Agent`) and `AgentRunId` to `DenialTaskHistory`. This keeps one audit trail rather than two, and means an auditor asking "who changed this task" gets one answer.

### 5.5 UI changes (LabMetricsDashboard → Denial Workflow)

New tab: **AI Recommendations**, visible to Admin, AR Manager, AR Reviewer (reviewers see only their own, consistent with spec §8).

Per row:
- Claim / CPT / denial code / payer / balance
- **Recommended action** and confidence
- **Rationale**, two or three sentences
- **Policy citation**, expandable, with document name, version and effective date
- **Days to timely-filing deadline**, red when under a configurable threshold
- **Proposed payload**, shown as a diff against the current task state
- Buttons: **Approve** · **Modify & Approve** · **Reject** · **Escalate**
- Reject and Modify require a reason from a short structured list plus free text

Also required:
- Bulk approve, gated to recommendations above the confidence threshold **and** under the dollar cap
- An "Agent" column on the existing Task Board grid so a reviewer can see at a glance which tasks have a pending recommendation
- A visible per-lab **kill switch** for Admin

**Override reasons are the deliverable, not an afterthought.** They are the only structured signal we get about where the agent is wrong, and they are what Phase 6 tuning consumes.

### 5.6 Configuration, security and operations

- Foundry endpoint, model deployment name, PMS credentials → **Azure Key Vault**, referenced via **Managed Identity**. `AzureCliCredential` is for local development only.
- `SqlCommandTimeoutSeconds` parity with the existing worker (600 s) — the 30 s ADO.NET default is far too short for whole-run reads on a large lab.
- OpenTelemetry tracing (built into MAF) → Application Insights. Every agent run, tool call and approval decision must be traceable.
- Per-lab enablement so we can pilot on one lab and roll forward.

### 5.7 PHI handling — needs a decision before Phase 3

- Confirm the **Microsoft BAA** covers the Azure OpenAI / Foundry resources in the chosen region.
- Request the **abuse-monitoring / human-review opt-out** (a Microsoft form) so prompts containing PHI are not retained for human inspection.
- **Minimise PHI in prompts.** The agent needs claim id, CPT, denial code, payer, dates, coverage status, ICD compliance status, and AR note text. It does **not** need patient name, DOB, address, or MRN. Build a redaction step in the tool layer and test it.
- Log prompt/response **hashes plus token counts** by default; store full text only in the audit table, encrypted, with a retention policy.

---

## 6. Development phases

Each phase has a hard exit gate. We do not start the next phase until the gate is met.

### Phase 0 — Foundation & access · *2 weeks · .NET + Infra*

Azure subscription and BAA confirmed. Foundry project created, one chat model deployed. Key Vault, managed identities, networking. Repo scaffolding for both solutions. **Close the three pre-existing defects in §2.1.**

**Exit gate:** a "hello world" agent call succeeds from both .NET and Python against a de-identified test denial, and the three spec open items are closed.

### Phase 1 — Deterministic tool layer & data model · *3–4 weeks · .NET*

Tools 1, 2, 4, 5, 6, 10 built and unit-tested. New tables created and migrated. `DenialTaskHistory` extended. API skeleton with role gates. **No model involved anywhere in this phase.**

**Exit gate:** every tool is callable and unit-tested with no LLM in the loop; the classifier reproduces the current manual classification on 100 historical denials **exactly**.

*This phase is the one to protect from being compressed. If the classifier is not deterministic and correct here, nothing downstream can be trusted.*

### Phase 2 — Knowledge base & retrieval · *3 weeks · Python*

Payer-policy corpus ingested, chunked, embedded, indexed in Azure AI Search with document version and effective date as filterable metadata. Document Intelligence pipeline for medical records. Both wrapped as an MCP server. Retrieval evaluation set built.

**Exit gate:** 20 seeded policy questions return the correct clause with a correct citation. Policy retrieval returns **only** currently-effective versions.

### Phase 3 — Single agent, shadow mode · *3–4 weeks · .NET + Python*

MAF agent in .NET, wired to the Phase 1 tools and the Phase 2 MCP server. Recommendations written to `DenialAgentRecommendation`. **Nothing is executed and nothing is shown to reviewers yet.** Golden set of 100 historical denials with known human outcomes.

**Exit gate:** agreement with the human decision on the golden set meets an agreed target (we suggest **≥ 85%** on action category), **zero** recommendations unsupported by the classification, **zero** recommendations without a citation, and no deadline ever computed by the model.

**This is the go/no-go point.** If agreement is poor, the answer is usually better rules or better retrieval, not a bigger model.

### Phase 4 — Human-in-the-loop in the product · *3–4 weeks · .NET*

The AI Recommendations tab. Approval endpoints, transactional writes, `ApprovalRequiredAIFunction` wiring, override capture. On approval the agent writes **only to DWMS** — status, notes, assignment. **No external submission yet.**

**Exit gate:** one pilot lab uses the tab for two weeks. Override rate and reason distribution reported. Every approval has a matching `DenialTaskHistory` row with `ActorType = Agent`.

### Phase 5 — Execution: appeals, rebills, submissions · *4–6 weeks · .NET*

PMS / clearinghouse client. Appeal letter rendering and document assembly. Submission runs against a **mock API first**, then a sandbox, then controlled production with per-action human approval. Confirmations stored; payer responses monitored.

**Exit gate:** an agreed number of approved appeals submitted end-to-end with confirmations stored, and a reconciliation report showing every submission traceable to an approver.

### Phase 6 — Workflow orchestration, scale, selective autonomy · *4+ weeks · .NET*

Replace the free-form agent loop with an explicit MAF `WorkflowBuilder` graph — Ingest → Classify → Approve → Execute → Update → Log — with checkpointing so a case waiting on approval survives a restart. Split into specialised agents if warranted (classifier / appeal-writer / QA reviewer). Batch processing. **Then, and only then**, consider narrow autonomy: specific low-risk denial categories, under a dollar cap, with sampled human audit.

**Exit gate:** a case can be paused for 48 hours awaiting approval and resume correctly after a service restart.

### Timeline summary

| Phase | Weeks | Cumulative | Primary owner |
|---|---|---|---|
| 0 — Foundation | 2 | 2 | Infra + .NET |
| 1 — Tool layer | 3–4 | 6 | .NET |
| 2 — Retrieval | 3 | 9 *(runs partly parallel to 1)* | Python |
| 3 — Shadow agent | 3–4 | 12 | .NET + Python |
| 4 — HITL approval | 3–4 | 16 | .NET |
| 5 — Execution | 4–6 | 22 | .NET |
| 6 — Orchestration | 4+ | 26+ | .NET |

**Team:** 1 senior .NET, 1 mid .NET, 1 Python/ML engineer, 0.5 SQL/data engineer, 0.5 QA. Plus — and this is not optional — **4–6 hours per week of a senior AR analyst's time** for the golden set, the classifier review, and the override analysis. Every failed project of this shape fails here.

---

## 7. Technology selections

| Concern | Selection | Alternative considered |
|---|---|---|
| Agent SDK | **Microsoft Agent Framework 1.0** (.NET primary, Python for tools) | Semantic Kernel — now the foundation layer under MAF; AutoGen — maintenance mode. LangGraph would fragment the stack. |
| Agent hosting | **Foundry Agent Service** — no additional platform charge; also supports hosted agents built on MAF | Self-host in Container Apps — viable, more ops work |
| Model | **GPT-5 class** for reasoning; a **small/nano model** for cheap classification and triage | GPT-5.5 if quality demands it — roughly 4× the input cost |
| Policy retrieval | **Azure AI Search** (vector + semantic hybrid) | pgvector / self-hosted — cheaper, more to run |
| Document extraction | **Azure Document Intelligence** — Layout or prebuilt models | Custom extraction only if our forms are non-standard; it is materially more expensive |
| Tool interop | **MCP** between .NET agent and Python services | Plain REST — fine, but loses native discovery |
| Queueing | **Azure Service Bus**, or reuse the existing `dbo.UserReqReports` pattern | Reusing the existing pattern is faster for Phase 4 |
| Secrets | **Key Vault + Managed Identity** | — |
| Observability | **OpenTelemetry → Application Insights** | — |
| Long-running approval waits | **MAF Workflow checkpointing**, or Durable Functions | — |

**On model choice:** MAF 1.0 supports six providers with a one-line swap (Azure OpenAI, OpenAI, Anthropic, Bedrock, Gemini, Ollama). We should exploit that — pick one for Phase 3, and re-benchmark against the golden set before Phase 5 rather than committing early.

---

## 8. Cost and subscriptions

> All rates are US-East list prices gathered in **August 2026** from public Microsoft and third-party pricing sources. They are for **budget scoping, not a quote** — confirm every line in the Azure Pricing Calculator before committing.

### 8.1 Platform and per-unit rates

| Service | Rate | Note |
|---|---|---|
| **Foundry Agent Service** | **No additional charge** | You pay for the model tokens and the tools the agent invokes |
| **GPT-5** (Global Standard) | ~$1.25 / M input · ~$10.00 / M output | Cached input roughly $0.13 / M — worth designing for |
| **GPT-5-nano** | ~$0.05 / M input · ~$0.40 / M output | For triage / classification assist |
| **GPT-5.5** | ~$5 / M input · ~$30 / M output | Only if Phase 3 quality requires it |
| **Batch (async)** | ~50% off standard | Good fit for overnight bulk analysis |
| **Azure AI Search — Basic** | ~$75 / month | Adequate for POC and a single-lab pilot |
| **Azure AI Search — Standard S1** | ~$250 / month | Realistic production tier |
| **Document Intelligence — Read (OCR)** | ~$1.50 / 1,000 pages | Plain text extraction |
| **Document Intelligence — Layout / prebuilt** | ~$10 / 1,000 pages | Structure-aware; the usual choice |
| **Document Intelligence — custom extraction** | ~$30–50 / 1,000 pages | Sources vary; verify. Training is free. |
| **Document Intelligence — free tier** | 500 pages / month | Enough for development |
| **Blob Storage** | ~$0.02 / GB / month | Negligible |
| **Service Bus, Key Vault** | ~$10–15 / month combined | |
| **Container Apps / Functions** | ~$50–200 / month | Depends on always-on vs consumption |
| **Application Insights** | Per-GB ingestion | Budget $50–150; verify current per-GB rate |
| **Azure SQL** | Existing | No new spend if we use the lab databases |

**Provisioned Throughput Units (PTUs)** start around $2,448/month and only break even at very high sustained volume. **We do not need them.** Stay on pay-as-you-go.

### 8.2 Worked monthly estimate

*Assumptions — please correct these, they drive everything:* 5,000 denials analysed per month; ~8,000 input and ~2,000 output tokens per denial including a verification pass; 15% require document extraction (~3,000 pages/month); policy corpus of ~2,000 documents.

| Line | POC (Phases 0–3) | Pilot (Phases 4–5) | Production (one lab, steady) |
|---|---|---|---|
| Model tokens | $50–150 | $150–300 | $250–400 |
| Azure AI Search | $75 (Basic) | $75 (Basic) | $250 (S1) |
| Document Intelligence | $0 (free tier) | $30 | $30–60 |
| Compute (Container Apps / Functions) | $50 | $100 | $150–200 |
| Storage, Service Bus, Key Vault | $15 | $20 | $25 |
| Application Insights | $50 | $75 | $100–150 |
| **Estimated monthly total** | **~$240–340** | **~$450–600** | **~$800–1,100** |

Sensitivity: token spend scales linearly with volume, so 20,000 denials/month roughly quadruples that one line — to ~$1,000–1,600 — while everything else stays flat. Even then, **the Azure bill is not the expensive part of this project; the engineering time is.**

### 8.3 Subscriptions and licences to request

| Item | Why | Notes |
|---|---|---|
| **Azure subscription** with Foundry access | Required | Request a budget of ~$1,000/month with alerts at 50/80/100% |
| **Microsoft BAA** covering the Azure AI resources | HIPAA — **hard blocker** | Must be in place before any real PHI is sent |
| **Abuse-monitoring opt-out** | Prevents PHI retention for human review | Separate Microsoft request; allow lead time |
| **Azure Dev/Test subscription** | Cheaper non-prod rates | Optional but recommended |
| Visual Studio subscriptions | If not already held | Confirm current per-seat rate |
| GitHub Copilot Business (per developer) | Optional productivity | Confirm current per-seat rate |
| PMS / clearinghouse **sandbox credentials** | **Phase 5 blocker** | Request now — vendor lead times are the usual schedule risk |

### 8.4 Cost controls to build in from day one

- Azure Budget scoped to the AI resource group, alerts at 50 / 80 / 100%
- Per-lab and per-day token caps enforced in `LRN.DenialAgent.Worker`
- Prompt caching for the stable portion of the system prompt and classifier context
- Small model for triage, large model only for the cases that need it
- Batch API for overnight bulk analysis
- Token counts and estimated cost recorded per run in `DenialAgentRun`, so cost per denial is a reportable metric, not a surprise on the invoice

---

## 9. Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Agent inherits the spec §11.1 / §11.2 / §11.3 pipeline defects | High | High | Close them in Phase 0 |
| Model computes or reasons about a filing deadline | Medium | **Severe** — missed appeal window | Deadline is deterministic code; agent receives it as an input, never derives it |
| Payer policy corpus goes stale | High | High | Version + effective-date metadata; retrieval filters to current versions; quarterly refresh owned by a named person |
| Duplicate appeal submitted | Medium | High | `CheckDuplicateSubmission` guard on `UniqueTrackId`, enforced before any submission |
| PHI sent to a model without a BAA | Low | **Severe** | Phase 0 gate; redaction in the tool layer; integration test |
| Automation bias — reviewers rubber-stamp | **High** | High | Confidence display, mandatory reason on reject/modify, sampled audit of approvals, override rate as a tracked metric |
| Golden-set agreement below target at Phase 3 | Medium | Medium | It is a gate, not a surprise. Response is better rules and retrieval, not a bigger model. |
| Model or SDK churn | High | Low | MAF 1.0 has an LTS commitment and one-line provider swap; pin versions, re-benchmark before Phase 5 |
| PMS has no usable API | Medium | High | Confirm in Phase 0. UI automation is a genuine last resort — brittle and higher-risk. |
| AR SME time not allocated | **High** | **High** | Named person, booked hours, in the plan from Phase 1 |

### Success metrics (baseline these before Phase 3)

- Recommendation agreement rate vs human decision on the golden set
- Human override rate in production, and the reason distribution
- Cycle time per denial, agent-assisted vs manual
- Appeal overturn rate, agent-recommended vs manual
- Cost per denial analysed
- Zero tolerance: unsupported actions, uncited recommendations, model-derived deadlines

---

## 10. PHI, privacy and security gate

> Carried forward from *Manager Review — Development Plan, Architecture, Technology and Cost* (PHI/Security revision, 12 Aug 2026), now retired to [`archive/`](../archive/). This section is the authoritative version.

The Denial Workflow carries claim, AR-note and medical-record content. **Real PHI must not enter the AI environment until Security, Privacy/Compliance and Legal have approved the specific architecture, Azure services, model deployments, regions, contracts and operational controls.** That approval is a formal project gate, not a task inside a phase.

Using Azure or Microsoft Foundry does not by itself make the application compliant. Compliance depends on which services are selected, how they are configured, what the contracts cover, how data flows, and what organisational controls exist around them.

**Recommendation:** continue architecture and development on synthetic or de-identified data, and make real-PHI access a gate that sits between Phase 2 and Phase 3.

### 10.1 Where the gate sits

| Stage | Data | Gate to clear |
|---|---|---|
| Phase 0 | No production PHI | Architecture, data classification, PHI/PII assessment, security review |
| Phase 1 | Synthetic / de-identified | Deterministic tools; regression pass |
| Phase 2 | Synthetic / de-identified | AI POC, no live claim execution; AI evaluation pass |
| **PHI Gate** | **Controlled PHI** | **Written Security / Privacy / Legal approval, plus confirmation that the chosen services and contracts cover the workload** |
| Phase 3 | Approved PHI | Shadow processing with human AR decisions; human-comparison pass |
| Phase 4 | Approved PHI | Agent workflow; safety + audit pass |
| Phase 5+ | Approved PHI | Controlled production automation, after business approval |

### 10.2 PHI-safe architecture

The agent must not hold unrestricted database access or direct PMS write permissions. PHI is minimised *before* it reaches a prompt, a retrieval index, or any model call:

```text
Denial Workflow
   → ASP.NET Core gateway
   → PHI minimisation / redaction
   → authorised context tools  →  AI agent  →  policy / evidence retrieval
   → deterministic validation
   → human approval
   → PMS / clearinghouse
   → immutable audit
```

**Security rule:** the model selects from approved tools; it cannot self-authorise. Tool permissions, parameters, approval requirements and financial thresholds are enforced in application code — the same principle as §3, applied to data access rather than to decisions.

### 10.3 Data minimisation rules

| Area | Rule |
|---|---|
| Prefer sending | Claim ID, CPT, denial code, payer, service dates, coverage status, ICD compliance status, and only the relevant AR note text |
| Avoid unless required | Patient name, DOB, address, medical record number, unrelated demographics |
| Medical documents | Document-level authorisation; process only the pages or sections the denial actually needs |
| Prompts | A minimisation/redaction step, implemented **and tested** — not a convention |
| Logs | Never write raw prompts, medical records or incidental PHI to telemetry |
| Model training | Production PHI is excluded from training and fine-tuning unless separately approved |
| Retention | Defined retention and deletion rules for prompts, outputs, documents, embeddings and audit records |

### 10.4 Confirmation checklist (all items before the PHI gate opens)

- [ ] Security approves the Azure architecture, identity, network and access controls
- [ ] Privacy/Compliance confirms the applicable regime — Singapore PDPA, US healthcare requirements, or both
- [ ] Legal confirms Microsoft contractual/privacy terms and any required BAA/DPA coverage
- [ ] Selected Azure AI / Foundry services, model deployments and region are approved for the intended PHI workload
- [ ] Data-residency requirements confirmed
- [ ] Microsoft abuse-monitoring / human-review controls reviewed, and any required opt-out requests submitted
- [ ] Production PHI excluded from developer laptops, local model calls, and uncontrolled Dev/Test environments
- [ ] Entra ID, managed identity, RBAC and server-side authorisation enabled
- [ ] Secrets and PMS credentials in Key Vault
- [ ] Application Insights / OpenTelemetry configured so PHI cannot leak into traces
- [ ] Every AI run, tool call, approval, rejection, override and execution is auditable
- [ ] Per-lab enablement, shadow mode and kill switch all available
- [ ] PHI incident/breach response owner and procedure defined

### 10.5 Go / no-go rule

- **NO-GO for real PHI** while service coverage, security architecture, data residency, retention, access control or the required contractual/privacy approvals are unresolved.
- **GO for the PHI shadow pilot** only after written approval, with minimisation, auditability, access control and monitoring verified.
- **GO for live execution** only after the shadow accuracy and safety thresholds in §6 are met *and* the business has approved the human-in-the-loop execution model.

---

## 11. Decisions requested

1. **Approve the .NET-primary / Python-for-tools split** (§4), or direct otherwise.
2. **Approve closing the three pipeline defects (§2.1) as Phase 0 work** before agent development starts.
3. **Confirm the HIPAA BAA path** and who owns the abuse-monitoring opt-out request.
4. **Name the pilot lab** and confirm its data is clean (i.e. not NorthWest until spec §11.2 is resolved).
5. **Name the AR subject-matter expert** and confirm 4–6 hours per week from Phase 1.
6. **Set the Phase 3 go/no-go threshold** — we propose ≥ 85% agreement on action category.
7. **Set the write-off dollar threshold** above which manager approval is mandatory.
8. **Decide who approves an agent recommendation.** The current model separates assignment (manager) from status change (reviewer). We propose: reviewer approves action recommendations; manager approves write-offs above threshold. This needs an explicit ruling.
9. **Approve an Azure budget** of ~$1,000/month with alerting, and authorise the Dev/Test subscription.
10. **Authorise the PMS / clearinghouse sandbox credential request now** — it is the most likely thing to delay Phase 5.
11. **Confirm the volume assumptions in §8.2** (denials per month, document pages per month), which drive the entire cost model.

### Additional decisions for the PHI gate (§10)

12. **Nominate the Security / Privacy / Compliance owner** for the PHI gate. Without a named owner the gate has no one to open it.
13. **Confirm the regulatory scope** — US-regulated healthcare data, Singapore personal data (PDPA), or both. This decides which contractual path applies and is a prerequisite for decision 3.
14. **Approve the initial Azure region and data-residency requirements.**
15. **Approve the PHI minimisation / redaction and document-processing approach** (§10.2, §10.3).
16. **Approve who may access PHI** in Dev, Test, Shadow and Production.
17. **Approve retention periods** for AI inputs, outputs, documents and audit records.
18. **Confirm the Microsoft service privacy / abuse-monitoring review process** where PHI is involved.
19. **Confirm that claim-changing actions remain behind human approval** for the whole pilot.

---

## Appendix A — End-to-end flow (target state, Phase 5)

```
Denial run completes (LRN.DenialDatabaseWorker)
        ↓
Queue message per eligible DenialTaskBoard row
        ↓
LRN.DenialAgent.Worker picks it up
        ↓
Tool 1: GetDenialContext      — normalise CLM prefix, resolve UniqueTrackId
Tool 2: GetDenialClassification — DETERMINISTIC. Action code + category.
Tool 4: GetTimelyFilingDeadline — DETERMINISTIC. Expired → escalate, stop.
Tool 6: CheckDuplicateSubmission — already appealed → escalate, stop.
        ↓
Agent reads AR notes + denial context
Tool 3: GetPayerPolicy (via Python MCP server) — returns clause + citation
        ↓
[if documents required] Document Intelligence extraction via MCP
        ↓
Agent returns a STRUCTURED RECOMMENDATION
        ↓
Deterministic validation:
  · action must be supported by the classification (Tool 2)
  · citation must be present and currently effective
  · deadline must be in the future
  · amount must be within the configured cap
        ↓  fails any check → escalate to human, stop
        ↓
Write DenialAgentRecommendation + DenialAgentCitation + DenialAgentToolCall
        ↓
Surface in the AI Recommendations tab
        ↓
   { Human decision }
     ├─ Reject  → reason captured → task returns to the normal queue
     ├─ Modify  → corrected payload captured → proceed
     └─ Approve → proceed
        ↓
Single transaction:
  · DenialTaskBoard updated (respecting ActionScope claim-level propagation)
  · DenialTaskHistory row, ActorType = Agent, AgentRunId set
  · DenialAgentApproval row
        ↓
[Appeal or Rebill] → PMS / clearinghouse submission
        ↓
Store confirmation · monitor payer response · close or schedule follow-up
```

## Appendix B — Phase 0 checklist

- [ ] Azure subscription provisioned, budget + alerts configured
- [ ] Microsoft BAA confirmed for the chosen region
- [ ] Abuse-monitoring opt-out submitted
- [ ] Foundry project created, chat model deployed
- [ ] Key Vault + managed identities created
- [ ] `dbo.DenialVerification` / `dbo.DenialVerificationTask` naming resolved (spec §11.1)
- [ ] NorthWest empty task board root-caused (spec §11.2)
- [ ] Report Control Board lab mapping fixed (spec §11.3)
- [ ] PMS API documentation obtained; sandbox credentials requested
- [ ] Golden-set denials selected (100 historical, known outcomes, de-identified)
- [ ] AR SME named and hours booked
- [ ] Repos created, CI configured, package versions pinned and confirmed against current MAF releases
