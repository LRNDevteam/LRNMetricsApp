SET NOCOUNT ON;

-- Augustus-specific ClaimLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'UID')
    ALTER TABLE dbo.ClaimLevelData ADD UID NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Aging')
    ALTER TABLE dbo.ClaimLevelData ADD Aging NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientName')
    ALTER TABLE dbo.ClaimLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'SubscriberId')
    ALTER TABLE dbo.ClaimLevelData ADD SubscriberId NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EnteredWeek')
    ALTER TABLE dbo.ClaimLevelData ADD EnteredWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EnteredStatus')
    ALTER TABLE dbo.ClaimLevelData ADD EnteredStatus NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledWeek')
    ALTER TABLE dbo.ClaimLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledStatus')
    ALTER TABLE dbo.ClaimLevelData ADD BilledStatus NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PostedWeek')
    ALTER TABLE dbo.ClaimLevelData ADD PostedWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ModField')
    ALTER TABLE dbo.ClaimLevelData ADD ModField NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ScrubberEditReason')
    ALTER TABLE dbo.ClaimLevelData ADD ScrubberEditReason NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CheqNo')
    ALTER TABLE dbo.ClaimLevelData ADD CheqNo NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'TimeToPay')
    ALTER TABLE dbo.ClaimLevelData ADD TimeToPay NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PaymentPercent')
    ALTER TABLE dbo.ClaimLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidCount')
    ALTER TABLE dbo.ClaimLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidAmount')
    ALTER TABLE dbo.ClaimLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Adjudicated')
    ALTER TABLE dbo.ClaimLevelData ADD Adjudicated NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjudicatedAmount')
    ALTER TABLE dbo.ClaimLevelData ADD AdjudicatedAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30')
    ALTER TABLE dbo.ClaimLevelData ADD Bucket30 NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30Amount')
    ALTER TABLE dbo.ClaimLevelData ADD Bucket30Amount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60')
    ALTER TABLE dbo.ClaimLevelData ADD Bucket60 NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60Amount')
    ALTER TABLE dbo.ClaimLevelData ADD Bucket60Amount NVARCHAR(500) NULL;

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCodeXUnitsXModifierOrginal')
    ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PanelNew')
    ALTER TABLE dbo.ClaimLevelData ADD PanelNew NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Source')
    ALTER TABLE dbo.ClaimLevelData ADD Source NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PanelCategory')
    ALTER TABLE dbo.ClaimLevelData ADD PanelCategory NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BillingStatus')
    ALTER TABLE dbo.ClaimLevelData ADD BillingStatus NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'LBilledDate')
    ALTER TABLE dbo.ClaimLevelData ADD LBilledDate NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BProcessDate')
    ALTER TABLE dbo.ClaimLevelData ADD BProcessDate NVARCHAR(100) NULL;

IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'UID')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD UID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Aging')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Aging NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientName')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'SubscriberId')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD SubscriberId NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EnteredWeek')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EnteredStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredStatus NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledWeek')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledStatus NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PostedWeek')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PostedWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ModField')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ModField NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ScrubberEditReason')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD ScrubberEditReason NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CheqNo')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CheqNo NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'TimeToPay')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD TimeToPay NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PaymentPercent')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidCount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidAmount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Adjudicated')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Adjudicated NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjudicatedAmount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjudicatedAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30 NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30Amount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60 NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60Amount')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Amount NVARCHAR(500) NULL;

    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCodeXUnitsXModifierOrginal')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PanelNew')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PanelNew NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Source')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD Source NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PanelCategory')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD PanelCategory NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BillingStatus')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BillingStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'LBilledDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD LBilledDate NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BProcessDate')
        ALTER TABLE dbo.ClaimLevelDataArchive ADD BProcessDate NVARCHAR(100) NULL;
END

PRINT 'Augustus ClaimLevel alter script completed.';
