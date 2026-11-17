# LRN AI Platform --- Codex Implementation Guide

**Document purpose:** Implementation brief for Codex to build the LRN AI
platform, beginning with Phase 1: local model comparison using Ollama.

**Project:** LRN AI --- Denial Analysis & AR Recommendations\
**Initial target framework:** .NET 8\
**Initial model runtime:** Ollama, running locally on the developer's
Windows machine\
**Initial deployment:** Local development only; Azure deployment is a
later phase\
**Document status:** Baseline architecture and implementation
requirements

------------------------------------------------------------------------

## 1. Product objective

Build a separate AI platform for LRN that supports denial analysis and
accounts-receivable (AR) recommendations. The platform will analyse
authorised claim and denial facts, retrieve relevant EOBs and other
documents, find similar historical cases, and return evidence-supported
recommendations to AR reviewers.

The first module is **Denial Analysis and AR Recommendations**.

Example questions the platform should eventually help answer:

-   Why was a claim denied?
-   What is the likely root cause?
-   What should the AR reviewer do next?
-   Which payer policy passages, EOB details or historical cases support
    the recommendation?
-   What documents or information are missing?
-   What is the potential recovery amount, calculated from trusted LRN
    data?

The AI platform must be an assistive decision-support system. It must
not independently close claims, change workflow status, issue
write-offs, submit appeals or perform other financial/workflow actions.

## 2. Confirmed implementation decisions

These decisions were explicitly selected:

  -----------------------------------------------------------------------
  Area                                Decision
  ----------------------------------- -----------------------------------
  First module                        Denial analysis and AR
                                      recommendations

  Development hosting                 Local development first

  Model strategy                      Compare Qwen, Llama and DeepSeek

  Model runtime                       Ollama

  Model hosting for Phase 1           Local Ollama

  LRN data access                     Hybrid: existing LRN APIs plus
                                      controlled direct SQL access

  Document source                     Existing Azure Blob Storage

  Structured data                     Existing LRN lab databases and
                                      related LRN data sources

  AI-specific persistence             Separate `LRNAI` database

  API style                           REST API

  API version prefix                  `/api/ai/v1`

  Initial API target                  .NET 8

  Frontend                            Existing LRN React applications
                                      call the AI API

  Azure                               Later deployment phase; do not
                                      build Azure hosting into Phase 1
  -----------------------------------------------------------------------

Do not silently change these choices. If a requirement conflicts with
them, explain the conflict and ask before changing the architecture.

## 3. Existing LRN context and constraints

The platform must fit the existing LRN environment:

-   Existing applications include LRNMetricsApp/LabMetricsDashboard,
    LRN.ReportsApi and denial/AR workflow React applications.
-   Existing APIs and workers use .NET, including .NET 8.
-   SQL data is split across multiple lab databases, with additional LRN
    master and application databases.
-   The existing API/application flow already has user identity, roles
    and selected-lab context.
-   The existing application manages lab-level access. The AI API must
    not trust a lab identifier supplied by a browser without validating
    the authenticated user's permission.
-   The existing data access pattern selects the authorised lab database
    through the connection/repository layer. Do not introduce redundant
    `LabId` filters into every query when the selected database itself
    provides the isolation boundary.
-   Preserve distinctions between `ClaimID`, `VisitNumber`, CPT code,
    denial code and other claim identifiers. Do not assume ClaimID and
    VisitNumber are interchangeable.
-   Denial task data may be large (hundreds of thousands of records).
    Use bounded, targeted queries and pagination; do not load entire
    tables into memory.
-   Existing workflow roles and state transitions remain owned by the
    existing LRN workflow application/API.
-   EOBs and patient-related supporting documents are intended for the
    existing Azure Blob Storage account. The AI system should reference
    Blob objects securely rather than copying original files into the AI
    database.
-   Key Vault is already used in the LRN environment. Secrets must not
    be committed to source control.

