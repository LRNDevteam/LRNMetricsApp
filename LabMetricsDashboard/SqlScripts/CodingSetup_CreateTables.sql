-- =====================================================================
-- SQL Script: Create CodingSetupMasterList tables for the Coding Setup Module
-- Database: LRNMaster (DefaultConnection)
-- NOTE: The existing PanelPathogenCPTlist table is NOT modified.
--       Each lab's coding setup data is stored in CodingSetupMasterList,
--       separated by the LabName column.
-- =====================================================================

-- 1. Main table – one row per panel/pathogen/CPT combination per lab
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CodingSetupMasterList')
BEGIN
    CREATE TABLE dbo.CodingSetupMasterList (
        Id              INT IDENTITY(1,1) PRIMARY KEY,
        LabName         NVARCHAR(100)  NOT NULL,
        PanelName       NVARCHAR(200)  NOT NULL,
        TestName        NVARCHAR(200)  NULL,
        PathogenName    NVARCHAR(200)  NOT NULL,
        CPTCode         NVARCHAR(50)   NOT NULL,
        DefaultUnits    DECIMAL(10,2)  NOT NULL DEFAULT 1,
        DefaultICDCodes NVARCHAR(500)  NULL,
        SortOrder       INT            NOT NULL DEFAULT 0,
        IsActive        BIT            NOT NULL DEFAULT 1,
        CreatedBy       NVARCHAR(100)  NULL,
        CreatedDate     DATETIME       NULL DEFAULT GETDATE(),
        ModifiedBy      NVARCHAR(100)  NULL,
        ModifiedDate    DATETIME       NULL
    );

    CREATE NONCLUSTERED INDEX IX_CodingSetupMasterList_Lab
        ON dbo.CodingSetupMasterList (LabName, IsActive)
        INCLUDE (PanelName, TestName, PathogenName, CPTCode);

    PRINT 'Created CodingSetupMasterList table.';
END
GO

-- 2. Audit / Change History table
IF NOT EXISTS (SELECT 1 FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_NAME = 'CodingSetupMasterList_Audit')
BEGIN
    CREATE TABLE dbo.CodingSetupMasterList_Audit (
        AuditId     INT IDENTITY(1,1) PRIMARY KEY,
        RecordId    INT            NOT NULL,
        LabName     NVARCHAR(100)  NOT NULL,
        FieldName   NVARCHAR(100)  NOT NULL,
        OldValue    NVARCHAR(MAX)  NULL,
        NewValue    NVARCHAR(MAX)  NULL,
        ChangedBy   NVARCHAR(100)  NULL,
        ChangedDate DATETIME       NOT NULL DEFAULT GETDATE()
    );

    CREATE NONCLUSTERED INDEX IX_CodingSetupMasterList_Audit_RecordId
        ON dbo.CodingSetupMasterList_Audit (RecordId);

    PRINT 'Created CodingSetupMasterList_Audit table.';
END
GO
