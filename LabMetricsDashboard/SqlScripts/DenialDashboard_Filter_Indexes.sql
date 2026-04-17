USE [LRNMaster]
GO

/* Run this in each LAB database for faster denial dashboard filters.
   Replace [YOUR_LAB_DATABASE] with the target lab database name if needed. */

/* Example:
USE [InHealthLRN]
GO
*/

IF OBJECT_ID(N'dbo.DenialTaskBoard', N'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskBoard_Lab_Run_Status' AND object_id = OBJECT_ID(N'dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_Lab_Run_Status
        ON dbo.DenialTaskBoard (LabId, RunId, Status, Priority, ActionCategory, DenialClassification)
        INCLUDE (TaskID, UniqueTrackId, AssignedTo, InsuranceBalance, DueDate, DateCompleted, PayerName, PayerType, PanelName, ReferringProvider, ClinicName, SalesRepname, FirstBilledDate, DateOfService);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskBoard_FilterDates' AND object_id = OBJECT_ID(N'dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_FilterDates
        ON dbo.DenialTaskBoard (LabId, RunId, FirstBilledDate, DateOfService)
        INCLUDE (TaskID, Status, Priority, ActionCategory, DenialClassification, PayerName, PayerType, PanelName, ReferringProvider, ClinicName, SalesRepname, InsuranceBalance, DueDate);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskBoard_UniqueTrackId_RunId' AND object_id = OBJECT_ID(N'dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_UniqueTrackId_RunId
        ON dbo.DenialTaskBoard (UniqueTrackId, RunId)
        INCLUDE (TaskID, LabId, Status, AssignedTo, DateCompleted);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialTaskBoard_TaskID_RunId' AND object_id = OBJECT_ID(N'dbo.DenialTaskBoard'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskID_RunId
        ON dbo.DenialTaskBoard (TaskID, RunId)
        INCLUDE (UniqueTrackId, LabId, Status, AssignedTo, DateCompleted);
    END;
END;
GO

IF OBJECT_ID(N'dbo.DenialLineItem', N'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialLineItem_Lab_Run_Status' AND object_id = OBJECT_ID(N'dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_Lab_Run_Status
        ON dbo.DenialLineItem (LabId, RunId, TaskStatus, Priority, ActionCategory, DenialClassification)
        INCLUDE (AccessionNo, DateOfService, FirstBilledDate, PayerName, PayerType, PanelName, ReferringProvider, ClinicName, SalesRepname, InsuranceBalance, TotalBalance);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialLineItem_FilterDates' AND object_id = OBJECT_ID(N'dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_FilterDates
        ON dbo.DenialLineItem (LabId, RunId, FirstBilledDate, DateOfService)
        INCLUDE (AccessionNo, TaskStatus, Priority, ActionCategory, DenialClassification, PayerName, PayerType, PanelName, ReferringProvider, ClinicName, SalesRepname, InsuranceBalance, TotalBalance);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialLineItem_PayerPanel' AND object_id = OBJECT_ID(N'dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_PayerPanel
        ON dbo.DenialLineItem (LabId, RunId, PayerName, PayerType, PanelName)
        INCLUDE (AccessionNo, DateOfService, FirstBilledDate, TaskStatus, Priority, ActionCategory, DenialClassification, InsuranceBalance, TotalBalance);
    END;
END;
GO


IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ClaimLevelData_ClaimID_Latest' AND object_id = OBJECT_ID(N'dbo.ClaimLevelData'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_ClaimLevelData_ClaimID_Latest
        ON dbo.ClaimLevelData (ClaimID, InsertedDateTime DESC, RecordId DESC)
        INCLUDE (InsuranceBalance)
        WHERE ClaimID IS NOT NULL AND InsuranceBalance IS NOT NULL;
    END;
END;
GO

/* Optional indexes when you want better denial performance without depending on RunId. */
IF OBJECT_ID(N'dbo.DenialLineItem', N'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialLineItem_FilterDates_NoRun' AND object_id = OBJECT_ID(N'dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_FilterDates_NoRun
        ON dbo.DenialLineItem (FirstBilledDate, DateOfService)
        INCLUDE (VisitNumber, AccessionNo, DenialDate, TaskStatus, Priority, ActionCategory, DenialClassification, PayerName, PayerType, PanelName, ReferringProvider, ClinicName, SalesRepname, InsuranceBalance, TotalBalance);
    END;

    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialLineItem_VisitNumber_DenialDate' AND object_id = OBJECT_ID(N'dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_DenialDate
        ON dbo.DenialLineItem (VisitNumber, DenialDate)
        INCLUDE (InsuranceBalance, TotalBalance, PayerName, DenialCodeNormalized, DenialDescription, DateOfService, FirstBilledDate, TaskStatus, Priority, ActionCategory, DenialClassification);
    END;
END;
GO


/* Special summary logic indexes for Augustus (19), Certus (18), Northwest (20)
   Supports ClaimLevelData -> DenialLineItem join on ClaimID = VisitNumber for weekly/monthly insights. */
IF OBJECT_ID(N'dbo.ClaimLevelData', N'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ClaimLevelData_ClaimID_SummaryJoin' AND object_id = OBJECT_ID(N'dbo.ClaimLevelData'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_ClaimLevelData_ClaimID_SummaryJoin
        ON dbo.ClaimLevelData (ClaimID)
        INCLUDE (InsuranceBalance, PayerName, PayerName_Raw, Panelname);
    END;
END;
GO

IF OBJECT_ID(N'dbo.DenialLineItem', N'U') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_DenialLineItem_VisitNumber_SummaryJoin' AND object_id = OBJECT_ID(N'dbo.DenialLineItem'))
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_SummaryJoin
        ON dbo.DenialLineItem (VisitNumber, DenialDate)
        INCLUDE (DenialCodeOriginal, DenialCodeNormalized, DenialDescription, TotalBalance, FirstBilledDate, DateOfService, TaskStatus, Priority, ActionCategory, DenialClassification, SalesRepname, ClinicName, ReferringProvider, PayerType, PayerNameNormalized);
    END;
END;
GO
