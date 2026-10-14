SET NOCOUNT ON;

-- Augustus-specific LineLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPostedDate')
    ALTER TABLE dbo.LineLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EncounterPaymentPostedDate')
    ALTER TABLE dbo.LineLevelData ADD EncounterPaymentPostedDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PanelNew')
    ALTER TABLE dbo.LineLevelData ADD PanelNew NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Source')
    ALTER TABLE dbo.LineLevelData ADD Source NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UID')
    ALTER TABLE dbo.LineLevelData ADD UID NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Valid')
    ALTER TABLE dbo.LineLevelData ADD [Valid] NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PanelCategory')
    ALTER TABLE dbo.LineLevelData ADD PanelCategory NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientName')
    ALTER TABLE dbo.LineLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'SubscriberId')
    ALTER TABLE dbo.LineLevelData ADD SubscriberId NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ClaimAmount')
    ALTER TABLE dbo.LineLevelData ADD ClaimAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Date')
    ALTER TABLE dbo.LineLevelData ADD [Date] NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'EnteredStatus')
    ALTER TABLE dbo.LineLevelData ADD EnteredStatus NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BilledStatus')
    ALTER TABLE dbo.LineLevelData ADD BilledStatus NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CptWithUnits')
    ALTER TABLE dbo.LineLevelData ADD CptWithUnits NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Proc')
    ALTER TABLE dbo.LineLevelData ADD [Proc] NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CheqNo')
    ALTER TABLE dbo.LineLevelData ADD CheqNo NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AdjAmount')
    ALTER TABLE dbo.LineLevelData ADD AdjAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'InsBalance')
    ALTER TABLE dbo.LineLevelData ADD InsBalance NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatBalance')
    ALTER TABLE dbo.LineLevelData ADD PatBalance NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UpdatedDenial')
    ALTER TABLE dbo.LineLevelData ADD UpdatedDenial NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CombinedDenial')
    ALTER TABLE dbo.LineLevelData ADD CombinedDenial NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPercent')
    ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'Loc')
    ALTER TABLE dbo.LineLevelData ADD Loc NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BillingStatus')
    ALTER TABLE dbo.LineLevelData ADD BillingStatus NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'LBilledDate')
    ALTER TABLE dbo.LineLevelData ADD LBilledDate NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BProcessDate')
    ALTER TABLE dbo.LineLevelData ADD BProcessDate NVARCHAR(100) NULL;

IF OBJECT_ID('dbo.LineLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPostedDate')
        ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPostedDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EncounterPaymentPostedDate')
        ALTER TABLE dbo.LineLevelDataArchive ADD EncounterPaymentPostedDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PanelNew')
        ALTER TABLE dbo.LineLevelDataArchive ADD PanelNew NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Source')
        ALTER TABLE dbo.LineLevelDataArchive ADD Source NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UID')
        ALTER TABLE dbo.LineLevelDataArchive ADD UID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Valid')
        ALTER TABLE dbo.LineLevelDataArchive ADD [Valid] NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PanelCategory')
        ALTER TABLE dbo.LineLevelDataArchive ADD PanelCategory NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientName')
        ALTER TABLE dbo.LineLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'SubscriberId')
        ALTER TABLE dbo.LineLevelDataArchive ADD SubscriberId NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ClaimAmount')
        ALTER TABLE dbo.LineLevelDataArchive ADD ClaimAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Date')
        ALTER TABLE dbo.LineLevelDataArchive ADD [Date] NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'EnteredStatus')
        ALTER TABLE dbo.LineLevelDataArchive ADD EnteredStatus NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BilledStatus')
        ALTER TABLE dbo.LineLevelDataArchive ADD BilledStatus NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CptWithUnits')
        ALTER TABLE dbo.LineLevelDataArchive ADD CptWithUnits NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Proc')
        ALTER TABLE dbo.LineLevelDataArchive ADD [Proc] NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CheqNo')
        ALTER TABLE dbo.LineLevelDataArchive ADD CheqNo NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AdjAmount')
        ALTER TABLE dbo.LineLevelDataArchive ADD AdjAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'InsBalance')
        ALTER TABLE dbo.LineLevelDataArchive ADD InsBalance NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatBalance')
        ALTER TABLE dbo.LineLevelDataArchive ADD PatBalance NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UpdatedDenial')
        ALTER TABLE dbo.LineLevelDataArchive ADD UpdatedDenial NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CombinedDenial')
        ALTER TABLE dbo.LineLevelDataArchive ADD CombinedDenial NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPercent')
        ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'Loc')
        ALTER TABLE dbo.LineLevelDataArchive ADD Loc NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BillingStatus')
        ALTER TABLE dbo.LineLevelDataArchive ADD BillingStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'LBilledDate')
        ALTER TABLE dbo.LineLevelDataArchive ADD LBilledDate NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BProcessDate')
        ALTER TABLE dbo.LineLevelDataArchive ADD BProcessDate NVARCHAR(100) NULL;
END

PRINT 'Augustus LineLevel alter script completed.';
