-- LRN Averages Import Worker — CPTAverage / PanelAverage target tables.
--
-- Both tables already exist in LRNMaster; the CREATE blocks below mirror the live
-- schema so a fresh database matches production, and the ALTER block is the part
-- that actually runs on an existing install.
--
-- The point of the ALTER: PanelAverage.PayerID was NOT NULL, so a source row with
-- no payer id failed the whole SqlBulkCopy batch with
--   "Column 'PayerID' does not allow DBNull.Value"
-- and the import transaction rolled back. Making it NULLable lets those rows land.
--
-- Column names match the DataTables built in ImportService (BuildCptTable /
-- BuildPanelTable) — the bulk copy maps by name, so any rename here must be
-- mirrored there. CPTAvgId / PanelAvgId and CreatedON are not supplied by the
-- import: the first is IDENTITY, the second defaults to GETDATE().
USE LRNMaster;
GO

/* ------------------------------------------------------------------ CPTAverage */
IF OBJECT_ID('dbo.CPTAverage', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CPTAverage
    (
        CPTAvgId                        INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_CPTAverage PRIMARY KEY CLUSTERED,
        LabID                           INT             NULL,
        LabName                         NVARCHAR(250)   NULL,
        PayerCommonCode                 NVARCHAR(250)   NULL,
        PayerDisplayName                NVARCHAR(250)   NULL,
        CPTCode                         NVARCHAR(250)   NULL,
        AvgUnits                        INT             NULL,
        PanelName                       NVARCHAR(250)   NULL,
        WindowType                      NVARCHAR(250)   NULL,
        StartDate                       DATE            NULL,
        EndDate                         DATE            NULL,
        AsOfDateTime                    DATE            NULL,
        PaidLineCount                   INT             NULL,
        AvgChargeAmountPerUnit          DECIMAL(18,2)   NULL,
        AvgPaidAmountPerUnit            DECIMAL(18,2)   NULL,
        AvgAllowedAmountPerUnit         DECIMAL(18,2)   NULL,
        AvgPatientPaidAmountPerUnit     DECIMAL(18,2)   NULL,
        AvgPatientResponsibilityPerUnit DECIMAL(18,2)   NULL,
        MedianPaidAmount                DECIMAL(18,2)   NULL,
        P25PaidAmount                   DECIMAL(18,2)   NULL,
        P75PaidAmount                   DECIMAL(18,2)   NULL,
        TotalLineCount                  INT             NULL,
        DeniedLineCount                 INT             NULL,
        AdjustedLineCount               INT             NULL,
        LastSeenDOS                     DATE            NULL,
        Global_Payer_ID                 INT             NULL,   -- NULLable: file may carry no payer id
        CreatedON                       DATETIME        NOT NULL
            CONSTRAINT DF_CPTAverage_CreatedON DEFAULT (GETDATE())
    );

    CREATE NONCLUSTERED INDEX IX_CPTAverage_Lab_Payer   ON dbo.CPTAverage(LabID, Global_Payer_ID);
    CREATE NONCLUSTERED INDEX IX_CPTAverage_CPT_Panel   ON dbo.CPTAverage(CPTCode, PanelName);
    CREATE NONCLUSTERED INDEX IX_CPTAverage_Window_Date ON dbo.CPTAverage(WindowType, StartDate, EndDate);
END
GO

/* ---------------------------------------------------------------- PanelAverage */
IF OBJECT_ID('dbo.PanelAverage', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PanelAverage
    (
        PanelAvgId                  INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_PanelAverage PRIMARY KEY CLUSTERED,
        PayerID                     NVARCHAR(50)    NULL,       -- NULLable: file may carry no payer id
        PayerDisplayName            NVARCHAR(250)   NULL,
        PanelName                   NVARCHAR(50)    NULL,
        WindowType                  NVARCHAR(50)    NULL,
        StartDate                   DATE            NULL,
        EndDate                     DATE            NULL,
        AsOfDateTime                DATE            NULL,
        PaidLineCount               INT             NULL,
        AvgChargeAmount             DECIMAL(18,2)   NULL,
        AvgPaidAmount               DECIMAL(18,2)   NULL,
        AvgAllowedAmount            DECIMAL(18,2)   NULL,
        AvgPatientPaidAmount        DECIMAL(18,2)   NULL,
        AvgPatientResponsibility    DECIMAL(18,2)   NULL,
        MedianPaidAmount            DECIMAL(18,2)   NULL,
        P25PaidAmount               DECIMAL(18,2)   NULL,
        P75PaidAmount               DECIMAL(18,2)   NULL,
        TotalLineCount              INT             NULL,
        DeniedLineCount             INT             NULL,
        AdjustedLineCount           INT             NULL,
        LastSeenDOS                 DATE            NULL,
        LabName                     NVARCHAR(50)    NULL,
        LabId                       INT             NULL,
        CreatedON                   DATETIME        NOT NULL
            CONSTRAINT DF_PanelAverage_CreatedON DEFAULT (GETDATE())
    );

    CREATE NONCLUSTERED INDEX IX_PanelAverage_Payer_Panel ON dbo.PanelAverage(PayerID, PanelName, WindowType);
    CREATE NONCLUSTERED INDEX IX_PanelAverage_Lab         ON dbo.PanelAverage(LabId);
    CREATE NONCLUSTERED INDEX IX_PanelAverage_Date        ON dbo.PanelAverage(StartDate, EndDate, AsOfDateTime);
END
GO

/* ------------------------------------------- Relax payer id columns to NULLABLE */
-- Idempotent: each block is a no-op once the column is already NULLable.
-- PayerID participates only in the non-unique index IX_PanelAverage_Payer_Panel,
-- so ALTER COLUMN needs no constraint to be dropped first; the index stays valid.
IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.PanelAverage') AND name = 'PayerID' AND is_nullable = 0)
BEGIN
    ALTER TABLE dbo.PanelAverage ALTER COLUMN PayerID NVARCHAR(50) NULL;
    PRINT 'dbo.PanelAverage.PayerID -> NULL';
END
ELSE
    PRINT 'dbo.PanelAverage.PayerID already NULLable — no change';
GO

IF EXISTS (
    SELECT 1 FROM sys.columns
    WHERE object_id = OBJECT_ID('dbo.CPTAverage') AND name = 'Global_Payer_ID' AND is_nullable = 0)
BEGIN
    ALTER TABLE dbo.CPTAverage ALTER COLUMN Global_Payer_ID INT NULL;
    PRINT 'dbo.CPTAverage.Global_Payer_ID -> NULL';
END
ELSE
    PRINT 'dbo.CPTAverage.Global_Payer_ID already NULLable — no change';
GO

/* --------------------------------------------------------------------- Verify */
SELECT TABLE_NAME, COLUMN_NAME, DATA_TYPE, CHARACTER_MAXIMUM_LENGTH, IS_NULLABLE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE (TABLE_NAME = 'PanelAverage' AND COLUMN_NAME IN ('PayerID', 'PayerDisplayName'))
   OR (TABLE_NAME = 'CPTAverage'   AND COLUMN_NAME IN ('Global_Payer_ID', 'PayerCommonCode'))
ORDER BY TABLE_NAME, COLUMN_NAME;
GO