Do not assume actual lab connection strings, Blob container names, model
tags, network addresses or secret values. Use placeholders and
environment variables until the developer supplies real values.

## 4. Architecture

### 4.1 Logical architecture

``` text
Existing LRN React applications
    |
    v
Existing LRN authentication / Entra ID / role and lab permission context
    |
    v
LRN.AI.Api (.NET 8 REST API)
    |
    +-- Application use cases and orchestration
    |
    +-- Hybrid LRN data access
    |      +-- Existing LRN API clients
    |      +-- Controlled read-only SQL repositories
    |
    +-- Document access and retrieval
    |      +-- Existing Azure Blob Storage
    |      +-- Text extraction / OCR worker (later phase)
    |      +-- Chunking and vector retrieval (later phase)
    |
    +-- Model gateway
    |      +-- Ollama provider
    |             +-- Qwen
    |             +-- Llama
    |             +-- DeepSeek
    |
    +-- AI-specific persistence (LRNAI database)
    |
    +-- Audit, telemetry and evaluation
```

### 4.2 Separation of responsibilities

**Existing LRN applications/API** - Remain the source of user identity,
role assignment and lab authorisation. - Continue to own workflow state
and workflow actions. - Provide claim/denial data through existing APIs
where appropriate.

**LRN.AI.Api** - Exposes AI business operations. - Authenticates callers
and validates the user's lab scope. - Orchestrates retrieval, model
calls, validation and persistence. - Does not expose an unrestricted
prompt-to-model endpoint to ordinary users.

**Application layer** - Contains use cases such as denial analysis, AR
recommendation and model comparison. - Depends on interfaces, not
concrete Ollama, SQL or Blob implementations.

**Domain layer** - Contains business entities, enums, value objects and
deterministic rules. - Must not depend on infrastructure libraries.

**Infrastructure layer** - Implements Ollama HTTP calls, LRN API
clients, SQL repositories, Blob access, document extraction, retrieval,
logging and persistence.

**Worker** - Will later process document ingestion, extraction,
chunking, embedding and reprocessing. - Phase 1 may scaffold the worker
project, but it does not need production document-processing jobs yet.

### 4.3 Security boundary

The LLM must never: - Connect directly to lab SQL databases. - Execute
arbitrary SQL. - Read arbitrary Blob paths. - Decide which lab a user is
authorised to access. - Change claim or denial workflow states. -
Perform financial transactions or write-offs. - Submit appeals or
messages automatically.

All data must be retrieved by authorised application services. Only the
minimum necessary facts and document excerpts should be passed to the
model.

## 5. Solution and project structure

Create the following solution:

``` text
LRN.AI/
├── LRN.AI.sln
├── Directory.Build.props
├── .editorconfig
├── .gitignore
├── README.md
├── CODEX.md
│
├── src/
│   ├── LRN.AI.Api/
│   │   ├── Controllers/
│   │   │   ├── ModelsController.cs
│   │   │   ├── DenialAnalysisController.cs       # later phase
│   │   │   ├── ARRecommendationsController.cs   # later phase
│   │   │   └── DocumentsController.cs            # later phase
│   │   ├── Contracts/
│   │   │   └── Models/
│   │   ├── Middleware/
│   │   ├── Extensions/
│   │   ├── Program.cs
│   │   └── appsettings.json
│   │
│   ├── LRN.AI.Application/
│   │   ├── Abstractions/
│   │   │   ├── ILLMProvider.cs
│   │   │   ├── ILRNClaimApiClient.cs
│   │   │   ├── IClaimDataRepository.cs
│   │   │   ├── IDocumentRepository.cs
│   │   │   ├── IRetrievalService.cs
│   │   │   └── IRecommendationService.cs
│   │   ├── Models/
│   │   ├── DenialAnalysis/                       # later phase
│   │   ├── ARRecommendations/                    # later phase
│   │   └── Common/
│   │
│   ├── LRN.AI.Domain/
│   │   ├── Entities/
│   │   ├── Enums/
│   │   ├── ValueObjects/
│   │   └── Rules/
│   │
│   ├── LRN.AI.Infrastructure/
│   │   ├── AI/
│   │   │   └── Ollama/
│   │   ├── LRNApi/
│   │   ├── Persistence/
│   │   │   ├── Sql/
│   │   │   └── Repositories/
│   │   ├── Documents/
│   │   │   └── BlobStorage/
│   │   ├── Retrieval/
│   │   └── Observability/
│   │
│   └── LRN.AI.Worker/
│       ├── Jobs/
│       └── Program.cs
│
└── tests/
    ├── LRN.AI.UnitTests/
    ├── LRN.AI.IntegrationTests/
    └── LRN.AI.ModelEvaluationTests/
```

