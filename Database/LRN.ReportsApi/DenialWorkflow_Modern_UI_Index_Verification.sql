/*
  Denial Workflow modern UI support indexes.
  These are additive and guarded so the script can be run safely more than once.
*/

IF OBJECT_ID('dbo.DenialTaskBoard', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_WorkFlow_Assigned_Claim' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_Lab_WorkFlow_Assigned_Claim
        ON dbo.DenialTaskBoard(LabId, WorkFlowStatus, AssignedTo, ClaimID)
        INCLUDE(Status, PayerName, PatientName, DateOfService, CreatedOn, InsuranceBalance);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_Claim' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_Lab_Claim
        ON dbo.DenialTaskBoard(LabId, ClaimID)
        INCLUDE(TaskID, CPTCode, DenialCode, DenialClassification, ActionCategory, Status, InsuranceBalance);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE INDEX IX_DenialTaskBoard_Lab_CreatedOn
        ON dbo.DenialTaskBoard(LabId, CreatedOn)
        INCLUDE(ClaimID, WorkFlowStatus, AssignedTo, InsuranceBalance);
END

IF OBJECT_ID('dbo.DenialLineItem', 'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_Visit_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
       AND COL_LENGTH('dbo.DenialLineItem', 'LabId') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'VisitNumber') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'DateOfService') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'PayerName') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'DenialClassification') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'PanelName') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'BilledAmount') IS NOT NULL
       AND COL_LENGTH('dbo.DenialLineItem', 'InsuranceBalance') IS NOT NULL
        CREATE INDEX IX_DenialLineItem_Lab_Visit_DOS
        ON dbo.DenialLineItem(LabId, VisitNumber, DateOfService)
        INCLUDE(PayerName, DenialClassification, PanelName, BilledAmount, InsuranceBalance);
END

IF OBJECT_ID('dbo.DenialClaimEscalations', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimEscalations_Lab_Status_Claim_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialClaimEscalations'))
        CREATE INDEX IX_DenialClaimEscalations_Lab_Status_Claim_CreatedOn
        ON dbo.DenialClaimEscalations(LabId, Status, ClaimId, CreatedOn);

IF OBJECT_ID('dbo.DenialTaskHistory', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskHistory_Lab_Track_ActionDate' AND object_id = OBJECT_ID('dbo.DenialTaskHistory'))
        CREATE INDEX IX_DenialTaskHistory_Lab_Track_ActionDate
        ON dbo.DenialTaskHistory(LabId, UniqueTrackId, ActionDate DESC);

IF OBJECT_ID('dbo.DenialClaimNotes', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimNotes_Lab_Claim_CreatedOn' AND object_id = OBJECT_ID('dbo.DenialClaimNotes'))
        CREATE INDEX IX_DenialClaimNotes_Lab_Claim_CreatedOn
        ON dbo.DenialClaimNotes(LabId, ClaimId, CreatedOn DESC);

IF OBJECT_ID('dbo.DenialClaimDocuments', 'U') IS NOT NULL
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialClaimDocuments_Lab_Claim_UploadedOn' AND object_id = OBJECT_ID('dbo.DenialClaimDocuments'))
        CREATE INDEX IX_DenialClaimDocuments_Lab_Claim_UploadedOn
        ON dbo.DenialClaimDocuments(LabId, ClaimId, UploadedOn DESC);
