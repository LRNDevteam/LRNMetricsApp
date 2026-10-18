/*
Run this once in each LAB database that contains DenialTaskBoard / DenialLineItem.
It improves Denial Workflow dashboard, task board, summary, filters, and claim assignment loading.
Safe to run multiple times.
*/
SET NOCOUNT ON;

IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Status_Assigned_Due' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Status_Assigned_Due
        ON dbo.DenialTaskBoard (LabId, Status, AssignedTo, DueDate, TaskID)
        INCLUDE (ClaimID, DenialCode, DenialClassification, ActionCategory, Priority, InsuranceBalance, PayerName, PayerNameNormalized, ClinicName, SalesRepname, ReferringProvider, DateOfService, RunId, CreatedOn);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Class_Action' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Class_Action
        ON dbo.DenialTaskBoard (LabId, DenialClassification, ActionCategory)
        INCLUDE (Status, AssignedTo, DueDate, TaskID, ClaimID, DenialCode, Priority, InsuranceBalance, PayerName, PayerNameNormalized, CreatedOn);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Code_Payer' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Code_Payer
        ON dbo.DenialTaskBoard (LabId, DenialCode, PayerNameNormalized)
        INCLUDE (Status, AssignedTo, DueDate, TaskID, ClaimID, DenialClassification, ActionCategory, Priority, InsuranceBalance, PayerName, CreatedOn);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_TaskBoard_Lab_Claim' AND object_id = OBJECT_ID('dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DWF_TaskBoard_Lab_Claim
        ON dbo.DenialTaskBoard (LabId, ClaimID)
        INCLUDE (TaskID, UniqueTrackId, CPTCode, DenialCode, DenialClassification, ActionCategory, Priority, Status, AssignedTo, InsuranceBalance, DueDate, DateOfService, PayerName, PayerNameNormalized);
    END;
END;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_DOS' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_DOS
        ON dbo.DenialLineItem (LabId, DateOfService DESC)
        INCLUDE (VisitNumber, PayerNameNormalized, PanelName, PatientName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance, DenialCodeNormalized, DenialClassification, ActionCategory);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_DWF_LineItem_Lab_Code_Payer' AND object_id = OBJECT_ID('dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DWF_LineItem_Lab_Code_Payer
        ON dbo.DenialLineItem (LabId, DenialCodeNormalized, PayerNameNormalized)
        INCLUDE (VisitNumber, DateOfService, ClinicName, ReferringProvider, PatientID, PatientName, PatientDOB, PanelName, SalesRepname, InsuranceBalance, DenialClassification, ActionCategory);
    END;
END;
GO