### 5.1 Dependency direction

-   `Domain` has no project dependencies.
-   `Application` references `Domain`.
-   `Infrastructure` references `Application` and `Domain`.
-   `Api` references `Application` and `Infrastructure`.
-   `Worker` references `Application` and `Infrastructure`.
-   Tests reference the projects they test.

Do not let Domain or Application reference Ollama SDKs, SQL client
implementations, Azure SDKs or ASP.NET controllers.

## 6. Phase 1 scope

Phase 1 is a local model-comparison API. It must be runnable before any
live LRN data is connected.

### 6.1 Included

1.  Create the .NET 8 solution and projects.
2.  Configure nullable reference types and implicit usings.
3.  Add project references and package references.
4.  Implement the `ILLMProvider` abstraction.
5.  Implement an Ollama provider using `HttpClient`.
6.  Read locally installed model tags from Ollama.
7.  Implement a model comparison use case that sends the same prompt to
    selected models.
8.  Return each model's response, duration and any per-model error.
9.  Add configuration and environment-variable overrides.
10. Add health checks or a clear Ollama connectivity check.
11. Add unit tests with mocked HTTP responses.
12. Add integration-test instructions requiring a running local Ollama
    instance.
13. Add README instructions and sample curl requests.

### 6.2 Not included in Phase 1

-   Live claim or denial data access.
-   Real EOB or patient-document processing.
-   Blob document ingestion.
-   OCR.
-   Embeddings or vector search.
-   Actual denial root-cause recommendations.
-   Actual AR recommendation generation.
-   Azure hosting or GPU deployment.
-   Automated workflow updates.
-   Production Entra integration unless already available as a reusable
    existing authentication package/configuration.

Scaffold interfaces for later phases only where useful. Do not add
unused complex infrastructure or speculative dependencies.

## 7. Phase 1 API contracts

Base path:

``` text
/api/ai/v1
```

### 7.1 GET `/api/ai/v1/models`

Purpose: return the models available in the configured local Ollama
instance.

Example response:

``` json
{
  "provider": "Ollama",
  "connected": true,
  "models": [
    {
      "name": "exact-installed-qwen-tag",
      "sizeBytes": 123456789,
      "modifiedAt": "2026-11-07T00:00:00Z"
    },
    {
      "name": "exact-installed-llama-tag",
      "sizeBytes": 123456789,
      "modifiedAt": "2026-11-07T00:00:00Z"
    }
  ]
}
```

The values above are illustrative. The endpoint must return actual
Ollama tags and must not invent missing model names.

If Ollama is unavailable, return a meaningful service-unavailable
response or a documented response shape with `connected: false`. Do not
return fake model data.

### 7.2 POST `/api/ai/v1/models/compare`

Purpose: send the same prompt to multiple selected Ollama models and
return comparable results.

Request:

``` json
{
  "prompt": "Explain the likely causes of a CO-11 denial. Do not assume claim-specific facts.",
  "modelNames": [
    "exact-qwen-tag",
    "exact-llama-tag",
    "exact-deepseek-tag"
  ],
  "systemPrompt": "You are an assistant evaluating medical billing denial concepts. Do not invent facts.",
  "temperature": 0.2,
  "maxTokens": 1200
}
```

