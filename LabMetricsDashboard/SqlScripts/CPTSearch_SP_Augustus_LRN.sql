-- ============================================================
-- CPT Code Search  –  Augustus Labs
-- Deploy on:  LRNMaster
-- Queries:    Augustus_LRN.dbo.LineLevelData
--             Augustus_LRN.dbo.ClaimLevelData
--
-- Usage:
--   USE LRNMaster
--   EXEC dbo.usp_CPTCodeSearch_Augustus_LRN @CPTCode = '87798'
--
-- Column names confirmed from live data (Augustus_LRN):
--   LineLevelData  : CPTCode, Units, Modifier, Panelname,
--                    DenialCode, ClaimStatus, PayerName, PayerType,
--                    DateofService, TotalPayments, ChargeAmount
--   ClaimLevelData : CPTCodeXUnitsXModifier, ClaimID, Panelname,
--                    ClaimStatus, DenialCode, TotalPayments, ChargeAmount
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_CPTCodeSearch_Augustus_LRN
    @CPTCode NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET @CPTCode = LTRIM(RTRIM(@CPTCode));

    -- ===========================================================================
    -- RS 1 : LineLevelData  –  Panel × ClaimStatus × DenialCode summary
    --        Shows exactly what purpose the CPT was billed for,
    --        whether each line was claimed or denied, and the financials.
    -- ===========================================================================
    SELECT
        ISNULL(LTRIM(RTRIM(Panelname)),    '(No Panel)') AS PanelName,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),  '')            AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(DenialCode)),   '')            AS DenialCode,
        COUNT(*)                                          AS LineCount,
        -- Units: default 1 when NULL (some rows have blank Units)
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0) AS TotalUnits,
        -- DeniedUnits: has a DenialCode  OR  status contains Denied/Rejected
        ISNULL(SUM(CASE
            WHEN (DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> '')
              OR  UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) LIKE '%DENIED%'
              OR  UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) LIKE '%REJECTED%'
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)
            ELSE 0 END), 0)                               AS DeniedUnits,
        -- ClaimedUnits: no denial code AND status not Denied/Rejected
        ISNULL(SUM(CASE
            WHEN (DenialCode IS NULL OR LTRIM(RTRIM(DenialCode)) = '')
             AND  UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) NOT LIKE '%DENIED%'
             AND  UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) NOT LIKE '%REJECTED%'
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)
            ELSE 0 END), 0)                               AS ClaimedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0) AS TotalPayments,
        ISNULL(SUM(ISNULL(TRY_CAST(ChargeAmount  AS DECIMAL(18,2)), 0)), 0) AS TotalCharges,
        ISNULL(MIN(CASE WHEN ISNULL(DateofService, '') <> ''
                        THEN DateofService END), '')       AS EarliestDOS,
        ISNULL(MAX(ISNULL(DateofService, '')), '')          AS LatestDOS
    FROM Augustus_LRN.dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
    GROUP BY
        ISNULL(LTRIM(RTRIM(Panelname)),   '(No Panel)'),
        ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
        ISNULL(LTRIM(RTRIM(DenialCode)),  '')
    ORDER BY TotalPayments DESC;


    -- ===========================================================================
    -- RS 2 : Denial Code Breakdown
    -- ===========================================================================
    SELECT
        LTRIM(RTRIM(DenialCode))                            AS DenialCode,
        COUNT(*)                                            AS LineCount,
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)         AS DeniedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0) AS Payments
    FROM Augustus_LRN.dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
      AND DenialCode IS NOT NULL
      AND LTRIM(RTRIM(DenialCode)) <> ''
    GROUP BY LTRIM(RTRIM(DenialCode))
    ORDER BY LineCount DESC;


    -- ===========================================================================
    -- RS 3 : Monthly Trend  (by DateofService year-month)
    -- ===========================================================================
    SELECT
        ISNULL(FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM'), 'Unknown') AS MonthYear,
        COUNT(*)                                            AS LineCount,
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)          AS TotalUnits,
        ISNULL(SUM(CASE WHEN DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1) ELSE 0 END), 0) AS DeniedUnits,
        ISNULL(SUM(CASE WHEN DenialCode IS NULL OR LTRIM(RTRIM(DenialCode)) = ''
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1) ELSE 0 END), 0) AS ClaimedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0)  AS TotalPayments
    FROM Augustus_LRN.dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
    GROUP BY ISNULL(FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM'), 'Unknown')
    ORDER BY MonthYear;


    -- ===========================================================================
    -- RS 4 : ClaimLevelData  –  Claims that contain this CPT code
    --        CPTCodeXUnitsXModifier is a combined multi-CPT string, e.g.:
    --        "87491,87496,...,87798"  →  LIKE search to find matching claims
    -- ===========================================================================
    SELECT
        ISNULL(LTRIM(RTRIM(Panelname)),   '(No Panel)')    AS PanelName,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')               AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(DenialCode)),  '')               AS DenialCode,
        COUNT(DISTINCT
            CASE WHEN ClaimID LIKE '%.00'
                 THEN LEFT(ClaimID, LEN(ClaimID) - 3)
                 ELSE ClaimID END)                          AS ClaimCount,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0) AS TotalPayments,
        ISNULL(SUM(ISNULL(TRY_CAST(ChargeAmount  AS DECIMAL(18,2)), 0)), 0) AS TotalCharges
    FROM Augustus_LRN.dbo.ClaimLevelData
    WHERE CPTCodeXUnitsXModifier LIKE '%' + @CPTCode + '%'
    GROUP BY
        ISNULL(LTRIM(RTRIM(Panelname)),   '(No Panel)'),
        ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
        ISNULL(LTRIM(RTRIM(DenialCode)),  '')
    ORDER BY ClaimCount DESC;


    -- ===========================================================================
    -- RS 5 : Payer Breakdown  (top 20 by payments)
    -- ===========================================================================
    SELECT TOP 20
        ISNULL(LTRIM(RTRIM(PayerName)), '(Unknown)')        AS PayerName,
        ISNULL(LTRIM(RTRIM(PayerType)), '')                 AS PayerType,
        COUNT(*)                                            AS LineCount,
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)          AS TotalUnits,
        ISNULL(SUM(CASE WHEN DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1) ELSE 0 END), 0) AS DeniedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0)  AS TotalPayments
    FROM Augustus_LRN.dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
    GROUP BY
        ISNULL(LTRIM(RTRIM(PayerName)), '(Unknown)'),
        ISNULL(LTRIM(RTRIM(PayerType)), '')
    ORDER BY TotalPayments DESC;

END
GO

-- ── Quick verify ────────────────────────────────────────────────────────────
-- EXEC dbo.usp_CPTCodeSearch_Augustus_LRN @CPTCode = '87798'
