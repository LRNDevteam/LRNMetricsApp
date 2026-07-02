/*
DenialWorkflow_Performance_Indexes_And_Backfill_20260701.sql

Purpose
-------
Pre-apply (in a reviewed maintenance window) the schema/index work that the app would otherwise
create automatically on first connection (see EnsureDenialTaskBoardNormalizedClaimIdAsync in
SqlDenialWorkflowRepository.cs). Running it here instead avoids surprise DDL firing under
production load and lets a DBA review it first.

Context: this was written against a live schema dump (NWL_LRN) that showed:
  - DenialTaskBoard.ClaimIDNormalized already exists but as a PLAIN nullable column (not computed).
    The app's claim-matching queries were recently simplified to compare this column directly
    (instead of recomputing REPLACE/LTRIM/RTRIM(ClaimID) every time) for a large performance win.
    That simplification is only correct if every row's ClaimIDNormalized is actually populated and
    consistent with ClaimID. Legacy rows created before this column existed may have it NULL/blank
    (this is exactly what an old code comment in the repo warned about), so this script backfills
    those before relying on it.
  - DenialLineItem.VisitNumberNormalized already exists as a persisted computed column (an earlier
    app-triggered migration already added it) but had no supporting index yet.
  - None of the supporting indexes below existed yet in the dump provided.

This script is idempotent and safe to re-run. Run once per lab database (each lab is a separate
database per LabConfig:LabsID / ConnectionStrings).

Estimated impact: on a table with roughly 300k rows, the backfill UPDATE and each index build
should complete in low tens of seconds, but please run in a maintenance window and take a backup
first per your normal change process.
*/

SET NOCOUNT ON;

------------------------------------------------------------------------------------------------
-- 1. Backfill DenialTaskBoard.ClaimIDNormalized for any legacy NULL/blank rows.
--    Safe to re-run: only touches rows where the column is currently NULL or blank.
------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    UPDATE dbo.DenialTaskBoard
    SET ClaimIDNormalized = CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL(ClaimID, ''))), 'CLM-', ''))
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(ClaimIDNormalized, ''))), '') IS NULL
      AND NULLIF(LTRIM(RTRIM(ISNULL(ClaimID, ''))), '') IS NOT NULL;

    PRINT CONCAT('DenialTaskBoard.ClaimIDNormalized backfill: ', @@ROWCOUNT, ' row(s) updated.');
END;
GO

------------------------------------------------------------------------------------------------
-- 2. Backfill DenialTaskBoard.AssignedOn (used for aging/assignment-duration reporting) for any
--    assigned task that has never had it set.
------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL AND COL_LENGTH('dbo.DenialTaskBoard', 'AssignedOn') IS NOT NULL
BEGIN
    UPDATE dbo.DenialTaskBoard
    SET AssignedOn = COALESCE(ReviewerUpdatedOn, CreatedOn, SYSDATETIME())
    WHERE NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo, ''))), '') IS NOT NULL
      AND AssignedOn IS NULL;

    PRINT CONCAT('DenialTaskBoard.AssignedOn backfill: ', @@ROWCOUNT, ' row(s) updated.');
END;
GO