Rules: - `prompt` is required and must have a configurable maximum
length. - `modelNames` must contain 1--3 distinct model names. - Every
requested model must be verified against the Ollama tags list, unless a
deliberate configuration option allows otherwise. - Model names are
configuration/input identifiers, not executable commands. - Apply
request timeout and cancellation. - Do not log prompt contents by
default because later prompts may contain PHI. - Enforce sensible limits
for temperature and output tokens. - Use the same prompt, system prompt
and generation settings for all models.

Example response:

``` json
{
  "comparisonId": "generated-guid",
  "startedAt": "2026-11-07T00:00:00Z",
  "completedAt": "2026-11-07T00:00:12Z",
  "results": [
    {
      "modelName": "exact-qwen-tag",
      "success": true,
      "response": "Model response...",
      "durationMs": 4200,
      "error": null
    },
    {
      "modelName": "exact-llama-tag",
      "success": true,
      "response": "Model response...",
      "durationMs": 3900,
      "error": null
    },
    {
      "modelName": "exact-deepseek-tag",
      "success": false,
      "response": null,
      "durationMs": 180000,
      "error": {
        "code": "ModelTimeout",
        "message": "The model did not complete within the configured timeout."
      }
    }
  ]
}
```

One model failure must not discard successful results from the other
models. Return an overall HTTP success response when the comparison
request was accepted and processed, with individual result
success/failure fields. Return 400 for invalid input and 503 when the
Ollama service cannot be reached at all.

### 7.3 GET `/health`

Return API health. If adding a separate Ollama health endpoint,
distinguish API health from model-provider health.

## 8. Model provider abstraction

Implement an application-level interface similar to:

``` csharp
public interface ILLMProvider
{
    string ProviderName { get; }

    Task<LLMResponse> GenerateAsync(
        LLMRequest request,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<LLMModelInfo>> GetAvailableModelsAsync(
        CancellationToken cancellationToken);
}
```

Use typed request/response objects:

``` csharp
public sealed record LLMRequest(
    string ModelName,
    string Prompt,
    string? SystemPrompt,
    double Temperature,
    int MaxTokens);

public sealed record LLMResponse(
    string ModelName,
    string Content,
    long DurationMs);

public sealed record LLMModelInfo(
    string Name,
    long? SizeBytes,
    DateTimeOffset? ModifiedAt);
```

Names may be adjusted to the project's conventions, but keep the
abstraction independent of Ollama-specific JSON contracts.

Infrastructure implementation:

``` text
OllamaLLMProvider
```

Use `IHttpClientFactory` and a named or typed `HttpClient`. Do not
create a new `HttpClient` for each request. Configure base URL and
timeout via options.

Ollama endpoints: - `GET /api/tags` for installed model tags. -
`POST /api/chat` for chat generation.

For chat generation, set `stream: false` for the first implementation so
the API receives a complete response. Map the Ollama response into
`LLMResponse`.

The exact Ollama response DTOs must match the Ollama API response
format. Handle: - Non-success HTTP status. - Connection refused / DNS
errors. - Timeout. - Malformed JSON. - Missing message content. -
Cancellation. - Model not found.

Do not expose raw stack traces or internal exception details to API
callers.

## 9. Configuration

Use configuration options, not hardcoded values.

Example `appsettings.json`:

``` json
{
  "AI": {
    "DefaultProvider": "Ollama",
    "Ollama": {
      "BaseUrl": "http://localhost:11434",
      "TimeoutSeconds": 180,
      "KeepAlive": "5m"
    },
    "Comparison": {
      "MaxModelsPerRequest": 3,
      "MaxPromptCharacters": 12000,
      "DefaultTemperature": 0.2,
      "DefaultMaxTokens": 1200
    }
  },
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft.AspNetCore": "Warning"
    }
  },
  "AllowedHosts": "*"
}
```

