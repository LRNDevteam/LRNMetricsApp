SET NOCOUNT ON;

-- ============================================================
-- 25_BeechTree_WOSummary_Refresh_SP.sql
--
-- Creates dbo.usp_RefreshBT_WOSummary.
--
-- Called after every new TransactionDetail Adjustment XLSX
-- is imported into dbo.BTTransactionDetailData.
--
-- Logic:
--   1. TRUNCATE dbo.BTWOSummary  (full rebuild every run).
--
--   2. INSERT into BTWOSummary from BTTransactionDetailData:
--        VisitNumber, TransactionCode, TransactionCodeDesc,
--        TransactionDetail (= TransactionCode + ' - ' + TransactionCodeDesc),
--        TDateofService (= DateOfService from the XLSX),
--        CreatedDateTime (= GETDATE()),
--        WOFileName (= FileName of the most-recently inserted file).
--
--   3. UPDATE BTWOSummary by cross-matching on VisitNumber
--      against dbo.ClaimLevelData.ClaimID to populate:
--        ClaimID, CdateofService, UpdatedDateTime, ClaimFileSourcename.
--
-- Run AFTER 23_ and 24_ scripts.
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_RefreshBT_WOSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- ── 1. Full rebuild: truncate first ───────────────────────
    TRUNCATE TABLE dbo.BTWOSummary;

    -- ── 2. Insert from the raw data table ────────────────────
    --    WOFileName: use the FileName from the latest file batch
    --    (identified by the maximum Id in BTTransactionDetailData).
    INSERT INTO dbo.BTWOSummary
    (
        VisitNumber,
        TransactionCode,
        TransactionCodeDesc,
        TransactionDetail,
        TDateofService,
        CreatedDateTime,
        WOFileName
    )
    SELECT
        d.VisitNumber,
        d.TransactionCode,
        d.TransactionCodeDesc,
        -- Derived field: combined descriptor
        ISNULL(d.TransactionCode, '') + ' - ' + ISNULL(d.TransactionCodeDesc, '')
            AS TransactionDetail,
        d.DateOfService         AS TDateofService,
        GETDATE()               AS CreatedDateTime,
        d.FileName              AS WOFileName
    FROM dbo.BTTransactionDetailData AS d
    INNER JOIN
    (
        -- Restrict to the most-recently inserted file batch
        SELECT FileName
        FROM   dbo.BTTransactionDetailData
        WHERE  Id = (SELECT MAX(Id) FROM dbo.BTTransactionDetailData)
    ) AS latest ON d.FileName = latest.FileName;

    -- ── 3. Cross-match with ClaimLevelData to fill claim columns
    --    Join key: BTWOSummary.VisitNumber = ClaimLevelData.ClaimID
    UPDATE w
    SET
        w.ClaimID             = c.ClaimID,
        w.CdateofService      = c.DateofService,
        w.UpdatedDateTime     = GETDATE(),
        w.ClaimFileSourcename = c.FileName
    FROM dbo.BTWOSummary       AS w
    INNER JOIN dbo.ClaimLevelData AS c
        ON LTRIM(RTRIM(w.VisitNumber)) = LTRIM(RTRIM(c.ClaimID));

    -- Return summary counts for caller logging
    SELECT
        (SELECT COUNT(*) FROM dbo.BTWOSummary)                        AS TotalRows,
        (SELECT COUNT(*) FROM dbo.BTWOSummary WHERE ClaimID IS NOT NULL) AS MatchedRows;
END
GO

PRINT 'dbo.usp_RefreshBT_WOSummary created.';
GO

PRINT '25_BeechTree_WOSummary_Refresh_SP.sql completed successfully.';
GO
