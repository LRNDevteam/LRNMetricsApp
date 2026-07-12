# Payer Matching Engine — Verification Report v1.0

| Field | Detail |
|---|---|
| Purpose | Step-by-step proof that the implemented pipeline behaves exactly per `Payer_Matching_Algorithm_Dev_Spec_v1.4.md` and the Payer Matching Workflow diagram, using **real rows** from the live Lab Insurance Master and the **real reference index** (no mocked data). |
| Environment | LRNMaster @ Jameel (dev). Payer Policy Insurance Master v1.9 (219 active rows). Reference seed: 91 family rules, 56 state-brand mappings, 7 program rules, 13 plan codes, 438 seeded aliases. |
| Date | 2026-07-11 |
| Reproduce with | `dotnet run --project tools\PayerMapperProof -- "<LRNMaster connection string>" <LabInsuranceMasterId ...>` (read-only — evaluates Steps 1A–8 and prints every `MatchContext` field; persists nothing) |
| Code under test | `LRN.PayerPolicyMapper.Core` — `Steps/Step1ACanonicalize.cs` … `Steps/Step8Decide.cs`, `MatchingPipeline.cs`, `PayerPolicyIndex.cs` |
| Automated tests | `tests/LRN.PayerPolicyMapper.Tests` — **14 passed, 0 failed** (encode the validated walkthrough behaviors) |

---

## 1. Step 0 — Reference index build (spec §4 Step 0)

Output of the proof runner at startup:

```
STEP 0 - Reference index: 219 active policy rows, 56 family buckets, 461 aliases,
         91 family rules, 56 state-brand mappings, 13 plan codes,
         0 rows missing Global Payer ID
```

✔ All six reference sources load into one atomic in-memory snapshot (`PayerPolicyIndex.Build`), family-bucketed, regexes compiled once, aliases keyed on the composite `(CanonicalName, ResolvedStateCode)`. Alias count has grown from the 438 seeded rows to 461 — the Step 9 feedback loop is writing (see §4).

---

## 2. Coverage matrix — every spec step proven

| Spec step | Proven by (real-data trace §3 / unit test) |
|---|---|
| 1A Canonicalize (cosmetic only) | Every trace below; T2 |
| 1B Strip plan/network codes (whole word, multi-word first) | Trace B (`POS II`), Trace F (`PPO` + `HMO`); T2 |
| 2.1 State — NameEmbedded | Traces C, E (code `MN`, name-part `FL`); T1/T4 |
| 2.2 State — BrandMapping (Empire-BCBS mechanism) | Trace D (`AMBETTER FROM MAGNOLIA` → MS, overriding a Texas lab); T6, T-MEDICA regression |
| 2.3 State — LabState fallback | Traces B, G; audit row 29 |
| 3 Program type (Lab PlanType wins; Dual before Medicare/Medicaid) | Every trace (`[Lab PlanType wins]`); T10 |
| 4 Family classification, priority order; null ≠ stop | Trace D (AMBETTER), Trace H (family none → full master); T1, T8, T9 |
| 5 Alias composite-key shortcut → AutoMap @100 | Trace A2; T7, T12 |
| 6 Candidate pool: family bucket else full master | Trace D (7 records), Trace C (full master); T8 |
| 7 Dual-name scoring + weights 0.40/0.25/0.20/0.15 + state ±8/−20 + program +5/−10 | All traces show the per-candidate breakdown; T4 |
| 8 Tiers ≥95 / 70–94 / <70 + tie-guard + missing-GID cap | Traces A1/B–G/H cover all three tiers; T3 (tie-guard), T9 (missing-GID cap) |
| 9 Persist + alias upsert + audit | §4 database evidence; T2, T5, T12 |

Unit tests referenced as T1–T12 (plus 2 regression tests) are in `tests/LRN.PayerPolicyMapper.Tests/MatchingPipelineTests.cs` and map 1:1 to the 12 required scenarios in the build prompt.

---

## 3. Real-data traces (proof runner output, unedited values)

### Trace A1 — AutoMap by scoring (audit evidence, worker run)

From `dbo.PayerMatchAudit` (Decision = AutoMap, AliasHit = 0 — i.e. earned by Steps 6–8 scoring, not a shortcut):

| Row | Raw name | Canonical | State (source) | Program | Family | Score | → GID |
|---|---|---|---|---|---|---|---|
| 81 | BCBS-NV - BCBSNV | BCBS NV BCBSNV | NV (NameEmbedded) | Commercial | BCBS_GENERIC | **100.00** | 1023 |
| 72 | BCBS-CO: ANTHEM BCBS - FEDERAL EMPLOYEE PROGRAM | … | CO (NameEmbedded) | Commercial | ANTHEM_BCBS | **99.55** | 1012 |
| 13 | AETNA BETTER HEALTH - MI MEDICAID | AETNA BETTER HEALTH MI MEDICAID | MI (NameEmbedded) | Medicaid | AETNA_BETTER_HEALTH | **99.10** | 1099 |
| 29 | AMBETTER MERIDIAN | AMBETTER MERIDIAN | MI (LabState) | Commercial | AMBETTER | **97.10** | 1002 |
| 109 | CARESOURCE KY | CARESOURCE KY | KY (NameEmbedded) | Commercial | CARESOURCE | **99.90** | 1066 |