The values are development defaults and should be validated at startup.
Use environment variables for overrides, for example:

``` text
AI__Ollama__BaseUrl=http://localhost:11434
AI__Ollama__TimeoutSeconds=180
```

Do not commit credentials or sensitive production values. Ollama is
normally local and may not require a credential in this development
configuration, but network access must be restricted if the endpoint is
exposed beyond localhost.

## 10. Package references

Keep Phase 1 package usage small. Prefer built-in .NET capabilities
where practical.

Potential package references: - `Microsoft.Extensions.Http` if needed by
the hosting/project arrangement. -
`Microsoft.Extensions.Options.ConfigurationExtensions` if needed. -
`Microsoft.AspNetCore.OpenApi` for API OpenAPI support if desired. -
`Microsoft.NET.Test.Sdk` for tests. - `xunit` and
`xunit.runner.visualstudio` for unit tests. - `Moq` or `NSubstitute` for
test doubles.

Do not add Semantic Kernel, Agent Framework, LangChain, vector database
SDKs, EF Core or Azure SDK packages to Phase 1 unless a concrete
implemented feature needs them. A direct `HttpClient` integration is
sufficient for the first Ollama comparison endpoint.

Pin compatible package versions and verify they support the selected
target framework. Do not invent package versions; use the current stable
compatible versions available in the developer's NuGet environment.

## 11. Hybrid LRN data access --- future-phase design

The confirmed approach is hybrid:

1.  Use existing LRN APIs where they already provide validated claim,
    denial or workflow information.
2.  Use controlled direct read-only SQL repositories for data not
    exposed by existing APIs or where a measured retrieval need
    justifies direct SQL.
3.  Centralise selected-lab connection resolution.
4.  Enforce user/lab permission checks before retrieving any data.
5.  Never accept an arbitrary database name or connection string from a
    client.
6.  Use parameterised SQL and bounded queries.
7.  Avoid loading entire denial tables. Support targeted
    claim/visit/CPT/denial lookups and paging.
8.  Keep write operations and workflow changes in existing LRN APIs.

Create future interfaces such as:

``` csharp
public interface ILRNClaimApiClient
{
    Task<ClaimContext?> GetClaimContextAsync(
        string claimReference,
        string authorisedLabKey,
        CancellationToken cancellationToken);
}

public interface IClaimDataRepository
{
    Task<DenialContext?> GetDenialContextAsync(
        DenialLookup lookup,
        AuthorisedLabContext labContext,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<HistoricalDenialCase>> GetSimilarCasesAsync(
        HistoricalCaseQuery query,
        AuthorisedLabContext labContext,
        CancellationToken cancellationToken);
}
```

These are future-phase contracts; do not invent endpoint URLs or SQL
schema names. Inspect the existing LRN API and database schema before
implementing them.

## 12. Document source and retrieval --- future-phase design

Confirmed source: existing Azure Blob Storage.

Future document flow:

``` text
Blob object
   -> secure document registration
   -> text extraction / OCR
   -> page-aware chunking
   -> embeddings
   -> vector index
   -> authorised retrieval
   -> relevant excerpts and source references in model context
```

The original document remains in Blob Storage. The AI database stores
document metadata and processing/indexing state. Extracted text and
chunks may be stored according to the agreed retention and PHI policy.

Future document metadata should include: - Internal document ID. -
Authorised lab key. - Source type (EOB, patient document, payer policy,
other). - Blob container/object reference. - Original filename. -
Claim/visit reference when applicable. - Payer, CPT and denial metadata
where known. - Processing status. - Content hash. - Created/processed
timestamps.

Retrieval must enforce lab, claim and document permissions before
returning chunks. Vector search is not an authorisation boundary.

## 13. AI-specific database --- future-phase design

Create a separate `LRNAI` database for AI metadata and audit, not a
duplicate of all operational claim data.

