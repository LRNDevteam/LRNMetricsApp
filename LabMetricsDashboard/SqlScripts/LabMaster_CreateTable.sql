-- =================================================================
-- LabMaster table for managing Labs from the Admin UI.
-- Run against the LRNMaster database (DefaultConnection).
-- Idempotent: creates table + missing columns + unique LabName index.
-- =================================================================

IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'Labs')
BEGIN
    CREATE TABLE dbo.Labs (
        LabId        INT IDENTITY(1,1) PRIMARY KEY,
        LabName      NVARCHAR(200) NOT NULL,
        IsActive     BIT NOT NULL DEFAULT 1,
        CreatedBy    NVARCHAR(100) NULL,
        CreatedDate  DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME(),
        ModifiedBy   NVARCHAR(100) NULL,
        ModifiedDate DATETIME2 NULL
    );
END
GO

-- Add missing columns if the Labs table already existed with fewer columns.
IF COL_LENGTH('dbo.Labs', 'IsActive') IS NULL
    ALTER TABLE dbo.Labs ADD IsActive BIT NOT NULL CONSTRAINT DF_Labs_IsActive DEFAULT 1;
GO

IF COL_LENGTH('dbo.Labs', 'CreatedBy') IS NULL
    ALTER TABLE dbo.Labs ADD CreatedBy NVARCHAR(100) NULL;
GO

IF COL_LENGTH('dbo.Labs', 'CreatedDate') IS NULL
    ALTER TABLE dbo.Labs ADD CreatedDate DATETIME2 NOT NULL CONSTRAINT DF_Labs_CreatedDate DEFAULT SYSUTCDATETIME();
GO

IF COL_LENGTH('dbo.Labs', 'ModifiedBy') IS NULL
    ALTER TABLE dbo.Labs ADD ModifiedBy NVARCHAR(100) NULL;
GO

IF COL_LENGTH('dbo.Labs', 'ModifiedDate') IS NULL
    ALTER TABLE dbo.Labs ADD ModifiedDate DATETIME2 NULL;
GO

-- Enforce LabName uniqueness (case-insensitive uses default collation).
IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'UX_Labs_LabName' AND object_id = OBJECT_ID('dbo.Labs'))
BEGIN
    CREATE UNIQUE INDEX UX_Labs_LabName ON dbo.Labs(LabName);
END
GO
