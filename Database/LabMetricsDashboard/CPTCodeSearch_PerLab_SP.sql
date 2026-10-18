-- ============================================================
-- CPT Code Search  –  Per-Lab Stored Procedure
--
-- Deploy this SP to EACH lab database individually:
--   Augustus_LRN, Beech_Tree, Certus_LRN, CoveLRN,
--   Elixir_LRN, InHealthDTRLRN, NWL, PCRLOA,
--   Phi_Life, Rising_Tides
--
-- Column names confirmed from FieldMappings.json + live data:
--   LineLevelData  : CPTCode, Units, Modifier, Panelname,
--                    DenialCode, ClaimStatus, PayerName, PayerType,
--                    DateofService, TotalPayments, ChargeAmount
--   ClaimLevelData : CPTCodeXUnitsXModifier, ClaimID, Panelname,
--                    ClaimStatus, DenialCode, TotalPayments, ChargeAmount
--
-- Usage (run in Augustus_LRN context first):
--   USE Augustus_LRN
--   EXEC dbo.usp_CPTCodeSearch @CPTCode = '87798'
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_CPTCodeSearch
    @CPTCode NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET @CPTCode = LTRIM(RTRIM(@CPTCode));

    -- ── RS 1 : Line Level  –  Panel / Payer summary ───────────────────────────
    -- Groups by Panel + ClaimStatus + DenialCode + Payer so the UI can show
    -- exactly what purpose and for which payer the CPT was claimed / denied.
    SELECT
        ISNULL(LTRIM(RTRIM(Panelname)),    '(No Panel)')  AS PanelName,
        ISNULL(LTRIM(RTRIM(ClaimStatus)),  '')             AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(DenialCode)),   '')             AS DenialCode,
        ISNULL(LTRIM(RTRIM(PayerName)),    '(Unknown)')    AS PayerName,
        ISNULL(LTRIM(RTRIM(PayerType)),    '')             AS PayerType,
        COUNT(*)                                           AS LineCount,
        -- Units: default to 1 when NULL
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)         AS TotalUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0) AS TotalPayments,
        ISNULL(SUM(ISNULL(TRY_CAST(ChargeAmount  AS DECIMAL(18,2)), 0)), 0) AS TotalCharges,
        -- Denied = has a denial code OR status contains Denied / Rejected / Adjusted
        ISNULL(SUM(CASE
            WHEN (DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> '')
              OR UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) LIKE '%DENIED%'
              OR UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) LIKE '%REJECTED%'
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)
            ELSE 0 END), 0)                                AS DeniedUnits,
        -- Claimed = no denial code AND status is not Denied/Rejected
        ISNULL(SUM(CASE
            WHEN (DenialCode IS NULL OR LTRIM(RTRIM(DenialCode)) = '')
             AND UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) NOT LIKE '%DENIED%'
             AND UPPER(LTRIM(RTRIM(ISNULL(ClaimStatus, '')))) NOT LIKE '%REJECTED%'
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)
            ELSE 0 END), 0)                                AS ClaimedUnits,
        ISNULL(MIN(CASE WHEN ISNULL(DateofService, '') <> '' THEN DateofService END), '') AS EarliestDOS,
        ISNULL(MAX(ISNULL(DateofService, '')), '')          AS LatestDOS
    FROM dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,   ''))),
        LTRIM(RTRIM(ISNULL(ClaimStatus, ''))),
        LTRIM(RTRIM(ISNULL(DenialCode,  ''))),
        LTRIM(RTRIM(ISNULL(PayerName,   ''))),
        LTRIM(RTRIM(ISNULL(PayerType,   '')))
    ORDER BY TotalPayments DESC;


    -- ── RS 2 : Denial Code Breakdown ──────────────────────────────────────────
    SELECT
        LTRIM(RTRIM(DenialCode))                           AS DenialCode,
        COUNT(*)                                           AS LineCount,
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)         AS DeniedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0) AS Payments
    FROM dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
      AND DenialCode IS NOT NULL
      AND LTRIM(RTRIM(DenialCode)) <> ''
    GROUP BY LTRIM(RTRIM(DenialCode))
    ORDER BY LineCount DESC;


    -- ── RS 3 : Monthly Trend (DOS-based) ──────────────────────────────────────
    SELECT
        ISNULL(FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM'), 'Unknown') AS MonthYear,
        COUNT(*)                                           AS LineCount,
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)          AS TotalUnits,
        ISNULL(SUM(CASE
            WHEN DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1) ELSE 0 END), 0) AS DeniedUnits,
        ISNULL(SUM(CASE
            WHEN DenialCode IS NULL OR LTRIM(RTRIM(DenialCode)) = ''
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1) ELSE 0 END), 0) AS ClaimedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0)  AS TotalPayments
    FROM dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
    GROUP BY ISNULL(FORMAT(TRY_CAST(DateofService AS DATE), 'yyyy-MM'), 'Unknown')
    ORDER BY MonthYear;


    -- ── RS 4 : Claim Level Summary ────────────────────────────────────────────
    -- CPTCodeXUnitsXModifier is a combined multi-CPT string, e.g.
    --   "87491,87496,...,87798"  →  LIKE search to find claims that include CPT
    SELECT
        ISNULL(LTRIM(RTRIM(Panelname)),   '(No Panel)')   AS PanelName,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')              AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(DenialCode)),  '')              AS DenialCode,
        COUNT(DISTINCT
            CASE WHEN ClaimID LIKE '%.00'
                 THEN LEFT(ClaimID, LEN(ClaimID) - 3)
                 ELSE ClaimID END)                         AS ClaimCount,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0) AS TotalPayments,
        ISNULL(SUM(ISNULL(TRY_CAST(ChargeAmount  AS DECIMAL(18,2)), 0)), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE CPTCodeXUnitsXModifier LIKE '%' + @CPTCode + '%'
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname,   ''))),
        LTRIM(RTRIM(ISNULL(ClaimStatus, ''))),
        LTRIM(RTRIM(ISNULL(DenialCode,  '')))
    ORDER BY ClaimCount DESC;


    -- ── RS 5 : Top Payer Breakdown ────────────────────────────────────────────
    SELECT TOP 20
        ISNULL(LTRIM(RTRIM(PayerName)), '(Unknown)')       AS PayerName,
        ISNULL(LTRIM(RTRIM(PayerType)), '')                AS PayerType,
        COUNT(*)                                           AS LineCount,
        ISNULL(SUM(ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1)), 0)          AS TotalUnits,
        ISNULL(SUM(CASE
            WHEN DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''
            THEN ISNULL(TRY_CAST(Units AS DECIMAL(18,2)), 1) ELSE 0 END), 0) AS DeniedUnits,
        ISNULL(SUM(ISNULL(TRY_CAST(TotalPayments AS DECIMAL(18,2)), 0)), 0)  AS TotalPayments
    FROM dbo.LineLevelData
    WHERE LTRIM(RTRIM(ISNULL(CPTCode, ''))) = @CPTCode
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName, ''))),
        LTRIM(RTRIM(ISNULL(PayerType, '')))
    ORDER BY TotalPayments DESC;

END
GO

-- ── Quick verify after deploy ──────────────────────────────────────────────
-- EXEC dbo.usp_CPTCodeSearch @CPTCode = '87798'