Initial planned tables:

  -----------------------------------------------------------------------
  Table                               Purpose
  ----------------------------------- -----------------------------------
  `AI_Document`                       Document metadata and Blob
                                      reference

  `AI_DocumentChunk`                  Extracted page-aware chunks

  `AI_AnalysisRun`                    Analysis request, status and
                                      model/prompt metadata

  `AI_Recommendation`                 Structured recommendation

  `AI_RecommendationEvidence`         Evidence references supporting a
                                      recommendation

  `AI_ReviewerFeedback`               Accepted/rejected/edited
                                      recommendation and outcome

  `AI_ModelRegistry`                  Provider/model/version details

  `AI_PromptVersion`                  Versioned prompt templates

  `AI_ModelEvaluation`                Benchmark measurements
  -----------------------------------------------------------------------

Suggested `AI_AnalysisRun` fields: - `AnalysisRunId` - `LabKey` -
`ClaimReference` - `VisitNumber` - `CPTCode` - `DenialCode` -
`AnalysisType` - `ModelId` - `PromptVersion` - `RetrievalVersion` -
`InputSnapshotHash` - `Status` - `StartedOn` - `CompletedOn` -
`CreatedBy`

Suggested `AI_Recommendation` fields: - `RecommendationId` -
`AnalysisRunId` - `RootCause` - `SuggestedAction` - `ActionCategory` -
`Priority` - `EstimatedRecoveryAmount` - `EstimatedRecoveryCurrency` -
`MissingDocuments` - `Explanation` - `ConfidenceBand` -
`RequiresHumanReview`

The model must not generate authoritative financial calculations.
Amounts, balances, units and totals must come from SQL/C# business
logic. Model confidence must not be represented as a calibrated recovery
probability unless separately validated.

## 14. Future denial-analysis workflow

``` text
React Denial Workflow
    -> LRN.AI.Api
    -> authenticate caller and validate lab permission
    -> retrieve claim/denial facts through hybrid data access
    -> retrieve permitted EOB/policy documents from Blob-derived index
    -> retrieve similar historical cases
    -> build bounded, structured model context
    -> call selected model
    -> validate structured response and evidence references
    -> apply deterministic business checks
    -> save analysis, model metadata and evidence in LRNAI
    -> return recommendation to React
    -> reviewer accepts, edits or rejects
    -> save reviewer feedback and actual outcome
```

Analysis should be asynchronous for potentially long-running
model/document requests. Return `202 Accepted` and an analysis ID, then
provide a status/result endpoint. A later phase may add SignalR
notifications.

## 15. Future API contracts

Base path: `/api/ai/v1`

  --------------------------------------------------------------------------------------------
  Method                  Endpoint                                     Purpose
  ----------------------- -------------------------------------------- -----------------------
  `POST`                  `/denials/analyse`                           Start denial analysis

  `GET`                   `/analyses/{analysisRunId}`                  Read analysis
                                                                       status/result

  `POST`                  `/ar/recommendations`                        Generate AR
                                                                       recommendations

  `GET`                   `/claims/{claimReference}/recommendations`   Read prior
                                                                       recommendations

  `POST`                  `/recommendations/{id}/feedback`             Capture reviewer
                                                                       feedback

  `POST`                  `/documents/ingest`                          Register a document for
                                                                       processing

  `GET`                   `/documents/{documentId}`                    Read processing status

  `GET`                   `/models`                                    List configured Ollama
                                                                       models (Phase 1)

  `POST`                  `/models/compare`                            Compare selected models
                                                                       (Phase 1)
  --------------------------------------------------------------------------------------------

Future denial-analysis request example:

``` json
{
  "labKey": "NWL",
  "claimReference": "claim-reference",
  "visitNumber": "visit-number",
  "cptCode": "cpt-code",
  "denialCode": "CO-11",
  "payerName": "payer-name",
  "includeHistoricalCases": true,
  "includeDocuments": true
}
```

The lab key is only a requested context selector; it must be checked
against authenticated user permissions.

## 16. Model evaluation

