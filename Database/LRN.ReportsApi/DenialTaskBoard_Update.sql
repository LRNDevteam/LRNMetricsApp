
/*
Run this once in each lab database.
It creates the normalized claim id used by Denial Workflow joins:
DenialTaskBoard.ClaimID = 'CLM-10001'
DenialLineItem.VisitNumber = '10001'
*/
IF OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.DenialTaskBoard','ClaimIDNormalized') IS NULL
    BEGIN
        ALTER TABLE dbo.DenialTaskBoard
        ADD ClaimIDNormalized AS CONVERT(varchar(150), REPLACE(LTRIM(RTRIM(ISNULL([ClaimID],''))), 'CLM-', '')) PERSISTED;
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE name = 'IX_DenialTaskBoard_ClaimIDNormalized'
          AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_ClaimIDNormalized
        ON dbo.DenialTaskBoard (ClaimIDNormalized);
    END;

    IF NOT EXISTS
    (
        SELECT 1
        FROM sys.indexes
        WHERE name = 'IX_DenialTaskBoard_TaskView_ClaimIDNormalized'
          AND object_id = OBJECT_ID('dbo.DenialTaskBoard')
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_DenialTaskBoard_TaskView_ClaimIDNormalized
        ON dbo.DenialTaskBoard (Status, AssignedTo, ClaimIDNormalized)
        INCLUDE (TaskID, UniqueTrackId, CPTCode, SLAStatus, DueDate, InsuranceBalance, DenialCode, DenialClassification, ActionCategory);
    END;
END;

IF OBJECT_ID('dbo.DenialLineItem','U') IS NOT NULL
   AND NOT EXISTS
   (
       SELECT 1
       FROM sys.indexes
       WHERE name = 'IX_DenialLineItem_VisitNumber_ClaimView'
         AND object_id = OBJECT_ID('dbo.DenialLineItem')
   )
BEGIN
    CREATE NONCLUSTERED INDEX IX_DenialLineItem_VisitNumber_ClaimView
    ON dbo.DenialLineItem (VisitNumber, DateOfService)
    INCLUDE (PayerNameNormalized, PanelName, PatientDOB, ClinicName, ReferringProvider, PatientID, SalesRepname, InsuranceBalance);
END;
