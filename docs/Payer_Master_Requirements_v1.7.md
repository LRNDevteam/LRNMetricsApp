# Payer Master – Requirements Specification

| Field | Detail |
|---|---|
| Document Title | Payer Master – Requirements Specification |
| Project | Payer Master (Payer Policy Insurance Master & Lab Insurance Master) |
| Prepared For | Prasanna Ramalingam |
| Status | Draft – v1.7 (Refined state disambiguation precedence: name-embedded state > Lab State > Plan Type) |
| Date | July 7, 2026 |

## 1. Overview & Purpose

The Payer Master functionality consists of two linked reference data masters: the Payer Policy Insurance Master and the Lab Insurance Master. Together they connect payer definitions used in payer policy validation with the payer names found in lab production/master files, so that billed claim data can be validated against payer policy conditions such as coverage rules and ICD rules.

Each payer is assigned a unique Global Payer ID. A payer that exists in both masters (e.g., AETNA) carries the same Global Payer ID in both, forming the link between payer policy conditions and production billing data.

### 1.1 Document Scope

This document refines the original mock-up requirements based on stakeholder clarification covering payer matching logic, record granularity, cross-master lifecycle behavior, approval workflow rules, notification scope, field validation, and audit detail. Decisions made during clarification are incorporated directly into the functional requirements below; residual open items are listed in Section 10. A running log of every clarification question and decision is maintained separately in `clarifications_log.md`.

**Update (v1.2):** Reports Analyst access to the Payer Policy Insurance Master is confirmed as view-only. See Section 2 and Section 3.1.

**Update (v1.3):** Reports Manager added as a view-only notification recipient for Payer Policy Insurance Master updates. See Section 3.2 and Section 8.

**Update (v1.4):** Payer matching expanded into a full proposed-match, confidence-scoring, and approve/reject/override workflow, including "No Mapping Payer Found" handling. See Section 4.2–4.4 and Section 5.2.

**Update (v1.5):** Lab State confirmed as a disambiguation signal (over a manually entered Payer State) for state-agnostic raw payer names (e.g., generic "Medicare"); reject workflow refined to expect a manual mapping attempt first; re-evaluation trigger expanded to new payers added to either master.

**Update (v1.6):** Approve of a system-proposed match bypasses the approval workflow; confidence tiers finalized including an auto-map tier (≥95%, superseding the earlier "always manual review" decision); "No Mapping Payer Found" intentionally receives no escalation; deactivation of a linked Payer Policy record now flags the Lab Insurance Master mapping and notifies all users; bulk approve/reject of proposed mappings approved in principle with UI design still open; scheduled batch re-scan added alongside the event-driven trigger.

**Update (v1.7):** State disambiguation precedence refined to a 3-tier order: **(1) a state code or state name embedded directly in the raw Payer Name** (e.g., "Medicare TX," "BCBS of Texas") takes first precedence; **(2) Lab State** is used only when the raw name does not specify a state; **(3) Plan Type** remains the third-tier signal, applied regardless of which state signal was used. See Section 4.4 and Section 5.2 (rewritten).

## 2. Roles & Permissions

The following roles interact with the two masters. Permissions differ by master, as summarized below.

| Role | Payer Policy Insurance Master | Lab Insurance Master |
|---|---|---|
| LRN Admin | Add / Edit / Deactivate / Approve | Add / Edit / Deactivate / Approve |
| Payer Policy Admin | Add / Edit / Deactivate / Approve | No access |
| Reports Analyst | View only | Add / Edit / Deactivate (subject to approval) |
| Reports Manager | View only | Add / Edit / Deactivate / Approve |
| ETL | View only | View only |

Note: ETL is view-only in both masters but is still included in certain notification distributions (see Section 8) to keep the technical/integration team aware of upstream data changes.

## 3. Payer Policy Insurance Master

Source: the Payer Policy database. The unique list of payers in the payer policy database forms the payer master in the Payer Policy Insurance Master.

### 3.1 Phase 1 Functional Requirements

