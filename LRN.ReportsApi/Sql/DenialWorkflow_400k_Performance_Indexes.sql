/*
Run this once on EACH lab database that contains DenialInsight / DenialLineItem / DenialTaskBoard / DenialVerificationTask.
Safe to re-run. Avoids wide composite nvarchar keys that can exceed SQL Server's 1700-byte index key limit.
*/
SET NOCOUNT ON;

IF OBJECT_ID('dbo.DenialInsight') IS NOT NULL
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialInsight_Lab_Paging' AND object_id = OBJECT_ID('dbo.DenialInsight'))
        DROP INDEX IX_DenialInsight_Lab_Paging ON dbo.DenialInsight;

    CREATE NONCLUSTERED INDEX IX_DenialInsight_Lab_Paging
    ON dbo.DenialInsight (LabId, InsuranceBalance DESC, CreatedOn DESC)
    INCLUDE (DenialCodes, RunId, AssignedTo, ResponsibilityReviewer, HighImpactInsurance, ActionCategory, ActionCode, NoOfDenialCount, NoOfClaimsCount, TotalBalance, ImpactPercentage, LabName);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialInsight_Lab_Filter' AND object_id = OBJECT_ID('dbo.DenialInsight'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialInsight_Lab_Filter
        ON dbo.DenialInsight (LabId, RunId, CreatedOn)
        INCLUDE (DenialCodes, HighImpactInsurance, AssignedTo, InsuranceBalance, ActionCategory, ActionCode);
    END;
END;

IF OBJECT_ID('dbo.DenialLineItem') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_Claim' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_Lab_Claim
        ON dbo.DenialLineItem (LabId, VisitNumber)
        INCLUDE (PatientID, PatientDOB, ClinicName, SalesRepname, ReferringProvider, PayerName, PayerNameNormalized, DateOfService);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_Filter_Denial' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_Lab_Filter_Denial ON dbo.DenialLineItem (LabId, DenialCodeNormalized);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_Filter_Payer' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_Lab_Filter_Payer ON dbo.DenialLineItem (LabId, PayerNameNormalized);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_Filter_Action' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_Lab_Filter_Action ON dbo.DenialLineItem (LabId, ActionCategory);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialLineItem_Lab_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_Lab_DOS ON dbo.DenialLineItem (LabId, DateOfService);
END;

IF OBJECT_ID('dbo.DenialTaskBoard') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_Queue' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_Queue
        ON dbo.DenialTaskBoard (LabId, AssignedTo, Status, DueDate, TaskID)
        INCLUDE (RunId, UniqueTrackId, ClaimID, PatientId, CPTCode, DenialCode, DenialClassification, ActionCategory, Priority, InsuranceBalance, PayerName, CreatedOn);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_Claim_Assign' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_Claim_Assign
        ON dbo.DenialTaskBoard (LabId, ClaimID)
        INCLUDE (TaskID, AssignedTo, Status, CPTCode, DenialCode, InsuranceBalance, ActionCategory, ReviewerUpdatedOn);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_AssignLookup' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_AssignLookup
        ON dbo.DenialTaskBoard (LabId, DenialCode, RunId)
        INCLUDE (PayerName, AssignedTo, Status, TaskID, ReviewerUpdatedOn);
    END;

    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_FilterOptions' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        DROP INDEX IX_DenialTaskBoard_Lab_FilterOptions ON dbo.DenialTaskBoard;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_Status' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_Status ON dbo.DenialTaskBoard (LabId, Status);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_ActionCategory' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_ActionCategory ON dbo.DenialTaskBoard (LabId, ActionCategory);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_Priority' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_Priority ON dbo.DenialTaskBoard (LabId, Priority);

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialTaskBoard_Lab_DenialCode' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_DenialCode ON dbo.DenialTaskBoard (LabId, DenialCode);
END;

IF OBJECT_ID('dbo.DenialVerificationTask') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DenialVerificationTask_Lab_Paging' AND object_id = OBJECT_ID('dbo.DenialVerificationTask'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialVerificationTask_Lab_Paging
        ON dbo.DenialVerificationTask (LabId, VerificationId DESC)
        INCLUDE (TaskID, UniqueTrackId, ClaimID, PatientId, CPTCode, DenialCode, Status, AssignedTo, RunId, PayerName, CreatedOn, VerificationStatus);
    END;
END;
