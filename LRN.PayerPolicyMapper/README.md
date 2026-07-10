# LRN Payer Policy Mapper

Automatic Global Payer ID mapping for `dbo.LabInsuranceMaster` against `dbo.PayerPolicyInsuranceMaster`
(both in **LRNMaster**). New lab payer rows arrive with only `PayerNameRaw` populated; this system
canonicalizes the name, resolves state/program/family signals, fuzzy-scores candidates and either
auto-maps, queues ranked suggestions for a person, or flags "No Match Found".

## How the pieces fit

| Piece | Role |
|---|---|
| **LRN.PayerPolicyMapper.Core** (class library) | The matching pipeline (Steps 0–9), the in-memory reference index, and the SQL repositories. Built once, referenced by both hosts below so the web app and the worker run the *same* logic. |
| **LRN.ReportsApi** (existing web API) | Upload hook (evaluates just-imported rows synchronously and returns `{ autoMapped, pendingReview, noMatch }` in the import summary), `GET api/master-values/insurance-payers/{id}/suggestions`, ranked typeahead `GET api/master-values/payer-policy-insurance/search?q=`, and the three explicit actions `POST .../mapping/approve`, `.../mapping/manual`, `.../mapping/reject`. |
| **LabMetricsDashboard** (existing MVC app) | The Lab Insurance Master screen's **Match** button now shows the pipeline's ranked suggestions with score breakdowns (name / state / program), the missing-Global-Payer-ID flag, a ranked manual search box, and Approve / Manual Map / Reject actions. |
| **LRN.PayerPolicyMapper** (new Worker Service / Windows service) | Poll loop (default 30 s) claiming unmapped rows with `UPDATE TOP … OUTPUT` + `READPAST` (multiple instances never double-process), rules-change re-evaluation, and a nightly 02:00 UTC safety-net rescan of all unmapped rows. |
| **tests/LRN.PayerPolicyMapper.Tests** | 13 xUnit tests encoding the validated real behavior from the walkthrough documents (tie-guard, dual-name scoring, composite alias keys, concurrent claim, alias idempotency, …). |

### The pipeline (Core/Steps, do not tune)

