# Payer Alias Resolution — Deployment

**Version 1.1 · Status: Bridge deployed and verified 2026-08-25; agent instructions pending · Owner: LRN Dev**

> **Bridge is live.** `reimb-dab-api:v3` is running on revision `0000006`. `ResolvePayerName`
> is confirmed over MCP with EXECUTE and a `PayerText` parameter, and returns
> `{ Family, PayerDisplayName }` rows. Verified: `carefirst` → 4 CareFirst payers;
> `aetna better health` → only `AETNA_BETTER_HEALTH` plans, correctly beating plain Aetna;
> an unknown payer → empty result. Steps 1–5 are done; Step 6 (agent instructions) and
> Step 7 (testing) remain.

Step-by-step update, deploy and test for adding payer alias matching to the Reimbursement
Insights agent. The design rationale — and why this belongs in the bridge rather than the
Foundry prompt or the dashboard — is in
[Payer_Alias_Resolution_v1.0.pdf](Payer_Alias_Resolution_v1.0.pdf). Read that first if you
need the *why*; this document is the *how*.

---

## What changes

| Component | Change | Redeploy needed |
|---|---|---|
| LRNMaster | New `dbo.usp_AI_ResolvePayerName`, plus an EXECUTE grant to `dab_reader` | — |
| Bridge (`reimb-dab-api`) | New `ResolvePayerName` entity in `dab-config.json`; image rebuilt as `:v3` | **Yes** |
| Foundry agent | One new section in the system instructions | Instructions save only |
| API Management | Nothing | No |
| LabMetricsDashboard | Nothing | No |
| `reimb-agent-proxy` (App Service) | Nothing | No |

API Management needs no work because adding an entity creates no new URL at the MCP layer —
`/mcp` is a single endpoint and entities travel inside the JSON-RPC payload. The REST path
`/api/ResolvePayerName` is already covered by the two wildcard operations (`GET /{*path}`,
`POST /{*path}`) added in Phase 8 Part A.

Config source of truth is [`bridge/dab-config.json`](../../bridge/dab-config.json). Until this
change the bridge config existed only inside the running container and a Cloud Shell home
directory; edit the repo copy from now on.

---

## Prerequisites

Confirm all four before starting. Each one causes a different failure later if missed.

1. **The procedure exists and returns rows.**

   ```sql
   EXEC dbo.usp_AI_ResolvePayerName 'carefirst';
   ```

2. **`dab_reader` can execute it.** Without this the entity lists correctly in
   `describe_entities` and only fails at call time, which reads like an agent fault rather
   than a permissions one.

   ```sql
   GRANT EXECUTE ON dbo.usp_AI_ResolvePayerName TO dab_reader;
   ```

3. **The parameter name matches the config exactly**, minus the `@`.
   `bridge/dab-config.json` declares `PayerText`.

   ```sql
   SELECT name FROM sys.parameters
   WHERE object_id = OBJECT_ID('dbo.usp_AI_ResolvePayerName');
   ```

4. **The live `runtime` block and view `key-fields` match the repo copy.** The repo config
   was reconstructed from the running bridge's `describe_entities` output; the entity block
   is verified, the `runtime` block is not. Pull the live file and diff before building:

   ```bash
   az containerapp exec --name reimb-dab-api --resource-group RG-LRNAnalytics-SQL --command "sh"
   # inside: find / -iname "dab-config.json" 2>/dev/null   then cat the path it returns
   ```

   If the live `runtime.mcp` settings differ from the repo copy, **keep the live ones** — MCP
   works today, so that file is correct by definition.

---

## Step 1 — Get the build context into Cloud Shell

`az acr build .` uploads the **current directory** as the build context, so `Dockerfile` and
`dab-config.json` must sit together in Cloud Shell. They live in the repo on your machine;
Cloud Shell cannot see them.

Run every command from here on in **Cloud Shell**, not inside the container. If your prompt
reads `sh-5.1#` you are still inside the bridge from prerequisite 4 — press **Ctrl+D** first.
`az` is not installed in the DAB image and never will be.

