SET NOCOUNT ON;

-- Elixir-specific LineLevel additional columns

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPostedDate') ALTER TABLE dbo.LineLevelData ADD PaymentPostedDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'T_F') ALTER TABLE dbo.LineLevelData ADD T_F NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'VisitXCptXMod') ALTER TABLE dbo.LineLevelData ADD VisitXCptXMod NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UID') ALTER TABLE dbo.LineLevelData ADD UID NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientFirstName') ALTER TABLE dbo.LineLevelData ADD PatientFirstName NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PatientLastName') ALTER TABLE dbo.LineLevelData ADD PatientLastName NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AgingDOS') ALTER TABLE dbo.LineLevelData ADD AgingDOS NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ServiceToDate') ALTER TABLE dbo.LineLevelData ADD ServiceToDate NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'AgingDOE') ALTER TABLE dbo.LineLevelData ADD AgingDOE NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'OrderingPhysicianFirstName') ALTER TABLE dbo.LineLevelData ADD OrderingPhysicianFirstName NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ServiceLocationCode') ALTER TABLE dbo.LineLevelData ADD ServiceLocationCode NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PrimarySubId') ALTER TABLE dbo.LineLevelData ADD PrimarySubId NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CptXModXUnits') ALTER TABLE dbo.LineLevelData ADD CptXModXUnits NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'ServiceChargeAmount') ALTER TABLE dbo.LineLevelData ADD ServiceChargeAmount NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'LineLevelDenialCode') ALTER TABLE dbo.LineLevelData ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'DenialReason') ALTER TABLE dbo.LineLevelData ADD DenialReason NVARCHAR(MAX) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BillingOption') ALTER TABLE dbo.LineLevelData ADD BillingOption NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BillStatus') ALTER TABLE dbo.LineLevelData ADD BillStatus NVARCHAR(200) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'BatchNo') ALTER TABLE dbo.LineLevelData ADD BatchNo NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CreatedOn') ALTER TABLE dbo.LineLevelData ADD CreatedOn NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'CreatedBy') ALTER TABLE dbo.LineLevelData ADD CreatedBy NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UpdatedOn') ALTER TABLE dbo.LineLevelData ADD UpdatedOn NVARCHAR(100) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'UpdatedBy') ALTER TABLE dbo.LineLevelData ADD UpdatedBy NVARCHAR(500) NULL;
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelData') AND name = 'PaymentPercent') ALTER TABLE dbo.LineLevelData ADD PaymentPercent NVARCHAR(100) NULL;

IF OBJECT_ID('dbo.LineLevelDataArchive') IS NOT NULL
BEGIN
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPostedDate') ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPostedDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'T_F') ALTER TABLE dbo.LineLevelDataArchive ADD T_F NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'VisitXCptXMod') ALTER TABLE dbo.LineLevelDataArchive ADD VisitXCptXMod NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UID') ALTER TABLE dbo.LineLevelDataArchive ADD UID NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientFirstName') ALTER TABLE dbo.LineLevelDataArchive ADD PatientFirstName NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PatientLastName') ALTER TABLE dbo.LineLevelDataArchive ADD PatientLastName NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AgingDOS') ALTER TABLE dbo.LineLevelDataArchive ADD AgingDOS NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ServiceToDate') ALTER TABLE dbo.LineLevelDataArchive ADD ServiceToDate NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'AgingDOE') ALTER TABLE dbo.LineLevelDataArchive ADD AgingDOE NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'OrderingPhysicianFirstName') ALTER TABLE dbo.LineLevelDataArchive ADD OrderingPhysicianFirstName NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ServiceLocationCode') ALTER TABLE dbo.LineLevelDataArchive ADD ServiceLocationCode NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PrimarySubId') ALTER TABLE dbo.LineLevelDataArchive ADD PrimarySubId NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CptXModXUnits') ALTER TABLE dbo.LineLevelDataArchive ADD CptXModXUnits NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'ServiceChargeAmount') ALTER TABLE dbo.LineLevelDataArchive ADD ServiceChargeAmount NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'LineLevelDenialCode') ALTER TABLE dbo.LineLevelDataArchive ADD LineLevelDenialCode NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'DenialReason') ALTER TABLE dbo.LineLevelDataArchive ADD DenialReason NVARCHAR(MAX) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BillingOption') ALTER TABLE dbo.LineLevelDataArchive ADD BillingOption NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BillStatus') ALTER TABLE dbo.LineLevelDataArchive ADD BillStatus NVARCHAR(200) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'BatchNo') ALTER TABLE dbo.LineLevelDataArchive ADD BatchNo NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CreatedOn') ALTER TABLE dbo.LineLevelDataArchive ADD CreatedOn NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'CreatedBy') ALTER TABLE dbo.LineLevelDataArchive ADD CreatedBy NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UpdatedOn') ALTER TABLE dbo.LineLevelDataArchive ADD UpdatedOn NVARCHAR(100) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'UpdatedBy') ALTER TABLE dbo.LineLevelDataArchive ADD UpdatedBy NVARCHAR(500) NULL;
    IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE [object_id] = OBJECT_ID('dbo.LineLevelDataArchive') AND name = 'PaymentPercent') ALTER TABLE dbo.LineLevelDataArchive ADD PaymentPercent NVARCHAR(100) NULL;
END

PRINT 'Elixir LineLevel alter script completed.';