------------------------------------------------------------------------------------------------
-- 3. DenialTaskBoard supporting indexes.
------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_AssignedOn' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_AssignedOn
        ON dbo.DenialTaskBoard (AssignedOn, AssignedTo)
        INCLUDE (ClaimID, TaskID, CPTCode, Status);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_ClaimIDNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimIDNormalized
        ON dbo.DenialTaskBoard (ClaimIDNormalized);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_TaskView_ClaimIDNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskView_ClaimIDNormalized
        ON dbo.DenialTaskBoard (Status, AssignedTo, ClaimIDNormalized)
        INCLUDE (TaskID, UniqueTrackId, CPTCode, SLAStatus, DueDate, InsuranceBalance, DenialCode, DenialClassification, ActionCategory);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_ClaimAssignment_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimAssignment_Status
        ON dbo.DenialTaskBoard (ClaimIDNormalized)
        INCLUDE (TaskID, Status, AssignedTo, CreatedOn, SLAStatus, UniqueTrackId, RunId);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Status_Assigned_Created' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Status_Assigned_Created
        ON dbo.DenialTaskBoard (LabId, Status, AssignedTo, CreatedOn, ClaimIDNormalized)
        INCLUDE (TaskID, ClaimID, CPTCode, SLAStatus, WorkFlowStatus, InsuranceBalance, DenialCode, DenialClassification, ActionCategory, Priority, PayerName, PanelName, DateOfService);

    IF COL_LENGTH('dbo.DenialTaskBoard', 'ClaimUID') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_ClaimUID_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_ClaimUID_Status
        ON dbo.DenialTaskBoard (LabId, ClaimUID, Status, AssignedTo, CreatedOn)
        INCLUDE (TaskID, ClaimIDNormalized, CPTCode, SLAStatus, WorkFlowStatus, InsuranceBalance, DenialClassification, ActionCategory);

    -- Supports the new SLA Breached / SLA At Risk KPIs and queue (SLAStatus filtered, scoped by lab).
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_SLAStatus_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_SLAStatus_Status
        ON dbo.DenialTaskBoard (LabId, SLAStatus, Status)
        INCLUDE (ClaimID, ClaimIDNormalized, TaskID, AssignedTo, DueDate);

    -- AR Reviewer views (My Worklist, claim-menu-counts) filter every request by AssignedTo.
    -- Wrapping the column in LOWER/LTRIM/RTRIM at query time is non-sargable and forces a full
    -- scan of this 300k+ row table. This persisted mirror lets those filters seek instead.
    IF COL_LENGTH('dbo.DenialTaskBoard', 'AssignedToNormalized') IS NULL
        ALTER TABLE dbo.DenialTaskBoard
        ADD AssignedToNormalized AS LOWER(LTRIM(RTRIM(ISNULL([AssignedTo], '')))) PERSISTED;
END;
GO

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL AND COL_LENGTH('dbo.DenialTaskBoard', 'AssignedToNormalized') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_AssignedToNormalized' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_AssignedToNormalized
        ON dbo.DenialTaskBoard (AssignedToNormalized)
        INCLUDE (ClaimIDNormalized, Status, TaskID, SLAStatus, DueDate, CreatedOn);
END;
GO

------------------------------------------------------------------------------------------------
-- 4. DenialLineItem supporting indexes.
------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialLineItem', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialLineItem', 'VisitNumberNormalized') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_VisitNumberNormalized' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumberNormalized
        ON dbo.DenialLineItem (VisitNumberNormalized);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_VisitNumber_ClaimView' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_ClaimView
        ON dbo.DenialLineItem (VisitNumber, DateOfService)
        INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_ClaimAssignment_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_ClaimAssignment_Page
        ON dbo.DenialLineItem (DateOfService DESC, VisitNumber)
        INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_DOS_Visit_Page' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_DOS_Visit_Page
        ON dbo.DenialLineItem (LabId, DateOfService DESC, VisitNumber)
        INCLUDE (PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);

    IF COL_LENGTH('dbo.DenialLineItem', 'ClaimUID') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_ClaimUID_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_ClaimUID_DOS
        ON dbo.DenialLineItem (LabId, ClaimUID, DateOfService DESC)
        INCLUDE (VisitNumber, PayerName, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, ActionCategory, DenialClassification);
END;
GO

------------------------------------------------------------------------------------------------
-- 5. DenialClaimEscalations supporting index.
------------------------------------------------------------------------------------------------
IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_Escalations_Lab_Claim_Active' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
        CREATE NONCLUSTERED INDEX IX_DWF_Escalations_Lab_Claim_Active
        ON dbo.DenialClaimEscalations (LabId, ClaimId, IsDeleted)
        INCLUDE (Status, EscalatedToRole, EscalatedTo, Comments);
END;
GO

PRINT 'DenialWorkflow_Performance_Indexes_And_Backfill_20260701.sql complete.';