```bash
mkdir -p ~/dab-bridge-v3 && cd ~/dab-bridge-v3
```

Upload `bridge/dab-config.json` and `bridge/Dockerfile` with Cloud Shell's upload button.
Upload accepts single files only and always drops them in the home directory regardless of
the working directory, so move them afterwards:

```bash
mv ~/dab-config.json ~/Dockerfile ~/dab-bridge-v3/
ls -l                       # confirm both are present before building
```

## Step 2 — Build and push the image

```bash
az acr build --registry reimbacr5955 --image reimb-dab-api:v3 .
```

`:v2` stays in the registry as the rollback point, the same way `:latest` was kept when v2
shipped.

## Step 3 — Point the container app at it

```bash
az containerapp update \
  --name reimb-dab-api \
  --resource-group RG-LRNAnalytics-SQL \
  --image reimbacr5955.azurecr.io/reimb-dab-api:v3
```

## Step 4 — Confirm the revision actually took traffic

`containerapp update` creates a revision; it does not guarantee it started. A bad
`key-fields` value or a mismatched parameter name makes DAB fail to boot, and you want that
from the revision list rather than from a confused agent.

```bash
az containerapp revision list -n reimb-dab-api -g RG-LRNAnalytics-SQL \
  --query "[].{Name:name,Active:properties.active,Traffic:properties.trafficWeight,State:properties.provisioningState}" \
  -o table
```

Expect the newest revision showing `Active: True`, `Traffic: 100`, `State: Provisioned`.
If not:

```bash
az containerapp logs show -n reimb-dab-api -g RG-LRNAnalytics-SQL --type console --tail 50
```

## Step 5 — Verify the bridge

**REST first** — it needs no MCP handshake, so it isolates the entity from the agent:

```bash
curl "https://reimb-dab-api.blackrock-c44bb33c.southcentralus.azurecontainerapps.io/api/ResolvePayerName?PayerText=carefirst"
```

**Then confirm the agent will see it.** Against `/mcp`, `describe_entities` must list
`ResolvePayerName` with an **EXECUTE** permission and a `PayerText` parameter. The bridge
already exposes an `execute_entity` tool alongside `read_records` (verified 2026-08-21 via
`tools/list`), so stored procedures are callable with no runtime change.

If the entity appears but shows no permissions, the `actions` array is wrong — a stored
procedure takes `execute`, never `read`.

**Confirm the existing four still work.** Adding an entity changes what `describe_entities`
returns, so re-run a known-good question before relying on the fifth.

## Step 6 — Update the agent instructions

In ai.azure.com, on the `ReimbursementAnalysis` agent. This is the **only** Foundry change —
the MCP tool connection, server URL and authentication all stay as they are, because the new
tool arrives on the address the agent already uses. Nothing uses it until this is added.

Wording below is written against the call shape and output verified live on 2026-08-25, not
against the original proposal:

```
# Resolving payer names

Users type short forms and aliases ("BCBS", "carefirst", "United") that do not
match PayerDisplayName in the data. Never filter PayerDisplayName using the
user's own words.

When a question names a payer:

1. Call execute_entity with entity "ResolvePayerName" and parameters
   { "PayerText": "<the payer words from the question>" }.
   It returns rows of { Family, PayerDisplayName }.

2. If it returns no rows, tell the user that no payer matching that name was
   found. Do not guess, and do not answer about a different payer.

3. Otherwise treat the returned PayerDisplayName values as the complete and only
   set of payers the question refers to. Query the relevant entity filtered by
   CPTCode or PanelName, then keep only the rows whose PayerDisplayName exactly
   matches one of the returned values.

4. Report every matching payer separately, following the existing per-lab and
   window-type process. Never merge them into one figure, and never use the
   Family name in place of a payer name in your response.

An exact full payer name resolves to itself, so run this step for every payer
question.
```