- LRN Admin and Payer Policy Admin can directly add, edit, and deactivate a payer record; these actions are applied immediately without requiring approval.
- Reports Analyst has view-only access to the Payer Policy Insurance Master. Reports Analyst cannot add, edit, update, or deactivate payer records in this master.
- ETL has view-only access to all records in the Payer Policy Insurance Master.
- A pending Phase 2 auto-inserted candidate record (see Section 3.4) left unactioned by LRN Admin or Payer Policy Admin beyond the defined SLA window (see Section 5.2) automatically triggers an escalation reminder to both eligible approvers.
- A full audit trail is created for every action performed in the Payer Policy Insurance Master (see Section 7).

### 3.2 Notifications

Channel: all notifications above are delivered both in-app and via email.

| Trigger | Message / Content | Recipients |
|---|---|---|
| New payer added | "Review Lab Insurance Master – New Payer added to Payer Policy Insurance Master" | LRN Admin, Payer Policy Admin, Reports Analyst, Reports Manager, ETL |
| Existing payer updated | "Review Lab Insurance Master – Payer record updated in Payer Policy Insurance Master", including payer name, Global Payer ID, and action performed | Same as above |
| Payer deactivated | Instructs LRN Admin, Reports Manager, and Reports Analyst to manually review and, if applicable, deactivate the corresponding record(s) in the Lab Insurance Master | LRN Admin, Reports Manager, Reports Analyst |
| Approval pending (Phase 2 only) | Notifies eligible approvers of a system-generated candidate record awaiting review (see Section 3.4) | LRN Admin, Payer Policy Admin |
| SLA escalation | Reminder notification when a pending Phase 2 approval exceeds the SLA window | LRN Admin, Payer Policy Admin |

### 3.3 Fields & Validation

| Field | Type / Validation Rule |
|---|---|
| Payer Name | Free text; mandatory. On save, a normalized-name match against existing active records triggers a duplicate warning; user may override and proceed. |
| Payer Name Normalized | System-generated from Payer Name (case normalization, punctuation/whitespace stripping); read-only. |
| Global Payer ID | System auto-generated, sequential, unique; assigned on approval; read-only; never reused, including after deactivation. |
| Payer Common Code | Free text; optional. |
| Payer Group Code | Free text; optional. |
| Plan Type | Dropdown from a maintained enumerated list (e.g., Medicare, Medicaid, Commercial, Managed Care, Other); mandatory. |
| Is Active | System-managed flag (Active / Inactive); set via the Deactivate action; not directly editable. |
| Benefit Manager | Dropdown from a maintained enumerated list; optional. |
| Benefit Manager Code | Free text or auto-populated based on Benefit Manager selection; optional. |
| Payer State | Dropdown from a maintained enumerated list (U.S. states); mandatory. Used as a disambiguation signal in Lab Insurance Master payer matching (see Section 5.2), particularly for state-specific plans under a generic name (e.g., Medicare, Medicaid). |
| Remarks | Free text; optional. |

### 3.4 Phase 2 Functionality

- When a new payer is added to the Payer Policy database, the system automatically inserts a candidate payer record into the Payer Policy Insurance Master and triggers an approval flow to Payer Policy Admin / LRN Admin.
- The record is inserted into the Payer Policy Insurance Master only if approved by Payer Policy Admin or LRN Admin.
- The record is not inserted or updated if rejected by Payer Policy Admin or LRN Admin.
- All Phase 2 actions are recorded in the audit trail.

## 4. Lab Insurance Master

Source: the master file synced across labs. The Lab Insurance Master contains the unique list of payer names as they appear in each lab's master file. The raw payer name is normalized and mapped to the Global Payer ID in the Payer Policy Insurance Master to connect production billing data with payer policy conditions.

### 4.1 Record Granularity

The Lab Insurance Master maintains one record per Payer + Lab combination. If the same payer appears in the master files of multiple labs, a separate record is created for each lab, and each such record is independently mapped to the same Global Payer ID once confirmed.

### 4.2 Phase 1 Functional Requirements