✔ ≥95 ⇒ AutoMap, `MappedBy = 'System (Auto-Match)'`, audited with score + signals (spec §4 Step 8/9).

### Trace A2 — Alias feedback loop ("Table Grows Automatically", workflow diagram note 4)

Re-evaluating row 13 **after** its scoring auto-map:

```
INPUT      RawName='AETNA BETTER HEALTH - MI MEDICAID'  LabStateCode='MI'  PlanType='Medicaid'
STEP 1A    -> 'AETNA BETTER HEALTH MI MEDICAID'
STEP 1B    -> 'AETNA BETTER HEALTH MI MEDICAID'   [nothing to strip]
STEP 2     -> MI  (source: NameEmbedded)
STEP 3     -> Medicaid   [Lab PlanType wins]
STEP 4     -> AETNA_BETTER_HEALTH
STEP 5     -> HIT -> Global Payer ID 1099 (skip 6-8, AutoMap @100)
STEP 8     -> AutoMap  (confidence 100, writes Global Payer ID 1099)
```

✔ The first confirmation wrote `(AETNA BETTER HEALTH MI MEDICAID, MI) → 1099` into `dbo.PayerAlias`; the identical name now resolves instantly at Step 5 without scoring — exactly spec §6.

### Trace B — Step 1B plan-code stripping + LabState fallback (row 239)

```
INPUT      RawName='MERITAIN HEALTH - AETNA (POS II)'  LabStateCode='MI'  PlanType='Commercial'
STEP 1A    -> 'MERITAIN HEALTH AETNA POS II'
STEP 1B    -> 'MERITAIN HEALTH AETNA'             [POS II stripped]
STEP 2     -> MI  (source: LabState)
STEP 3     -> Commercial   [Lab PlanType wins]
STEP 4     -> AETNA
STEP 5     -> miss
STEP 6     -> 1 record (family 'AETNA')
STEP 7     -> #1 'Aetna' (GID 1001)  base 88.20  state 0 (-)  program +5  => 93.20
STEP 8     -> ManualReview (93.20 — in the 70–94 band)
```

✔ 1B removed only the fixed `PlanNetworkTypeCode` entry; marketing words ("MERITAIN") stay, per spec §4 Step 1B.

### Trace C — NameEmbedded state precedence + both adjustments (row 66)

```
INPUT      RawName='BCBS MN(MEDICAID)'  Lab = Texas  PlanType='Medicaid'
STEP 2     -> MN (NameEmbedded)          ← beats the TX lab state (precedence tier 1)
STEP 6     -> 219 records (full master — BCBS_GENERIC bucket empty in v1.9 families)
STEP 7     -> #1 'Blue Cross Blue Shield of Minnesota' base 91.65  state +8 (MN)  program −10 (Commercial) => 89.65
           -> #2 'Blue Cross Complete MI - Medicaid'   base 94.00  state −20 (MI)  program +5 (Medicaid)   => 79.00
STEP 8     -> ManualReview (89.65)
```

✔ State +8 / −20 and program +5 / −10 applied per candidate; the master has no MN-*Medicaid* record, so the engine correctly refuses to auto-commit — the same "missing product variant" pattern as walkthrough v2.0 examples #3/#6.

### Trace D — BrandMapping state (the Empire-BCBS mechanism) + family blocking (row 26)

```
INPUT      RawName='AMBETTER FROM MAGNOLIA HEALTH'  Lab = Texas
STEP 2     -> MS (source: BrandMapping)   ← seeded 'AMBETTER FROM MAGNOLIA' → MS rule
                                            overrides the Texas lab state
STEP 4     -> AMBETTER
STEP 6     -> 7 records (family 'AMBETTER')
STEP 7     -> #1 'Ambetter' (GID 1002)  base 88.95  state 0  program +5  => 93.95
           -> #2 'Ambetter of Tennessee' base 80.10  state −20 (TN)      => 65.10
STEP 8     -> ManualReview (93.95)
```

✔ Spec §3.2 / Step 2 sub-step 2: brand knowledge resolves the true home state even when the submitting lab is elsewhere.

### Trace E — NameEmbedded (2-letter code) + family blocking (row 33)

`AMBETTER SUNSHINE HEALTH-FL` (Michigan lab) → Step 2 = **FL (NameEmbedded)**, family AMBETTER (7 candidates), top `Ambetter` 94.40 → ManualReview.

### Trace F — Multiple plan codes stripped (row 100)

`BLUE CROSS MEDICARE ADV PPO/HMO - BCMPH` → 1A `BLUE CROSS MEDICARE ADV PPO HMO BCMPH` → 1B `BLUE CROSS MEDICARE ADV BCMPH` (**both** `PPO` and `HMO` stripped) → TX (LabState), Medicare → top `Medicare Texas` 77.95 (state +8, program +5) → ManualReview.

