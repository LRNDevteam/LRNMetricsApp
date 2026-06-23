# Denial Code Master Upload and Denial Action Verification Requirements

Last updated: 2026-06-15

## 1. Purpose

The Denial Code Master workflow allows AR Managers to maintain denial-code action mappings and safely apply action changes to already assigned open denial tasks.

When a Denial Code Master upload changes action-related fields for assigned open claims/tasks, the system must not silently overwrite reviewer work. Instead, it must create an Action Change Verification queue where the AR Manager can review affected claims, inspect task-level old/new values, and approve or ignore the changes.

## 2. Roles and Access

Only AR Manager users can access:

- Denial Code Master
- Denial Code Master Excel upload
- Action Change Verification
- Approve/ignore action change decisions

Non-AR Manager users must receive access denied responses and must not see the Denial Code Master or Action Change Verification menu entries.

## 3. Denial Code Master Maintenance

### 3.1 Denial Code Master Fields

Each Denial Code Master row is maintained by the following data fields:

- Denial Code
- Denial Description
- Denial Classification
- Coverage Status
- ICD Compliance Status
- Denial Validity
- Action Code
- Recommended Action
- Action Category
- Task
- Short Category
- Priority
- SLA Days
- Notes / Comments
- Created / updated audit fields

The unique business key is:

- Denial Code
- Coverage Status
- ICD Compliance Status

### 3.2 Manual Maintenance

The AR Manager must be able to:

- Search Denial Code Master rows.
- Add a new denial-code mapping.
- Edit an existing mapping.
- Delete an existing mapping.
- Regenerate the classifier Excel.
- Export the current classifier Excel.

After create, update, delete, or regenerate, the classifier Excel must be regenerated.

### 3.3 Excel Upload

The AR Manager must be able to upload an Excel file from Denial Code Master.

The import must:

- Accept Excel files only.
- Validate required values.
- Insert new Denial Code Master rows.
- Update or replace existing rows when the same business key is found.
- Report inserted, updated, skipped, and failed counts.
- Return validation/import errors when applicable.
- Regenerate the classifier Excel after successful import processing.

## 4. Action Change Detection

The upload process must detect when action-related values change for assigned open claim/task rows.

Action-related fields are:

- Action Code
- Action Category
- Task
- Short Category

If these values change for assigned open tasks, the system must create an Action Change Verification batch instead of directly applying the new action values to those tasks.

The import result must include:

- Whether action change warnings exist.
- Verification batch id.
- Affected claim count.
- Affected task count.

The UI must show an “Assigned Open Claims Affected” warning after upload and allow the AR Manager to review now or later.

## 5. Action Change Verification View

### 5.1 Recommended View

The Action Change Verification page must follow the Claim Assignment page interaction pattern.

The page must use:

- A left claim list pane.
- A right claim detail drawer.
- Claim ID link styling matching Claim Assignment.
- A Tasks tab for affected task rows.
- A History tab for claim workflow history.

The page must not show a separate Claim Level / Task Level toggle because it is not meaningful for this workflow. The default and primary review context is claim-level.

### 5.2 Left Claim Pane

The left pane must show grouped affected claims.

Each claim row must include:

- Claim ID as a link-style control.
- Patient identifier.
- Payer name.
- Affected task count.
- Pending/approved/ignored status summary.

The left pane must support local search by:

- Claim ID
- Patient ID
- Payer
- Assigned user
- Denial code
- Old/new action fields

Clicking a claim must open that claim in the right drawer and show the task split.

### 5.3 Right Claim Drawer

The right drawer must show:

- Claim ID
- Payer
- Patient ID
- Affected task count
- Assigned To
- Claim Status
- Denial Codes
- ICD Status
- Coverage Status

The drawer must show claim-level old/new summary cards for:

- Action Code
- Action Category
- Task
- Short Category

Changed values must be visually highlighted:

- Old values: red treatment
- New values: green treatment

### 5.4 Task Split

The Tasks tab must show affected task rows for the selected claim.

Each task row must show:

- Task ID
- Assigned To
- Denial Code
- ICD Compliance Status
- Coverage Status
- Old Action Code
- New Action Code
- Old Action Category
- New Action Category
- Old Task
- New Task
- Old Short Category
- New Short Category
- Verification Status
- Approve / Ignore row actions

Only fields that changed should receive the old/new visual highlight.

Task-row actions:

- Approve applies the new action values for that task only.
- Ignore leaves that task unchanged and removes it from pending action verification.

