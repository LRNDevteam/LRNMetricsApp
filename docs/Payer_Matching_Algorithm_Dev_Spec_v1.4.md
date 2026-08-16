# Payer Matching Engine — Developer Implementation Spec

Companion to `Payer_Master_Requirements_v1.7.md` (functional requirements), `clarifications_log.md` (decision history), and `Payer_Master_Reference_Tables_v1.1.md` (full schema for every supporting rules/alias table referenced below). This document specifies the step-by-step algorithm, the C# libraries to use at each step, and the input/output of each step, so the engineering team can implement without re-deriving the design decisions already made.

**v1.1 changes:** Step 1 is split into two distinct sub-steps — cosmetic cleanup (1A) and stripping known network/plan-type codes like "PPO"/"POS II" (1B), which was previously only described as a *recommendation* in the worked examples, not an actual pipeline step. Also added Section 3.1 ("Rules Engine vs. Reasoning") and Section 3.2 ("Capturing Brand-to-State Knowledge") to make an easy-to-miss limitation explicit: the family and state-brand rules only know what a person explicitly taught them — see those sections before assuming the system can "figure out" a new brand the way a person reading this doc can.

**v1.2 changes:** `PayerAlias` is now keyed on `(canonicalName, resolvedStateCode)` instead of `canonicalName` alone (Step 5, Section 6). A `canonicalName`-only key lets a state-ambiguous raw name (e.g., bare "Medicare") that was only resolved via one lab's `LabState` fallback get silently reused for a completely different lab in a different state. This isn't theoretical — it's a real case found by running this pipeline logic against the live Lab Insurance Master (v1.8.4): the bare canonical name "MEDICARE" already resolves to two different Global Payer IDs (1195 for an Illinois lab, 1186 with no state signal) among the 521 rows that already carry a confirmed `Global_Payer_ID`. Section 6 also now explains why `PayerAlias` is a separate table rather than a query against Lab Insurance Master directly.

**v1.3 changes:** Added an explicit `MatchContext` object (Section 9) that is created once per raw name and threaded through every step in Section 4, and annotated each step's Input/Output against it. This closes a real ambiguity: once Step 4 classifies a family and Step 6 narrows the candidate list, does Step 7 score the *family name* against the candidates, or does it still use the *original* canonical name and state? **It uses the originals, unchanged.** `CandidateFamily` (Step 4) and `Candidates` (Step 6) are fields *added alongside* `CanonicalName` and `ResolvedStateCode`, not replacements for them. See the explanatory block at the top of Section 4.

**v1.4 changes:** Two related gaps closed. First, Section 2's supporting-tables list only named `PayerAlias` and `PayerMatchAudit` — it was missing `PayerFamilyRule`, `StateBrandMapping`, `ProgramTypeRule`, and `PlanNetworkTypeCode`, even though Steps 1B, 2, 3, and 4 all depend on them. All four are now listed, and Steps 1B/2/3/4 each name the exact table they read from instead of describing it only in prose. Second, and found while fixing the first: Section 3.2 already claimed Step 2 checks `StateBrandMapping` before falling back to Lab State, but Step 2's own ordered algorithm never actually included that check — it only had "state in the name" and "Lab State fallback." Step 2 now has three ordered sub-steps instead of two, and `StateSignalSource` gains a new `BrandMapping` value (Section 9) to record which of the three resolved it, since that distinction goes into the audit trail like the others.

## 1. Purpose

Given a raw payer name from the Lab Insurance Master (plus its Lab State and, if present, Plan Type), determine the correct Global Payer ID from the Payer Policy Insurance Master — automatically where confidence is high, routed to a human where it isn't, and clearly flagged when no match exists at all.

## 2. Data Inputs Required

**Payer Policy Insurance Master** (reference/target table, ~230 rows today):
- `Payer_Name`, `Payer_Name_Normalized`, `Global_Payer_ID`, `Payer_Family` (new field — see Section 3), `Payer_State`, `Plan_Type`, `Is_Active`

**Lab Insurance Master** (source table, one row per Payer + Lab combination):
- `Payer_Name_Raw`, `Lab_State`, `Plan_Type` (if populated at sync time), `Global_Payer_ID` (nullable until mapped), `Mapping_Status`, `Review_Flag`

**Supporting tables (new, needed for this design)** — full column-level data model for every table below lives in `Payer_Master_Reference_Tables_v1.1.md`; this list just states what each one is for and which step consumes it:

| Table | Feeds which step | One-line purpose |
|---|---|---|
| `PlanNetworkTypeCode` | Step 1B | Fixed list of network/plan codes (PPO, HMO, POS II, ...) stripped before scoring |
| `StateBrandMapping` | Step 2 (2nd sub-step, before Lab State fallback) | Brand → home-state lookup for brands like Empire that don't spell out their state in the name |
| `ProgramTypeRule` | Step 3 | Keyword rules that detect Medicare/Medicaid/Commercial/Exchange/Federal/Dual |
| `PayerFamilyRule` | Step 4 | Ordered brand-family classification rules used as the Step 6 blocking key |
| `PayerAlias` | Step 5 | Confirmed `(canonicalName, resolvedStateCode) → Global Payer ID` mappings (composite key — see Step 5 and Section 6), seeded from historical confirmations and grown automatically (Section 8) |
| `PayerMatchAudit` | Step 9 | One row per evaluation/decision, per Section 6 of the requirements doc |

## 3. Where "Payer Family" Fits

Payer Family is a **blocking key**, not a matching output. It narrows the candidate pool before fuzzy scoring runs, both for speed and — more importantly — to stop structurally different products with similar names (e.g., "Aetna" vs. "Aetna Better Health") from being scored against each other in the first place. If a raw name's family can't be determined, the engine does **not** stop — it falls back to scoring against the full active Payer Policy Master rather than giving up (see Step 6). Family classification affects which tier a match can reach, not whether matching is attempted at all — this is the specific bug found in the original Python script that this design corrects.

### 3.1 Rules Engine vs. Reasoning — read this before assuming the system is "smart"

Everything in Steps 3 and 4 below — recognizing that "IDPA" means Illinois Medicaid, that "Railroad" should route to Palmetto GBA, that "AARP"-branded Medicare Advantage plans are underwritten by UHC — works **only because a person wrote each of those facts down as an explicit rule ahead of time**, in `ProgramTypeRule` or `PayerFamilyRule`. The C# code has no general knowledge of the health insurance industry. It is a lookup against a list, not a reasoning process. If a new abbreviation or brand shows up tomorrow that nobody thought to add — a new TPA acronym, a new regional Medicaid brand name, a new Medicare contractor — the system will not "figure it out" the way a person reading this document can. It will either misclassify it or, more likely, return no family match at all (`CandidateFamily = null`), the exact same "family_unknown" failure mode already found and diagnosed in the original Python script's rules CSV.

**Practical implication for the team:** the family-rule list and the state-brand list (Section 3.2) are not "set once and done" configuration — they are a living reference dataset that needs the same ongoing ownership as the Payer Policy Insurance Master itself. Two ways to keep it current without requiring a person to manually notice every gap:
1. **The alias table (Section 6) captures the "answer" permanently after the first human confirmation**, regardless of whether a family rule ever existed for it — so even an unrecognized brand only costs one manual review, not a repeat one, and the algorithm's rule gaps never block a name from eventually becoming instant/deterministic.
2. **An optional LLM-assisted fallback**, discussed earlier in this project, can propose a family/brand/state guess for anything the deterministic rules don't cover — but its answer should feed into the same scoring-and-human-review pipeline as everything else, never write a `Global_Payer_ID` directly. That preserves the auditability the rest of this design is built around.

### 3.2 Capturing Brand-to-State Knowledge (the "Empire BCBS" problem)

A related but separate gap: without an explicit lookup, state resolution only looks *inside the raw text* or falls back to the *lab's* state — it has no notion that "Empire Blue Cross Blue Shield" is specifically a New York brand, because that fact isn't written anywhere in the name itself. When the lab happens to be in a different state (a real, observed case: a Utah lab submitting an Empire BCBS claim), the Lab-State fallback actively points the wrong direction, and no rule catches it. This is the exact same category of gap as Section 3.1 — outside knowledge that has to be explicitly captured somewhere, because the system cannot infer it from the text alone.

