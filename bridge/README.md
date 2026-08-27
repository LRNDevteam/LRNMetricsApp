# Reimbursement bridge (`reimb-dab-api`)

Data API Builder over LRNMaster, sitting between the Foundry agent and the database. The
agent reaches it through API Management at `https://reimb-agent-apim.azure-api.net/reimb/mcp`;
the Container App's own address still answers directly and is not yet firewalled.

These files are the source of truth for the bridge's configuration. Until now the config
existed only inside the running container and a Cloud Shell home directory, which the build
log flagged twice as a risk — edit here, then rebuild.

## Entities

| Entity | Source | Type | Actions |
|---|---|---|---|
| `CPTAverage` | `dbo.CPTAverage` | table | read |
| `CPTPricingStatistics` | `dbo.vw_AI_CPT_PricingStatistics` | view | read |
| `PanelPricingStatistics` | `dbo.vw_AI_Panel_PricingStatistics` | view | read |
| `ComparePayerPricingForCPT` | `dbo.vw_AI_ComparePayerPricingForCPT` | view | read |
| `ResolvePayerName` | `dbo.usp_AI_ResolvePayerName` | stored-procedure | **execute** |

The first four were verified against the live bridge via `describe_entities` on
2026-08-21 — all four report READ and nothing else. `ResolvePayerName` is the new one.

`execute` is a different action from `read`, and it maps to a different MCP tool: the agent
calls stored procedures through `execute_entity`, not `read_records`. Both tools are already
exposed by the bridge (confirmed via `tools/list`), so no runtime change is needed to make
the procedure callable.

## Before you rebuild — three things to reconcile

The entity definitions above are verified. These three are not, because the live config was
never in source control. Pull it out of the running container and compare before you build:

```bash
az containerapp exec --name reimb-dab-api --resource-group RG-LRNAnalytics-SQL --command "sh"
# inside: find / -iname "dab-config.json" 2>/dev/null   then cat the path it returns
```

1. **The `runtime` block.** MCP is live on the running bridge, so whatever that config says
   is correct by definition. If its MCP settings differ from the `runtime.mcp` block here,
   keep the live one — this file's version is a reasonable reconstruction, not a verified copy.
2. **`key-fields` on the three views.** DAB cannot infer a key for a view. `PricingId` is the
   first column of all three per the schema reference, but confirm against the live config.
3. **The stored procedure's parameter name.** The `parameters` key must match the procedure's
   actual parameter exactly, minus the `@`. This file assumes `@PayerText`. Check with:

   ```sql
   SELECT name FROM sys.parameters
   WHERE object_id = OBJECT_ID('dbo.usp_AI_ResolvePayerName');
   ```

Also grant the reader account execute rights, or every call returns a permission error:

```sql
GRANT EXECUTE ON dbo.usp_AI_ResolvePayerName TO dab_reader;
```

## Build and deploy

From this folder in Cloud Shell (or anywhere with the Azure CLI):

```bash
az acr build --registry reimbacr5955 --image reimb-dab-api:v3 .

az containerapp update \
  --name reimb-dab-api \
  --resource-group RG-LRNAnalytics-SQL \
  --image reimbacr5955.azurecr.io/reimb-dab-api:v3
```

`:v2` stays in the registry as the rollback point, exactly as `:latest` was kept when v2
shipped. To roll back, re-run `containerapp update` pointing at `:v2`.

## Verify

The REST surface is the quickest check — it needs no MCP handshake:

```bash
curl "https://reimb-dab-api.blackrock-c44bb33c.southcentralus.azurecontainerapps.io/api/ResolvePayerName?PayerText=carefirst"
```

Then confirm the agent can actually see it. Against the MCP endpoint, `describe_entities`
should now list `ResolvePayerName` with an EXECUTE permission and a `PayerText` parameter.
If the entity appears but shows no permissions, the `actions` array is wrong — a stored
procedure takes `execute`, never `read`.

Last, re-run the Phase 5 questions in the Foundry Playground. Adding an entity changes what
`describe_entities` returns to the agent, so it is worth confirming the existing four still
behave before relying on the fifth.

## After it is live

The agent will not use the new tool until its instructions tell it to. Add the payer
resolution rule to the system instructions in ai.azure.com — resolve first, never filter
`PayerDisplayName` with the user's own words — then retest with a short form such as
"carefirst" alongside a full payer name.
