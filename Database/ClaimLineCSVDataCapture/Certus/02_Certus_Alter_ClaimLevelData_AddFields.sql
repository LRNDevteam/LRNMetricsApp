SET NOCOUNT ON;

-- Certus-specific ClaimLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCodeXUnitsXModifierOrginal') ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'T_F') ALTER TABLE dbo.ClaimLevelData ADD T_F NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'SubscriberId') ALTER TABLE dbo.ClaimLevelData ADD SubscriberId NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientName') ALTER TABLE dbo.ClaimLevelData ADD PatientName NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ICDCodes') ALTER TABLE dbo.ClaimLevelData ADD ICDCodes NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DiagnosisPointer') ALTER TABLE dbo.ClaimLevelData ADD DiagnosisPointer NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EnteredWeek') ALTER TABLE dbo.ClaimLevelData ADD EnteredWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'EnteredStatus') ALTER TABLE dbo.ClaimLevelData ADD EnteredStatus NVARCHAR(1000) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledWeek') ALTER TABLE dbo.ClaimLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledStatus') ALTER TABLE dbo.ClaimLevelData ADD BilledStatus NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ModField') ALTER TABLE dbo.ClaimLevelData ADD ModField NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ServiceUnit') ALTER TABLE dbo.ClaimLevelData ADD ServiceUnit NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTXUnits') ALTER TABLE dbo.ClaimLevelData ADD CPTXUnits NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCombined') ALTER TABLE dbo.ClaimLevelData ADD CPTCombined NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Aging') ALTER TABLE dbo.ClaimLevelData ADD Aging NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Description') ALTER TABLE dbo.ClaimLevelData ADD [Description] NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PostedWeek') ALTER TABLE dbo.ClaimLevelData ADD PostedWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ClaimAmount') ALTER TABLE dbo.ClaimLevelData ADD ClaimAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'OriginalDenialCode') ALTER TABLE dbo.ClaimLevelData ADD OriginalDenialCode NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'LineLevelDenials') ALTER TABLE dbo.ClaimLevelData ADD LineLevelDenials NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DenialCombination') ALTER TABLE dbo.ClaimLevelData ADD DenialCombination NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PaymentPercent') ALTER TABLE dbo.ClaimLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'RejectionReasons') ALTER TABLE dbo.ClaimLevelData ADD RejectionReasons NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'RejectionCategory') ALTER TABLE dbo.ClaimLevelData ADD RejectionCategory NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidCount') ALTER TABLE dbo.ClaimLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidAmount') ALTER TABLE dbo.ClaimLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Adjudicated') ALTER TABLE dbo.ClaimLevelData ADD Adjudicated NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjudicatedAmount') ALTER TABLE dbo.ClaimLevelData ADD AdjudicatedAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30') ALTER TABLE dbo.ClaimLevelData ADD Bucket30 NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30Amount') ALTER TABLE dbo.ClaimLevelData ADD Bucket30Amount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60') ALTER TABLE dbo.ClaimLevelData ADD Bucket60 NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60Amount') ALTER TABLE dbo.ClaimLevelData ADD Bucket60Amount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ClaimType') ALTER TABLE dbo.ClaimLevelData ADD ClaimType NVARCHAR(MAX) NULL;

IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCodeXUnitsXModifierOrginal') ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'T_F') ALTER TABLE dbo.ClaimLevelDataArchive ADD T_F NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'SubscriberId') ALTER TABLE dbo.ClaimLevelDataArchive ADD SubscriberId NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientName') ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientName NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ICDCodes') ALTER TABLE dbo.ClaimLevelDataArchive ADD ICDCodes NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DiagnosisPointer') ALTER TABLE dbo.ClaimLevelDataArchive ADD DiagnosisPointer NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EnteredWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'EnteredStatus') ALTER TABLE dbo.ClaimLevelDataArchive ADD EnteredStatus NVARCHAR(1000) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledStatus') ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledStatus NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ModField') ALTER TABLE dbo.ClaimLevelDataArchive ADD ModField NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ServiceUnit') ALTER TABLE dbo.ClaimLevelDataArchive ADD ServiceUnit NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTXUnits') ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTXUnits NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCombined') ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCombined NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Aging') ALTER TABLE dbo.ClaimLevelDataArchive ADD Aging NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Description') ALTER TABLE dbo.ClaimLevelDataArchive ADD [Description] NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PostedWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD PostedWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ClaimAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD ClaimAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'OriginalDenialCode') ALTER TABLE dbo.ClaimLevelDataArchive ADD OriginalDenialCode NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'LineLevelDenials') ALTER TABLE dbo.ClaimLevelDataArchive ADD LineLevelDenials NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DenialCombination') ALTER TABLE dbo.ClaimLevelDataArchive ADD DenialCombination NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PaymentPercent') ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'RejectionReasons') ALTER TABLE dbo.ClaimLevelDataArchive ADD RejectionReasons NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'RejectionCategory') ALTER TABLE dbo.ClaimLevelDataArchive ADD RejectionCategory NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidCount') ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Adjudicated') ALTER TABLE dbo.ClaimLevelDataArchive ADD Adjudicated NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjudicatedAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjudicatedAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30 NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30Amount') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60 NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60Amount') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ClaimType') ALTER TABLE dbo.ClaimLevelDataArchive ADD ClaimType NVARCHAR(MAX) NULL;
END

PRINT 'Certus ClaimLevel alter script completed.';
