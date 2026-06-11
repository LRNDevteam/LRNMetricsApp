-- ============================================================
-- usp_RefreshPCR_CS_PanelAverages  –  Updated with AvgAdjudicated
-- Changes from original:
--   • AvgAdjudicated added to INSERT column list and SELECT
--   • Placed after AdjucticatedAmount (logical ordering)
-- ============================================================

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE [dbo].[usp_RefreshPCR_CS_PanelAverages]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxCheckDate   DATE;
    DECLARE @StartCheckDate DATE;
    DECLARE @EndCheckDate   DATE;

    -- Determine rolling 180-day window based on latest valid CheckDate
    SELECT @MaxCheckDate = MAX(TRY_CAST(CheckDate AS DATE))
    FROM   dbo.ClaimLevelData
    WHERE  TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND  TRY_CAST(CheckDate AS DATE) <= CAST(GETDATE() AS DATE);

    IF @MaxCheckDate IS NULL
    BEGIN
        RAISERROR('No valid CheckDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;

    SET @StartCheckDate = DATEADD(DAY, -180, @MaxCheckDate);
    SET @EndCheckDate   = @MaxCheckDate;

    -- ── Source CTE ───────────────────────────────────────────────────────────
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,       'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,   'Unknown'))) AS PayerName,
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                LTRIM(RTRIM(ClaimID))
            )                                                AS VisitKey,
            TRY_CAST(ChargeAmount      AS DECIMAL(18,2))    AS Chg,
            TRY_CAST(InsurancePayment  AS DECIMAL(18,2))    AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                        AS ClaimStatus,
            LTRIM(RTRIM(BilledUnbilled))                     AS BilledUnbilled,
            LTRIM(RTRIM(AgingBucket))                        AS Bucket,
            LTRIM(RTRIM(FullyPaidCount))                     AS FullyPaidCountFlag,
            TRY_CAST(FullyPaidAmount   AS DECIMAL(18,2))    AS FullyPaidAmountValue,
            LTRIM(RTRIM(AdjucticatedCount))                  AS AdjucticatedCountFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))   AS AdjucticatedAmountValue
        FROM dbo.ClaimLevelData
        WHERE Panelname IS NOT NULL
          AND LTRIM(RTRIM(Panelname)) <> ''
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @StartCheckDate AND @EndCheckDate
          AND NOT (
                LTRIM(RTRIM(ClaimStatus))   = 'No Response'
            AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled'
          )
    ),

    -- ── Aggregation ──────────────────────────────────────────────────────────
    agg AS (
        SELECT
            PanelName,
            PayerName,
            COUNT(DISTINCT VisitKey)                            AS NoOfClaims,
            ISNULL(SUM(Chg),    0)                              AS TotalCharges,
            ISNULL(SUM(InsPay), 0)                              AS CarrierPayment,

            -- Fully Paid
            COUNT(CASE WHEN FullyPaidCountFlag = 'Fully Paid Count'
                       THEN VisitKey END)                       AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidCountFlag = 'Fully Paid Count'
                            THEN FullyPaidAmountValue ELSE 0
                       END), 0)                                 AS FullyPaidAmount,

            -- Adjudicated
            COUNT(CASE WHEN AdjucticatedCountFlag IS NOT NULL
                        AND AdjucticatedCountFlag <> ''
                       THEN VisitKey END)                       AS AdjucticatedCount,
            ISNULL(SUM(CASE WHEN AdjucticatedCountFlag IS NOT NULL
                             AND AdjucticatedCountFlag <> ''
                            THEN AdjucticatedAmountValue ELSE 0
                       END), 0)                                 AS AdjucticatedAmount,

            -- Aging 30+
            COUNT(CASE WHEN Bucket IN ('30+','60+','90+','120+')
                       THEN VisitKey END)                       AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket IN ('30+','60+','90+','120+')
                            THEN InsPay ELSE 0
                       END), 0)                                 AS Days30Amount,

            -- Aging 60+
            COUNT(CASE WHEN Bucket IN ('60+','90+','120+')
                       THEN VisitKey END)                       AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket IN ('60+','90+','120+')
                            THEN InsPay ELSE 0
                       END), 0)                                 AS Days60Amount
        FROM src
        GROUP BY PanelName, PayerName
    )

    -- ── Write to snapshot table ───────────────────────────────────────────────
    SELECT *
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.PCR_CS_PanelAverages;

    INSERT INTO dbo.PCR_CS_PanelAverages
    (
        PanelName,
        PayerName,
        NoOfClaims,
        TotalCharges,
        CarrierPayment,
        AvgCarrierPayment,
        FullyPaidCount,
        FullyPaidAmount,
        AvgFullyPaid,
        AdjucticatedCount,
        AdjucticatedAmount,
        AvgAdjudicated,          -- ← NEW
        Days30Count,
        Days30Amount,
        AvgDays30,
        Days60Count,
        Days60Amount,
        AvgDays60,
        RefreshedAt
    )
    SELECT
        PanelName,
        PayerName,
        NoOfClaims,
        TotalCharges,
        CarrierPayment,
        CASE WHEN NoOfClaims       > 0 THEN CarrierPayment   / NoOfClaims       ELSE 0 END AS AvgCarrierPayment,
        FullyPaidCount,
        FullyPaidAmount,
        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount  / FullyPaidCount   ELSE 0 END AS AvgFullyPaid,
        AdjucticatedCount,
        AdjucticatedAmount,
        CASE WHEN AdjucticatedCount > 0 THEN AdjucticatedAmount / AdjucticatedCount ELSE 0 END AS AvgAdjudicated,  -- ← NEW
        Days30Count,
        Days30Amount,
        CASE WHEN Days30Count      > 0 THEN Days30Amount     / Days30Count      ELSE 0 END AS AvgDays30,
        Days60Count,
        Days60Amount,
        CASE WHEN Days60Count      > 0 THEN Days60Amount     / Days60Count      ELSE 0 END AS AvgDays60,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;

    PRINT 'usp_RefreshPCR_CS_PanelAverages completed.';
    PRINT 'StartCheckDate : ' + CONVERT(VARCHAR(10), @StartCheckDate, 120);
    PRINT 'EndCheckDate   : ' + CONVERT(VARCHAR(10), @EndCheckDate,   120);
END;
GO
