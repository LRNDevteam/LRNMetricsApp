/*
  Target database: LRNMaster / Reports API DefaultConnection.
  Creates Admin Master Values insurance maintenance tables.
*/

IF OBJECT_ID('dbo.LabInsuranceMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LabInsuranceMaster
    (
        LabInsuranceMasterId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_LabInsuranceMaster PRIMARY KEY,
        PayerCode NVARCHAR(50) NULL,
        PayerNameRaw NVARCHAR(250) NOT NULL,
        PayerNameNormalized NVARCHAR(250) NULL,
        GlobalPayerID INT NULL,
        PayerGroupCode NVARCHAR(250) NULL,
        PayerCommonCode NVARCHAR(250) NULL,
        Parent NVARCHAR(250) NULL,
        PlanType NVARCHAR(250) NULL,
        MCOType NVARCHAR(250) NULL,
        PayerState NVARCHAR(50) NULL,
        IsActive NVARCHAR(50) NULL,
        BenefitAdminCode NVARCHAR(250) NULL,
        BenefitAdministrator NVARCHAR(250) NULL,
        Remarks NVARCHAR(500) NULL,
        LabName NVARCHAR(50) NULL,
        LabId INT NULL,
        LabState NVARCHAR(50) NULL,
        LabStateCode NVARCHAR(10) NULL,
        CreatedBy NVARCHAR(100) NULL,
        CreatedOn DATETIME2 NOT NULL CONSTRAINT DF_LabInsuranceMaster_CreatedOn DEFAULT SYSUTCDATETIME(),
        ModifiedBy NVARCHAR(100) NULL,
        ModifiedOn DATETIME2 NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabInsuranceMaster_LabId_PayerCode' AND object_id = OBJECT_ID('dbo.LabInsuranceMaster'))
    CREATE INDEX IX_LabInsuranceMaster_LabId_PayerCode ON dbo.LabInsuranceMaster (LabId, PayerCode);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabInsuranceMaster_PayerNameNormalized' AND object_id = OBJECT_ID('dbo.LabInsuranceMaster'))
    CREATE INDEX IX_LabInsuranceMaster_PayerNameNormalized ON dbo.LabInsuranceMaster (PayerNameNormalized);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LabInsuranceMaster_GlobalPayerID' AND object_id = OBJECT_ID('dbo.LabInsuranceMaster'))
    CREATE INDEX IX_LabInsuranceMaster_GlobalPayerID ON dbo.LabInsuranceMaster (GlobalPayerID);
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.LabInsuranceMaster
    WHERE PayerNameNormalized IS NOT NULL
      AND LTRIM(RTRIM(PayerNameNormalized)) <> ''
      AND GlobalPayerID IS NOT NULL
    GROUP BY PayerNameNormalized, GlobalPayerID
    HAVING COUNT(1) > 1
)
BEGIN
    THROW 51001, 'Duplicate LabInsuranceMaster PayerNameNormalized + GlobalPayerID combinations exist. Clean duplicates before creating UX_LabInsuranceMaster_NormalizedName_GlobalPayerID.', 1;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabInsuranceMaster_NormalizedName_GlobalPayerID' AND object_id = OBJECT_ID('dbo.LabInsuranceMaster'))
    CREATE UNIQUE INDEX UX_LabInsuranceMaster_NormalizedName_GlobalPayerID
        ON dbo.LabInsuranceMaster (PayerNameNormalized, GlobalPayerID)
        WHERE PayerNameNormalized IS NOT NULL AND GlobalPayerID IS NOT NULL;
GO

IF OBJECT_ID('dbo.PayerPolicyInsuranceMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PayerPolicyInsuranceMaster
    (
        PayerPolicyInsuranceMasterId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerPolicyInsuranceMaster PRIMARY KEY,
        PayerCode NVARCHAR(50) NULL,
        PayerName NVARCHAR(250) NOT NULL,
        PayerNameNormalized NVARCHAR(250) NULL,
        GlobalPayerID INT NULL,
        PayerGroupCode NVARCHAR(250) NULL,
        PayerCommonCode NVARCHAR(250) NULL,
        PlanType NVARCHAR(250) NULL,
        PayerState NVARCHAR(50) NULL,
        IsActive NVARCHAR(50) NULL,
        BenefitAdminCode NVARCHAR(250) NULL,
        BenefitAdministrator NVARCHAR(250) NULL,
        Remarks NVARCHAR(500) NULL,
        IsMCO NVARCHAR(50) NULL,
        CreatedBy NVARCHAR(100) NULL,
        CreatedOn DATETIME2 NOT NULL CONSTRAINT DF_PayerPolicyInsuranceMaster_CreatedOn DEFAULT SYSUTCDATETIME(),
        ModifiedBy NVARCHAR(100) NULL,
        ModifiedOn DATETIME2 NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_PayerCode' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE INDEX IX_PayerPolicyInsuranceMaster_PayerCode ON dbo.PayerPolicyInsuranceMaster (PayerCode);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_PayerNameNormalized' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE INDEX IX_PayerPolicyInsuranceMaster_PayerNameNormalized ON dbo.PayerPolicyInsuranceMaster (PayerNameNormalized);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_GlobalPayerID' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE INDEX IX_PayerPolicyInsuranceMaster_GlobalPayerID ON dbo.PayerPolicyInsuranceMaster (GlobalPayerID);
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.PayerPolicyInsuranceMaster
    WHERE PayerNameNormalized IS NOT NULL
      AND LTRIM(RTRIM(PayerNameNormalized)) <> ''
      AND GlobalPayerID IS NOT NULL
    GROUP BY PayerNameNormalized, GlobalPayerID
    HAVING COUNT(1) > 1
)
BEGIN
    THROW 51002, 'Duplicate PayerPolicyInsuranceMaster PayerNameNormalized + GlobalPayerID combinations exist. Clean duplicates before creating UX_PayerPolicyInsuranceMaster_NormalizedName_GlobalPayerID.', 1;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PayerPolicyInsuranceMaster_NormalizedName_GlobalPayerID' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE UNIQUE INDEX UX_PayerPolicyInsuranceMaster_NormalizedName_GlobalPayerID
        ON dbo.PayerPolicyInsuranceMaster (PayerNameNormalized, GlobalPayerID)
        WHERE PayerNameNormalized IS NOT NULL AND GlobalPayerID IS NOT NULL;
GO
