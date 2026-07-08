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
    -- Global payer policy master. GlobalPayerId is stored as NVARCHAR (numeric values only) and
    -- GlobalPayerCode is the NOT-NULL business key; PayerGroupCode is an integer code.
    CREATE TABLE dbo.PayerPolicyInsuranceMaster
    (
        PPInsuranceMasterId INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PayerPolicyInsuranceMaster PRIMARY KEY,
        GlobalPayerId NVARCHAR(50) NULL,
        GlobalPayerCode NVARCHAR(250) NOT NULL,
        PayerGroupCode INT NULL,
        BenefitAdminCode NVARCHAR(250) NULL,
        BenefitAdministrator NVARCHAR(250) NULL,
        PayerNameRaw NVARCHAR(250) NULL,
        PayerNameNormalized NVARCHAR(50) NULL,
        PayerShortCode NVARCHAR(50) NULL,
        PlanType NVARCHAR(250) NULL,
        PayerState NVARCHAR(250) NULL,
        IsActive NVARCHAR(50) NULL,
        Remarks NVARCHAR(500) NULL,
        CreatedBy NVARCHAR(100) NULL,
        CreatedOn DATETIME2 NOT NULL CONSTRAINT DF_PayerPolicyInsuranceMaster_CreatedOn DEFAULT SYSUTCDATETIME(),
        ModifiedBy NVARCHAR(100) NULL,
        ModifiedOn DATETIME2 NULL
    );
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_GlobalPayerCode' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE INDEX IX_PayerPolicyInsuranceMaster_GlobalPayerCode ON dbo.PayerPolicyInsuranceMaster (GlobalPayerCode);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_PayerNameNormalized' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE INDEX IX_PayerPolicyInsuranceMaster_PayerNameNormalized ON dbo.PayerPolicyInsuranceMaster (PayerNameNormalized);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_PayerNameRaw' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE INDEX IX_PayerPolicyInsuranceMaster_PayerNameRaw ON dbo.PayerPolicyInsuranceMaster (PayerNameRaw);
GO

-- Natural key for the policy master upsert: (PayerNameRaw, PayerNameNormalized, GlobalPayerId).
IF EXISTS
(
    SELECT 1
    FROM dbo.PayerPolicyInsuranceMaster
    WHERE PayerNameRaw IS NOT NULL
      AND LTRIM(RTRIM(PayerNameRaw)) <> ''
    GROUP BY PayerNameRaw, PayerNameNormalized, GlobalPayerId
    HAVING COUNT(1) > 1
)
BEGIN
    THROW 51002, 'Duplicate PayerPolicyInsuranceMaster (PayerNameRaw, PayerNameNormalized, GlobalPayerId) combinations exist. Clean duplicates before creating UX_PayerPolicyInsuranceMaster_NaturalKey.', 1;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PayerPolicyInsuranceMaster_NaturalKey' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE UNIQUE INDEX UX_PayerPolicyInsuranceMaster_NaturalKey
        ON dbo.PayerPolicyInsuranceMaster (PayerNameRaw, PayerNameNormalized, GlobalPayerId)
        WHERE PayerNameRaw IS NOT NULL;
GO