- When a new master file is synced for the latest week, the system checks for payers not yet present in the Lab Insurance Master (evaluated per Payer + Lab combination).
- If a new payer record is found, the system creates a new record with the Payer Name (Raw) and Lab Name populated, and Mapping Status set to Unmapped.
- LRN Admin, Reports Manager, Reports Analyst, and ETL are notified: "New Payer record added to the Lab Insurance Master, Review to map the payer."
- The system evaluates candidate Global Payer ID matches against the Payer Policy Insurance Master with a confidence score, and either auto-maps, queues for manual review, or shows "No Mapping Payer Found," per the confidence tiers and state-disambiguation precedence in Section 5.2.
- LRN Admin, Reports Manager, and Reports Analyst can add, edit, and deactivate a payer record in the Lab Insurance Master.
- When a Reports Analyst creates, updates, or deactivates a payer record via free-text edit, the action is routed to LRN Admin and Reports Manager for approval. This routing does not apply to approving a system-proposed match (see Section 5.2) but does apply to manual mapping.
- Approval by either LRN Admin or Reports Manager is sufficient for a routed action to be saved; rejection by either prevents the action from being saved.
- Rejection requires a rejection reason/comment, included in the notification to the Reports Analyst.
- A pending approval left unactioned beyond the SLA window automatically escalates to LRN Admin and Reports Manager.
- The Reports Analyst is notified of the approval or rejection outcome, including the rejection reason when applicable.
- ETL has view-only access to the Lab Insurance Master.
- A full audit trail is created for every action performed in the Lab Insurance Master, including system-performed auto-map actions (see Section 6).

### 4.3 Notifications

Channel: all notifications above are delivered both in-app and via email, unless noted otherwise.

| Trigger | Message / Content | Recipients |
|---|---|---|
| New unmapped payer found during sync | "New Payer record added to the Lab Insurance Master, Review to map the payer" | LRN Admin, Reports Manager, Reports Analyst, ETL |
| Existing payer updated | "Existing Payer record updated in Lab Insurance Master", including payer name, Global Payer ID, and action performed | LRN Admin, Reports Manager, Reports Analyst, ETL |
| No mapping candidate found | In-app alert on the record only: "No Mapping Payer Found in Payer Policy Master." No email/escalation notification is sent — this state is expected for payers with no corresponding policy at all, and the record may remain Unmapped indefinitely until a future match is found (see Section 5.2). | LRN Admin, Reports Manager, Reports Analyst (viewing the record) |
| Linked payer deactivated in Payer Policy Master | Flags the mapped Lab Insurance Master record for review: "Linked payer policy record has been deactivated — mapping requires review" | LRN Admin, Reports Manager, Reports Analyst, ETL |
| Approval pending | Notifies eligible approvers of a Reports Analyst free-text edit or manual mapping awaiting review | LRN Admin, Reports Manager |
| Approval / rejection outcome | Notifies the Reports Analyst of the decision, including rejection reason if rejected | Reports Analyst (submitter) |
| SLA escalation | Reminder notification when a pending approval exceeds the SLA window | LRN Admin, Reports Manager |

### 4.4 Fields & Validation