### 5.5 Claim-Level Actions

The drawer header must provide only:

- Approve Claim
- Ignore Claim

Approve Claim must approve all pending affected tasks for the selected claim.

Ignore Claim must ignore all pending affected tasks for the selected claim.

If the selected claim has no pending verification rows, both claim-level buttons must be disabled.

### 5.6 History Tab

The History tab must show claim workflow history, not notes/documents tabs.

History should include available workflow audit events such as:

- Current assignment snapshot
- Assignment audit
- Task history
- Claim/line notes as historical events where available
- Escalation history where available
- Document upload history where available

The history display must show:

- Event date/time
- Event title/type
- Description
- Task/CPT where applicable
- Old/new assigned user where applicable
- Old/new status where applicable
- Action by / created by

## 6. Filters and Summary

The Action Change Verification page must support filters for:

- Search
- Batch
- Denial Code
- ICD Compliance Status
- Coverage Status
- Assigned To
- Status

The page must not show Source File in the filter controls or summary tiles.

Summary tiles must show:

- Affected Claims
- Affected Tasks
- Pending
- Approved
- Ignored

The Batch filter should display batch ids, not source filenames.

## 7. Approval and Ignore Behavior

### 7.1 Approve

Approve must apply the new Denial Code Master action details to the selected verification row(s):

- New Action Code
- New Action Category
- New Task
- New Short Category

Approve must update verification status to Confirmed/Approved and record:

- Verified by
- Verified on

### 7.2 Ignore

Ignore must not update the underlying task action values.

Ignore must update verification status to Ignored and record:

- Verified by
- Verified on

### 7.3 Confirmation Modal

Before approve or ignore, the system must show a confirmation modal with:

- Action type: approve or ignore
- Scope: claim or task
- Count of affected pending rows
- Clear explanation of what will happen

## 8. Export

The Action Change Verification page must allow export of the filtered verification result to Excel.

The exported file must include enough detail to audit:

- Batch
- Claim ID
- Task ID
- Assigned To
- Denial Code
- ICD Compliance Status
- Coverage Status
- Old/new action values
- Verification Status
- Verified by/on
- Created on

## 9. API Requirements

### 9.1 Denial Code Master APIs

Required endpoints:

- `GET /denial-code-master`
- `GET /denial-code-master/lookups`
- `GET /denial-code-master/{denialCode}`
- `POST /denial-code-master`
- `PUT /denial-code-master/{denialCode}`
- `DELETE /denial-code-master/{denialCode}`
- `POST /denial-code-master/import`
- `POST /denial-code-master/regenerate-export`
- `GET /denial-code-master/export`

All endpoints require AR Manager access and LabId validation.

### 9.2 Action Change Verification APIs

Required endpoints:

- `GET /denial-action-verification`
- `GET /denial-action-verification/batch/{batchId}`
- `GET /denial-action-verification/lookups`
- `POST /denial-action-verification/{verificationId}/confirm`
- `POST /denial-action-verification/confirm-selected`
- `POST /denial-action-verification/batch/{batchId}/confirm-all`
- `POST /denial-action-verification/{verificationId}/ignore`
- `GET /denial-action-verification/export`

All endpoints require AR Manager access and LabId validation.

### 9.3 Claim History API

The Action Change Verification History tab must use the existing claim history API:

- `GET /claim-history`

Required query values:

- LabId
- ClaimId
- HistoryLevel = Claim

## 10. Data and Audit Requirements

The system must persist:

- Upload batch metadata
- Source file name internally for audit
- Uploaded by
- Uploaded on
- Affected claims count
- Affected tasks count
- Pending count
- Confirmed/approved count
- Ignored count
- Verification row status
- Verified by
- Verified on

Source file may be stored internally but must not be shown in Action Change Verification filters or summary tiles.

## 11. Success Criteria

The workflow is complete when:

- AR Manager can upload Denial Code Master Excel.
- Import reports inserted/updated/skipped/failed counts.
- Assigned open task action changes are detected.
- A warning is shown with affected claim/task counts.
- AR Manager can navigate to Action Change Verification.
- The page shows claim-level review using Claim Assignment-style layout.
- Claim ID is rendered as a link-style control.
- A selected claim shows affected task split.
- Old/new changed task values are highlighted.
- AR Manager can approve/ignore at claim level.
- AR Manager can approve/ignore individual task rows.
- History tab shows claim workflow history.
- Source file is not shown in filters or summary tiles.
- Export works for the filtered verification data.
