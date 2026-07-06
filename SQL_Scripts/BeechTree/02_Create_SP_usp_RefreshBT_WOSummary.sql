-- ============================================================
-- Script  : 02_Create_SP_usp_RefreshBT_WOSummary.sql
-- Purpose : Creates (or alters) dbo.usp_RefreshBT_WOSummary.
--           Joins BTTransactionDetailData (VisitNumber) with
--           ClaimLevelData (ClaimID) on DateofService, groups
--           by TransactionCode / TransactionCodeDesc / DateofService,
--           and rebuilds dbo.BTWOSummary with MatchingCount.
-- Run On  : BeechTree lab database (Beech_Tree DB)
-- Run     : Run 01_Create_BTWOSummary_Table.sql first.
-- ============================================================

IF OBJECT_ID('dbo.usp_RefreshBT_WOSummary', 'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_RefreshBT_WOSummary;
GO

CREATE PROCEDURE dbo.usp_RefreshBT_WOSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Step 1: Clear previous aggregates ─────────────────────────────────────
    TRUNCATE TABLE dbo.BTWOSummary;

    -- ── Step 2: Rebuild from joined + grouped source data ─────────────────────
    --
    --   Join key  : BTTransactionDetailData.VisitNumber  = ClaimLevelData.ClaimID
    --   Date match: TRY_CAST(BTTransactionDetailData.DateOfService AS DATE)
    --             = TRY_CAST(ClaimLevelData.DateofService AS DATE)
    --               (cast to DATE so format differences like MM/DD/YYYY vs M/D/YYYY
    --                vs YYYY-MM-DD do not cause rows to be silently excluded)
    --
    --   Output columns:
    --     ClaimID                 – from ClaimLevelData (matched via VisitNumber)
    --     TransactionCode         – from BTTransactionDetailData
    --     TransactionCodeDesc     – from BTTransactionDetailData
    --     TransactionCodeCombined – TransactionCode + ' - ' + TransactionCodeDesc
    --     DateofService           – matched date (from BTTransactionDetailData)
    --     MatchingCount           – number of rows in the joined group
    -- ──────────────────────────────────────────────────────────────────────────

    INSERT INTO dbo.BTWOSummary
        (ClaimID, TransactionCode, TransactionCodeDesc, TransactionCodeCombined, DateofService, MatchingCount)
    SELECT
        LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50))))          AS ClaimID,
        td.TransactionCode,
        td.TransactionCodeDesc,
        ISNULL(LTRIM(RTRIM(td.TransactionCode)),     '')
            + ' - '
            + ISNULL(LTRIM(RTRIM(td.TransactionCodeDesc)), '')  AS TransactionCodeCombined,
        td.DateOfService                                         AS DateofService,
        COUNT(*)                                                 AS MatchingCount
    FROM dbo.BTTransactionDetailData AS td
    INNER JOIN dbo.ClaimLevelData    AS cl
        ON  LTRIM(RTRIM(CAST(td.VisitNumber  AS NVARCHAR(50))))
          = LTRIM(RTRIM(CAST(cl.ClaimID      AS NVARCHAR(50))))
        AND TRY_CAST(td.DateOfService  AS DATE)
          = TRY_CAST(cl.DateofService  AS DATE)
    WHERE TRY_CAST(td.DateOfService AS DATE) IS NOT NULL
      AND TRY_CAST(cl.DateofService  AS DATE) IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(CAST(cl.ClaimID AS NVARCHAR(50)))),
        td.TransactionCode,
        td.TransactionCodeDesc,
        td.DateOfService;

    -- ── Step 3: Return summary counts to the caller (ClaimLineCSVDataCapture) ─
    SELECT
        COUNT(*)        AS TotalRows,
        SUM(MatchingCount) AS MatchedRows
    FROM dbo.BTWOSummary;

END
GO

PRINT 'dbo.usp_RefreshBT_WOSummary created successfully.';
GO
