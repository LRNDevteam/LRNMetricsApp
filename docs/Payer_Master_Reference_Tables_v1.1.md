# Payer Matching Engine — Reference Tables Requiring Ongoing Maintenance

Companion to `Payer_Matching_Algorithm_Dev_Spec_v1.4.md`. That document specifies the matching pipeline; this document lists every supporting table the pipeline depends on that is **not** the Payer Policy Insurance Master or Lab Insurance Master themselves — the reference/rules data that has to be actively maintained for the "intelligence" described in Section 3.1 of the dev spec to keep working as new payers, brands, and acronyms appear.

**v1.1 changes:** `PayerAlias`'s data model now includes `ResolvedStateCode` as part of a composite lookup key (with `CanonicalName`), not `CanonicalName` alone — see the updated Section 5 below for why, including a real example found in the client's live Lab Insurance Master data.

## Summary

| Table | Purpose (one line) | Who maintains it | Update trigger |
|---|---|---|---|
| `PayerFamilyRule` | Groups payer name variants under a parent brand for blocking | LRN Admin / Payer Policy Admin | New unclassified brand/acronym found (family = null) |
| `StateBrandMapping` | Maps a brand to its known home state when state isn't in the name | LRN Admin / Payer Policy Admin | New single-state brand causes wrong Lab-State fallback |
| `ProgramTypeRule` | Detects Medicare/Medicaid/Commercial/Exchange/etc. from keywords | LRN Admin / Payer Policy Admin | New coverage-type keyword or acronym found |
| `PlanNetworkTypeCode` | Fixed list of network/plan codes stripped before scoring | LRN Admin / Payer Policy Admin (rare) | New CMS/industry plan-type code appears |
| `PayerAlias` | Remembers every confirmed `(raw name, state)` → Global Payer ID mapping | System (auto), reviewed by LRN Admin | Every confirmed auto-map, approval, or manual map |

The first four are **rules tables** — hand-authored, low row count, high leverage, and exactly what Section 3.1 of the dev spec means when it says the engine "only knows what a person explicitly taught it." The fifth, `PayerAlias`, is a **self-learning table** — it grows automatically from confirmed matches and rarely needs manual entry, only occasional cleanup.

---

## 1. `PayerFamilyRule`

**Purpose:** Groups payer name variants (e.g., "Aetna Better Health of Kentucky," "Aetna Better Health of Louisiana") under one parent brand family ("Aetna Better Health") so Step 4/6 of the matching pipeline can narrow candidates to that family instead of comparing against all ~230 Payer Policy Master records.

**Description:** An ordered list of regex-style patterns, each mapped to a family name. Order matters — more specific brand patterns must be evaluated before generic catch-all patterns, or specific brands get miscategorized into the generic bucket (the exact bug found and fixed twice already: Independence/Capital Blue Cross and Anthem both initially fell into generic "BCBS"). Covers acronym/alias cases like IDPA→Medicaid, Railroad→Palmetto GBA, AARP→UHC — each one only exists because someone added that exact row.

**Data model:**

| Column | Type | Notes |
|---|---|---|
| `RuleId` | int, PK | |
| `Family` | nvarchar(100) | The canonical family name, e.g. "Anthem BCBS" |
| `Pattern` | nvarchar(200) | Regex pattern matched against the canonicalized name |
| `Priority` | int | Execution order — lower number evaluated first; specific rules get lower numbers than generic ones |
| `IsActive` | bit | Soft-disable without deleting history |
| `CreatedBy` / `CreatedDate` | nvarchar / datetime | Who added the rule and when |
| `Notes` | nvarchar(500) | Free text — e.g. "Railroad Medicare claims route to Palmetto GBA as the RRB contractor" |

**Maintenance note:** whenever a Lab Insurance Master record scores "No Match" or lands in Manual Review purely because `candidateFamily` came back null, that's the signal a new rule may be needed — not necessarily a code change, just a new row.

---

## 2. `StateBrandMapping`

**Purpose:** Captures that a payer brand is known to operate in a specific, limited set of states even when the state isn't spelled out in the raw name — the "Empire BCBS is a NY plan" problem from Section 3.2 of the dev spec.

**Description:** Checked in Step 2 (state resolution) *before* falling back to the submitting lab's state. Without an entry, a brand like Empire gets assigned whatever state the lab happens to be in, which is wrong whenever the lab and the payer's home state differ (a real observed case: a Utah lab submitting an Empire BCBS claim).

**Data model:**

| Column | Type | Notes |
|---|---|---|
| `MappingId` | int, PK | |
| `BrandKeyword` | nvarchar(100) | Keyword matched against the canonicalized name, e.g. "EMPIRE" |
| `StateCode` | char(2) | Home state, e.g. "NY" |
| `IsActive` | bit | |
| `CreatedBy` / `CreatedDate` | nvarchar / datetime | |
| `Notes` | nvarchar(500) | e.g. "Empire is the Anthem-affiliated BCBS brand exclusive to NY" |

**Maintenance note:** same trigger pattern as `PayerFamilyRule` — a Manual Review or No-Match case where the resolved state (from Lab State fallback) doesn't match the payer that was ultimately picked manually is the signal to add a row here.

---

## 3. `ProgramTypeRule`

**Purpose:** Detects the coverage/product line — Medicare, Medicaid, Commercial, Exchange, Federal, Dual — from keywords in the raw payer name, feeding Step 3 and the program-type scoring adjustment in Step 7 (+5 match / −10 mismatch).