Compare Qwen, Llama and DeepSeek using the same: - Prompt and system
prompt. - Generation settings. - Input facts. - Document excerpts. -
Historical case context.

Create a representative, de-identified or otherwise approved evaluation
dataset of approximately 100--300 historical denial cases, subject to
privacy and data governance approval.

Evaluate: - Root-cause accuracy against reviewer-confirmed outcomes. -
Recommendation usefulness and correctness. - Evidence support and
source-reference correctness. - Unsupported claims / hallucinations. -
JSON/schema validity. - Latency. - Token/output size where available. -
Hardware resource use and operational cost.

Do not choose a model based only on fluent explanations or its own
confidence score. Keep evaluation results by exact model tag/version and
runtime configuration.

## 17. Azure deployment --- later phase

Do not implement Azure deployment in Phase 1. Target architecture later:

-   Azure App Service for the .NET API, or an appropriate container
    hosting service.
-   Azure Container Registry for images.
-   Existing Azure Blob Storage for original documents.
-   Azure SQL for LRN operational data and `LRNAI` metadata.
-   Azure AI Search or another approved vector retrieval service.
-   Separate GPU-capable model hosting (GPU VM, GPU-enabled Azure
    Container Apps where available, or Azure Machine Learning managed
    endpoints).
-   Azure Key Vault for secrets.
-   Managed identity and private networking.
-   Application Insights and centralised monitoring.

Do not run large LLM inference inside a normal App Service plan. The API
and model runtime should be independently deployable. Check regional GPU
availability, quota, pricing, security and scaling before selecting the
hosting service.

## 18. Security, privacy and operational requirements

These are mandatory design constraints:

1.  Validate authenticated user and lab permissions on every relevant
    request.
2.  Enforce lab and claim scope before SQL, API, Blob or vector
    retrieval.
3.  Use read-only database credentials for AI data retrieval.
4.  Use parameterised SQL and query timeouts.
5.  Do not expose arbitrary SQL, arbitrary prompts or arbitrary Blob
    paths as general user-facing tools.
6.  Do not log PHI or full prompts by default.
7.  Encrypt data in transit and at rest.
8.  Use Key Vault/managed identity for production secrets and service
    access.
9.  Treat document text as untrusted data; defend against prompt
    injection in documents.
10. Validate every model response against a strict schema.
11. Verify evidence references against the context actually retrieved
    for that analysis.
12. Keep an audit trail of model/provider/version, prompt version, input
    references, evidence and reviewer outcome.
13. Keep human approval for financial and workflow actions.
14. Define retention and deletion policies for prompts, outputs,
    extracted text, chunks and audit records.
15. Avoid sending unnecessary patient information to the model.

## 19. Implementation instructions for Codex

Work incrementally. Do not attempt to implement all future phases in one
pass.

### Task A --- inspect and scaffold

1.  Inspect the repository/workspace before changing files.
2.  If an existing solution is present, do not overwrite it. Propose how
    to integrate the new solution.
3.  Create the project structure in Section 5.
4.  Target `net8.0` for all Phase 1 projects.
5.  Enable nullable reference types and implicit usings.
6.  Add the project references in the dependency direction specified
    above.
7.  Add only package references required by the implemented Phase 1
    features.
8.  Add `.gitignore`, `.editorconfig`, `Directory.Build.props`,
    `README.md` and this `CODEX.md`.

### Task B --- implement Ollama provider

1.  Define provider-independent request/response/model types in
    Application.
2.  Define `ILLMProvider`.
3.  Implement `OllamaLLMProvider` in Infrastructure.
4.  Use `IHttpClientFactory`.
5.  Implement `/api/tags` and non-streaming `/api/chat`.
6.  Map Ollama response types to provider-independent types.
7.  Add timeout, cancellation and robust error handling.
8.  Never return raw internal exceptions to clients.

### Task C --- implement model comparison

1.  Add typed compare request and response DTOs.
2.  Validate prompt length, model count, duplicate model names,
    temperature and token limit.