This is why Step 2 (below) has three ordered sub-steps, not two: a hand-curated `StateBrandMapping` table (e.g., "HOME STATE HEALTH → MO", "SUPERIOR HEALTH → TX," and now "EMPIRE → NY") is checked *after* looking for a state embedded in the text but *before* falling back to Lab State. Empire simply wasn't in that table before — add a row and Step 2 resolves it correctly on every future occurrence, the same way it already handles a state spelled out in the name. This is the cheapest of three mitigations, in increasing order of effort:
1. **`StateBrandMapping`**, as just described — the cheapest fix, and should be extended for every well-known single-state brand as it's discovered — Empire, Wellmark (IA/SD), HMSA (HI), and any others surfaced through testing or production review queues.
2. **The alias table (Section 6), same as Section 3.1.** Once a person confirms "Empire Blue Cross Blue Shield - EMPBC" maps to the New York record one time, that exact raw string is remembered permanently — no state-guessing needed for that variant ever again.
3. **LLM fallback**, same caveat as above — useful for brands nobody has hard-coded yet, but its output is a *suggested* candidate for a human to confirm, not an authoritative write.

## 4. Step-by-Step Pipeline (Real-Time, on new/unmapped Lab Insurance Master record)

**How data flows between steps — read this before Step 0.** Every step below reads from and writes to one shared `MatchContext` object, created once per incoming raw name (full C# definition in Section 9). This is worth being explicit about, because it answers a question that's easy to get wrong otherwise: once Step 4 classifies a family and Step 6 narrows the candidate list, does Step 7 score the *family name* against the candidates, or does it still use the *original* canonical name and state?

**It uses the originals, unchanged.** `CanonicalName` (set in Step 1B) and `ResolvedStateCode` (set in Step 2) are never overwritten or replaced by later steps — they sit on `MatchContext` exactly as set until Step 9 persists the result. `CandidateFamily` (Step 4) and `Candidates` (Step 6) are *additional* fields added alongside them, used only to decide which Payer Policy Master records are worth scoring — the family name itself is never compared against anything.

Worked example — Lab "Beach Tree" (Utah) sends raw name "Aetna":

| `MatchContext` field | Set by | Value in this example |
|---|---|---|
| `RawName` | Step 1A (input) | `"Aetna"` |
| `CanonicalName` | Step 1B | `"AETNA"` |
| `ResolvedStateCode` | Step 2 | `"UT"` (Lab State fallback — no state in the text, no `StateBrandMapping` hit either) |
| `ResolvedProgramType` | Step 3 | `"Commercial"` |
| `CandidateFamily` | Step 4 | `"Aetna"` — used only to filter, never itself compared |
| `Candidates` | Step 6 | `[ Global ID 1001 ]` — the one record in the Aetna family |
| `ScoredCandidates` | Step 7 | `[ (1001, score ≈ 100) ]` — scores `CanonicalName` "AETNA" against candidate 1001's `Payer_Name` "Aetna", and `ResolvedStateCode` "UT" against candidate 1001's blank `Payer_State` (adjustment = 0, since the candidate side is missing) |
| `Decision` / `ConfidenceScore` | Step 8 | `AutoMap` / `100` |

Every field above lives on the *same object* for the life of this one match attempt — nothing is computed and thrown away between steps. Later steps simply see more filled-in fields than earlier ones; they never see *fewer* or *substituted* ones. Keep this table format in mind — it's a useful way to trace any future example through the pipeline field by field.

### Step 0 — Reference Index Build (startup + on Payer Policy Master or rules-table change)
- **What:** Load all active Payer Policy Insurance Master records into memory, indexed two ways: `Dictionary<string PayerFamily, List<PayerPolicyRecord>>` (for blocking) and `Dictionary<string NormalizedName, PayerPolicyRecord>` (for exact lookups). Also load the four rules tables and `PayerAlias` into memory:
  - `PlanNetworkTypeCode` → `List<string>` (Step 1B)
  - `StateBrandMapping` → ordered `List<(string BrandKeyword, string StateCode)>` (Step 2)
  - `ProgramTypeRule` → ordered `List<(string ProgramType, string Pattern)>` (Step 3)
  - `PayerFamilyRule` → ordered `List<(string Family, string Pattern)>` (Step 4)
  - `PayerAlias` → `Dictionary<(string CanonicalName, string? ResolvedStateCode), int GlobalPayerId>` (Step 5, composite key)
- **Note on lifetime:** all of the above are long-lived, shared objects rebuilt on the relevant table's change events — they are **not** part of `MatchContext`. `MatchContext` is created fresh for every single raw name evaluated; these indexes are read by many `MatchContext` instances concurrently.
- **Library:** Entity Framework Core or Dapper to query; `ConcurrentDictionary<TKey,TValue>` or `IMemoryCache` to hold the indexes in memory; refresh triggered by a change event on the relevant table (add/edit/deactivate a rule or a Payer Policy Master record) or a timer.
- **Output:** In-memory `PayerPolicyIndex` object (bundling all of the above), reused across all Step 1–9 calls until invalidated.

### Step 1A — Canonicalize the raw name
- **What:** Uppercase, strip punctuation, collapse whitespace. Same transformation applied to both the incoming raw name and every reference name, so comparisons are apples-to-apples. **This step does not remove any words — it only standardizes formatting.** A name like "Aetna - Choice (POS II)" becomes "AETNA CHOICE POS II" here; the plan-network wording is still present at the end of this step.
- **Library:** `System.Text.RegularExpressions` (`Regex.Replace`).
- **Input:** `MatchContext.RawName`
- **Output:** Written to `MatchContext.FormattedName`.

### Step 1B — Strip known network/plan-type codes
- **What:** Remove every code listed in the `PlanNetworkTypeCode` table if it appears as a whole word: `POS II, HDHP/HSA, PPO, HMO, EPO, POS, HDHP, HSA, CDHP, FFS, ACO, SNP, PFFS` today (the same list already used in the original Python script for a different purpose — extracting plan type — repurposed here to strip it before scoring, since it's just noise for name-matching). **Only this fixed, generic table is safe to strip automatically.** Payer-specific marketing product names like "Choice," "Select," or "Signature Administrators" are deliberately *not* in `PlanNetworkTypeCode` and are not stripped here, because there's no safe generic rule for them — a word list broad enough to catch "Choice" would also strip meaningful words elsewhere (e.g., "Medicare Advantage" must keep the word "Advantage"). Those get absorbed the same way brand/state gaps do — see Section 3.1 — by the alias table remembering the full confirmed name after a human reviews it once.
- **Library:** `System.Text.RegularExpressions`.
- **Input:** `MatchContext.FormattedName`, `PlanNetworkTypeCode` (loaded in Step 0)
- **Output:** Written to `MatchContext.CanonicalName` — **this field is never overwritten again for the life of this match attempt.** Steps 2–7 all read it as-is.
- **Example, real data:** "AETNA CHOICE POS II" → "AETNA CHOICE." The base text-similarity score against "Aetna" moves from 88.75 to 91.32 just from dropping "POS II" — which, after the state/program adjustments in Step 7, moves the *final* score for that example from 93.75 (just under the auto-map bar) to 96.32 (clears it). See `Payer_Matching_Walkthrough_Examples_v2.0.md`, example #1, which was run *before* this step existed and should be re-read with that in mind.

### Step 2 — Resolve the state signal (three ordered sub-steps)
- **What, in strict order:**
  1. Try to parse a U.S. state code or state name directly out of `CanonicalName` (regex/dictionary lookup against all 50 states + DC, both full names and 2-letter codes) → `StateSignalSource = NameEmbedded`.
  2. If none found, check `StateBrandMapping` (loaded in Step 0) for a `BrandKeyword` match against `CanonicalName` → `StateSignalSource = BrandMapping`. This is the Section 3.2 fix — it's what lets "Empire Blue Cross Blue Shield" resolve to NY even though the word "New York" never appears in the name, without needing the submitting lab to also be in NY.
  3. If still nothing, fall back to `LabState` (converted to a 2-letter code via the same lookup table) → `StateSignalSource = LabState`.
  4. If none of the three produce a value, state signal is null → `StateSignalSource = None`.
- **Library:** `System.Text.RegularExpressions` + a static `Dictionary<string,string>` (state name → code), ported directly from `STATE_NAME_TO_CODE` in the existing Python script, plus the `StateBrandMapping` dictionary from Step 0.
- **Input:** `MatchContext.CanonicalName`, `MatchContext.LabState`, `StateBrandMapping` (loaded in Step 0)
- **Output:** Written to `MatchContext.ResolvedStateCode` (nullable) and `MatchContext.StateSignalSource` (enum: `NameEmbedded | BrandMapping | LabState | None`) — **also never overwritten again.** The source is recorded because it goes into the audit trail (Section 6 of requirements doc) and because it's what makes the Step 5 composite-key logic safe (a `BrandMapping` or `NameEmbedded` source is a durable fact about the payer; a `LabState` source is only a fact about *this specific lab*).

### Step 3 — Resolve the program/plan type signal
- **What:** Regex match `CanonicalName` against the `ProgramTypeRule` table's ordered keyword list (Medicare, Medicaid, Commercial, Exchange, Federal, Dual — same categories as the existing script's `detect_program_type`). If `LabPlanType` was already populated on the Lab record at sync time, that takes precedence over inferring from the name.
- **Library:** `System.Text.RegularExpressions`.
- **Input:** `MatchContext.CanonicalName`, `MatchContext.LabPlanType` (if present), `ProgramTypeRule` (loaded in Step 0)
- **Output:** Written to `MatchContext.ResolvedProgramType`.

### Step 4 — Family classification (blocking key)
- **What:** Run `CanonicalName` through the `PayerFamilyRule` table's ordered pattern list (same structure as the `Payer Family` column just added to the Payer Policy Master — e.g., Aetna Better Health before Aetna, Anthem BCBS before generic BCBS, and so on). **Ordering matters:** more specific brand rules must be checked before generic catch-all rules, or specific brands get miscategorized into the generic bucket (this exact bug was caught and fixed in the reference data — see the rule-ordering note in the family classification script).
- **Library:** `System.Text.RegularExpressions`, rules expressed as an ordered `List<(string Family, string Pattern)>` — loaded from `PayerFamilyRule` (a maintainable table, not hard-coded), so business can extend it without a code deploy.
- **Input:** `MatchContext.CanonicalName`, `PayerFamilyRule` (loaded in Step 0)
- **Output:** Written to `MatchContext.CandidateFamily` (nullable). **This is an additional field, not a replacement for `CanonicalName` or `ResolvedStateCode` — those remain untouched.** If null, do not stop — proceed to Step 6 with no family filter (full-master fallback).

### Step 5 — Alias / manual-override exact match
- **What:** Look up `(CanonicalName, ResolvedStateCode)` in the `PayerAlias` dictionary built in Step 0. **The key is a composite of both fields, not `CanonicalName` alone** — see the note below for why.
- **Why the composite key matters:** for a name where the state is embedded in the text itself (e.g., "AMBETTER OF ALABAMA") or resolved via `StateBrandMapping` (e.g., "EMPIRE BLUECROSS"), `CanonicalName` alone is already effectively unambiguous — every lab that ever sends that exact text means the same payer. But for a bare, state-ambiguous name — plain "Medicare," "Medicaid," "Aetna Better Health" with no state in the text and no `StateBrandMapping` entry — the *only* reason Step 2 resolved a state at all was the **submitting lab's own state** (`StateSignalSource = LabState`). If the alias table cached that answer under `CanonicalName` alone, a completely different lab in a different state sending the same bare text would silently inherit the first lab's state-specific answer — which is exactly the kind of silent wrong auto-map this whole design exists to prevent. This is not a hypothetical: running this logic against the real Lab Insurance Master (v1.8.4, 521 already-mapped rows) surfaced one live case — the bare canonical name "MEDICARE" resolves to Global Payer ID 1195 for a lab in Illinois (`StateSignalSource = LabState`) and to Global Payer ID 1186 for a lab with no state signal at all. A `CanonicalName`-only key would have forced one of those two real, valid answers onto the other.
- **Library:** Plain dictionary lookup, O(1), keyed on a tuple/composite string (e.g., `"MEDICARE|IL"`).
- **Input:** `MatchContext.CanonicalName`, `MatchContext.ResolvedStateCode` (both already sitting on the context since Steps 1B and 2 — Step 5 doesn't re-derive them)
- **Output:** Written to `MatchContext.AliasHitGlobalPayerId` (nullable). **If found, skip directly to Step 9 with `ConfidenceScore = 100` and `Decision = AutoMap` — no need to run Steps 6–8.**
- **Side effect of the composite key:** unambiguous national payers (e.g., "AETNA" with no state in the text) will still generate one alias row per distinct `ResolvedStateCode` they've been seen with, even though they all resolve to the same Global Payer ID — some redundancy, but it costs nothing at lookup time and guarantees correctness for the ambiguous cases. In the real data this produced 438 alias rows from 521 mapped source rows — not a 1:1 reduction, but each row is now safe to trust blindly.

### Step 6 — Candidate set selection (blocking)
- **What:** If `CandidateFamily` is not null, candidates = all active Payer Policy Master records where `Payer_Family == CandidateFamily`. If `CandidateFamily` is null, candidates = **all** active Payer Policy Master records (full-master fallback — this is the fix over the original script, which incorrectly stopped here instead of falling back).
- **Library:** LINQ (`.Where()`) over the in-memory index from Step 0.
- **Input:** `MatchContext.CandidateFamily`, `PayerPolicyIndex` (the Step 0 index, not `MatchContext`)
- **Output:** Written to `MatchContext.Candidates`. **This narrows *which* records will be scored in Step 7 — it does not touch `CanonicalName` or `ResolvedStateCode`, which remain exactly as Steps 1B and 2 set them.**

### Step 7 — Fuzzy scoring against each candidate
- **What:** For each candidate in `MatchContext.Candidates`, compute a blended base name score, then apply state and program-type adjustments.
  - **Base name score** = `0.40 × TokenSetRatio + 0.25 × WeightedRatio + 0.20 × PartialRatio + 0.15 × TokenSortRatio` (same weights as the validated Python script — proven against your real data, no need to re-derive).
  - **State adjustment:** if `ResolvedStateCode` and candidate's `Payer_State` both present and equal → **+8**; both present and different → **−20** (heavily penalized — a state mismatch on a state-specific plan like Medicare/Medicaid is a strong negative signal); either missing → **0**.
  - **Program-type adjustment:** match → **+5**; mismatch → **−10**; either missing → **0**.
  - Final score clamped to **0–100**.
- **Library:** `FuzzySharp` (or the higher-performance fork `Raffinert.FuzzySharp`) for `TokenSetRatio`, `WeightedRatio`, `PartialRatio`, `TokenSortRatio` — these are direct C# ports of the same rapidfuzz/FuzzyWuzzy functions already validated in the Python script. If Jaro-Winkler is wanted as a supplementary signal later, `FuzzyString` provides it — not required for v1.
- **Input:** `MatchContext.CanonicalName`, `MatchContext.ResolvedStateCode`, `MatchContext.ResolvedProgramType` (set back in Steps 1B/2/3 — unchanged since), and `MatchContext.Candidates` (set in Step 6). **Four independent fields read off the same context object — not a single value handed off from Step 6.** `CandidateFamily` itself is not an input here; its job ended at Step 6.
- **Output:** Written to `MatchContext.ScoredCandidates`, sorted descending, **top 5 retained.**

### Step 8 — Confidence tier decision
| Tier | Score | Decision |
|---|---|---|
| Auto-map | ≥ 95 | Map immediately, no human review. |
| Manual review | 70–94 | Present ranked top-5 candidates for Approve / Reject / Manual Map. |
| No match | < 70 (or zero candidates scored) | "No Mapping Payer Found in Payer Policy Master"; stays Unmapped. |

- **Library:** plain comparison logic — no external library needed.
- **Input:** `MatchContext.ScoredCandidates` (from Step 7), or `MatchContext.AliasHitGlobalPayerId` (from Step 5, if that shortcut was taken).
- **Output:** Written to `MatchContext.Decision` and `MatchContext.ConfidenceScore`.

### Step 9 — Persist the result + audit entry
- **Auto-map (Step 5 alias hit or Step 8 ≥95):** write `Global_Payer_ID`, set `Mapping_Status = Mapped`, `MappedBy = "System (Auto-Match)"`. Write a `PayerMatchAudit` row capturing the score, the candidate, the state signal source, and program type used.
- **Manual review (70–94):** store the top-5 candidates + scores against the Lab record (e.g., a `PendingMatchCandidates` child table); `Mapping_Status` stays `Unmapped — Pending Review`. Trigger the "new unmapped payer" / review notification per Section 4.3 of the requirements doc.
- **No match (<70):** `Mapping_Status = Unmapped`; set the record-level alert "No Mapping Payer Found in Payer Policy Master." **No email/escalation is sent** — this is an intentional decision (Section 4.3/5.2 of the requirements doc), not an oversight.
- **Library:** Entity Framework Core / Dapper for the writes; whatever your existing audit-logging convention is for the `PayerMatchAudit` insert.
- **Input:** the final state of `MatchContext` — everything set across Steps 1A–8 is available here for the audit row, not just the immediate decision.

## 5. Manual Actions (triggered from the UI, not automatic)

These apply to records sitting in the "Manual review" tier (70–94) or "No match" tier (<70).

| Action | What happens | Approval routing |
|---|---|---|
| **Approve** (confirm a system-proposed candidate) | Writes the selected candidate's `Global_Payer_ID`; `Mapping_Status = Mapped`, `MappedBy = "Approved (System Match)"`. | **Bypasses** the Reports Analyst approval workflow — applies immediately for any role, because the value being confirmed is the system's own evaluation, not a user-originated edit. |
| **Reject** | No data change. `Mapping_Status` stays `Unmapped`. | No-op — approval routing doesn't apply since nothing changed. |
| **Manual Map** (user searches Payer Policy Master directly and picks a Global Payer ID) | Writes the user-selected `Global_Payer_ID`; `Mapping_Status = Mapped`, `MappedBy = "Manual (<username>)"`. | **Requires** the standard Reports Analyst approval workflow (routed to LRN Admin/Reports Manager) when performed by Reports Analyst; applied immediately if performed by LRN Admin or Reports Manager. |

- **Distinguishing Approve vs. Manual Map:** these must be two separate UI actions/endpoints (e.g., `POST /mappings/{id}/approve` vs. `POST /mappings/{id}/manual-map`), each logging its own `PayerMatchAudit` entry with an explicit `ActionType`. The system never needs to infer intent — the endpoint called *is* the intent.
- **Manual Map search:** recommend a typeahead endpoint that runs Steps 1A–1B (canonicalize + strip network-type codes) + Step 7 (fuzzy score, no family filter) against the full Payer Policy Master, so the user gets ranked suggestions rather than a flat alphabetical list to scroll through.

## 6. Alias Table Feedback Loop (self-improving matching)

Every time a mapping is finalized — whether via auto-map, an approved system match, or an approved manual map — upsert `(CanonicalName, ResolvedStateCode) → Global_Payer_ID` into `PayerAlias` (composite key, per Step 5's note above — not `CanonicalName` alone). The next time that exact raw-name-and-state combination appears (from the same lab or a different one), Step 5 catches it immediately at 100% confidence, without re-running fuzzy scoring. This is what makes review volume shrink over time instead of staying flat.

**Why not just query the Lab Insurance Master directly instead of maintaining a separate table?** Lab Insurance Master already stores a confirmed `Global_Payer_ID` per raw name — but it's scoped one row per Payer+Lab combination, so a brand-new lab sending a raw name that's already been solved for a different lab gets a brand-new, unresolved row; nothing propagates the earlier confirmation unless something explicitly looks it up. `PayerAlias` is that lookup, implemented as its own indexed, canonicalized table rather than a live query against the full operational master, for two concrete reasons: (1) Lab Insurance Master rows can sit in non-confirmed states (`Unmapped — Pending Review`, `No Mapping Payer Found`, or pointing at a since-deactivated `Global_Payer_ID`) that a query would have to remember to filter out correctly every time — `PayerAlias` only ever receives writes at the moment of confirmation, so a bad state can't leak in by omission; (2) it gives the business a place to proactively seed a known synonym before any lab has ever sent that raw text, which a view over Lab Insurance Master alone couldn't do.

## 7. Re-Evaluation Triggers

1. **Event-driven:** whenever a new payer is added and approved in the Payer Policy Insurance Master, or a new raw name is added to the Lab Insurance Master, re-run Steps 1–9 for all currently `Unmapped` Lab records (not just the new one — a newly added Payer Policy record might resolve records that were previously "No Match"). The same trigger should apply when any of the four rules tables (`PayerFamilyRule`, `StateBrandMapping`, `ProgramTypeRule`, `PlanNetworkTypeCode`) gets a new or edited row — a newly added `StateBrandMapping` entry, for instance, can turn a previously ambiguous Manual Review case into a clean Auto-Map on re-evaluation.
2. **Scheduled batch (safety net):** a nightly/end-of-day job re-runs Steps 1–9 for every outstanding `Unmapped` record, independent of the event trigger. Recommended: **Hangfire** (simplest to operate in a .NET web app, dashboard included) or **Quartz.NET** if you need more complex cron-style scheduling.

## 8. C# Library Summary

| Need | Library | Notes |
|---|---|---|
| Token set / token sort / partial / weighted ratio fuzzy scoring | **FuzzySharp** or **Raffinert.FuzzySharp** (NuGet) | Direct C# port of the same FuzzyWuzzy/rapidfuzz functions used and validated in the Python script. `Raffinert.FuzzySharp` (v5.0.2+) is a bit-parallel accelerated fork with `PartialRatio` fixes — prefer it for new builds. |
| Jaro-Winkler (optional, supplementary) | **FuzzyString** (NuGet) | Not required for v1 scoring; keep in mind if the team wants to add it as a tie-breaker later. |
| Regex-based parsing (state, brand mapping, program type, family, canonicalization) | `System.Text.RegularExpressions` (built-in) | No external dependency needed. |
| In-memory reference index / caching | `ConcurrentDictionary<TKey,TValue>` or `IMemoryCache` (built-in) | Holds the Payer Policy index plus all four rules tables and `PayerAlias`; rebuild on the relevant table's change events. |
| Data access | Entity Framework Core or Dapper | Whichever the team already standardizes on. |
| Scheduled batch job | **Hangfire** (recommended) or **Quartz.NET** | Hangfire is generally simpler to stand up inside an existing ASP.NET app and gives a built-in dashboard for monitoring job runs — useful for showing business the nightly re-scan actually ran. |

## 9. Suggested Core Data Contracts (C#)

**`MatchContext` is the central object described in Section 4** — created once per raw name, passed to every step, and never has a field overwritten once set (only added to). Everything else below (`PayerPolicyRecord`, `MatchCandidate`, the enums) are the smaller building blocks it's made of. `MatchResult` is a slimmed, public-facing projection built from the final `MatchContext` state at the end of Step 9, for returning to the caller or UI — it is not a separate pipeline object.

```csharp
// Created fresh for every raw payer name evaluated. Threaded through Steps 1A-9.
// Fields are only ever added to, never overwritten once set — see Section 4's
// worked example (Lab "Beach Tree" / UT / "Aetna") for how this plays out end to end.
public class MatchContext
{
    // --- Input, provided by the caller ---
    public string RawName { get; set; }
    public string? LabState { get; set; }
    public string? LabPlanType { get; set; }

    // --- Set by Step 1A ---
    public string FormattedName { get; set; }

    // --- Set by Step 1B (never overwritten after this point) ---
    public string CanonicalName { get; set; }

    // --- Set by Step 2 (never overwritten after this point) ---
    public string? ResolvedStateCode { get; set; }
    public StateSignalSource StateSignalSource { get; set; }

    // --- Set by Step 3 ---
    public string? ResolvedProgramType { get; set; }

    // --- Set by Step 4 — a filter key only, never itself compared to anything ---
    public string? CandidateFamily { get; set; }

    // --- Set by Step 5, only if an alias hit is found ---
    public int? AliasHitGlobalPayerId { get; set; }

    // --- Set by Step 6 — does NOT touch CanonicalName or ResolvedStateCode above ---
    public List<PayerPolicyRecord> Candidates { get; set; } = new();

    // --- Set by Step 7 ---
    public List<MatchCandidate> ScoredCandidates { get; set; } = new();

    // --- Set by Step 8 ---
    public MatchDecision Decision { get; set; }
    public double ConfidenceScore { get; set; }
}

public record PayerPolicyRecord(
    int GlobalPayerId, string PayerName, string PayerNameNormalized,
    string PayerFamily, string PayerState, string PlanType, bool IsActive);

public record MatchCandidate(PayerPolicyRecord Candidate, double Score);

// BrandMapping added in v1.4 — distinguishes a StateBrandMapping hit (a durable fact
// about the payer) from a LabState fallback (only a fact about the submitting lab).
public enum StateSignalSource { NameEmbedded, BrandMapping, LabState, None }
public enum MatchDecision { AutoMap, ManualReview, NoMatch }

// Built from MatchContext at the end of Step 9 — not populated incrementally itself.
public record MatchResult(
    MatchDecision Decision,
    IReadOnlyList<MatchCandidate> TopCandidates, // up to 5
    double ConfidenceScore,
    string? ResolvedStateCode,
    StateSignalSource StateSignalSource,
    string? ResolvedProgramType,
    string? CandidateFamily);
```

## 10. Notes Carried Over From the Requirements Doc (don't re-litigate these)

- Thresholds of 95 / 70 are provisional defaults validated against the one-time bulk-import run; revisit only with real production data, not guesswork.
- "No Mapping Payer Found" intentionally has no escalation notification — records may sit Unmapped indefinitely; that's expected for payers with no policy at all.
- Deactivating a Payer Policy Master record behind an existing mapping does not clear the mapping automatically — it sets a review flag and notifies all roles with Lab Insurance Master access (Section 5.3 of requirements doc).
- Bulk approve/reject of proposed mappings is approved in principle but its UI is a separate, not-yet-designed piece of work (Section 7.2/10 of requirements doc) — don't build it as part of this pipeline without that design first.
