# LRN AI — Denial Analysis & AR Recommendations

.NET 8 REST API (`/api/ai/v1`) for LRN's AI decision-support platform. **Phase 1** compares local
Qwen / Llama / DeepSeek models through Ollama. No live claim data, documents or PHI are used yet.

- Architecture and requirements: [CODEX.md](CODEX.md)
- Delivery plan: [docs/TASK_SCHEDULE.md](docs/TASK_SCHEDULE.md)
- HIPAA safeguards and their status: [docs/HIPAA_SAFEGUARDS.md](docs/HIPAA_SAFEGUARDS.md)

The platform is assistive only. It never changes workflow status, writes off balances, submits appeals or
touches lab databases directly.

## Solution layout

```text
LRN.AI.sln
src/
  LRN.AI.Domain          entities and rules (empty until Phase 2)
  LRN.AI.Application     ILLMProvider, model comparison use case, validation, PHI guard, audit contract
  LRN.AI.Infrastructure  Ollama provider (HttpClient), options validation, audit log sink
  LRN.AI.Api             controllers, LRN JWT auth, policies, rate limiting, security headers, health
  LRN.AI.Worker          host scaffold for Phase 3 document jobs
tests/
  LRN.AI.UnitTests             mocked HTTP + fake provider, no Ollama needed
  LRN.AI.IntegrationTests      live Ollama, opt-in
  LRN.AI.ModelEvaluationTests  live side-by-side model runs, opt-in
```

Dependencies only point one way: Domain ← Application ← Infrastructure ← Api/Worker. Application has no Ollama,
SQL, Azure or ASP.NET dependency.

## 1. Install and start Ollama

```powershell
winget install Ollama.Ollama          # or the installer from https://ollama.com/download
$env:OLLAMA_HOST = "127.0.0.1:11434"  # keep Ollama bound to this machine (the default); do not expose 0.0.0.0
ollama serve                          # if it is not already running as the tray app / service
```

Pull the models to compare. The tags below are examples; choose sizes that fit the machine's RAM/GPU:

```powershell
ollama pull qwen2.5:7b
ollama pull llama3.1:8b
ollama pull deepseek-r1:8b
ollama list                           # copy the exact NAME values from here into requests
curl.exe http://localhost:11434/api/tags
```

Model names in requests must be the **exact tags `ollama list` prints**. The API checks every name against
`/api/tags` and never invents or assumes a model.

Keep `OLLAMA_DEBUG` off. Debug logging can write prompts to the Ollama server log.

## 2. Run the API

```powershell
cd LRN.AI
dotnet run --project src/LRN.AI.Api --launch-profile http     # http://localhost:5280, Swagger at /swagger
```

**Authentication.** In `Development`, `AI:Security:DevelopmentBypass` signs in loopback callers as
`local-developer` with the evaluation roles, so no token is needed on your own machine. In every other
environment the API requires the LRN workflow JWT that LabMetricsDashboard issues
(`Authorization: Bearer <token>`). It is validated with the same `DenialWorkflowAuth:JwtSigningKey`, issuer and
audience as LRN.ReportsApi. Startup fails if the key is missing, and it fails if the bypass is switched on
outside Development.

Supply the key outside source control:

```powershell
dotnet user-secrets set "DenialWorkflowAuth:JwtSigningKey" "<same key as LabMetricsDashboard>" --project src/LRN.AI.Api
# or: $env:DenialWorkflowAuth__JwtSigningKey = "..."   or appsettings.Local.json (gitignored)
```

The model endpoints require a role listed in `AI:Security:ModelEvaluationRoles` (default `Admin`), because the
compare endpoint accepts free text.

## 3. Configuration

All values are in `src/LRN.AI.Api/appsettings.json`, are validated at startup, and can be overridden with
environment variables (`:` becomes `__`).