**Description:** Same structure as `PayerFamilyRule` — ordered keyword-to-category rules. This is the table equivalent of the original `product_line_rules.csv` you provided. Covers cases where the coverage type isn't the literal word "Medicaid" but a known signal for it, e.g. "Better Health" or "IDPA" implying Medicaid-managed coverage for certain brands.

**Data model:**

| Column | Type | Notes |
|---|---|---|
| `RuleId` | int, PK | |
| `ProgramType` | nvarchar(50) | Medicare / Medicaid / Commercial / Exchange / Federal / Dual |
| `Pattern` | nvarchar(200) | Regex pattern |
| `Priority` | int | Execution order |
| `IsActive` | bit | |
| `CreatedBy` / `CreatedDate` | nvarchar / datetime | |
| `Notes` | nvarchar(500) | |

**Maintenance note:** distinct from `PayerFamilyRule` — a name can resolve a family correctly but still need a program-type signal added separately (family tells you *who*, program type tells you *what kind of plan*).

---

## 4. `PlanNetworkTypeCode`

**Purpose:** Holds the fixed, generic list of network/plan-type codes (PPO, HMO, POS II, HDHP/HSA, EPO, POS, HDHP, HSA, CDHP, FFS, ACO, SNP, PFFS) stripped from the raw name in Step 1B, before fuzzy scoring — this is the fix for the "plan names weren't being stripped" gap.

**Description:** Unlike the three rules tables above, this list changes rarely — it's a closed, generic set of industry-standard network designations, not brand-specific vocabulary. It's kept as a table rather than hard-coded so a new CMS-recognized plan type (a new SNP subtype, for example) can be added without a code deploy. This table intentionally does **not** include marketing/product names like "Choice" or "Select" — those aren't safe to strip generically (see dev spec Section 4, Step 1B) and are handled through `PayerAlias` instead.

**Data model:**

| Column | Type | Notes |
|---|---|---|
| `CodeId` | int, PK | |
| `Code` | nvarchar(20) | e.g. "PPO", "POS II" |
| `IsActive` | bit | |
| `Notes` | nvarchar(500) | |

**Maintenance note:** review periodically (e.g., annually) against CMS plan-type terminology rather than reactively — this table doesn't get discovered as broken the way the other three do, since a missed code just slightly under-scores a match rather than misclassifying it.

---

## 5. `PayerAlias`

**Purpose:** Remembers every previously confirmed raw-name-to-Global-Payer-ID mapping so the exact same variant resolves instantly at 100% confidence on future occurrences, without repeating fuzzy scoring or manual review (Step 5 of the dev spec, feedback loop described in Section 6).

**Description:** The one table in this set that is **not** hand-authored — it's written automatically at Step 9 every time a mapping is finalized (auto-map, approved system match, or approved manual map), regardless of whether any of the four rules tables above had a matching rule for it. This is what makes review volume shrink over time: even a name the rules tables completely fail to classify only ever costs one manual review, because the alias table remembers the answer permanently after that.

**Data model:**

| Column | Type | Notes |
|---|---|---|
| `AliasId` | int, PK | |
| `CanonicalName` | nvarchar(200) | Output of Step 1B |
| `ResolvedStateCode` | char(2), nullable | State used at confirmation time, from Step 2 |
| `GlobalPayerId` | int, FK → Payer Policy Master | |
| `ConfirmedBy` | nvarchar(100) | Username, or "System (Auto-Match)" |
| `ConfirmedDate` | datetime | |
| `SourceAction` | nvarchar(50) | AutoMap / Approved / ManualMap — for audit traceability |

**Why `ResolvedStateCode` is part of the key, not just an extra column:** `(CanonicalName, ResolvedStateCode)` together form the unique/indexed lookup key — `CanonicalName` alone is not safe. A state-ambiguous raw name (bare "Medicare," "Medicaid," "Aetna Better Health" with no state in the text) only gets a state at all because Step 2 fell back to the *submitting lab's* state. Caching that under `CanonicalName` alone would let a different lab in a different state silently inherit the first lab's state-specific answer. This is a real, observed case, not a hypothetical: running this logic against the live Lab Insurance Master (v1.8.4) found the bare canonical name "MEDICARE" already resolving to two different Global Payer IDs depending on which lab's state was used — 1195 for an Illinois lab, 1186 with no state signal at all — among just the 521 rows that already carry a confirmed Global Payer ID. See `PayerAlias_sample_v1.0.csv` for a full worked table built from that real data.

**Maintenance note:** the only manual upkeep this table needs is cleanup, not authoring — if a Payer Policy Master record is later merged, split, or deactivated, any aliases pointing at the old `GlobalPayerId` need to be re-pointed or removed so the system doesn't keep confidently auto-mapping to a stale target. Recommend a periodic (e.g., quarterly) orphan-check job that flags `PayerAlias` rows pointing at inactive Payer Policy Master records.

---

## Tables Intentionally Left Out of This List

- **`PayerMatchAudit`** — logs every match *attempt* (including rejections and no-matches), not reference data. It's fully system-generated and isn't something business users author or maintain; it's a read/reporting table, not a rules table.
- **Payer Policy Insurance Master / Lab Insurance Master** — the two primary masters this whole pipeline maps between. They're maintained under the existing workflows already defined in `requirements_v1.7.md`, not new tables introduced by the matching engine.