| Field | Type / Validation Rule |
|---|---|
| Payer Name (Raw) | System-populated from the lab master file at sync time; read-only source value. Frequently generic/state-agnostic (e.g., "Medicare"), but sometimes already contains an embedded state code or state name (e.g., "Medicare TX," "BCBS of Texas"). Where present, this embedded state is the **first**-precedence disambiguation signal — see Lab State below and Section 5.2. |
| Payer Name Normalized | System-generated from Payer Name (Raw); read-only. |
| Global Payer ID | Populated automatically (auto-map tier), on approval of a proposed match, or via manual mapping; blank until mapped. |
| Mapping Status | System-managed: Unmapped (no confirmed Global Payer ID, including "No Mapping Payer Found" and rejected-without-manual-mapping states) or Mapped (confirmed); filterable. Mapped records additionally indicate whether the mapping was System (Auto-Match), Approved (reviewed match), or Manual (user-searched). |
| Review Flag | System-managed flag, cleared by default; set to "Review Required — Linked Payer Deactivated" when the Payer Policy Insurance Master record behind an existing mapping is deactivated (see Section 5.3); cleared once a user re-maps or deactivates the linked Lab Insurance Master record. |
| Proposed Match Candidates | System-generated at evaluation time: up to the top 5 ranked candidates, each showing Confidence Score, Insurance Name, and Global Payer ID from the Payer Policy Insurance Master; read-only; cleared once the record is Mapped. Not populated for auto-mapped (≥95%) records beyond the single matched candidate retained in the audit trail. |
| Match Confidence Score | System-generated numeric score for the proposed or auto-applied match; read-only; retained in the audit trail at the time of the decision (see Section 6). |
| Payer Common Code | Free text or carried over from the mapped Payer Policy Insurance Master record; optional. |
| Payer Group Code | Free text; optional. |
| Payer State | Dropdown from a maintained enumerated list; mandatory. Not used directly in match scoring (see Section 5.2 precedence order); available as informational/reference data on the record. |
| Plan Type | Dropdown from a maintained enumerated list; mandatory. **Third**-precedence signal factored into the match confidence score (see Section 5.2). |
| Lab Name | System-populated from the master file source; read-only. |
| Lab State | Dropdown from a maintained enumerated list, or system-populated from source if available. **Second**-precedence disambiguation signal in payer matching — used only when the raw Payer Name does not already specify a state (see Section 5.2). |
| Is Active | System-managed flag (Active / Inactive); set via the Deactivate action. |
| Remarks | Free text; optional. |

## 5. Cross-Master Rules

### 5.1 Global Payer ID Generation

The Global Payer ID is system auto-generated as a sequential, unique identifier when a new payer record is approved in the Payer Policy Insurance Master. It is not user-editable and is never reused, including for a payer that is later deactivated and re-added.

### 5.2 Payer Matching, Confidence Scoring & Approval SLA

When a Lab Insurance Master record is Unmapped (newly added, previously rejected without a successful manual mapping, or previously "No Mapping Payer Found"), the system evaluates it against the Payer Policy Insurance Master as follows:

**Candidate proposal.** The system compares the normalized Payer Name against active records in the Payer Policy Insurance Master and computes a Match Confidence Score for each candidate.

**State disambiguation precedence.** Raw payer names entered in LIS/PMS systems are frequently generic and state-agnostic (e.g., "Medicare"), but sometimes already specify a state. The system resolves the state signal used for scoring in strict precedence order:
1. **State embedded in the raw Payer Name** (e.g., "Medicare TX," "BCBS of Texas," "Medicaid Florida") — if the system can parse a recognizable U.S. state code or state name directly out of Payer Name (Raw), that extracted state takes precedence over all other signals and is compared against each candidate's Payer State.
2. **Lab State** — used only when no state can be parsed from the raw Payer Name. The state where the submitting lab is located is compared against each candidate's Payer State.
3. **Plan Type** — applied as a third-tier secondary signal regardless of which state signal (1) or (2) was used, comparing the Lab Insurance Master record's Plan Type against each candidate's Plan Type.