1A canonicalize → 1B strip plan codes (`POS II` before `POS`; result is written to
`PayerNameNormalized`) → 2 resolve state (name-embedded → StateBrandMapping → lab state; the source
gates the tie rule) → 3 program type (`PlanType` wins, else ProgramTypeRule by priority) →
4 family (PayerFamilyRule by priority; null family falls back to the full master) → 5 alias
shortcut on the **composite** key `(CanonicalName, ResolvedStateCode)` → 6 candidate pool →
7 fuzzy score (`0.40·TokenSet + 0.25·Weighted + 0.20·Partial + 0.15·TokenSort` against **both** the
candidate's raw and normalized names, better wins; state ±8/−20, program +5/−10) → 8 decide
(≥95 auto-map, 70–94 review, <70 no-match, plus the mandatory tie-guard and the
missing-Global-Payer-ID cap) → 9 persist + `dbo.PayerMatchAudit` + `dbo.PayerAlias` upsert.

### Upload hook choice

The existing Lab Insurance Master import is synchronous (single HTTP request through
`SqlMasterValuesRepository.ImportInsurancePayersAsync`), so the pipeline runs **synchronously in the
import request** for the just-imported unmapped rows and the summary appears immediately in the
upload result. Rows saved with a Global Payer ID conflict (Import-vs-Policy modal) are excluded —
they wait for the user's choice. Anything the request misses is picked up by the worker within one
poll cycle.

## Deployment

1. Run `LRN.ReportsApi/Sql/Payer_Matching_Reference_Tables_DDL_and_Seed.sql` (already deployed in
   most environments — it seeds the rules tables and 438 aliases).
2. **Run `LRN.ReportsApi/Sql/001_payer_mapper_additions.sql` before deploying this build** — it is
   idempotent and adds `MappingStatus` / `MappedBy` / `LastEvaluatedOn` to `LabInsuranceMaster`
   (with backfill) plus `PendingMatchCandidates` and `PayerMatchAudit`. The web app's Lab master
   queries reference these columns, so the script is a hard prerequisite.
3. Deploy LRN.ReportsApi + LabMetricsDashboard as usual.
4. Install the worker as a Windows service (`LRN - Payer Policy Mapper`), pointing
   `ConnectionStrings:DefaultConnection` at the same LRNMaster as the API.

## Configuration knobs (worker `appsettings.json`; thresholds also honored by the API)

```json
"PayerMapper":   { "PollIntervalSeconds": 30, "BatchSize": 50, "NightlyHourUtc": 2 },
"PayerMatching": { "AutoMapThreshold": 95, "ReviewThreshold": 70, "TieMarginPoints": 0.5, "TopCandidates": 5 }
```

## GlobalPayerId type mismatch (known, intentional)

`PayerPolicyInsuranceMaster.GlobalPayerId` is `nvarchar(50)`; `LabInsuranceMaster.GlobalPayerID` is
`int`. The index loads the policy side with `TRY_CONVERT(INT, …)`; rows where the cast fails (e.g.
the real "Aetna Betterhealth" row with no id) are still loaded as **manual-review-only candidates**
— they are suggested with a "No Global Payer ID on file" flag but can never be auto-mapped or
approved, and a startup warning lists them. All mapping writes store the parsed int.
**Recommended future migration:** convert `PayerPolicyInsuranceMaster.GlobalPayerId` to `INT`
(after fixing the non-numeric rows) and add a foreign key from `PayerAlias.GlobalPayerId`. Do not
change the columns until then.

## How business users extend the rules without a deploy

All matching knowledge lives in LRNMaster tables; the index rebuilds automatically (worker: on the
next poll cycle via the rules-version watermark, web app: within ~5 minutes):

- **New brand family / sub-brand:** insert into `dbo.PayerFamilyRule` (lower `Priority` = evaluated
  first; use 10 for sub-brands that must beat their parent, 50 standard, 900 catch-alls).
- **Brand → home-state:** insert into `dbo.StateBrandMapping` (e.g. a new regional Blue). This can
  rescue previous "No Match Found" rows on the next cycle.
- **New coverage keyword:** `dbo.ProgramTypeRule` (keep the NULL-pattern Commercial row last at 999).
- **New plan/network code to strip:** `dbo.PlanNetworkTypeCode`.
- **Known alias:** confirmed mappings land in `dbo.PayerAlias` automatically on every AutoMap /
  Approve / Manual Map; hand-seeding a row (CanonicalName must be the Step-1B canonical form) makes
  that name map instantly.

Note: `PlanNetworkTypeCode` has no audit-date columns, so its watermark uses row count + max id —
an in-place `UPDATE` there may not trigger an immediate rebuild (the nightly rescan still covers it).

## Operational notes

- **Worker claim semantics:** stamping `LastEvaluatedOn` *is* the claim. A row whose evaluation
  throws stays claimed (so a poison row cannot wedge the loop) and is retried on the next rules
  change or nightly rescan.
- **Reject** is audit-only by design: the row stays `Unmapped - Pending Review` with its stored
  candidates.
- **Approval-routed roles** (Reports Analyst): the new Approve/Manual Map/Reject actions write
  directly, so they are limited to roles with direct-write authority; analysts keep the legacy
  Confirm Mapping flow, which goes through the LRN Admin / Reports Manager approval queue (that
  path does not write `PayerAlias` — an approver re-confirming via the new flow does).
- Review notifications go to the existing `dbo.PayerMasterNotifications` mechanism
  (`TriggerType = 'MappingReviewNeeded'`); NoMatch is intentionally silent apart from the Remarks
  note "No Mapping Payer Found in Payer Policy Master".