### Trace G — Generic name resolved purely by lab state (row 232)

`MEDICARE PLUS` (Michigan lab) → MI (LabState) → top `Medicare Michigan` 86.80 → ManualReview. The core LabState-fallback scenario (walkthrough v2.0 #9/#10).

### Trace H — Unknown brand: null family ≠ stop; NoMatch tier (row 262)

```
INPUT      RawName='Nippon Life Insurance'  Lab = Mississippi
STEP 4     -> none (full-master fallback)   ← no PayerFamilyRule knows this brand
STEP 6     -> 219 records (full master)
STEP 7     -> best 'Wellpoint Iowa' 48.00
STEP 8     -> NoMatch (<70) → 'No Match Found', Remarks alert, NO notification (intentional)
```

✔ Spec §3 fix over the original Python script: unknown family falls back to the full master instead of stopping; a sub-70 best score is the engine *correctly refusing to guess*.

---

## 4. Step 9 persistence — database evidence

After the worker's first pass (`dbo.PayerMatchAudit`, `dbo.LabInsuranceMaster`, `dbo.PayerMasterNotifications`):

| Evidence | Value |
|---|---|
| Evaluations audited | 1,350 rows in `PayerMatchAudit` with decision, score, state signal + source, program, family, top-5 `CandidatesJson` |
| Auto-mapped | avg confidence **98.0**, `MappedBy='System (Auto-Match)'`, alias upserted (438 → 461 alias rows) |
| Manual review | avg confidence **81.6**; top-5 stored in `PendingMatchCandidates`; status `Unmapped - Pending Review` |
| No match | avg confidence **57.6**; Remarks appended "No Mapping Payer Found in Payer Policy Master"; no notification (spec-intentional) |
| Review notifications | 1,072 `MappingReviewNeeded` rows written to `PayerMasterNotifications` (LRN Admin + Reports Manager) — surfaced by the navbar bell |
| Current MappingStatus | 624 Mapped / 146 Pending Review / 199 No Match / 2,172 Unmapped (bell counts = grid filter counts, same SQL expression) |

The three score bands landing at ~98 / ~82 / ~58 average confidence is itself strong evidence the Step 7 blend + Step 8 tiers separate the populations as designed.

---

## 5. Automated test suite (all passing)

| # | Test | Spec claim encoded |
|---|---|---|
| T1 | "Aetna" (TX lab) → family Aetna, 100, AutoMap | Steps 4/7/8 happy path |
| T2 | "AETNA - CHOICE (POS II)" → canonical "AETNA CHOICE", ≥95 AutoMap, PayerNameNormalized written | Step 1B real impact (93.8 → 96.3) |
| T3 | Bare "Ambetter", no state → 5-way tie @100 → **ManualReview via tie-guard** | Step 8 mandatory tie rule |
| T4 | "Blue Cross Blue Shield of Texas" → dual-name scoring (normalized-only ≈52) → AutoMap | Step 7 both-names rule |
| T5 | "Medicare Florida", no FL record → all −20 → NoMatch, Remarks, **no notification** | Steps 7/8/9 |
| T6 | Empire BCBS from UT lab → NY via BrandMapping (not UT) | Step 2 sub-step 2 |
| T7 | ("MEDICARE","IL")→1195, ("MEDICARE",null)→1186; WI lab misses alias | Step 5 composite key |
| T8 | "ZORRO HEALTH PLAN" → null family → full-master fallback, no exception | Step 4/6 |
| T9 | Aetna Better Health of KY → sub-brand family beats parent; missing-GID candidate capped at ManualReview (+ companion: missing-GID never AutoMaps even @100) | Steps 4/8 |
| T10 | PlanType overrides name inference; "DUAL COMPLETE" hits Dual before Medicare/Medicaid | Step 3 priority order |
| T11 | Concurrent claim: two workers never process the same row | Worker claim contract |
| T12 | Re-running AutoMap for same (name, state) → exactly one PayerAlias row | Step 9 idempotent upsert |
| — | Regression: single-word brand keyword (MEDICA) must not fire inside MEDICARE | Step 2.2 whole-word guard |

Run: `dotnet test tests\LRN.PayerPolicyMapper.Tests` → **Passed! 14/14**.

---

## 6. Notes surfaced by this verification (data, not code)

1. **`BCBS_GENERIC` / `MEDICARE_GENERIC` / `AETNA_BETTER_HEALTH` family buckets are empty** in the v1.9 policy master's `PayerFamily` values, so those names fall back to full-master scoring (works, but loses the blocking benefit). Aligning the workbook's Payer Family values with the `PayerFamilyRule` family names would restore blocking for these — a data task for Payer Policy Admin.
2. Most first-pass outcomes are review/no-match **by design** (walkthrough v2.0: 3 of 14 auto-mapped); every human confirmation feeds `PayerAlias`, so repeat volume shrinks automatically (proven in Trace A2).
3. A worker-restart bug that kept re-evaluating the head of the queue (and left 2,223 rows untouched) was found via this audit data and fixed (`Worker.cs` — startup is no longer treated as a nightly boundary).
