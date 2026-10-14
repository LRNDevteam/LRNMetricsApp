SET NOCOUNT ON;

-- Elixir-specific ClaimLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CPTCodeXUnitsXModifierOrginal') ALTER TABLE dbo.ClaimLevelData ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'T_F') ALTER TABLE dbo.ClaimLevelData ADD T_F NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientFirstName') ALTER TABLE dbo.ClaimLevelData ADD PatientFirstName NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientLastName') ALTER TABLE dbo.ClaimLevelData ADD PatientLastName NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PatientAddress') ALTER TABLE dbo.ClaimLevelData ADD PatientAddress NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Coverage') ALTER TABLE dbo.ClaimLevelData ADD Coverage NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AgingDOS') ALTER TABLE dbo.ClaimLevelData ADD AgingDOS NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ServiceToDate') ALTER TABLE dbo.ClaimLevelData ADD ServiceToDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AgingDOE') ALTER TABLE dbo.ClaimLevelData ADD AgingDOE NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Facility') ALTER TABLE dbo.ClaimLevelData ADD Facility NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ServiceLocationCode') ALTER TABLE dbo.ClaimLevelData ADD ServiceLocationCode NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ServiceLocationName') ALTER TABLE dbo.ClaimLevelData ADD ServiceLocationName NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PrimarySubId') ALTER TABLE dbo.ClaimLevelData ADD PrimarySubId NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'ICDField') ALTER TABLE dbo.ClaimLevelData ADD ICDField NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DODWeek') ALTER TABLE dbo.ClaimLevelData ADD DODWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BilledWeek') ALTER TABLE dbo.ClaimLevelData ADD BilledWeek NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'DenialReason') ALTER TABLE dbo.ClaimLevelData ADD DenialReason NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BillingOption') ALTER TABLE dbo.ClaimLevelData ADD BillingOption NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CurrentStatus') ALTER TABLE dbo.ClaimLevelData ADD CurrentStatus NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BatchNo') ALTER TABLE dbo.ClaimLevelData ADD BatchNo NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CreatedOn') ALTER TABLE dbo.ClaimLevelData ADD CreatedOn NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'CreatedBy') ALTER TABLE dbo.ClaimLevelData ADD CreatedBy NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'UpdatedOn') ALTER TABLE dbo.ClaimLevelData ADD UpdatedOn NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'UpdatedBy') ALTER TABLE dbo.ClaimLevelData ADD UpdatedBy NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'BillStatus') ALTER TABLE dbo.ClaimLevelData ADD BillStatus NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'PaymentPercent') ALTER TABLE dbo.ClaimLevelData ADD PaymentPercent NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidCount') ALTER TABLE dbo.ClaimLevelData ADD FullyPaidCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'FullyPaidAmount') ALTER TABLE dbo.ClaimLevelData ADD FullyPaidAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjucticatedCount') ALTER TABLE dbo.ClaimLevelData ADD AdjucticatedCount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'AdjucticatedAmount') ALTER TABLE dbo.ClaimLevelData ADD AdjucticatedAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30Count') ALTER TABLE dbo.ClaimLevelData ADD Bucket30Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket30Amount') ALTER TABLE dbo.ClaimLevelData ADD Bucket30Amount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60Count') ALTER TABLE dbo.ClaimLevelData ADD Bucket60Count NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelData') AND name = 'Bucket60Amount') ALTER TABLE dbo.ClaimLevelData ADD Bucket60Amount NVARCHAR(500) NULL;

IF OBJECT_ID('dbo.ClaimLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CPTCodeXUnitsXModifierOrginal') ALTER TABLE dbo.ClaimLevelDataArchive ADD CPTCodeXUnitsXModifierOrginal NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'T_F') ALTER TABLE dbo.ClaimLevelDataArchive ADD T_F NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientFirstName') ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientFirstName NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientLastName') ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientLastName NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PatientAddress') ALTER TABLE dbo.ClaimLevelDataArchive ADD PatientAddress NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Coverage') ALTER TABLE dbo.ClaimLevelDataArchive ADD Coverage NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AgingDOS') ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingDOS NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ServiceToDate') ALTER TABLE dbo.ClaimLevelDataArchive ADD ServiceToDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AgingDOE') ALTER TABLE dbo.ClaimLevelDataArchive ADD AgingDOE NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Facility') ALTER TABLE dbo.ClaimLevelDataArchive ADD Facility NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ServiceLocationCode') ALTER TABLE dbo.ClaimLevelDataArchive ADD ServiceLocationCode NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ServiceLocationName') ALTER TABLE dbo.ClaimLevelDataArchive ADD ServiceLocationName NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PrimarySubId') ALTER TABLE dbo.ClaimLevelDataArchive ADD PrimarySubId NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'ICDField') ALTER TABLE dbo.ClaimLevelDataArchive ADD ICDField NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DODWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD DODWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BilledWeek') ALTER TABLE dbo.ClaimLevelDataArchive ADD BilledWeek NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'DenialReason') ALTER TABLE dbo.ClaimLevelDataArchive ADD DenialReason NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BillingOption') ALTER TABLE dbo.ClaimLevelDataArchive ADD BillingOption NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CurrentStatus') ALTER TABLE dbo.ClaimLevelDataArchive ADD CurrentStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BatchNo') ALTER TABLE dbo.ClaimLevelDataArchive ADD BatchNo NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CreatedOn') ALTER TABLE dbo.ClaimLevelDataArchive ADD CreatedOn NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'CreatedBy') ALTER TABLE dbo.ClaimLevelDataArchive ADD CreatedBy NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'UpdatedOn') ALTER TABLE dbo.ClaimLevelDataArchive ADD UpdatedOn NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'UpdatedBy') ALTER TABLE dbo.ClaimLevelDataArchive ADD UpdatedBy NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'BillStatus') ALTER TABLE dbo.ClaimLevelDataArchive ADD BillStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'PaymentPercent') ALTER TABLE dbo.ClaimLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidCount') ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'FullyPaidAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD FullyPaidAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjucticatedCount') ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjucticatedCount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'AdjucticatedAmount') ALTER TABLE dbo.ClaimLevelDataArchive ADD AdjucticatedAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30Count') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket30Amount') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket30Amount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60Count') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Count NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.ClaimLevelDataArchive') AND name = 'Bucket60Amount') ALTER TABLE dbo.ClaimLevelDataArchive ADD Bucket60Amount NVARCHAR(500) NULL;
END

PRINT 'Elixir ClaimLevel alter script completed.';
