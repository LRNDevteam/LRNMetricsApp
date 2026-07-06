-- ============================================================
-- Script  : 01_Create_BTWOSummary_Table.sql
-- Purpose : Creates dbo.BTWOSummary table for BeechTree
--           Write-Off summary aggregated from
--           BTTransactionDetailData x ClaimLevelData.
-- Run On  : BeechTree lab database (Beech_Tree DB)
-- Run     : Once (idempotent — skipped if table already exists)
-- ============================================================

drop table BTWOSummary
IF OBJECT_ID('dbo.BTWOSummary', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.BTWOSummary
    (
        Id                      INT           IDENTITY(1,1)  NOT NULL,
        ClaimID                 NVARCHAR(50)                 NULL,    -- ClaimID from ClaimLevelData (matched via VisitNumber)
        TransactionCode         NVARCHAR(100)                NULL,
        TransactionCodeDesc     NVARCHAR(500)                NULL,
        TransactionCodeCombined NVARCHAR(620)                NULL,    -- TransactionCode + ' - ' + TransactionCodeDesc
        DateofService           NVARCHAR(50)                 NULL,
        MatchingCount           INT                          NOT NULL DEFAULT 0,
        InsertedDateTime        DATETIME                     NOT NULL DEFAULT GETDATE(),

        CONSTRAINT PK_BTWOSummary PRIMARY KEY CLUSTERED (Id)
    );

    PRINT 'dbo.BTWOSummary created successfully.';
END
ELSE
BEGIN
    PRINT 'dbo.BTWOSummary already exists — skipped.';
END
GO
