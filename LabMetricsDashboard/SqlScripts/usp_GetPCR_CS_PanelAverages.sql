-- ============================================================
-- usp_GetPCR_CS_PanelAverages
-- Pattern: mirrors usp_GetPhi_CS_PanelAverages
--
-- • No filters   → returns snapshot from dbo.PCR_CS_PanelAverages (fast)
-- • Any filter   → queries live dbo.ClaimLevelData   (accurate)
--
-- Multi-value payer/panel filters use pipe '|' delimiter
-- e.g. @PayerNames = 'BCBS|Medicare|Aetna'
--
-- PCR-specific column names kept as-is (matching the table):
--   AdjucticatedCount / AdjucticatedAmount  (note spelling)
--   FullyPaidCount flag value = 'Fully Paid Count'
--   Adjudicated flag = any non-empty AdjucticatedCount value
-- ============================================================

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE [dbo].[usp_GetPCR_CS_PanelAverages]
    @PayerNames     NVARCHAR(MAX) = NULL,   -- pipe-delimited e.g. 'BCBS|Medicare'
    @PanelNames     NVARCHAR(MAX) = NULL,   -- pipe-delimited e.g. 'MOLECULAR,Pathology|Blood'
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Detect whether any filter is active ──────────────────────────────────
    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    -- ── No filter → serve snapshot (instant) ─────────────────────────────────
    IF @HasFilter = 0
    BEGIN
        SELECT
            PanelName,
            PayerName,
            NoOfClaims,
            TotalCharges,
            CarrierPayment,
            AvgCarrierPayment,
            FullyPaidCount,
            FullyPaidAmount,
            AvgFullyPaid,
            AdjucticatedCount   AS AdjudicatedCount,
            AdjucticatedAmount  AS AdjudicatedAmount,
            AvgAdjudicated,
            Days30Count,
            Days30Amount,
            AvgDays30,
            Days60Count,
            Days60Amount,
            AvgDays60,
            RefreshedAt
        FROM  dbo.PCR_CS_PanelAverages
        ORDER BY PanelName, PayerName;
        RETURN;
    END;

    -- ── Parse pipe-delimited filter lists ────────────────────────────────────
    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM   STRING_SPLIT(@PayerNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM   STRING_SPLIT(@PanelNames, '|')
        WHERE  NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    -- When no CheckDate filter supplied, use same 6-month rolling window as Refresh SP
    DECLARE @CheckFrom DATE = ISNULL(@CheckDateFrom, DATEADD(MONTH, -6, CAST(GETDATE() AS DATE)));
    DECLARE @CheckTo   DATE = ISNULL(@CheckDateTo,   CAST(GETDATE() AS DATE));

    -- ── Live query from ClaimLevelData ────────────────────────────────────────
    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,       'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw,   'Unknown')))  AS PayerName,
            COALESCE(
                NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
                LTRIM(RTRIM(ClaimID))
            )                                                  AS VisitKey,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))       AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))       AS InsPay,
            LTRIM(RTRIM(ISNULL(FullyPaidCount,      '')))     AS FPC,
            TRY_CAST(FullyPaidAmount  AS DECIMAL(18,2))       AS FullyPaidAmt,
            -- PCR uses AdjucticatedCount (note spelling)
            LTRIM(RTRIM(ISNULL(AdjucticatedCount,   '')))     AS AdjC,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))     AS AdjAmt,
            LTRIM(RTRIM(ISNULL(AgingBucket,          '')))    AS Bucket
        FROM dbo.ClaimLevelData
        WHERE Panelname IS NOT NULL
          AND LEN(LTRIM(RTRIM(Panelname))) > 0
          AND NOT (
                LTRIM(RTRIM(ClaimStatus))    = 'No Response'
            AND LTRIM(RTRIM(BilledUnbilled)) = 'Unbilled'
          )
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @CheckFrom AND @CheckTo
          -- Payer filter
          AND (@HasPayerFilter = 0
               OR LTRIM(RTRIM(ISNULL(PayerName_Raw, ''))) IN (SELECT Value FROM @PayerList))
          -- Panel filter
          AND (@HasPanelFilter = 0
               OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          -- DOS range
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          -- First billed range
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    agg AS (
        SELECT
            PanelName,
            PayerName,
            COUNT(DISTINCT VisitKey)                                                       AS NoOfClaims,
            ISNULL(SUM(Chg),    0)                                                         AS TotalCharges,
            ISNULL(SUM(InsPay), 0)                                                         AS CarrierPayment,

            -- Fully Paid  (PCR flag value = 'Fully Paid Count')
            COUNT(DISTINCT CASE WHEN FPC  = 'Fully Paid Count' THEN VisitKey END)          AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FPC  = 'Fully Paid Count'
                            THEN FullyPaidAmt ELSE 0 END), 0)                              AS FullyPaidAmount,

            -- Adjudicated (PCR: any non-empty AdjucticatedCount value)
            COUNT(DISTINCT CASE WHEN AdjC IS NOT NULL
                                 AND AdjC <> ''         THEN VisitKey END)                 AS AdjucticatedCount,
            ISNULL(SUM(CASE WHEN AdjC IS NOT NULL
                             AND AdjC <> ''
                            THEN AdjAmt ELSE 0 END), 0)                                    AS AdjucticatedAmount,

            -- Aging 30+
            COUNT(DISTINCT CASE WHEN Bucket IN ('30+','60+','90+','120+')
                                THEN VisitKey END)                                         AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket IN ('30+','60+','90+','120+')
                            THEN InsPay ELSE 0 END), 0)                                    AS Days30Amount,

            -- Aging 60+
            COUNT(DISTINCT CASE WHEN Bucket IN ('60+','90+','120+')
                                THEN VisitKey END)                                         AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket IN ('60+','90+','120+')
                            THEN InsPay ELSE 0 END), 0)                                    AS Days60Amount
        FROM src
        GROUP BY PanelName, PayerName
    )
    SELECT
        PanelName,
        PayerName,
        NoOfClaims,
        TotalCharges,
        CarrierPayment,
        CAST(CASE WHEN NoOfClaims        > 0 THEN CarrierPayment    / NoOfClaims        ELSE 0 END AS DECIMAL(18,2)) AS AvgCarrierPayment,
        FullyPaidCount,
        FullyPaidAmount,
        CAST(CASE WHEN FullyPaidCount    > 0 THEN FullyPaidAmount   / FullyPaidCount    ELSE 0 END AS DECIMAL(18,2)) AS AvgFullyPaid,
        AdjucticatedCount   AS AdjudicatedCount,
        AdjucticatedAmount  AS AdjudicatedAmount,
        CAST(CASE WHEN AdjucticatedCount > 0 THEN AdjucticatedAmount / AdjucticatedCount ELSE 0 END AS DECIMAL(18,2)) AS AvgAdjudicated,
        Days30Count,
        Days30Amount,
        CAST(CASE WHEN Days30Count       > 0 THEN Days30Amount      / Days30Count       ELSE 0 END AS DECIMAL(18,2)) AS AvgDays30,
        Days60Count,
        Days60Amount,
        CAST(CASE WHEN Days60Count       > 0 THEN Days60Amount      / Days60Count       ELSE 0 END AS DECIMAL(18,2)) AS AvgDays60
    FROM agg
    ORDER BY PanelName, PayerName;

END;
GO

-- ── Quick tests ─────────────────────────────────────────────────────────────
-- No filter  → snapshot
-- EXEC dbo.usp_GetPCR_CS_PanelAverages
--
-- Filter by payer
-- EXEC dbo.usp_GetPCR_CS_PanelAverages @PayerNames = 'BCBS|Medicare'
--
-- Filter by panel
-- EXEC dbo.usp_GetPCR_CS_PanelAverages @PanelNames = 'MOLECULAR,Pathology|Blood'
--
-- Filter by DOS range
-- EXEC dbo.usp_GetPCR_CS_PanelAverages @DosFrom = '2025-01-01', @DosTo = '2025-12-31'
--
-- Combined
-- EXEC dbo.usp_GetPCR_CS_PanelAverages
--      @PanelNames = 'MOLECULAR,Pathology',
--      @CheckDateFrom = '2025-06-01', @CheckDateTo = '2025-12-31'