3.  Confirm selected model tags exist in Ollama.
4.  Send identical prompt/settings to each selected model.
5.  Run model calls concurrently, with a configurable concurrency limit
    of at most three for this endpoint.
6.  Measure each model's elapsed time independently.
7.  Preserve successful outputs when another model fails.
8.  Return an overall comparison ID and individual model results.
9.  Avoid logging prompt or response content by default.

### Task D --- wire API and configuration

1.  Register validated options.
2.  Register the Ollama typed/named HttpClient.
3.  Register `ILLMProvider` and application services with dependency
    injection.
4.  Implement `GET /api/ai/v1/models`.
5.  Implement `POST /api/ai/v1/models/compare`.
6.  Add `/health`.
7.  Add OpenAPI support in Development.
8.  Use consistent ProblemDetails errors.
9.  Add request size limits and sensible timeouts.

### Task E --- tests and documentation

1.  Unit-test provider mapping and failure cases with mocked HTTP
    responses.
2.  Unit-test comparison validation and partial model failure behaviour.
3.  Add integration test instructions for a running Ollama instance.
4.  Add curl examples for listing models and comparing them.
5.  Document how to install/start Ollama and verify its endpoint.
6.  Document that model tags must be copied from the actual
    `ollama list` output.
7.  Run `dotnet restore`, `dotnet build` and `dotnet test`.
8.  Fix all build/test errors before declaring Phase 1 complete.

### Coding standards

-   Use async APIs and pass `CancellationToken`.
-   Use dependency injection.
-   Use `IOptions<T>` or validated options for configuration.
-   Use typed DTOs and avoid `object`/untyped dictionaries for core
    contracts.
-   Keep controllers thin; business orchestration belongs in
    Application.
-   Keep provider-specific JSON DTOs in Infrastructure.
-   Use structured logging but do not log PHI.
-   Do not hardcode model names or assume all three models are
    installed.
-   Do not introduce speculative packages or unnecessary microservices.
-   Do not claim a feature is implemented unless it builds and tests.
-   If a detail of the existing LRN API/schema is unknown, create an
    interface and clearly mark the integration point instead of
    inventing a URL, table or column.

## 20. Phase 1 acceptance criteria

Phase 1 is complete only when all the following are true:

-   [ ] Solution builds on .NET 8.
-   [ ] All projects have correct references and dependency direction.
-   [ ] API starts locally.
-   [ ] API can connect to local Ollama.
-   [ ] `GET /api/ai/v1/models` returns actual installed Ollama model
    tags.
-   [ ] API handles Ollama unavailable without crashing.
-   [ ] `POST /api/ai/v1/models/compare` accepts one to three installed
    model tags.
-   [ ] The same prompt and settings are sent to each model.
-   [ ] Successful model results are returned even if another model
    fails.
-   [ ] Per-model elapsed time is returned.
-   [ ] Invalid model lists and invalid parameters return validation
    errors.
-   [ ] Timeouts and cancellation are handled.
-   [ ] Prompt and response contents are not written to ordinary logs by
    default.
-   [ ] Unit tests pass.
-   [ ] README contains setup, configuration and curl instructions.
-   [ ] No live PHI or production credentials are required to run Phase
    1.

## 21. Recommended delivery order

1.  Scaffold solution and build.
2.  Add Ollama configuration and connectivity.
3.  Implement model listing.
4.  Implement single-model chat internally.
5.  Implement multi-model comparison endpoint.
6.  Add validation, timeouts and partial-failure handling.
7.  Add unit tests.
8.  Add README and runbook.
9.  Verify using the actual locally installed model tags.
10. Only after Phase 1 acceptance, begin Phase 2 data access.

**First coding objective:** deliver a clean, buildable .NET 8 solution
with a working Ollama model-list endpoint and model-comparison endpoint.
Do not start claim analysis, Blob ingestion or Azure deployment until
this milestone passes.
