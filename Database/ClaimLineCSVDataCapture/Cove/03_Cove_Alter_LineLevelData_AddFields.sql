SET NOCOUNT ON;

-- Cove-specific LineLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='PaymentPostedDate') ALTER TABLE dbo.LineLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='T_F') ALTER TABLE dbo.LineLevelData ADD T_F NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='UID') ALTER TABLE dbo.LineLevelData ADD UID NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='Facility') ALTER TABLE dbo.LineLevelData ADD Facility NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='PatientName') ALTER TABLE dbo.LineLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='SubscriberId') ALTER TABLE dbo.LineLevelData ADD SubscriberId NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='AgingDOS') ALTER TABLE dbo.LineLevelData ADD AgingDOS NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='EndDOS') ALTER TABLE dbo.LineLevelData ADD EndDOS NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='AgingDOE') ALTER TABLE dbo.LineLevelData ADD AgingDOE NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='BilledWeek') ALTER TABLE dbo.LineLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='LineLevelCPT') ALTER TABLE dbo.LineLevelData ADD LineLevelCPT NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='DODWeek') ALTER TABLE dbo.LineLevelData ADD DODWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='DeniedWeek') ALTER TABLE dbo.LineLevelData ADD DeniedWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='LineLevelDenialCode') ALTER TABLE dbo.LineLevelData ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelData') AND name='PaymentPercent') ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;

IF OBJECT_ID('dbo.LineLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='PaymentPostedDate') ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPostedDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='T_F') ALTER TABLE dbo.LineLevelDataArchive ADD T_F NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='UID') ALTER TABLE dbo.LineLevelDataArchive ADD UID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='Facility') ALTER TABLE dbo.LineLevelDataArchive ADD Facility NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='PatientName') ALTER TABLE dbo.LineLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='SubscriberId') ALTER TABLE dbo.LineLevelDataArchive ADD SubscriberId NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='AgingDOS') ALTER TABLE dbo.LineLevelDataArchive ADD AgingDOS NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='EndDOS') ALTER TABLE dbo.LineLevelDataArchive ADD EndDOS NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='AgingDOE') ALTER TABLE dbo.LineLevelDataArchive ADD AgingDOE NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='BilledWeek') ALTER TABLE dbo.LineLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='LineLevelCPT') ALTER TABLE dbo.LineLevelDataArchive ADD LineLevelCPT NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='DODWeek') ALTER TABLE dbo.LineLevelDataArchive ADD DODWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='DeniedWeek') ALTER TABLE dbo.LineLevelDataArchive ADD DeniedWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='LineLevelDenialCode') ALTER TABLE dbo.LineLevelDataArchive ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id]=OBJECT_ID('dbo.LineLevelDataArchive') AND name='PaymentPercent') ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
END

PRINT 'Cove LineLevel alter script completed.';