Step 3 filters by CPT and then keeps matching payers, rather than building a filter with a
dozen `or` clauses — `BCBS` alone resolves to well over a dozen payers. It also reuses the
path the instructions already take for questions that name no payer.

## Step 7 — Test

**Start a fresh Playground thread.** The MCP tool list is negotiated at session start, so an
existing thread will not see `ResolvePayerName`. Part A retesting hit this same thing.

| # | Question | Expected |
|---|---|---|
| 1 | Average reimbursement for carefirst for 87798 | Resolves; six labelled metrics, broken out by lab and payer |
| 2 | Average reimbursement for BCBS for 87798 | Resolves to every Blue Cross payer present, each reported separately |
| 3 | Average reimbursement for Aetna Better Health for 87798 | Resolves to the sub-brand, **not** to Aetna |
| 4 | The same question using a full stored payer name | Unchanged from before this deployment |
| 5 | A payer that does not exist | Says no matching payer was found; does not answer about a different one |
| 6 | A panel question using an alias | Resolves against the panel entity too |

Test 3 is the one that catches a broken priority order. Test 5 is the one that catches the
agent falling back to a guess.

Finish on the real screen: ask a question at
`/TestLrnAnalytics/ReimbursementChat` and confirm the same answer arrives through the proxy
and API Management.

---

## Rollback

Repoint the container app at the previous image. Nothing else needs undoing — the procedure
and the grant are additive and harmless if unused, and the agent instruction simply
references a tool that is no longer there.

```bash
az containerapp update -n reimb-dab-api -g RG-LRNAnalytics-SQL \
  --image reimbacr5955.azurecr.io/reimb-dab-api:v2
```

If the instruction was already saved, remove the "Resolving payer names" section too, or the
agent will keep trying to call a tool that has gone.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Entity missing from `describe_entities` | Image did not roll, or DAB rejected the config | Check the revision list (Step 4), then the console log |
| `sh: az: command not found` | You are inside the container from prerequisite 4, not in Cloud Shell | Ctrl+D, then run from Cloud Shell — `az` is not in the DAB image |
| `az acr build` cannot find the Dockerfile | The build context was never uploaded to Cloud Shell | Step 1 |
| Entity listed with no permissions | `actions` set to `read` | Stored procedures take `execute` |
| Agent never calls the tool | Instructions not saved, or an old chat thread | Save the instructions; start a fresh thread |
| Permission error at call time | `GRANT EXECUTE` missed | Prerequisite 2 |
| `Parameter ... not found` | Config parameter name does not match the procedure | Prerequisite 3 |
| DAB fails to start after update | Usually `key-fields` on a view | Compare against the live config pulled in Prerequisite 4 |
| Alias returns too many unrelated payers | Substring matching without word boundaries | Canonicalise both sides and pad with spaces so `UHC` cannot match inside `UHCSR` |

That last row matters: the .NET pipeline wraps every family pattern in `\b(?:...)\b`
precisely to stop short tokens firing inside longer names
(`LRN.PayerPolicyMapper.Core/PayerPolicyIndex.cs`). SQL `LIKE '%UHC%'` has no such
boundary, so the procedure must reproduce it.

---

## Related

| Document | Covers |
|---|---|
| [Payer_Alias_Resolution_v1.0.pdf](Payer_Alias_Resolution_v1.0.pdf) | The proposal: options considered, why the bridge, effort and risk |
| [`bridge/README.md`](../../bridge/README.md) | The bridge's entity list, config reconciliation notes, build commands |
| [Payer_Master_Reference_Tables_v1.1.md](../payer-master/Payer_Master_Reference_Tables_v1.1.md) | `PayerFamilyRule` and the other rules tables, and who maintains them |
| [Payer_Matching_Algorithm_Dev_Spec_v1.4.md](../payer-master/Payer_Matching_Algorithm_Dev_Spec_v1.4.md) | The claims-side pipeline this reuses the rules from |
