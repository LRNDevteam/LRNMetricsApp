SET NOCOUNT ON;

-- Cove-specific ClaimLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='CPTCodeXUnitsXModifierOrginal') ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='T_F') ALTER TABLE dbo.ClaimLevelData ADD T_F NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='UID') ALTER TABLE dbo.ClaimLevelData ADD UID NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Facility') ALTER TABLE dbo.ClaimLevelData ADD Facility NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='PatientName') ALTER TABLE dbo.ClaimLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='SubscriberId') ALTER TABLE dbo.ClaimLevelData ADD SubscriberId NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='AgingDOS') ALTER TABLE dbo.ClaimLevelData ADD AgingDOS NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='EndDOS') ALTER TABLE dbo.ClaimLevelData ADD EndDOS NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='AgingDOE') ALTER TABLE dbo.ClaimLevelData ADD AgingDOE NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='BilledWeek') ALTER TABLE dbo.ClaimLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ProcedureField') ALTER TABLE dbo.ClaimLevelData ADD ProcedureField NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Units') ALTER TABLE dbo.ClaimLevelData ADD Units NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='LineLevelCPT') ALTER TABLE dbo.ClaimLevelData ADD LineLevelCPT NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='DODWeek') ALTER TABLE dbo.ClaimLevelData ADD DODWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='DenialDate') ALTER TABLE dbo.ClaimLevelData ADD DenialDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='DeniedWeek') ALTER TABLE dbo.ClaimLevelData ADD DeniedWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='LineLevelDenialCode') ALTER TABLE dbo.ClaimLevelData ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='LineLevelICD') ALTER TABLE dbo.ClaimLevelData ADD LineLevelICD NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='ModifierField') ALTER TABLE dbo.ClaimLevelData ADD ModifierField NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='TotalWO') ALTER TABLE dbo.ClaimLevelData ADD TotalWO NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='TotalPayment') ALTER TABLE dbo.ClaimLevelData ADD TotalPayment NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='PaymentPercent') ALTER TABLE dbo.ClaimLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='BillStatus') ALTER TABLE dbo.ClaimLevelData ADD BillStatus NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='FullyPaidCount') ALTER TABLE dbo.ClaimLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='FullyPaidAmount') ALTER TABLE dbo.ClaimLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='AdjucticatedCount') ALTER TABLE dbo.ClaimLevelData ADD AdjucticatedCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='AdjucticatedAmount') ALTER TABLE dbo.ClaimLevelData ADD AdjucticatedAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Bucket30Count') ALTER TABLE dbo.ClaimLevelData ADD Bucket30Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Bucket30Amount') ALTER TABLE dbo.ClaimLevelData ADD Bucket30Amount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Bucket60Count') ALTER TABLE dbo.ClaimLevelData ADD Bucket60Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelData') AND name='Bucket60Amount') ALTER TABLE dbo.ClaimLevelData ADD Bucket60Amount NVARCHAR(500) NULL;

IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='CPTCodeXUnitsXModifierOrginal') ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='T_F') ALTER TABLE dbo.ClaimLevelDataArchive ADD T_F NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='UID') ALTER TABLE dbo.ClaimLevelDataArchive ADD UID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Facility') ALTER TABLE dbo.ClaimLevelDataArchive ADD Facility NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='PatientName') ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='SubscriberId') ALTER TABLE dbo.ClaimLevelDataArchive ADD SubscriberId NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='AgingDOS') ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingDOS NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='EndDOS') ALTER TABLE dbo.ClaimLevelDataArchive ADD EndDOS NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='AgingDOE') ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingDOE NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='BilledWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ProcedureField') ALTER TABLE dbo.ClaimLevelDataArchive ADD ProcedureField NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Units') ALTER TABLE dbo.ClaimLevelDataArchive ADD Units NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='LineLevelCPT') ALTER TABLE dbo.ClaimLevelDataArchive ADD LineLevelCPT NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='DODWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD DODWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='DenialDate') ALTER TABLE dbo.ClaimLevelDataArchive ADD DenialDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='DeniedWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD DeniedWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='LineLevelDenialCode') ALTER TABLE dbo.ClaimLevelDataArchive ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='LineLevelICD') ALTER TABLE dbo.ClaimLevelDataArchive ADD LineLevelICD NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='ModifierField') ALTER TABLE dbo.ClaimLevelDataArchive ADD ModifierField NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='TotalWO') ALTER TABLE dbo.ClaimLevelDataArchive ADD TotalWO NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='TotalPayment') ALTER TABLE dbo.ClaimLevelDataArchive ADD TotalPayment NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='PaymentPercent') ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='BillStatus') ALTER TABLE dbo.ClaimLevelDataArchive ADD BillStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='FullyPaidCount') ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='FullyPaidAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='AdjucticatedCount') ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjucticatedCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='AdjucticatedAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjucticatedAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Bucket30Count') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Bucket30Amount') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Bucket60Count') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.ClaimLevelDataArchive') AND name='Bucket60Amount') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Amount NVARCHAR(500) NULL;
END

PRINT 'Cove ClaimLevel alter script completed.';