**Recommended scoring approach (v1, pending validation against sample data and the business's existing alias/canonical payer-family reference):**
- Base name score: exact normalized match = 100; alias/canonical-family dictionary hit = 95; otherwise a blended fuzzy score (60% token-set ratio + 40% Jaro-Winkler), capped at 90 so a fuzzy match can never outrank a true exact/alias hit.
- State adjustment (using the precedence-resolved state signal above): match → +8; mismatch → −20 (heavily penalized, since a state mismatch on a state-specific plan like Medicare/Medicaid is a strong negative signal); no state signal available → 0.
- Plan Type adjustment: match → +5; mismatch → −10; unknown/blank → 0.
- Final score = base + adjustments, clamped to 0–100.
This is a working hypothesis to validate against real data, not a final formula — see Section 10.

**Confidence tiers and resulting behavior:**
| Tier | Score | Behavior |
|---|---|---|
| Auto-map | ≥ 95 | System maps automatically; no human review. Fully recorded in the audit trail with "Performed By: System (Auto-Match)" and the confidence score, so it remains reviewable after the fact. |
| Manual review | 70–94 | Shown in a ranked list of up to 5 candidates for the user to Approve, Reject, or Manually Map (see below). |
| No match | < 70 | No candidate is shown. Record displays "No Mapping Payer Found in Payer Policy Master" and remains Unmapped (see Section 4.3 — no escalation is sent for this state). |

Thresholds of 95 / 70 are provisional defaults pending validation against real data.

**Review actions (70–94 tier):**
- **Approve:** the selected Global Payer ID is written to the Global Payer ID field and Mapping Status is set to Mapped. This bypasses the standard Reports Analyst approval workflow and applies immediately, because the value being confirmed is the system's own evaluation, not a user-originated determination.
- **Reject:** no update is made to the record. This is a no-op with respect to data, so approval routing does not apply.
- **Manual mapping:** available regardless of tier outcome (auto-mapped, reviewed, rejected, or no match) — the user searches the Payer Policy Insurance Master directly and selects a Global Payer ID. This is subject to the standard Reports Analyst approval workflow (Section 4.2) when performed by Reports Analyst, since it is functionally equivalent to a manual edit; LRN Admin or Reports Manager performing the same action applies it immediately, consistent with their direct edit rights.
- *Distinguishing the two:* "Approve Proposed Match" and "Manual Map" are two separate, separately logged UI actions — the system always knows which path was taken and applies the correct approval-routing rule automatically; there is no ambiguity to resolve at review time.

**Unresolved records.** If the user rejects a proposed candidate and cannot identify a correct manual mapping, the record remains Unmapped and is held in the review queue for future re-evaluation. This is expected to happen — manual mapping is not itself mandatory if no correct match exists (see also "No match" tier above).

**Re-evaluation triggers.** All Unmapped records (rejected, "No Mapping Payer Found," or otherwise unresolved) are automatically re-queued and re-validated against the Payer Policy Insurance Master through two mechanisms:
1. **Event-driven:** immediately when a new payer record is added to either the Payer Policy Insurance Master or the Lab Insurance Master.
2. **Scheduled:** a batch re-scan of all outstanding Unmapped records runs on a defined schedule (business is leaning toward an end-of-day run at a defined time) as a safety net alongside the event-driven trigger. Exact run time is an open item — see Section 10.

**Audit trail.** Every proposed-match evaluation, auto-map, approval, rejection, and manual mapping is recorded in the audit trail, including the confidence score, the candidate(s) presented (or the single auto-matched candidate), which state signal precedence tier was used (name-embedded, Lab State, or none), and the Plan Type values used in scoring at that time (see Section 6).

Approval SLA: pending approval requests in either master that remain unactioned beyond the configured SLA window trigger an automatic escalation notification to all eligible approvers. The specific SLA duration (e.g., 24, 48, or 72 hours) is an open item to be confirmed — see Section 10.

### 5.3 Deactivation & Reactivation

- Deactivating a payer in the Payer Policy Insurance Master does not automatically deactivate the corresponding record(s) in the Lab Insurance Master. Instead, the linked Lab Insurance Master record(s) are flagged for review (Review Flag, Section 4.4) and the system sends a notification to all users with access to the Lab Insurance Master (LRN Admin, Reports Manager, Reports Analyst, ETL) instructing them to manually review and, if applicable, remap or deactivate the linked record(s).
- Deactivated payers are not reactivated. If a previously deactivated payer needs to be re-added, a new record is created through the standard add/approval workflow and receives a new Global Payer ID. The original deactivated record is retained for audit history.

### 5.4 Duplicate Handling

On save, if a new or edited payer's normalized name exactly matches an existing active record within the same master, the system displays a duplicate warning. The user may override and proceed if they confirm the entry is intentional (for example, two distinct payer entities that legitimately share a similar name).

## 6. Audit Trail Requirements

Full field-level before/after values are captured for every add, edit, deactivate, approve, and reject action across both masters. Each audit entry records: master name, record identifier (Global Payer ID), field changed, old value, new value, action type, performed by, timestamp, approval status, approver (if applicable), and rejection reason (if applicable).

For payer-mapping decisions in the Lab Insurance Master specifically, the audit entry additionally records: the confidence score and full set of candidates (or the single auto-matched candidate) presented at the time of the decision, which state signal precedence tier was used (name-embedded state, Lab State, or none) and its value, the Plan Type values used in scoring, and whether the outcome was an auto-map, an approved system-proposed match, a rejection, or a manual mapping. Auto-map entries record "Performed By: System (Auto-Match)."

The audit trail is view-only and accessible to all roles with access to the corresponding master, including ETL in a read-only capacity. Retention period is an open item — see Section 10.

## 7. Bulk Actions

### 7.1 Bulk Upload / Import

LRN Admin and Payer Policy Admin (Payer Policy Insurance Master), and LRN Admin and Reports Manager (Lab Insurance Master), can import multiple payer records at once via a template-based file upload (e.g., CSV/Excel). Reports Analyst can initiate bulk uploads only in the Lab Insurance Master (no bulk upload access to the Payer Policy Insurance Master, consistent with view-only access); each record in the batch is routed for approval independently, subject to the same approval workflow as individual records.

### 7.2 Bulk Approve / Reject

Approvers can select multiple pending requests from an approval queue and approve or reject them in a single action. Bulk rejection requires a rejection reason, which may be applied to the full selection or entered per record. Bulk actions do not apply to manual mapping, which is entered per record.

Bulk approve/reject of pending payer-mapping proposals is approved in principle, but the interface approach is not yet designed — specifically how a reviewer would see all proposed candidate matches for multiple different payers clearly enough on one screen to bulk-approve safely (as opposed to a single-field bulk edit). This needs further brainstorming, likely supported by a UI mockup, before it can be scoped for build — see Section 10.

## 8. Notification Channel & Recipient Summary

All notifications, regardless of master or trigger, are delivered through both channels below to every role with access to the relevant master, except record-level alerts (e.g., "No Mapping Payer Found"), which are in-app only and intentionally do not escalate further.

| Master | Recipients (role-based) | Channels |
|---|---|---|
| Payer Policy Insurance Master | LRN Admin, Payer Policy Admin, Reports Analyst (view-only recipient), Reports Manager (view-only recipient), ETL (view-only recipient) | In-app + Email |
| Lab Insurance Master | LRN Admin, Reports Manager, Reports Analyst, ETL (view-only recipient) | In-app + Email (In-app only, no escalation, for the "No Mapping Payer Found" record-level alert) |

## 9. Out of Scope (Phase 1 / Phase 2)

- Automated cross-master deactivation (deactivation sync remains a manual, notification-and-flag-driven step per Section 5.3).
- Automatic reactivation of deactivated payer records.
- Phase 2 auto-insert automation for the Lab Insurance Master (only the Payer Policy Insurance Master has a defined Phase 2 auto-insert trigger per Section 3.4).
- Bulk approve/reject UI for payer-mapping proposals — deferred pending design (see Section 7.2 and Section 10). Individual (non-bulk) approve/reject/manual-map remains in scope for Phase 1.

## 10. Assumptions & Open Items

- Expected data volumes and non-functional requirements (record counts, concurrent users, response-time targets) are not yet defined and should be confirmed with the technical team before UI/DB design sign-off.
- The approach for the one-time initial data migration of existing Payer Policy database records and current lab master files into the two new masters is not yet defined.
- The specific SLA duration for approval escalation (Section 5.2) needs a confirmed value; this document assumes a configurable window with no default hard-coded yet.
- The audit trail retention period is not yet defined.
- Enumerated (dropdown) list values for Plan Type, Payer State, and Benefit Manager need to be finalized with subject matter experts and a governance owner assigned for list maintenance.
- The confidence-score algorithm, weighting, and tier thresholds (95 / 70 provisional) are pending validation against a sample data file and the business's existing alias/canonical payer-family reference (Python file to be shared).
- The list of recognized state-name patterns/abbreviations to parse out of the raw Payer Name (e.g., "TX," "Texas," "of Texas") is not yet finalized — needs confirmation of expected formats seen in real lab master files.
- The exact scheduled re-scan time for outstanding Unmapped records is not yet finalized (business is leaning toward an end-of-day run at a defined time).
- The UI/UX approach for bulk-approving payer-mapping proposals across multiple payers needs further brainstorming and likely a mockup before it can be scoped.