| Key | Default | Notes |
|---|---|---|
| `AI:Ollama:BaseUrl` | `http://localhost:11434` | Must be loopback, or `https` for any other host |
| `AI:Ollama:TimeoutSeconds` | `180` | Per-model generation timeout (5–1800) |
| `AI:Ollama:ListTimeoutSeconds` | `10` | `/api/tags` timeout |
| `AI:Ollama:KeepAlive` | `5m` | Ollama `keep_alive` |
| `AI:Comparison:MaxModelsPerRequest` | `3` | 1–3 |
| `AI:Comparison:MaxConcurrency` | `3` | 1–3. Use 1 on a single GPU for comparable timings |
| `AI:Comparison:MaxPromptCharacters` | `12000` | |
| `AI:Comparison:DefaultTemperature` / `MaxTemperature` | `0.2` / `1.0` | |
| `AI:Comparison:DefaultMaxTokens` / `MaxOutputTokens` | `1200` / `4096` | |
| `AI:Comparison:RequireInstalledModels` | `true` | `false` passes unknown names straight to Ollama |
| `AI:Comparison:RejectLikelyPhi` | `true` | Rejects prompts that look like they contain SSN, MRN, DOB, MBI, phone or email |
| `AI:Security:ModelEvaluationRoles` | `["Admin"]` | |
| `AI:Security:ComparePermitsPerMinute` | `10` | Per user |
| `AI:Security:AllowedCorsOrigins` | `[]` | React app origins, when they call the API from the browser |
| `DenialWorkflowAuth:JwtSigningKey` | *(none)* | Secret. Never commit it |

Example: `$env:AI__Ollama__TimeoutSeconds = "300"`.

## 4. Endpoints and curl examples

Use `curl.exe` in PowerShell, because `curl` is an alias for `Invoke-WebRequest` there.

```powershell
curl.exe http://localhost:5280/health            # API liveness
curl.exe http://localhost:5280/health/ollama     # model provider: Healthy / Unhealthy

curl.exe http://localhost:5280/api/ai/v1/models

curl.exe -X POST http://localhost:5280/api/ai/v1/models/compare -H "Content-Type: application/json" `
  -d '{\"prompt\":\"Explain the likely causes of a CO-11 denial. Do not assume claim-specific facts.\",\"modelNames\":[\"qwen2.5:7b\",\"llama3.1:8b\",\"deepseek-r1:8b\"],\"temperature\":0.2,\"maxTokens\":1200}'
```

With a token (non-Development): add `-H "Authorization: Bearer <token>"`.

| Status | Meaning |
|---|---|
| 200 | Comparison ran. Each result has `success`, `response`, `durationMs`, token counts and `error` (`ModelTimeout`, `ModelNotFound`, `ProviderUnavailable`, `InvalidModelResponse`, `ProviderError`). One model failing never discards the others |
| 400 | ValidationProblemDetails: prompt missing or too long, 0 or more than 3 models, duplicates, not installed, temperature or maxTokens out of range, likely PHI |
| 401 / 403 | No valid token, or a role that is not an evaluation role |
| 429 | Per-user compare rate limit reached |
| 503 | Ollama could not be reached (`connected: false`). Nothing fake is returned |

## 5. Tests

```powershell
dotnet test LRN.AI.sln                                   # unit tests; live tests report as Skipped

$env:LRN_AI_OLLAMA_TESTS = "1"                           # live Ollama integration tests
$env:LRN_AI_TEST_MODEL  = "qwen2.5:7b"                   # optional; defaults to the first installed model
dotnet test tests/LRN.AI.IntegrationTests

$env:LRN_AI_EVAL_MODELS = "qwen2.5:7b,llama3.1:8b,deepseek-r1:8b"   # baseline side-by-side run
dotnet test tests/LRN.AI.ModelEvaluationTests
# results: tests/LRN.AI.ModelEvaluationTests/bin/Debug/net8.0/evaluation-results/comparison-*.json
```

The baseline evaluation prompts (`EvaluationPrompts.json`) are generic denial-code questions with no patient
data. The Phase 5 dataset of de-identified historical cases must never be committed.

## Logging and PHI

Prompts, system prompts and model output are never logged. Diagnostic logs carry the operation, model tag,
error code and HTTP status. Ollama error bodies are not read, because they can echo request content. Audit events
(`LRN.AI.Audit` log category) record the user, correlation id, action, outcome, model tags, prompt length and
per-model result codes and timings.
