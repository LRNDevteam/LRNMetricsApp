/*
  Target database: LRNMaster / Reports API DefaultConnection.
  Creates Admin Master Values insurance maintenance tables.
*/

-- Required for creating/rebuilding filtered indexes (sqlcmd defaults it OFF).
SET QUOTED_IDENTIFIER ON;
GO

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

-- The master holds one record per Payer + Lab combination, so the natural key is
-- PayerNameRaw + LabName (the key the bulk import upserts on). The old lab-agnostic
-- PayerNameNormalized + GlobalPayerID unique index is dropped: the same payer may
-- legitimately appear once per lab.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabInsuranceMaster_NormalizedName_GlobalPayerID' AND object_id = OBJECT_ID('dbo.LabInsuranceMaster'))
    DROP INDEX UX_LabInsuranceMaster_NormalizedName_GlobalPayerID ON dbo.LabInsuranceMaster;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.LabInsuranceMaster
    GROUP BY PayerNameRaw, LabName
    HAVING COUNT(1) > 1
)
BEGIN
    THROW 51001, 'Duplicate LabInsuranceMaster PayerNameRaw + LabName combinations exist. Clean duplicates before creating UX_LabInsuranceMaster_PayerNameRaw_LabName.', 1;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_LabInsuranceMaster_PayerNameRaw_LabName' AND object_id = OBJECT_ID('dbo.LabInsuranceMaster'))
    CREATE UNIQUE INDEX UX_LabInsuranceMaster_PayerNameRaw_LabName
        ON dbo.LabInsuranceMaster (PayerNameRaw, LabName);
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
        PayerNameNormalized NVARCHAR(250) NULL,
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

-- Migration: PayerNameNormalized was originally NVARCHAR(50), which truncates long payer
-- names (e.g. Highmark Blue Cross Blue Shield of Western New York). Widen to NVARCHAR(250)
-- to match the Lab master; the covering index is dropped first and recreated below.
IF EXISTS
(
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster')
      AND name = 'PayerNameNormalized'
      AND max_length > 0 AND max_length < 500
)
BEGIN
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_PayerPolicyInsuranceMaster_PayerNameNormalized' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
        DROP INDEX IX_PayerPolicyInsuranceMaster_PayerNameNormalized ON dbo.PayerPolicyInsuranceMaster;
    IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PayerPolicyInsuranceMaster_NaturalKey' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
        DROP INDEX UX_PayerPolicyInsuranceMaster_NaturalKey ON dbo.PayerPolicyInsuranceMaster;
    ALTER TABLE dbo.PayerPolicyInsuranceMaster ALTER COLUMN PayerNameNormalized NVARCHAR(250) NULL;
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

-- Natural key for the policy master upsert: (PayerNameRaw, GlobalPayerId). The previous
-- triple key that included PayerNameNormalized is dropped; all columns other than the
-- natural key are optional.
IF EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PayerPolicyInsuranceMaster_NaturalKey' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    DROP INDEX UX_PayerPolicyInsuranceMaster_NaturalKey ON dbo.PayerPolicyInsuranceMaster;
GO

IF EXISTS
(
    SELECT 1
    FROM dbo.PayerPolicyInsuranceMaster
    WHERE PayerNameRaw IS NOT NULL
      AND LTRIM(RTRIM(PayerNameRaw)) <> ''
    GROUP BY PayerNameRaw, GlobalPayerId
    HAVING COUNT(1) > 1
)
BEGIN
    THROW 51002, 'Duplicate PayerPolicyInsuranceMaster (PayerNameRaw, GlobalPayerId) combinations exist. Clean duplicates before creating UX_PayerPolicyInsuranceMaster_PayerName_GlobalPayerId.', 1;
END;
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_PayerPolicyInsuranceMaster_PayerName_GlobalPayerId' AND object_id = OBJECT_ID('dbo.PayerPolicyInsuranceMaster'))
    CREATE UNIQUE INDEX UX_PayerPolicyInsuranceMaster_PayerName_GlobalPayerId
        ON dbo.PayerPolicyInsuranceMaster (PayerNameRaw, GlobalPayerId)
        WHERE PayerNameRaw IS NOT NULL;
GO
