-- =====================================================================
-- VariantX: aggregate / read SP fixes from the VariantX file mapping
-- Database: VariantX_LRN
-- Date: 2026-09-30
--
-- Mapping facts used (VariantX ClaimLevelData / LineLevelData / LIMS files):
--   ClaimLevelData.ClaimStatus   = Fully Paid / Partially Paid / Denied ...  (claim status)
--   LineLevelData.ClaimStatus    = file "Current Status" (CLOSED / DENIED ...), not the paid status
--   ClaimLevelData.PlanType      = payer type (there is no PayerType column)
--   ClaimLevelData Fully Paid / Adjucticated / 30+ / 60+ flag columns hold a non-blank marker
--   LIMSMaster.SampleStatus      = sample status (Billable / System Test), no NewStatus column
--   LIMSMaster.TestType          = panel, PrimaryInsurance = payer, PhysicianName = provider
--
-- CS 1  usp_RefreshVarX_CS_CptVsPaymentPct   paid filter from claim-level ClaimStatus
-- CS 1b usp_GetVarX_CS_CptVsPaymentPct       filtered path = refresh rules
-- CS 2  usp_RefreshVarX_CS_PanelAverages     30+/60+/Adjudicated counts from non-blank flags
-- CS 2b usp_GetVarX_CS_PanelAverages         returns Adjudicated columns; filtered = refresh rules
-- CS 3  usp_GetVarX_CS_MonthlyClaimVolume    filtered path from ClaimLevelData (same as refresh)
-- CS 4  usp_GetVarX_CS_WeeklyClaimVolume     filtered path uses the same Wed-Tue CheckDate weeks
-- ES 1  usp_RefreshVarX_ExecutiveSummary     LIMS status column 'SampleStatus'
-- ES 2  usp_RefreshVarX_ExecutiveSummary_LIS_Alt  'SampleStatus' + panel 'TestType'
-- ES 3  usp_GetVarX_ExecutiveSummary         'SampleStatus' + panel 'TestType'
-- ES 4  usp_GetVarX_ExecutiveSummary_Detail  Payer Type from 'PlanType'
-- ES 5  usp_GetExecutiveSummaryDetail_LIS    'SampleStatus' + 'TestType' / 'PrimaryInsurance' / 'PhysicianName'
--
-- Only procedures change (CREATE OR ALTER); no tables or data are touched.
-- Run 99_VariantX_ExecuteAllAggregates.sql afterwards to rebuild the VarX_ tables.
-- =====================================================================
SET NOCOUNT ON;
GO

/* -----------------------------------------------------------------------------
   CS 1. CPT vs Payment %  (refresh)
   LineLevelData.ClaimStatus holds the "Current Status" file column for VariantX
   (CLOSED / DENIED / ...), so the paid filter reads the claim-level ClaimStatus
   (Fully Paid / Partially Paid) through ClaimID.
   SumUnits = SUM(Units), all lines (same rule as the shared C# CPT vs Payment %).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_CptVsPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

    ;WITH ClaimStat AS
    (
        SELECT LTRIM(RTRIM(ClaimID)) AS ClaimID, MAX(LTRIM(RTRIM(ClaimStatus))) AS ClaimStatus
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ClaimID))
    ),
    agg AS
    (
        SELECT
            LTRIM(RTRIM(l.CPTCode))                                             AS CPTCode,
            ISNULL(SUM(TRY_CAST(l.Units AS DECIMAL(18,2))), 0)                  AS SumUnits,
            ISNULL(SUM(CASE WHEN c.ClaimStatus IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(l.InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidIns,
            ISNULL(SUM(CASE WHEN c.ClaimStatus IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(l.ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChg
        FROM dbo.LineLevelData l
        LEFT JOIN ClaimStat c ON c.ClaimID = LTRIM(RTRIM(l.ClaimID))
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), '') IS NOT NULL
        GROUP BY LTRIM(RTRIM(l.CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidIns, PaidChg,
           CAST(CASE WHEN PaidChg <> 0 THEN PaidIns * 100.0 / PaidChg ELSE 0 END AS DECIMAL(10,2)) AS PaymentPct
    INTO #out
    FROM agg;

    TRUNCATE TABLE dbo.VarX_CS_CptVsPaymentPct;

    INSERT INTO dbo.VarX_CS_CptVsPaymentPct
        (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)
    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()
    FROM #out
    ORDER BY SumUnits DESC;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshVarX_CS_CptVsPaymentPct completed.';
END
GO

/* -----------------------------------------------------------------------------
   CS 1b. CPT vs Payment %  (read) - filtered path uses the same rules as the refresh.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CS_CptVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct
        FROM   dbo.VarX_CS_CptVsPaymentPct
        ORDER  BY SumUnits DESC;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH ClaimStat AS
    (
        SELECT LTRIM(RTRIM(ClaimID)) AS ClaimID, MAX(LTRIM(RTRIM(ClaimStatus))) AS ClaimStatus
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ClaimID))
    ),
    agg AS
    (
        SELECT
            LTRIM(RTRIM(l.CPTCode))                                             AS CPTCode,
            ISNULL(SUM(TRY_CAST(l.Units AS DECIMAL(18,2))), 0)                  AS SumUnits,
            ISNULL(SUM(CASE WHEN c.ClaimStatus IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(l.InsurancePayment AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidInsurancePayment,
            ISNULL(SUM(CASE WHEN c.ClaimStatus IN ('Fully Paid','Partially Paid')
                            THEN TRY_CAST(l.ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END), 0) AS PaidChargeAmount
        FROM dbo.LineLevelData l
        LEFT JOIN ClaimStat c ON c.ClaimID = LTRIM(RTRIM(l.ClaimID))
        WHERE NULLIF(LTRIM(RTRIM(l.CPTCode)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(l.PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(l.Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(l.DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(l.DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(l.FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(l.FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(l.CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(l.CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(l.CPTCode))
    )
    SELECT CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount,
           CAST(CASE WHEN PaidChargeAmount <> 0 THEN PaidInsurancePayment * 100.0 / PaidChargeAmount ELSE 0 END AS DECIMAL(10,2)) AS PaymentPct
    FROM agg
    ORDER BY SumUnits DESC;
END
GO

/* -----------------------------------------------------------------------------
   CS 2. Panel Averages (refresh)
   VariantX file flags: FullyPaidCount = 'Fully Paid', AdjucticatedCount = 'Adjucticated',
   Bucket30Count = '30+', Bucket60Count = '60+' (Elixir used '30 Bucket' / '60 Bucket',
   so the 30 / 60 columns were always 0). A flag is any non-blank value.
   Window unchanged: DateofService in the 6 calendar months up to the latest DOS.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_CS_PanelAverages
AS
BEGIN
    SET NOCOUNT ON;
    DROP TABLE IF EXISTS #out;

    DECLARE @MaxDos DATE =
    (
        SELECT MAX(TRY_CAST(DateofService AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) <= CAST(GETDATE() AS DATE)
    );
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, EOMONTH(@MaxDos, -6));

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelName,     'Unknown')))                                  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                                  AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID)))      AS VisitKey,
            TRY_CAST(ChargeAmount       AS DECIMAL(18,2))                                   AS Chg,
            TRY_CAST(InsurancePayment   AS DECIMAL(18,2))                                   AS InsPay,
            CASE WHEN NULLIF(LTRIM(RTRIM(FullyPaidCount)),    '') IS NOT NULL THEN 1 ELSE 0 END AS IsFullyPaid,
            TRY_CAST(FullyPaidAmount    AS DECIMAL(18,2))                                   AS FullyPaidAmount,
            CASE WHEN NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '') IS NOT NULL THEN 1 ELSE 0 END AS IsAdjudicated,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))                                   AS AdjudicatedAmount,
            CASE WHEN NULLIF(LTRIM(RTRIM(Bucket30Count)),     '') IS NOT NULL THEN 1 ELSE 0 END AS Is30,
            TRY_CAST(Bucket30Amount     AS DECIMAL(18,2))                                   AS Bucket30Amount,
            CASE WHEN NULLIF(LTRIM(RTRIM(Bucket60Count)),     '') IS NOT NULL THEN 1 ELSE 0 END AS Is60,
            TRY_CAST(Bucket60Amount     AS DECIMAL(18,2))                                   AS Bucket60Amount
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateofService AS DATE) <= CAST(GETDATE() AS DATE)
    )
    SELECT
        PanelName,
        PayerName,
        COUNT(VisitKey)                                                          AS ClaimCount,
        ISNULL(SUM(Chg), 0)                                                      AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                                   AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN IsFullyPaid   = 1 THEN VisitKey END)            AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN IsFullyPaid   = 1 THEN FullyPaidAmount   END), 0)   AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN IsAdjudicated = 1 THEN VisitKey END)            AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN IsAdjudicated = 1 THEN AdjudicatedAmount END), 0)   AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Is30 = 1 THEN VisitKey END)                     AS Days30Count,
        ISNULL(SUM(CASE WHEN Is30 = 1 THEN Bucket30Amount END), 0)               AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Is60 = 1 THEN VisitKey END)                     AS Days60Count,
        ISNULL(SUM(CASE WHEN Is60 = 1 THEN Bucket60Amount END), 0)               AS Days60Amount
    INTO #out
    FROM src
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.VarX_CS_PanelAverages;

    INSERT INTO dbo.VarX_CS_PanelAverages
        (PanelName, PayerName,
         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount,   FullyPaidAmount,   AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count,      Days30Amount,      AvgDays30,
         Days60Count,      Days60Amount,      AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName,
        ClaimCount, TotalCharges, CarrierPayment,
        CASE WHEN ClaimCount       > 0 THEN CarrierPayment    / ClaimCount       ELSE 0 END,
        FullyPaidCount,   FullyPaidAmount,
        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count,      Days30Amount,
        CASE WHEN Days30Count      > 0 THEN Days30Amount      / Days30Count      ELSE 0 END,
        Days60Count,      Days60Amount,
        CASE WHEN Days60Count      > 0 THEN Days60Amount      / Days60Count      ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerName;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshVarX_CS_PanelAverages completed.';
END
GO

/* -----------------------------------------------------------------------------
   CS 2b. Panel Averages (read)
   No filter: snapshot, now including the Adjudicated columns the refresh stores.
   Filter: the refresh rules above plus the UI filters.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CS_PanelAverages
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName,
                NoOfClaims,
                TotalCharges,
                CarrierPayment,
                FullyPaidCount,   FullyPaidAmount,
                ISNULL(AdjudicatedCount, 0)                    AS AdjudicatedCount,
                ISNULL(AdjudicatedAmount, CAST(0 AS DECIMAL(18,2))) AS AdjudicatedAmount,
                Days30Count,      Days30Amount,
                Days60Count,      Days60Amount
        FROM    dbo.VarX_CS_PanelAverages
        ORDER BY PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @MaxDos DATE =
    (
        SELECT MAX(TRY_CAST(DateofService AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) <= CAST(GETDATE() AS DATE)
    );
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, EOMONTH(@MaxDos, -6));

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelName,     'Unknown')))                                  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                                  AS PayerName,
            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)), ''), LTRIM(RTRIM(ClaimID)))      AS VisitKey,
            TRY_CAST(ChargeAmount       AS DECIMAL(18,2))                                   AS Chg,
            TRY_CAST(InsurancePayment   AS DECIMAL(18,2))                                   AS InsPay,
            CASE WHEN NULLIF(LTRIM(RTRIM(FullyPaidCount)),    '') IS NOT NULL THEN 1 ELSE 0 END AS IsFullyPaid,
            TRY_CAST(FullyPaidAmount    AS DECIMAL(18,2))                                   AS FullyPaidAmount,
            CASE WHEN NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '') IS NOT NULL THEN 1 ELSE 0 END AS IsAdjudicated,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))                                   AS AdjudicatedAmount,
            CASE WHEN NULLIF(LTRIM(RTRIM(Bucket30Count)),     '') IS NOT NULL THEN 1 ELSE 0 END AS Is30,
            TRY_CAST(Bucket30Amount     AS DECIMAL(18,2))                                   AS Bucket30Amount,
            CASE WHEN NULLIF(LTRIM(RTRIM(Bucket60Count)),     '') IS NOT NULL THEN 1 ELSE 0 END AS Is60,
            TRY_CAST(Bucket60Amount     AS DECIMAL(18,2))                                   AS Bucket60Amount
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(DateofService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateofService AS DATE) <= CAST(GETDATE() AS DATE)
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PanelName, PayerName,
        COUNT(VisitKey)                                                          AS NoOfClaims,
        ISNULL(SUM(Chg), 0)                                                      AS TotalCharges,
        ISNULL(SUM(InsPay), 0)                                                   AS CarrierPayment,
        COUNT(DISTINCT CASE WHEN IsFullyPaid   = 1 THEN VisitKey END)            AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN IsFullyPaid   = 1 THEN FullyPaidAmount   END), 0)   AS FullyPaidAmount,
        COUNT(DISTINCT CASE WHEN IsAdjudicated = 1 THEN VisitKey END)            AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN IsAdjudicated = 1 THEN AdjudicatedAmount END), 0)   AS AdjudicatedAmount,
        COUNT(DISTINCT CASE WHEN Is30 = 1 THEN VisitKey END)                     AS Days30Count,
        ISNULL(SUM(CASE WHEN Is30 = 1 THEN Bucket30Amount END), 0)               AS Days30Amount,
        COUNT(DISTINCT CASE WHEN Is60 = 1 THEN VisitKey END)                     AS Days60Count,
        ISNULL(SUM(CASE WHEN Is60 = 1 THEN Bucket60Amount END), 0)               AS Days60Amount
    FROM src
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, PayerName;
END
GO

/* -----------------------------------------------------------------------------
   CS 3. Monthly Claim Volume (read)
   Filtered path now reads ClaimLevelData like the refresh (it read LineLevelData,
   whose Panelname can be 'PANEL NOT LISTED', so filtered totals did not match).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CS_MonthlyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName,
                PayerName,
                PayerRank,
                BillYear,
                BillMonth,
                NoOfClaims,
                InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.VarX_CS_MonthlyClaimVolume
        ORDER BY PanelName, PayerRank, BillYear, BillMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH Agg AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (TRY_CAST(CheckDate AS DATE))             AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))             AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST(CheckDate AS DATE)),
            MONTH(TRY_CAST(CheckDate AS DATE))
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS INT) AS PayerRank,
            a.BillYear,
            CAST(a.BillMonth AS TINYINT) AS BillMonth,
            a.NoOfClaims,
            a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.BillYear, a.BillMonth;
END
GO

/* -----------------------------------------------------------------------------
   CS 4. Weekly Claim Volume (read)
   Filtered path now uses ClaimLevelData and the same 4 completed Wed-Tue CheckDate
   weeks as usp_RefreshVarX_CS_WeeklyClaimVolume (it used LineLevelData and
   Sunday-ending weeks, so filtered weeks differed from the unfiltered view).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_CS_WeeklyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName,
                PayerName,
                PayerRank,
                WeekKey,
                WeekStart,
                WeekEnd,
                NoOfClaims,
                InsurancePayment,
                CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
        FROM    dbo.VarX_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @Today DATE = CAST(GETDATE() AS DATE);
    DECLARE @MaxCheckDate DATE =
    (
        SELECT MAX(TRY_CAST(CheckDate AS DATE))
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) <= @Today
    );

    IF @MaxCheckDate IS NULL
    BEGIN
        SELECT  CAST(NULL AS NVARCHAR(500)) AS PanelName,
                CAST(NULL AS NVARCHAR(500)) AS PayerName,
                CAST(NULL AS INT)           AS PayerRank,
                CAST(NULL AS TINYINT)       AS WeekKey,
                CAST(NULL AS DATE)          AS WeekStart,
                CAST(NULL AS DATE)          AS WeekEnd,
                CAST(NULL AS INT)           AS NoOfClaims,
                CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
                CAST(NULL AS DECIMAL(18,2)) AS AveragePaidAmount
        WHERE 1 = 0;
        RETURN;
    END;

    -- Wed-Tue weeks (1900-01-03 is a Wednesday); latest completed week = Week 4.
    DECLARE @WeekStart DATE = DATEADD(DAY, -(DATEDIFF(DAY, '19000103', @MaxCheckDate) % 7), @MaxCheckDate);
    IF DATEADD(DAY, 6, @WeekStart) > @Today
        SET @WeekStart = DATEADD(DAY, -7, @WeekStart);

    DECLARE @W4Start DATE = @WeekStart,                  @W4End DATE = DATEADD(DAY,   6, @WeekStart);
    DECLARE @W3Start DATE = DATEADD(DAY,  -7, @W4Start), @W3End DATE = DATEADD(DAY,  -1, @W4Start);
    DECLARE @W2Start DATE = DATEADD(DAY, -14, @W4Start), @W2End DATE = DATEADD(DAY,  -8, @W4Start);
    DECLARE @W1Start DATE = DATEADD(DAY, -21, @W4Start), @W1End DATE = DATEADD(DAY, -15, @W4Start);

    ;WITH Src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelName,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    Agg AS (
        SELECT PanelName, PayerName, WeekKey,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(InsurancePayment), 0) AS InsurancePayment
        FROM Src
        WHERE WeekKey IS NOT NULL
        GROUP BY PanelName, PayerName, WeekKey
    ),
    Ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM Agg
        GROUP BY PanelName, PayerName
    )
    SELECT  a.PanelName,
            a.PayerName,
            CAST(r.PayerRank AS INT) AS PayerRank,
            CAST(a.WeekKey AS TINYINT) AS WeekKey,
            CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start WHEN 3 THEN @W3Start WHEN 4 THEN @W4Start END AS WeekStart,
            CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End   WHEN 3 THEN @W3End   WHEN 4 THEN @W4End   END AS WeekEnd,
            a.NoOfClaims,
            a.InsurancePayment,
            CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2)) AS AveragePaidAmount
    FROM Agg a
    JOIN Ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END
GO

/* -----------------------------------------------------------------------------
   ES 1. usp_RefreshVarX_ExecutiveSummary - deployed version; only change: the LIMS status column
   also matches VariantX 'SampleStatus' (Billable / System Test), so row I uses LIMSMaster.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_ExecutiveSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.VarX_ES_PMS;
	TRUNCATE TABLE dbo.VarX_ES_Cash;
	TRUNCATE TABLE dbo.VarX_ES_Avg;

	-- ───────────────────────────────────────────────────────────────────────
	--  #Base – one row per billable accession, DateofService-based period.
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #Base;

	SELECT
		AccessionNumber,
		YEAR (TRY_CAST(DateofService AS DATE))  AS ESYear,
		MONTH(TRY_CAST(DateofService AS DATE))  AS ESMonth,
		CASE WHEN LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) IN ('Unbilled','Unbilled - PB')
			 THEN 'Unbilled' ELSE 'Billed' END AS BilledUnbilled,
		ISNULL(LTRIM(RTRIM(ClaimStatus)), '')    AS ClaimStatus,
		ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0) AS ChargeAmount,
		ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0) AS InsurancePayment,
		ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0) AS PatientPayment,
		ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
		ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0) AS PatientAdjustments,
		ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0) AS InsuranceBalance,
		ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0) AS PatientBalance
	INTO #Base
	FROM dbo.ClaimLevelData
	WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
	  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '') IS NOT NULL;

	-- Periods: every (Year,Month) present in #Base PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  'I' Billed-Mismatch support: pre-aggregate Billed counts.
	--  #BaseBilledCount – ClaimLevelData Billed accessions per period.
	--  #LisBilled/#LisBilledCount – LIMSMaster accessions with
	--  NewStatus='Billable' AND BillCategory='Billed' per period
	--  (empty when dbo.LIMSMaster or the required columns don't exist,
	--  so I degenerates to I = F).
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT AccessionNumber) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	WHERE BilledUnbilled = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT AccessionNumber) FROM #Base WHERE BilledUnbilled = 'Billed';

	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession NVARCHAR(100) NOT NULL,
		ESYear    INT           NOT NULL,
		ESMonth   INT           NOT NULL
	);

	IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
	BEGIN
		DECLARE @AccCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('AccessionNumber','Accession','AccessionNo')
			ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

		DECLARE @DateCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('RequestCollectDate','DateofService','CollectionDate','ServiceDate','AccessionDate')
			ORDER BY CASE name
				WHEN 'RequestCollectDate' THEN 0 WHEN 'DateofService' THEN 1
				WHEN 'CollectionDate' THEN 2 WHEN 'ServiceDate' THEN 3
				WHEN 'AccessionDate' THEN 4 ELSE 5 END);

		DECLARE @NewStatusCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('NewStatus','Status','SampleStatus')
			ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 WHEN 'SampleStatus' THEN 2 ELSE 3 END);

		DECLARE @BillCategoryCol SYSNAME = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
			ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

		IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @NewStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL
		BEGIN
			DECLARE @LisBilledSql NVARCHAR(MAX) = N'
				INSERT INTO #LisBilled (Accession, ESYear, ESMonth)
				SELECT
					LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
					YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
					MONTH(TRY_CAST([' + @DateCol + N'] AS DATE))
				FROM dbo.LIMSMaster
				WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
				  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))) = ''Billable''
				  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))) = ''Billed'';';

			EXEC sp_executesql @LisBilledSql;
		END
		ELSE
		BEGIN
			PRINT 'usp_RefreshVarX_ExecutiveSummary: could not locate Accession/Date/NewStatus/BillCategory columns on dbo.LIMSMaster - ''I'' will degenerate to I = F.';
		END
	END

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled;

	-- ───────────────────────────────────────────────────────────────────────
	--  VarX_ES_PMS – F, G, H, I, J, K, L, M, N, O, P, P.1, P.2, P.3
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.VarX_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- F  No. of Billed Claims
		SELECT p.ESYear, p.ESMonth, 'F' AS RoleID, 'No. of Billed Claims' AS Description,
			   COUNT(DISTINCT b.AccessionNumber) AS ClaimCount
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled','Unbilled - PB')
		GROUP BY p.ESYear, p.ESMonth

		-- G  Unbilled Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G', 'Unbilled Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Unbilled','Unbilled - PB')
		GROUP BY p.ESYear, p.ESMonth

		-- H  Voided claims (spec gave no formula - see header note)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'Voided claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Voided'
		GROUP BY p.ESYear, p.ESMonth

		-- I  Billed Mismatches - LIS Accession Cannot be Matched (degenerates to I = F without LIMSMaster)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - LIS Accession Cannot be Matched',
			   ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0)
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		-- J  No. of Fully Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'No. of Fully Paid Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- K  No. of Fully Patient Responsibility Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'No. of Fully Patient Responsibility Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- L  No. of Patient Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'No. of Patient Paid Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		-- M  No. of Adjusted/Written Off Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- N  No. of Partially Adjusted claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- O  No. of Partially Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'O', 'No. of Partially Paid Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- P  No. of Insurance Balance Claims (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'No. of Insurance Balance Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Denied','No Response','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.1  No. of Fully Denied Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.1', '  No. of Fully Denied Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- P.2  No. of Partially Adjusted + Partially Denied Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.2', '  No. of Partially Denied Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.3  No. of No Response from Payor Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.3', '  No. of No Response from Payor Claims',
			   COUNT(DISTINCT b.AccessionNumber)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	) pms;

	-- ───────────────────────────────────────────────────────────────────────
	--  VarX_ES_Cash – Q, R, S, T, U, V, W, X, X.1, X.2, X.3
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.VarX_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, 0, ChargeValue, GETDATE()
	FROM
	(
		-- Q  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Q' AS RoleID, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS ChargeValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','Billed Amount 0')
		GROUP BY p.ESYear, p.ESMonth

		-- R  Unbilled Claims ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Unbilled Claims ($)',
			   ISNULL(SUM(b.ChargeAmount), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- S  Insurance Payment ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'S', 'Insurance Payment ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- T  Patient Responsibility ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Patient Responsibility ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- U  Adjustments / Write Off ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Adjustments / Write Off ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- V  Patient Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'V', 'Patient Paid ($)',
			   ISNULL(SUM(b.PatientPayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- W  Partially Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- X  Insurance Balance ($) (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0')
		GROUP BY p.ESYear, p.ESMonth

		-- X.1  Denials ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.1', '  Denials ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- X.2  Partially Denied ($) (Partially Denied + Partially Paid + Partially Adjusted + Patient Responsibility)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.2', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Partially Denied','Partially Paid','Partially Adjusted','Patient Responsibility')
		GROUP BY p.ESYear, p.ESMonth

		-- X.3  No Response from Payor ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.3', '  No Response from Payor ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	) cash;

	-- ───────────────────────────────────────────────────────────────────────
	--  VarX_ES_Avg – Y, Z, AA  [TABLE-DRIVEN]
	--
	--  Y   Average Payment ($) - Total Pay/Billed Claims
	--      Numerator  : S + W    (Insurance Payment ($) + Partially Paid ($))
	--      Denominator: F        (No. of Billed Claims)
	--
	--  Z   Average Payment ($) - Total Pay/Paid Claims
	--      Numerator  : S        (Insurance Payment ($))
	--      Denominator: J        (No. of Fully Paid Claims)
	--
	--  AA  Average Payment ($) - Total Pay/Adjudicated Claims
	--      Numerator  : S + W + V  (Insurance Payment ($) + Partially Paid ($) + Patient Paid ($))
	--      Denominator: J+M+K+L+N+O+P.1+P.2
	--                   (Fully Paid + Fully Adjusted + Patient Responsibility + Patient Paid +
	--                    Partially Adjusted + Partially Paid + Fully Denied + Partially Denied)
	-- ───────────────────────────────────────────────────────────────────────
	;WITH
	AvgNumSW AS
	(
		-- Y Numerator: S + W
		-- Insurance Payment ($) + Partially Paid ($)
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.VarX_ES_Cash
		WHERE RoleID IN ('S','W')
		GROUP BY ESYear, ESMonth
	),
	AvgNumS AS
	(
		-- Z Numerator: S
		-- Insurance Payment ($)
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.VarX_ES_Cash
		WHERE RoleID = 'S'
		GROUP BY ESYear, ESMonth
	),
	AvgNumSWV AS
	(
		-- AA Numerator: S + W + V
		-- Insurance Payment ($) + Partially Paid ($) + Patient Paid ($)
		SELECT ESYear, ESMonth, SUM(ESMonthChargeAmount) AS NumValue
		FROM dbo.VarX_ES_Cash
		WHERE RoleID IN ('S','W','V')
		GROUP BY ESYear, ESMonth
	),
	DenF AS
	(
		-- Y Denominator: F — No. of Billed Claims
		SELECT ESYear, ESMonth, ESMonthClaimCount AS DenomCount
		FROM dbo.VarX_ES_PMS
		WHERE RoleID = 'F'
	),
	DenZ AS
	(
		-- Z Denominator: J — No. of Fully Paid Claims
		SELECT ESYear, ESMonth, ESMonthClaimCount AS DenomCount
		FROM dbo.VarX_ES_PMS
		WHERE RoleID = 'J'
	),
	DenAA AS
	(
		-- AA Denominator: J+M+K+L+N+O+P.1+P.2
		-- Fully Paid + Fully Adjusted + Patient Responsibility + Patient Paid +
		-- Partially Adjusted + Partially Paid + Fully Denied + Partially Denied
		SELECT ESYear, ESMonth, SUM(ESMonthClaimCount) AS DenomCount
		FROM dbo.VarX_ES_PMS
		WHERE RoleID IN ('J','M','K','L','N','O','P.1','P.2')
		GROUP BY ESYear, ESMonth
	)
	INSERT INTO dbo.VarX_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	-- Y: (S + W) / F
	SELECT
		'Y',
		'Average Payment ($) - Total Pay/Billed Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumSW n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenF     d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

	UNION ALL
	-- Z: S / J
	SELECT
		'Z',
		'Average Payment ($) - Total Pay/Paid Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumS n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenZ    d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth

	UNION ALL
	-- AA: (S + W + V) / (J + M + K + L + N + O + P.1 + P.2)
	SELECT
		'AA',
		'Average Payment ($) - Total Pay/Adjudicated Claims',
		p.ESYear, p.ESMonth,
		ISNULL(d.DenomCount, 0),
		ISNULL(ROUND(ISNULL(n.NumValue, 0) / NULLIF(d.DenomCount, 0), 2), 0),
		GETDATE()
	FROM #Periods p
	LEFT JOIN AvgNumSWV n ON n.ESYear=p.ESYear AND n.ESMonth=p.ESMonth
	LEFT JOIN DenAA     d ON d.ESYear=p.ESYear AND d.ESMonth=p.ESMonth;

	-- Weighted annual averages. Never sum monthly averages.
	;WITH CashYear AS
	(
		SELECT ESYear,
			SUM(CASE WHEN RoleID IN ('S','W') THEN ESMonthChargeAmount ELSE 0 END) AS PayPlusPartial,
			SUM(CASE WHEN RoleID = 'S' THEN ESMonthChargeAmount ELSE 0 END) AS FullyPaidPayment,
			SUM(CASE WHEN RoleID IN ('S','W','V') THEN ESMonthChargeAmount ELSE 0 END) AS AdjudicatedPayment
		FROM dbo.VarX_ES_Cash
		WHERE ESYear > 0 AND ESMonth BETWEEN 1 AND 12
		GROUP BY ESYear
	),
	PmsYear AS
	(
		SELECT ESYear,
			SUM(CASE WHEN RoleID = 'F' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS BilledClaims,
			SUM(CASE WHEN RoleID = 'J' THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS PaidClaims,
			SUM(CASE WHEN RoleID IN ('J','M','K','L','N','O','P.1','P.2')
					 THEN CONVERT(DECIMAL(38,6), ESMonthClaimCount) ELSE 0 END) AS AdjudicatedClaims
		FROM dbo.VarX_ES_PMS
		WHERE ESYear > 0 AND ESMonth BETWEEN 1 AND 12
		GROUP BY ESYear
	)
	INSERT INTO dbo.VarX_ES_Avg
		(RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT v.RoleID, v.Description, p.ESYear, 0,
		CONVERT(INT, v.Denominator),
		CONVERT(DECIMAL(18,2), CASE WHEN v.Denominator = 0 THEN 0
			ELSE ROUND(v.Numerator / v.Denominator, 2) END),
		GETDATE()
	FROM PmsYear p
	LEFT JOIN CashYear c ON c.ESYear = p.ESYear
	CROSS APPLY
	(
		VALUES
			('Y',  'Average Payment ($) - Total Pay/Billed Claims',
			 CONVERT(DECIMAL(38,6), ISNULL(c.PayPlusPartial,0)), p.BilledClaims),
			('Z',  'Average Payment ($) - Total Pay/Paid Claims',
			 CONVERT(DECIMAL(38,6), ISNULL(c.FullyPaidPayment,0)), p.PaidClaims),
			('AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			 CONVERT(DECIMAL(38,6), ISNULL(c.AdjudicatedPayment,0)), p.AdjudicatedClaims)
	) v(RoleID, Description, Numerator, Denominator);

	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;

	IF OBJECT_ID('dbo.usp_VarX_ES_UpdatePmsBilledMismatch', 'P') IS NOT NULL
		EXEC dbo.usp_VarX_ES_UpdatePmsBilledMismatch;

	PRINT 'usp_RefreshVarX_ExecutiveSummary completed.';
END;
GO

/* -----------------------------------------------------------------------------
   ES 2. usp_RefreshVarX_ExecutiveSummary_LIS_Alt - deployed version; LIMS status column also matches
   'SampleStatus' (VarX_ES_LIS was empty: no NewStatus column) and panel also matches 'TestType'.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_ExecutiveSummary_LIS_Alt
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.VarX_ES_LIS;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
	BEGIN
		PRINT 'usp_RefreshVarX_ExecutiveSummary_LIS_Alt: dbo.LIMSMaster not found - nothing to do.';
		RETURN;
	END

	DECLARE @AccCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('AccessionNumber','Accession','AccessionNo')
		ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

	DECLARE @DateCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('DateOfCollection','RequestCollectDate','CollectionDate','DateofService','ServiceDate','AccessionDate')
		ORDER BY CASE name
			WHEN 'DateOfCollection'   THEN 0
			WHEN 'RequestCollectDate' THEN 1
			WHEN 'CollectionDate'     THEN 2
			WHEN 'DateofService'      THEN 3
			WHEN 'ServiceDate'        THEN 4
			WHEN 'AccessionDate'      THEN 5
			ELSE 6 END);

	DECLARE @NewStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('NewStatus','Status','SampleStatus')
		ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 WHEN 'SampleStatus' THEN 2 ELSE 3 END);

	DECLARE @BillCategoryCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
		ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

	DECLARE @ResultStatusCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
		ORDER BY CASE name
			WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
			WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
			WHEN 'IsResulted' THEN 4 ELSE 5 END);

	-- Optional — absence means no B.x panel sub-rows, SP still runs normally.
	DECLARE @PanelCol SYSNAME = (
		SELECT TOP 1 name FROM sys.columns
		WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
		  AND name IN ('Panel','PanelName','PanelType','TestPanel','TestType')
		ORDER BY CASE name WHEN 'Panel' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'PanelType' THEN 2 WHEN 'TestPanel' THEN 3 WHEN 'TestType' THEN 4 ELSE 5 END);

	IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @BillCategoryCol IS NULL OR @ResultStatusCol IS NULL
	BEGIN
		PRINT 'usp_RefreshVarX_ExecutiveSummary_LIS_Alt: could not locate Accession/Date/NewStatus/BillCategory/ResultStatus columns on dbo.LIMSMaster - skipping.';
		RETURN;
	END

	-- ── Build #Lis (real table - must survive past sp_executesql) ───────────
	DROP TABLE IF EXISTS #Lis;
	CREATE TABLE #Lis
	(
		Accession    NVARCHAR(100) NOT NULL,
		ESYear       INT           NOT NULL,
		ESMonth      INT           NOT NULL,
		NewStatus    NVARCHAR(100) NOT NULL,
		BillCategory NVARCHAR(100) NOT NULL,
		ResultStatus NVARCHAR(100) NOT NULL,
		Panel        NVARCHAR(300) NOT NULL  -- '' when @PanelCol not found
	);

	-- IsResulted is sometimes a bit/flag column rather than a status string;
	-- normalize it to 'Resulted' / 'Not Resulted' so the D.1 filter
	-- (ResultStatus = 'Resulted') works regardless of the underlying type.
	DECLARE @ResultExpr NVARCHAR(400);
	IF @ResultStatusCol = 'IsResulted'
		SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
								   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
								   ELSE ''Not Resulted'' END)';
	ELSE
		SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

	-- Panel expression: use detected column or empty string if column absent
	DECLARE @PanelExpr NVARCHAR(200) =
		CASE WHEN @PanelCol IS NOT NULL
		     THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), '''')))'
		     ELSE N'CAST('''' AS NVARCHAR(300))'
		END;

	DECLARE @LisSql NVARCHAR(MAX) = N'
		INSERT INTO #Lis (Accession, ESYear, ESMonth, NewStatus, BillCategory, ResultStatus, Panel)
		SELECT
			LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
			YEAR (TRY_CAST([' + @DateCol + N'] AS DATE)),
			MONTH(TRY_CAST([' + @DateCol + N'] AS DATE)),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))),
			LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))),
			' + @ResultExpr + N',
			' + @PanelExpr + N'
		FROM dbo.LIMSMaster
		WHERE TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL;';

	EXEC sp_executesql @LisSql;

	-- LIS-specific periods (LIMSMaster date-based) PLUS grand-total sentinel.
	DROP TABLE IF EXISTS #LisPeriods;
	SELECT DISTINCT ESYear, ESMonth INTO #LisPeriods FROM #Lis
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  VarX_ES_LIS - A, B, C, D, D.1, E, E.1-E.6
	-- ───────────────────────────────────────────────────────────────────────
	INSERT INTO dbo.VarX_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
	SELECT RoleID, Description, ESYear, ESMonth, ClaimCount, 0, GETDATE()
	FROM
	(
		-- A  Total Samples
		SELECT p.ESYear, p.ESMonth, 'A' AS RoleID, 'Total Samples' AS Description,
			   COUNT(DISTINCT l.Accession) AS ClaimCount
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- B  Billable Samples
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'B', 'Billable Samples',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Billable'
		GROUP BY p.ESYear, p.ESMonth

		-- C  Billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'C', 'Billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Billable'
						 AND l.BillCategory = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D  Unbilled
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D', 'Unbilled',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Billable'
						 AND l.BillCategory = 'Not Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- D.1  Resulted yet to be billed
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'D.1', '  Resulted yet to be billed',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.ResultStatus = 'Resulted'
						 AND l.NewStatus = 'Billable'
						 AND l.BillCategory = 'Not Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- E  Other Samples
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E', 'Other Samples',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus <> 'Billable'
		GROUP BY p.ESYear, p.ESMonth

		-- E.1  Client Bill
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.1', '  Client Bill',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Client Bill'
		GROUP BY p.ESYear, p.ESMonth

		-- E.2  Self Pay
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.2', '  Self Pay',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Self Pay'
		GROUP BY p.ESYear, p.ESMonth

		-- E.3  System Test
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.3', '  System Test',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'System Test'
		GROUP BY p.ESYear, p.ESMonth

		-- E.4  Deleted/Rejected
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.4', '  Deleted/Rejected',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Deleted/Rejected'
		GROUP BY p.ESYear, p.ESMonth

		-- E.5  CIP/Pending
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.5', '  CIP/Pending',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'CIP/Pending'
		GROUP BY p.ESYear, p.ESMonth

		-- E.6  Yet to be validated
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'E.6', '  Yet to be validated',
			   COUNT(DISTINCT l.Accession)
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear=0 OR (l.ESYear=p.ESYear AND l.ESMonth=p.ESMonth))
						 AND l.NewStatus = 'Yet to be validated'
		GROUP BY p.ESYear, p.ESMonth
	) lis;

	-- ── B.x  Panel sub-rows (Billable Samples by Panel) ─────────────────────
	-- Only inserted when @PanelCol was found; graceful no-op otherwise.
	IF @PanelCol IS NOT NULL
	BEGIN
		INSERT INTO dbo.VarX_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, RefreshedAt)
		SELECT
			'B.' + l.Panel,
			'  '  + l.Panel,
			p.ESYear,
			p.ESMonth,
			COUNT(DISTINCT l.Accession),
			0,
			GETDATE()
		FROM #LisPeriods p
		LEFT JOIN #Lis l ON (p.ESYear = 0 OR (l.ESYear = p.ESYear AND l.ESMonth = p.ESMonth))
		                 AND l.NewStatus = 'Billable'
		                 AND l.Panel     <> ''
		WHERE l.Panel IS NOT NULL AND l.Panel <> ''
		GROUP BY p.ESYear, p.ESMonth, l.Panel;
	END

	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #LisPeriods;

	-- Recalculate mismatch from the completed LIS C (Billed) snapshot.
	IF OBJECT_ID('dbo.usp_VarX_ES_UpdatePmsBilledMismatch', 'P') IS NOT NULL
		EXEC dbo.usp_VarX_ES_UpdatePmsBilledMismatch;

	PRINT 'usp_RefreshVarX_ExecutiveSummary_LIS_Alt completed.';
END;
GO

/* -----------------------------------------------------------------------------
   ES 3. usp_GetVarX_ExecutiveSummary - deployed version; filtered LIS scan: status column also matches
   'SampleStatus', panel column also matches 'TestType'.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_ExecutiveSummary
(
	@YearFrom     INT           = NULL,
	@YearTo       INT           = NULL,
	@MonthFrom    INT           = NULL,
	@MonthTo      INT           = NULL,
	@DosFrom      DATE          = NULL,
	@DosTo        DATE          = NULL,
	@BilledFrom   DATE          = NULL,
	@BilledTo     DATE          = NULL,
	@Panels       NVARCHAR(MAX) = NULL,
	@Clinics      NVARCHAR(MAX) = NULL,
	@Providers    NVARCHAR(MAX) = NULL,
	@Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
	SET NOCOUNT ON;

	DECLARE @HasFilter BIT =
		CASE
			WHEN @YearFrom     IS NOT NULL THEN 1
			WHEN @YearTo       IS NOT NULL THEN 1
			WHEN @MonthFrom    IS NOT NULL THEN 1
			WHEN @MonthTo      IS NOT NULL THEN 1
			WHEN @DosFrom      IS NOT NULL THEN 1
			WHEN @DosTo        IS NOT NULL THEN 1
			WHEN @BilledFrom   IS NOT NULL THEN 1
			WHEN @BilledTo     IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL THEN 1
			WHEN NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL THEN 1
			ELSE 0
		END;

	-- Date mode: DOS vs FirstBilledDate are mutually exclusive in the UI.
	-- @UseBilledDate = 1  → FirstBilledDate filter is active (@BilledFrom/@BilledTo set, @DosFrom/@DosTo NULL).
	--   #Base : ESYear/ESMonth derived from FirstBilledDate (not DateofService).
	--   LIS   : LISYear/LISMonth derived from BilledDate in LIMSMaster; live scan triggered.
	-- @UseBilledDate = 0  → DOS mode (or no date filter) — existing behaviour unchanged.
	DECLARE @UseBilledDate BIT = CASE
		WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
		 AND  @DosFrom IS NULL AND @DosTo IS NULL
		THEN 1 ELSE 0 END;

	-- ───────────────────────────────────────────────────────────────────────
	--  NO-FILTER PATH – fast path; read straight from aggregate tables.
	-- ───────────────────────────────────────────────────────────────────────
	IF @HasFilter = 0
	BEGIN
		SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
		FROM
		(
			SELECT RoleID AS RowCode, 'LIS' AS Category, Description,
				   ESYear AS BillYear, ESMonth AS BillMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue
			FROM   dbo.VarX_ES_LIS

			UNION ALL

			SELECT RoleID, 'PMS', Description, ESYear, ESMonth,
				   CAST(ESMonthClaimCount AS DECIMAL(18,2))
			FROM   dbo.VarX_ES_PMS

			UNION ALL

			SELECT RoleID, 'Cash', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.VarX_ES_Cash

			UNION ALL

			SELECT RoleID, 'Avg', Description, ESYear, ESMonth,
				   ESMonthChargeAmount
			FROM   dbo.VarX_ES_Avg
		) all_rows
		ORDER BY BillYear, BillMonth, RowCode;
		RETURN;
	END;

	-- ───────────────────────────────────────────────────────────────────────
	--  FILTERED PATH
	-- ───────────────────────────────────────────────────────────────────────

	-- Dimension filter staging tables
	CREATE TABLE #FilterPanels   (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterClinics  (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterProviders(Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
	CREATE TABLE #FilterReps     (Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);

	IF NULLIF(LTRIM(RTRIM(@Panels)),   '') IS NOT NULL
		INSERT INTO #FilterPanels(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Panels, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Clinics)),  '') IS NOT NULL
		INSERT INTO #FilterClinics(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Clinics, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Providers)),'') IS NOT NULL
		INSERT INTO #FilterProviders(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Providers, ',') WHERE LTRIM(RTRIM(value)) <> '';
	IF NULLIF(LTRIM(RTRIM(@Reps)),     '') IS NOT NULL
		INSERT INTO #FilterReps(Val)
		SELECT LTRIM(RTRIM(value)) COLLATE DATABASE_DEFAULT FROM STRING_SPLIT(@Reps, ',') WHERE LTRIM(RTRIM(value)) <> '';

	DECLARE @HasPanelFilter    BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterPanels)    THEN 1 ELSE 0 END;
	DECLARE @HasClinicFilter   BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterClinics)   THEN 1 ELSE 0 END;
	DECLARE @HasProviderFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterProviders) THEN 1 ELSE 0 END;
	DECLARE @HasRepFilter      BIT = CASE WHEN EXISTS (SELECT 1 FROM #FilterReps)      THEN 1 ELSE 0 END;

	-- @HasLisFilter: 1 when Panel/Clinic/Provider/Rep filter(s) are active OR BilledDate mode is active.
	-- DOS date params are intentionally NOT applied to LIMSMaster for VariantX (independent period system).
	-- @UseBilledDate = 1 forces a live LIMSMaster scan so LISYear/LISMonth are bucketed by
	--   BilledDate (not DateOfCollection) and @BilledFrom/@BilledTo bound the scan.
	-- SalesRep (@HasRepFilter) now included: LIMSMaster has a SaleRepName column
	-- (confirmed present), so a Rep-only filter must also trigger the live scan
	-- for it to take effect on the LIS section (see @RepCol below).
	DECLARE @HasLisFilter BIT = CASE
		WHEN @HasPanelFilter = 1 OR @HasClinicFilter = 1 OR @HasProviderFilter = 1
		  OR @HasRepFilter = 1 OR @UseBilledDate = 1
		THEN 1 ELSE 0 END;

	-- ── LIMSMaster column detection (shared by #Lis LIS scan and #LisBilled) ──
	DECLARE @AccCol          SYSNAME = NULL;
	DECLARE @DateCol         SYSNAME = NULL;
	DECLARE @NewStatusCol    SYSNAME = NULL;
	DECLARE @BillCategoryCol SYSNAME = NULL;
	DECLARE @ResultStatusCol SYSNAME = NULL;
	DECLARE @PanelCol        SYSNAME = NULL;
	DECLARE @ClinicCol       SYSNAME = NULL;
	DECLARE @ProviderCol     SYSNAME = NULL;
	DECLARE @RepCol          SYSNAME = NULL;
	DECLARE @BilledDateCol   SYSNAME = NULL;

	IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
	BEGIN
		SET @AccCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('AccessionNumber','Accession','AccessionNo')
			ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

		SET @DateCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('DateOfCollection','RequestCollectDate','CollectionDate','DateofService','ServiceDate','AccessionDate')
			ORDER BY CASE name
				WHEN 'DateOfCollection'   THEN 0
				WHEN 'RequestCollectDate' THEN 1
				WHEN 'CollectionDate'     THEN 2
				WHEN 'DateofService'      THEN 3
				WHEN 'ServiceDate'        THEN 4
				WHEN 'AccessionDate'      THEN 5
				ELSE 6 END);

		SET @NewStatusCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('NewStatus','Status','SampleStatus')
			ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 WHEN 'SampleStatus' THEN 2 ELSE 3 END);

		SET @BillCategoryCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
			ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

		SET @ResultStatusCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
			ORDER BY CASE name
				WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
				WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
				WHEN 'IsResulted' THEN 4 ELSE 5 END);

		-- Dimension filter columns (Panels → PanelName, Clinics → FacilityName, Provider → PhysicianName)
		-- PanelName is the confirmed/correct LIMSMaster column for the Panel filter.
		-- It is now prioritized first: it was previously ranked behind 'Panel', and
		-- when a same-named 'Panel' column exists but doesn't carry the values the
		-- UI passes (which come from ClaimLevelData.PanelType via the FilterOptions
		-- SP), the CHARINDEX predicate below never matches — causing the entire LIS
		-- breakdown to disappear whenever a Panel filter is applied.
		SET @PanelCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PanelName','Panel','PanelType','TestPanel','TestType')
			ORDER BY CASE name WHEN 'PanelName' THEN 0 WHEN 'Panel' THEN 1 WHEN 'PanelType' THEN 2 WHEN 'TestPanel' THEN 3 WHEN 'TestType' THEN 4 ELSE 5 END);

		SET @ClinicCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('FacilityName','ClinicName','Clinic','FacilityID')
			ORDER BY CASE name WHEN 'FacilityName' THEN 0 WHEN 'ClinicName' THEN 1 WHEN 'Clinic' THEN 2 WHEN 'FacilityID' THEN 3 ELSE 4 END);

		SET @ProviderCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('PhysicianName','ReferringProvider','ReferringPhysician','ProviderName')
			ORDER BY CASE name WHEN 'PhysicianName' THEN 0 WHEN 'ReferringProvider' THEN 1 WHEN 'ReferringPhysician' THEN 2 WHEN 'ProviderName' THEN 3 ELSE 4 END);

		SET @RepCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('SaleRepName','SalesRepName','SalesRep','Rep')
			ORDER BY CASE name WHEN 'SaleRepName' THEN 0 WHEN 'SalesRepName' THEN 1 WHEN 'SalesRep' THEN 2 WHEN 'Rep' THEN 3 ELSE 4 END);

		-- BilledDate: maps @BilledFrom/@BilledTo → LIMSMaster BilledDate column (billed-date mode).
		SET @BilledDateCol = (
			SELECT TOP 1 name FROM sys.columns
			WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
			  AND name IN ('BilledDate','FirstBilledDate','BilledOn','BillDate','FirstBillDate')
			ORDER BY CASE name
				WHEN 'BilledDate'    THEN 0 WHEN 'FirstBilledDate' THEN 1
				WHEN 'BilledOn'      THEN 2 WHEN 'BillDate'        THEN 3
				WHEN 'FirstBillDate' THEN 4 ELSE 5 END);
	END

	-- ── LIS rows ─────────────────────────────────────────────────────────────
	-- #LisOut holds all LIS rows; populated from aggregate (fast path) or
	-- live LIMSMaster scan (dimension-filtered path).
	-- Created before any branching so LisFinal CTE always has a valid source.
	DROP TABLE IF EXISTS #LisOut;
	CREATE TABLE #LisOut
	(
		RowCode     NVARCHAR(420) NOT NULL,
		Description NVARCHAR(420) NOT NULL,
		ESYear      INT           NOT NULL,
		ESMonth     INT           NOT NULL,
		MetricValue DECIMAL(18,2) NOT NULL
	);

	IF @HasLisFilter = 0
	BEGIN
		-- No LIS-applicable dimension filter → re-sum aggregate by Year/Month only.
		-- Also apply DOS date year/month bounds when @DosFrom/@DosTo are set so that
		-- selecting a DOS range (e.g. Jan–Jul 2026) restricts LIS to the same period
		-- (month-level granularity, matching the aggregate's ESYear/ESMonth bucketing).
		DROP TABLE IF EXISTS #LisFiltered;
		SELECT RoleID, Description, ESYear, ESMonth, ESMonthClaimCount
		INTO #LisFiltered
		FROM dbo.VarX_ES_LIS
		WHERE ESYear <> 0
		  AND (@YearFrom  IS NULL OR ESYear  >= @YearFrom)
		  AND (@YearTo    IS NULL OR ESYear  <= @YearTo)
		  AND (@MonthFrom IS NULL OR ESMonth >= @MonthFrom)
		  AND (@MonthTo   IS NULL OR ESMonth <= @MonthTo)
		  -- DOS lower bound: keep rows whose (ESYear,ESMonth) >= (DosFrom year, DosFrom month)
		  AND (@DosFrom IS NULL
			   OR ESYear  > YEAR (CAST(@DosFrom AS DATE))
			   OR (ESYear = YEAR (CAST(@DosFrom AS DATE)) AND ESMonth >= MONTH(CAST(@DosFrom AS DATE))))
		  -- DOS upper bound: keep rows whose (ESYear,ESMonth) <= (DosTo year, DosTo month)
		  AND (@DosTo   IS NULL
			   OR ESYear  < YEAR (CAST(@DosTo   AS DATE))
			   OR (ESYear = YEAR (CAST(@DosTo   AS DATE)) AND ESMonth <= MONTH(CAST(@DosTo   AS DATE))));

		INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
		SELECT RoleID, Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2))
		FROM #LisFiltered
		UNION ALL
		SELECT RoleID, MAX(Description), 0, 0, CAST(SUM(ESMonthClaimCount) AS DECIMAL(18,2))
		FROM #LisFiltered
		GROUP BY RoleID;
	END
	ELSE
	BEGIN
		-- Panel/Clinic/Provider filter OR billed-date mode active → scan LIMSMaster.
		--   DOS mode        : LISYear/LISMonth from DateOfCollection (no date bounds — independent period system).
		--   BilledDate mode : LISYear/LISMonth from BilledDate, bounded by @BilledFrom/@BilledTo.
		IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL
		   AND @NewStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL AND @ResultStatusCol IS NOT NULL
		BEGIN
			-- ResultStatus normalizer (IsResulted may be a bit/flag column)
			DECLARE @ResultExpr NVARCHAR(400);
			IF @ResultStatusCol = 'IsResulted'
				SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
										   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
										   ELSE ''Not Resulted'' END)';
			ELSE
				SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

			DROP TABLE IF EXISTS #Lis;
			CREATE TABLE #Lis
			(
				Accession    NVARCHAR(100) NOT NULL,
				ESYear       INT           NOT NULL,
				ESMonth      INT           NOT NULL,
				NewStatus    NVARCHAR(100) NOT NULL,
				BillCategory NVARCHAR(100) NOT NULL,
				ResultStatus NVARCHAR(100) NOT NULL,
				Panel        NVARCHAR(300) NOT NULL  -- '' when @PanelCol not found
			);

			-- Panel SELECT expression: use detected column or empty string if column absent
			DECLARE @PanelExpr NVARCHAR(200) =
				CASE WHEN @PanelCol IS NOT NULL
					 THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), '''')))'
					 ELSE N'CAST('''' AS NVARCHAR(300))'
				END;

			-- Period expression for LISYear/LISMonth:
			--   BilledDate mode → TRY_CAST([BilledDate] AS DATE)  (period bucketed by billed date)
			--   DOS mode        → TRY_CAST([DateOfCollection] AS DATE)
			-- TRY_CAST is used in both modes because LIMSMaster date columns may be stored as
			-- strings in some VariantX environments (same defensive pattern as the DOS path).
			DECLARE @LisPeriodExpr NVARCHAR(200) =
				CASE WHEN @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
					 THEN N'TRY_CAST([' + @BilledDateCol + N'] AS DATE)'
					 ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

			DECLARE @LisSql NVARCHAR(MAX) = N'
				INSERT INTO #Lis (Accession, ESYear, ESMonth, NewStatus, BillCategory, ResultStatus, Panel)
				SELECT
					LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
					YEAR (' + @LisPeriodExpr + N'),
					MONTH(' + @LisPeriodExpr + N'),
					LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))),
					LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))),
					' + @ResultExpr + N',
					' + @PanelExpr + N'
				FROM dbo.LIMSMaster
				WHERE ' + @LisPeriodExpr + N' IS NOT NULL
				  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL';

			-- Dimension filter predicates — COLLATE DATABASE_DEFAULT on both sides to avoid
			-- collation conflicts between LIMSMaster columns and NVARCHAR(MAX) parameters.
			IF @HasPanelFilter = 1 AND @PanelCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasClinicFilter = 1 AND @ClinicCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasProviderFilter = 1 AND @ProviderCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

			IF @HasRepFilter = 1 AND @RepCol IS NOT NULL
				SET @LisSql += N'
				  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @RepCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iReps + '','') COLLATE DATABASE_DEFAULT) > 0';

			-- FirstBilledDate bound: only in billed-date mode. Bounds the LIMSMaster scan by BilledDate.
			IF @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
				SET @LisSql += N'
				  AND (@iBilledFrom IS NULL OR ' + @LisPeriodExpr + N' >= @iBilledFrom)
				  AND (@iBilledTo   IS NULL OR ' + @LisPeriodExpr + N' <= @iBilledTo)';

			SET @LisSql += N';';

			EXEC sp_executesql @LisSql,
				N'@iPanels     NVARCHAR(MAX),
				  @iClinics    NVARCHAR(MAX),
				  @iProviders  NVARCHAR(MAX),
				  @iReps       NVARCHAR(MAX),
				  @iBilledFrom DATE,
				  @iBilledTo   DATE',
				@iPanels     = @Panels,
				@iClinics    = @Clinics,
				@iProviders  = @Providers,
				@iReps       = @Reps,
				@iBilledFrom = @BilledFrom,
				@iBilledTo   = @BilledTo;

			-- Aggregate #Lis into #LisOut, one row per (RowCode, ESYear, ESMonth)
			INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
			-- A  Total Samples
			SELECT 'A',   'Total Samples',                ESYear, ESMonth, CAST(COUNT(DISTINCT Accession) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- B  Billable Samples
			UNION ALL
			SELECT 'B',   'Billable Samples',             ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable'                                                           THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- C  Billed
			UNION ALL
			SELECT 'C',   'Billed',                       ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' AND BillCategory = 'Billed'                             THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- D  Unbilled
			UNION ALL
			SELECT 'D',   'Unbilled',                     ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' AND BillCategory = 'Not Billed'                         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- D.1  Resulted yet to be billed
			UNION ALL
			SELECT 'D.1', '  Resulted yet to be billed', ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' AND BillCategory = 'Not Billed' AND ResultStatus = 'Resulted' THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E  Other Samples
			UNION ALL
			SELECT 'E',   'Other Samples',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus <> 'Billable'                                                          THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.1  Client Bill
			UNION ALL
			SELECT 'E.1', '  Client Bill',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Client Bill'         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.2  Self Pay
			UNION ALL
			SELECT 'E.2', '  Self Pay',                   ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Self Pay'            THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.3  System Test
			UNION ALL
			SELECT 'E.3', '  System Test',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'System Test'         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.4  Deleted/Rejected
			UNION ALL
			SELECT 'E.4', '  Deleted/Rejected',           ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Deleted/Rejected'    THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.5  CIP/Pending
			UNION ALL
			SELECT 'E.5', '  CIP/Pending',                ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'CIP/Pending'         THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth
			-- E.6  Yet to be validated
			UNION ALL
			SELECT 'E.6', '  Yet to be validated',        ESYear, ESMonth, CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Yet to be validated' THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis GROUP BY ESYear, ESMonth;

			-- B.x  Panel sub-rows (Billable Samples by Panel, displayed under row B)
			INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
			SELECT 'B.' + Panel, '  ' + Panel, ESYear, ESMonth,
			       CAST(COUNT(DISTINCT CASE WHEN NewStatus = 'Billable' THEN Accession END) AS DECIMAL(18,2))
			FROM #Lis
			WHERE NewStatus = 'Billable' AND Panel <> ''
			GROUP BY Panel, ESYear, ESMonth;

			-- Grand-total sentinel (0,0) rows — sums all per-period rows, including B.x
			INSERT INTO #LisOut (RowCode, Description, ESYear, ESMonth, MetricValue)
			SELECT RowCode, MAX(Description), 0, 0, SUM(MetricValue)
			FROM #LisOut
			WHERE ESYear <> 0
			GROUP BY RowCode;
		END
	END

	-- PMS/Cash/Avg: live re-aggregation from ClaimLevelData, same #Base shape as file 16.
	-- Pre-create #Base so the two date-mode branches use INSERT (SELECT…INTO twice would
	-- raise Msg 2714 at compile time regardless of the IF/ELSE branch actually run).
	DROP TABLE IF EXISTS #Base;
	CREATE TABLE #Base
	(
		AccessionNumber      NVARCHAR(100)  COLLATE DATABASE_DEFAULT NOT NULL,
		ESYear               INT            NOT NULL DEFAULT 0,
		ESMonth              INT            NOT NULL DEFAULT 0,
		BilledUnbilled       NVARCHAR(200)  COLLATE DATABASE_DEFAULT NOT NULL DEFAULT '',
		ClaimStatus          NVARCHAR(200)  COLLATE DATABASE_DEFAULT NOT NULL DEFAULT '',
		ChargeAmount         DECIMAL(18,2)  NOT NULL DEFAULT 0,
		InsurancePayment     DECIMAL(18,2)  NOT NULL DEFAULT 0,
		PatientPayment       DECIMAL(18,2)  NOT NULL DEFAULT 0,
		InsuranceAdjustments DECIMAL(18,2)  NOT NULL DEFAULT 0,
		PatientAdjustments   DECIMAL(18,2)  NOT NULL DEFAULT 0,
		InsuranceBalance     DECIMAL(18,2)  NOT NULL DEFAULT 0,
		PatientBalance       DECIMAL(18,2)  NOT NULL DEFAULT 0
	);

	-- DOS mode / BilledDate mode: load #Base via dynamic SQL so missing
	-- ClaimLevel columns (ClinicName, ReferringProvider, SalesRepname, BillStatus)
	-- do not block CREATE PROCEDURE when scripts 02-05 were skipped.
	DECLARE @ClClinicCol SYSNAME =
	(
		SELECT TOP (1) c.name FROM sys.columns c
		WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
		  AND c.name IN (N'ClinicName', N'Facility', N'ServiceLocationName', N'Clinic')
		ORDER BY CASE c.name WHEN N'ClinicName' THEN 1 WHEN N'Facility' THEN 2 WHEN N'ServiceLocationName' THEN 3 ELSE 4 END
	);
	DECLARE @ClProviderCol SYSNAME =
	(
		SELECT TOP (1) c.name FROM sys.columns c
		WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
		  AND c.name IN (N'ReferringProvider', N'ReferringPhysician', N'Provider', N'ProviderName', N'OrderingProvider', N'BillingProvider')
		ORDER BY CASE c.name
			WHEN N'ReferringProvider' THEN 1 WHEN N'ReferringPhysician' THEN 2 WHEN N'Provider' THEN 3
			WHEN N'ProviderName' THEN 4 WHEN N'OrderingProvider' THEN 5 WHEN N'BillingProvider' THEN 6 ELSE 7 END
	);
	DECLARE @ClRepCol SYSNAME =
	(
		SELECT TOP (1) c.name FROM sys.columns c
		WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
		  AND c.name IN (N'SalesRepname', N'SalesRepName', N'SalesRep', N'SalesRep_Name')
		ORDER BY CASE c.name WHEN N'SalesRepname' THEN 1 WHEN N'SalesRepName' THEN 2 WHEN N'SalesRep' THEN 3 ELSE 4 END
	);

	DECLARE @BillStatusExpr NVARCHAR(400) =
		CASE WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'BillStatus') IS NOT NULL
			 THEN N'ISNULL(BillStatus, '''')'
			 ELSE N'CASE WHEN LTRIM(RTRIM(ISNULL(ClaimStatus, ''''))) IN (''Unbilled'',''Unbilled - PB'') THEN ''Unbilled'' ELSE ''Billed'' END'
		END;

	DECLARE @ClinicFilterSql NVARCHAR(MAX) =
		CASE WHEN @ClClinicCol IS NULL THEN N'AND (@HasClinicFilter = 0)'
			 ELSE N'AND (@HasClinicFilter = 0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(' + QUOTENAME(@ClClinicCol) + N', ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @Clinics + '','') COLLATE DATABASE_DEFAULT) > 0)'
		END;
	DECLARE @ProviderFilterSql NVARCHAR(MAX) =
		CASE WHEN @ClProviderCol IS NULL THEN N'AND (@HasProviderFilter = 0)'
			 ELSE N'AND (@HasProviderFilter = 0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(' + QUOTENAME(@ClProviderCol) + N', ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @Providers + '','') COLLATE DATABASE_DEFAULT) > 0)'
		END;
	DECLARE @RepFilterSql NVARCHAR(MAX) =
		CASE WHEN @ClRepCol IS NULL THEN N'AND (@HasRepFilter = 0)'
			 ELSE N'AND (@HasRepFilter = 0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(' + QUOTENAME(@ClRepCol) + N', ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @Reps + '','') COLLATE DATABASE_DEFAULT) > 0)'
		END;

	DECLARE @BaseSql NVARCHAR(MAX);
	DECLARE @BaseParams NVARCHAR(MAX) = N'
		@YearFrom INT, @YearTo INT, @MonthFrom INT, @MonthTo INT,
		@DosFrom DATE, @DosTo DATE, @BilledFrom DATE, @BilledTo DATE,
		@Panels NVARCHAR(MAX), @Clinics NVARCHAR(MAX), @Providers NVARCHAR(MAX), @Reps NVARCHAR(MAX),
		@HasPanelFilter BIT, @HasClinicFilter BIT, @HasProviderFilter BIT, @HasRepFilter BIT';

	IF @UseBilledDate = 0
	BEGIN
		SET @BaseSql = N'
		INSERT INTO #Base (AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
						   ChargeAmount, InsurancePayment, PatientPayment,
						   InsuranceAdjustments, PatientAdjustments,
						   InsuranceBalance, PatientBalance)
		SELECT
			AccessionNumber,
			ISNULL(YEAR (TRY_CAST(DateofService AS DATE)), 0),
			ISNULL(MONTH(TRY_CAST(DateofService AS DATE)), 0),
			' + @BillStatusExpr + N',
			ISNULL(LTRIM(RTRIM(ClaimStatus)), ''''),
			ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '''') IS NOT NULL
		  AND (@YearFrom  IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) >= @YearFrom)
		  AND (@YearTo    IS NULL OR YEAR (TRY_CAST(DateofService AS DATE)) <= @YearTo)
		  AND (@MonthFrom IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) >= @MonthFrom)
		  AND (@MonthTo   IS NULL OR MONTH(TRY_CAST(DateofService AS DATE)) <= @MonthTo)
		  AND (@DosFrom    IS NULL OR TRY_CAST(DateofService AS DATE) >= @DosFrom)
		  AND (@DosTo      IS NULL OR TRY_CAST(DateofService AS DATE) <= @DosTo)
		  AND (@HasPanelFilter = 0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(Panelname, ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @Panels + '','') COLLATE DATABASE_DEFAULT) > 0)
		  ' + @ClinicFilterSql + N'
		  ' + @ProviderFilterSql + N'
		  ' + @RepFilterSql + N';';
	END
	ELSE
	BEGIN
		SET @BaseSql = N'
		INSERT INTO #Base (AccessionNumber, ESYear, ESMonth, BilledUnbilled, ClaimStatus,
						   ChargeAmount, InsurancePayment, PatientPayment,
						   InsuranceAdjustments, PatientAdjustments,
						   InsuranceBalance, PatientBalance)
		SELECT
			AccessionNumber,
			ISNULL(YEAR (TRY_CAST(FirstBilledDate AS DATE)), 0),
			ISNULL(MONTH(TRY_CAST(FirstBilledDate AS DATE)), 0),
			' + @BillStatusExpr + N',
			ISNULL(LTRIM(RTRIM(ClaimStatus)), ''''),
			ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
			ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0)
		FROM dbo.ClaimLevelData
		WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
		  AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '''') IS NOT NULL
		  AND (@BilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @BilledFrom)
		  AND (@BilledTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @BilledTo)
		  AND (@HasPanelFilter = 0 OR CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(Panelname, ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @Panels + '','') COLLATE DATABASE_DEFAULT) > 0)
		  ' + @ClinicFilterSql + N'
		  ' + @ProviderFilterSql + N'
		  ' + @RepFilterSql + N'
		OPTION (RECOMPILE);';
	END

	EXEC sys.sp_executesql @BaseSql, @BaseParams,
		@YearFrom=@YearFrom, @YearTo=@YearTo, @MonthFrom=@MonthFrom, @MonthTo=@MonthTo,
		@DosFrom=@DosFrom, @DosTo=@DosTo, @BilledFrom=@BilledFrom, @BilledTo=@BilledTo,
		@Panels=@Panels, @Clinics=@Clinics, @Providers=@Providers, @Reps=@Reps,
		@HasPanelFilter=@HasPanelFilter, @HasClinicFilter=@HasClinicFilter,
		@HasProviderFilter=@HasProviderFilter, @HasRepFilter=@HasRepFilter;

	-- Periods: every (Year,Month) present in #Base PLUS a (0,0) grand-total sentinel.
	DROP TABLE IF EXISTS #Periods;
	SELECT DISTINCT ESYear, ESMonth INTO #Periods FROM #Base
	UNION ALL SELECT 0, 0;

	-- ───────────────────────────────────────────────────────────────────────
	--  'I' Billed-Mismatch support: pre-aggregate Billed counts (same
	--  auto-detect technique as 16_VariantX_ExecutiveSummary_Aggregate.sql,
	--  applied to the filtered #Base/#Periods).
	-- ───────────────────────────────────────────────────────────────────────
	DROP TABLE IF EXISTS #BaseBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT AccessionNumber) AS BilledCount
	INTO #BaseBilledCount
	FROM #Base
	WHERE BilledUnbilled = 'Billed'
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT AccessionNumber) FROM #Base WHERE BilledUnbilled = 'Billed';

	DROP TABLE IF EXISTS #LisBilled;
	CREATE TABLE #LisBilled
	(
		Accession NVARCHAR(100) NOT NULL,
		ESYear    INT           NOT NULL,
		ESMonth   INT           NOT NULL
	);

	-- Reuses @AccCol / @DateCol / @NewStatusCol / @BillCategoryCol / @PanelCol / @ClinicCol / @ProviderCol / @RepCol
	-- detected in the shared column-detection block above.
	-- When @HasLisFilter = 1, dimension filters are also applied so the
	-- Billed-Mismatch count (row I) stays consistent with the filtered LIS rows.
	IF @AccCol IS NOT NULL AND @DateCol IS NOT NULL AND @NewStatusCol IS NOT NULL AND @BillCategoryCol IS NOT NULL
	BEGIN
		-- Period expression for #LisBilled buckets — keeps row-I (Billed Mismatch)
		-- period basis consistent with #Base and #LisOut:
		--   BilledDate mode → TRY_CAST([BilledDate] AS DATE), bounded by @BilledFrom/@BilledTo
		--   DOS mode        → TRY_CAST([DateOfCollection] AS DATE), bounded by Year/Month range
		DECLARE @LisBilledPeriodExpr NVARCHAR(200) =
			CASE WHEN @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
				 THEN N'TRY_CAST([' + @BilledDateCol + N'] AS DATE)'
				 ELSE N'TRY_CAST([' + @DateCol + N'] AS DATE)' END;

		DECLARE @LisBilledSql NVARCHAR(MAX) = N'
			INSERT INTO #LisBilled (Accession, ESYear, ESMonth)
			SELECT
				LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))),
				YEAR (' + @LisBilledPeriodExpr + N'),
				MONTH(' + @LisBilledPeriodExpr + N')
			FROM dbo.LIMSMaster
			WHERE ' + @LisBilledPeriodExpr + N' IS NOT NULL
			  AND NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N']))), '''') IS NOT NULL
			  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol + N']), ''''))) = ''Billable''
			  AND LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), ''''))) = ''Billed''';

		-- Date bounds differ by mode: BilledDate range (billed mode) vs Year/Month range (DOS mode).
		IF @UseBilledDate = 1 AND @BilledDateCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND (@iBilledFrom IS NULL OR ' + @LisBilledPeriodExpr + N' >= @iBilledFrom)
			  AND (@iBilledTo   IS NULL OR ' + @LisBilledPeriodExpr + N' <= @iBilledTo)';
		ELSE
			SET @LisBilledSql += N'
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @YearFrom), 'NULL') + N' IS NULL OR YEAR (' + @LisBilledPeriodExpr + N') >= ' + ISNULL(CONVERT(NVARCHAR(20), @YearFrom), '0') + N')
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @YearTo), 'NULL') + N' IS NULL OR YEAR (' + @LisBilledPeriodExpr + N') <= ' + ISNULL(CONVERT(NVARCHAR(20), @YearTo), '0') + N')
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @MonthFrom), 'NULL') + N' IS NULL OR MONTH(' + @LisBilledPeriodExpr + N') >= ' + ISNULL(CONVERT(NVARCHAR(20), @MonthFrom), '0') + N')
			  AND (' + ISNULL(CONVERT(NVARCHAR(20), @MonthTo), 'NULL') + N' IS NULL OR MONTH(' + @LisBilledPeriodExpr + N') <= ' + ISNULL(CONVERT(NVARCHAR(20), @MonthTo), '0') + N')';

		-- When LIS dimension filters are active, apply them here too for consistent row-I mismatch count.
		-- COLLATE DATABASE_DEFAULT prevents collation conflicts between LIMSMaster columns and parameters.
		IF @HasPanelFilter = 1 AND @PanelCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iPanels + '','') COLLATE DATABASE_DEFAULT) > 0';

		IF @HasClinicFilter = 1 AND @ClinicCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iClinics + '','') COLLATE DATABASE_DEFAULT) > 0';

		IF @HasProviderFilter = 1 AND @ProviderCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iProviders + '','') COLLATE DATABASE_DEFAULT) > 0';

		IF @HasRepFilter = 1 AND @RepCol IS NOT NULL
			SET @LisBilledSql += N'
			  AND CHARINDEX(('','' + LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @RepCol + N']), ''''))) + '','') COLLATE DATABASE_DEFAULT, ('','' + @iReps + '','') COLLATE DATABASE_DEFAULT) > 0';

		SET @LisBilledSql += N';';

		EXEC sp_executesql @LisBilledSql,
			N'@iPanels     NVARCHAR(MAX),
			  @iClinics    NVARCHAR(MAX),
			  @iProviders  NVARCHAR(MAX),
			  @iReps       NVARCHAR(MAX),
			  @iBilledFrom DATE,
			  @iBilledTo   DATE',
			@iPanels     = @Panels,
			@iClinics    = @Clinics,
			@iProviders  = @Providers,
			@iReps       = @Reps,
			@iBilledFrom = @BilledFrom,
			@iBilledTo   = @BilledTo;
	END

	DROP TABLE IF EXISTS #LisBilledCount;
	SELECT ESYear, ESMonth, COUNT(DISTINCT Accession) AS BilledCount
	INTO #LisBilledCount
	FROM #LisBilled
	GROUP BY ESYear, ESMonth
	UNION ALL
	SELECT 0, 0, COUNT(DISTINCT Accession) FROM #LisBilled;

	;WITH LisFinal AS
	(
		-- Reads from #LisOut which is populated by either the aggregate fast-path
		-- (no LIS-applicable filter) or the live LIMSMaster scan (filtered path).
		-- Grand-total (0,0) sentinel rows are already present in #LisOut.
		SELECT RowCode, Description, ESYear, ESMonth, MetricValue
		FROM #LisOut
	),
	PMS AS
	(
		-- F  No. of Billed Claims
		SELECT p.ESYear, p.ESMonth, 'F' AS RowCode, 'No. of Billed Claims' AS Description,
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled','Unbilled - PB')
		GROUP BY p.ESYear, p.ESMonth

		-- G  Unbilled Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'G', 'Unbilled Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus IN ('Unbilled','Unbilled - PB')
		GROUP BY p.ESYear, p.ESMonth

		-- H  Voided claims (spec gave no formula - see file 16 header note)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'H', 'Voided claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Voided'
		GROUP BY p.ESYear, p.ESMonth

		-- I  Billed Mismatches - LIS Accession Cannot be Matched
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'I', 'Billed Mismatches - LIS Accession Cannot be Matched',
			   CAST(ISNULL(bb.BilledCount, 0) - ISNULL(ll.BilledCount, 0) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #BaseBilledCount bb ON bb.ESYear = p.ESYear AND bb.ESMonth = p.ESMonth
		LEFT JOIN #LisBilledCount  ll ON ll.ESYear = p.ESYear AND ll.ESMonth = p.ESMonth

		-- J  No. of Fully Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'J', 'No. of Fully Paid Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- K  No. of Fully Patient Responsibility Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'K', 'No. of Fully Patient Responsibility Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility'
		GROUP BY p.ESYear, p.ESMonth

		-- L  No. of Patient Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'L', 'No. of Patient Paid Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment'
		GROUP BY p.ESYear, p.ESMonth

		-- M  No. of Adjusted/Written Off Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'M', 'No. of Adjusted/Written Off Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- N  No. of Partially Adjusted claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'N', 'No. of Partially Adjusted claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted'
		GROUP BY p.ESYear, p.ESMonth

		-- O  No. of Partially Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'O', 'No. of Partially Paid Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- P  No. of Insurance Balance Claims (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P', 'No. of Insurance Balance Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Denied','No Response','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.1  No. of Fully Denied Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.1', '  No. of Fully Denied Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- P.2  No. of Partially Denied Claims (Partially Adjusted + Partially Denied)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.2', '  No. of Partially Denied Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied')
		GROUP BY p.ESYear, p.ESMonth

		-- P.3  No. of No Response from Payor Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'P.3', '  No. of No Response from Payor Claims',
			   CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2))
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	),
	Cash AS
	(
		-- Q  Total Billed ($)
		SELECT p.ESYear, p.ESMonth, 'Q' AS RowCode, 'Total Billed ($)' AS Description,
			   ISNULL(SUM(b.ChargeAmount), 0) AS MetricValue
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Unbilled','Unbilled - PB','Billed Amount 0')
		GROUP BY p.ESYear, p.ESMonth

		-- R  Unbilled Claims ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'R', 'Unbilled Claims ($)',
			   ISNULL(SUM(b.ChargeAmount), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Unbilled'
		GROUP BY p.ESYear, p.ESMonth

		-- S  Insurance Payment ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'S', 'Insurance Payment ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.ClaimStatus = 'Fully Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- T  Patient Responsibility ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'T', 'Patient Responsibility ($)',
			   ISNULL(SUM(b.PatientBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- U  Adjustments / Write Off ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'U', 'Adjustments / Write Off ($)',
			   ISNULL(SUM(b.InsuranceAdjustments), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- V  Patient Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'V', 'Patient Paid ($)',
			   ISNULL(SUM(b.PatientPayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
		GROUP BY p.ESYear, p.ESMonth

		-- W  Partially Paid ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'W', 'Partially Paid ($)',
			   ISNULL(SUM(b.InsurancePayment), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid'
		GROUP BY p.ESYear, p.ESMonth

		-- X  Insurance Balance ($) (parent)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X', 'Insurance Balance ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0')
		GROUP BY p.ESYear, p.ESMonth

		-- X.1  Denials ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.1', '  Denials ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied'
		GROUP BY p.ESYear, p.ESMonth

		-- X.2  Partially Denied ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.2', '  Partially Denied ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed'
						   AND b.ClaimStatus IN ('Partially Denied','Partially Paid','Partially Adjusted','Patient Responsibility')
		GROUP BY p.ESYear, p.ESMonth

		-- X.3  No Response from Payor ($)
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'X.3', '  No Response from Payor ($)',
			   ISNULL(SUM(b.InsuranceBalance), 0)
		FROM #Periods p
		LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
						   AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response'
		GROUP BY p.ESYear, p.ESMonth
	),
	AvgRows AS
	(
		-- Y  Average Payment ($) - Total Pay/Billed Claims
		SELECT p.ESYear, p.ESMonth, 'Y' AS RowCode, 'Average Payment ($) - Total Pay/Billed Claims' AS Description,
			   ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' OR (b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid') THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled','Unbilled - PB') THEN b.AccessionNumber END), 0), 2), 0) AS MetricValue
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- Z  Average Payment ($) - Total Pay/Paid Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
			   ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- AA  Average Payment ($) - Total Pay/Adjudicated Claims
		UNION ALL
		SELECT p.ESYear, p.ESMonth, 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			   ISNULL(ROUND(
						(SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' OR (b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid') THEN b.InsurancePayment ELSE 0 END)
						 + SUM(CASE WHEN b.BilledUnbilled = 'Billed' THEN b.PatientPayment ELSE 0 END))
						/ NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid'
													   OR (b.BilledUnbilled = 'Billed'
													       AND b.ClaimStatus IN ('Fully Adjusted','Patient Responsibility','Partially Paid','Fully Denied','Partially Denied'))
												  THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Periods p LEFT JOIN #Base b ON (p.ESYear=0 OR (b.ESYear=p.ESYear AND b.ESMonth=p.ESMonth))
		GROUP BY p.ESYear, p.ESMonth

		-- Weighted annual Y/Z/AA rows (ESMonth=0). These prevent the UI
		-- from adding monthly averages for filtered results.
		UNION ALL
		SELECT b.ESYear, 0, 'Y', 'Average Payment ($) - Total Pay/Billed Claims',
			   ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' OR (b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid') THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled','Unbilled - PB') THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Base b
		WHERE b.ESYear > 0
		GROUP BY b.ESYear

		UNION ALL
		SELECT b.ESYear, 0, 'Z', 'Average Payment ($) - Total Pay/Paid Claims',
			   ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.InsurancePayment ELSE 0 END)
					 / NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid' THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Base b
		WHERE b.ESYear > 0
		GROUP BY b.ESYear

		UNION ALL
		SELECT b.ESYear, 0, 'AA', 'Average Payment ($) - Total Pay/Adjudicated Claims',
			   ISNULL(ROUND(
						(SUM(CASE WHEN b.ClaimStatus = 'Fully Paid' OR (b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid') THEN b.InsurancePayment ELSE 0 END)
						 + SUM(CASE WHEN b.BilledUnbilled = 'Billed' THEN b.PatientPayment ELSE 0 END))
						/ NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus = 'Fully Paid'
													   OR (b.BilledUnbilled = 'Billed'
													       AND b.ClaimStatus IN ('Fully Adjusted','Patient Responsibility','Partially Paid','Fully Denied','Partially Denied'))
												  THEN b.AccessionNumber END), 0), 2), 0)
		FROM #Base b
		WHERE b.ESYear > 0
		GROUP BY b.ESYear
	)
	SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue
	FROM
	(
		SELECT RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth, MetricValue FROM LisFinal
		UNION ALL
		SELECT RowCode, 'PMS', Description, ESYear, ESMonth, MetricValue FROM PMS
		UNION ALL
		SELECT RowCode, 'Cash', Description, ESYear, ESMonth, MetricValue FROM Cash
		UNION ALL
		SELECT RowCode, 'Avg', Description, ESYear, ESMonth, MetricValue FROM AvgRows
	) all_rows
	ORDER BY BillYear, BillMonth, RowCode;

	DROP TABLE IF EXISTS #LisOut;
	DROP TABLE IF EXISTS #LisFiltered;
	DROP TABLE IF EXISTS #Lis;
	DROP TABLE IF EXISTS #Base;
	DROP TABLE IF EXISTS #Periods;
	DROP TABLE IF EXISTS #BaseBilledCount;
	DROP TABLE IF EXISTS #LisBilled;
	DROP TABLE IF EXISTS #LisBilledCount;
END;
GO

/* -----------------------------------------------------------------------------
   ES 4. usp_GetVarX_ExecutiveSummary_Detail - deployed version; Payer Type column falls back to VariantX
   'PlanType' (was always blank).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_ExecutiveSummary_Detail
(
    @Category NVARCHAR(10),
    @RowCode  NVARCHAR(20),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PatientExpr NVARCHAR(500);
    IF COL_LENGTH(N'dbo.ClaimLevelData', N'PatientName') IS NOT NULL
        SET @PatientExpr = N'LTRIM(RTRIM(ISNULL(PatientName, '''')))';
    ELSE IF COL_LENGTH(N'dbo.ClaimLevelData', N'PatientFirstName') IS NOT NULL
         AND COL_LENGTH(N'dbo.ClaimLevelData', N'PatientLastName') IS NOT NULL
        SET @PatientExpr = N'LTRIM(RTRIM(ISNULL(PatientFirstName, ''''))) + '' '' + LTRIM(RTRIM(ISNULL(PatientLastName, '''')))';
    ELSE IF COL_LENGTH(N'dbo.ClaimLevelData', N'PatientFirstName') IS NOT NULL
        SET @PatientExpr = N'LTRIM(RTRIM(ISNULL(PatientFirstName, '''')))';
    ELSE
        SET @PatientExpr = N'CAST('''' AS NVARCHAR(500))';

    DECLARE @ClinicExpr NVARCHAR(400) =
        CASE
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'ClinicName') IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(ClinicName, '''')))'
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'Facility') IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(Facility, '''')))'
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'ServiceLocationName') IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(ServiceLocationName, '''')))'
            ELSE N'CAST('''' AS NVARCHAR(500))'
        END;

    DECLARE @ProviderExpr NVARCHAR(400) =
        CASE
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'BillingProvider') IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(BillingProvider, '''')))'
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'ReferringProvider') IS NOT NULL
                THEN N'LTRIM(RTRIM(ISNULL(ReferringProvider, '''')))'
            ELSE N'CAST('''' AS NVARCHAR(500))'
        END;

    DECLARE @PayerTypeExpr NVARCHAR(400) =
        CASE
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'PayerType') IS NOT NULL
                THEN N'ISNULL(LTRIM(RTRIM(PayerType)), '''')'
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'PlanType') IS NOT NULL
                THEN N'ISNULL(LTRIM(RTRIM(PlanType)), '''')'
            ELSE N'CAST('''' AS NVARCHAR(200))'
        END;

    DECLARE @BillStatusExpr NVARCHAR(400) =
        CASE
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'BillStatus') IS NOT NULL
                THEN N'ISNULL(BillStatus, '''')'
            ELSE N'CASE WHEN LTRIM(RTRIM(ISNULL(ClaimStatus, ''''))) IN (''Unbilled'',''Unbilled - PB'') THEN ''Unbilled'' ELSE ''Billed'' END'
        END;

    DECLARE @FirstBilledExpr NVARCHAR(400) =
        CASE
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'FirstBilledDate') IS NOT NULL
                THEN N'FirstBilledDate'
            ELSE N'CAST(NULL AS NVARCHAR(100))'
        END;

    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        AccessionNumber       NVARCHAR(100)   NULL,
        PatientName           NVARCHAR(500)   NOT NULL,
        PayerName             NVARCHAR(500)   NOT NULL,
        Panelname             NVARCHAR(500)   NOT NULL,
        ClinicName            NVARCHAR(500)   NOT NULL,
        BillingProvider       NVARCHAR(500)   NOT NULL,
        DateofService         NVARCHAR(100)   NULL,
        FirstBilledDate       NVARCHAR(100)   NULL,
        BilledUnbilled        NVARCHAR(200)   NOT NULL,
        ClaimStatus           NVARCHAR(200)   NOT NULL,
        PayerType             NVARCHAR(200)   NOT NULL,
        ChargeAmount          DECIMAL(18,2)   NOT NULL,
        InsurancePayment      DECIMAL(18,2)   NOT NULL,
        PatientPayment        DECIMAL(18,2)   NOT NULL,
        InsuranceBalance      DECIMAL(18,2)   NOT NULL,
        PatientBalance        DECIMAL(18,2)   NOT NULL,
        InsuranceAdjustments  DECIMAL(18,2)   NOT NULL,
        PatientAdjustments    DECIMAL(18,2)   NOT NULL
    );

    DECLARE @sql NVARCHAR(MAX) = N'
    INSERT INTO #Base
    SELECT
        AccessionNumber,
        ' + @PatientExpr + N' AS PatientName,
        LTRIM(RTRIM(ISNULL(PayerName, ''''))) AS PayerName,
        ISNULL(LTRIM(RTRIM(Panelname)), '''') AS Panelname,
        ' + @ClinicExpr + N' AS ClinicName,
        ' + @ProviderExpr + N' AS BillingProvider,
        DateofService,
        ' + @FirstBilledExpr + N' AS FirstBilledDate,
        ' + @BillStatusExpr + N' AS BilledUnbilled,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '''') AS ClaimStatus,
        ' + @PayerTypeExpr + N' AS PayerType,
        ISNULL(TRY_CAST(ChargeAmount         AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(InsurancePayment     AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(PatientPayment       AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(InsuranceBalance     AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(PatientBalance       AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(InsuranceAdjustments AS DECIMAL(18,2)), 0),
        ISNULL(TRY_CAST(PatientAdjustments   AS DECIMAL(18,2)), 0)
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(AccessionNumber)), '''') IS NOT NULL
      AND (@Year = 0  OR YEAR (TRY_CAST(DateofService AS DATE)) = @Year)
      AND (@Month = 0 OR MONTH(TRY_CAST(DateofService AS DATE)) = @Month);';

    EXEC sys.sp_executesql @sql,
        N'@Year INT, @Month INT',
        @Year = @Year, @Month = @Month;

    IF @Category = 'PMS'
    BEGIN
        SELECT DISTINCT
            b.AccessionNumber AS VisitNumber,
            b.PatientName,
            b.PayerName,
            b.Panelname        AS PanelName,
            b.ClinicName,
            b.BillingProvider,
            b.DateofService,
            b.FirstBilledDate,
            b.BilledUnbilled,
            b.ClaimStatus,
            b.PayerType,
            b.ChargeAmount,
            b.InsurancePayment,
            b.PatientPayment,
            b.InsuranceBalance,
            b.PatientBalance,
            b.InsuranceAdjustments,
            b.PatientAdjustments
        FROM #Base b
        WHERE
               (@RowCode = 'F'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled'))
            OR (@RowCode = 'G'    AND b.ClaimStatus IN ('Unbilled','Unbilled - PB'))
            OR (@RowCode = 'H'    AND b.ClaimStatus = 'Voided')
            OR (@RowCode = 'I'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','Unbilled'))
            OR (@RowCode = 'J'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
            OR (@RowCode = 'K'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility')
            OR (@RowCode = 'L'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment')
            OR (@RowCode = 'M'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted')
            OR (@RowCode = 'N'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted')
            OR (@RowCode = 'O'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
            OR (@RowCode = 'P'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Denied','No Response','Partially Denied'))
            OR (@RowCode = 'P.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied')
            OR (@RowCode = 'P.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Adjusted','Partially Denied'))
            OR (@RowCode = 'P.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
        ORDER BY b.DateofService, b.AccessionNumber;
    END
    ELSE IF @Category = 'Cash'
    BEGIN
        SELECT DISTINCT
            b.AccessionNumber AS VisitNumber,
            b.PatientName,
            b.PayerName,
            b.Panelname        AS PanelName,
            b.ClinicName,
            b.BillingProvider,
            b.DateofService,
            b.FirstBilledDate,
            b.BilledUnbilled,
            b.ClaimStatus,
            b.PayerType,
            b.ChargeAmount,
            b.InsurancePayment,
            b.PatientPayment,
            b.InsuranceAdjustments,
            b.PatientAdjustments,
            b.InsuranceBalance,
            b.PatientBalance
        FROM #Base b
        WHERE
               (@RowCode = 'Q'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0'))
            OR (@RowCode = 'R'    AND b.ClaimStatus = 'Unbilled')
            OR (@RowCode = 'S'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
            OR (@RowCode = 'T'    AND b.BilledUnbilled = 'Billed')
            OR (@RowCode = 'U'    AND b.BilledUnbilled = 'Billed')
            OR (@RowCode = 'V'    AND b.BilledUnbilled = 'Billed')
            OR (@RowCode = 'W'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
            OR (@RowCode = 'X'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0'))
            OR (@RowCode = 'X.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Denied')
            OR (@RowCode = 'X.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Denied','Partially Paid','Partially Adjusted','Patient Responsibility'))
            OR (@RowCode = 'X.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
        ORDER BY b.DateofService, b.AccessionNumber;
    END

    DROP TABLE IF EXISTS #Base;
END;
GO

/* -----------------------------------------------------------------------------
   ES 5. usp_GetExecutiveSummaryDetail_LIS (LIS drill rows B..E.6) - deployed version; status column also
   matches 'SampleStatus' (drill returned no rows), panel also matches 'TestType', payer 'PrimaryInsurance',
   provider 'PhysicianName'.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LIS
(
    @RowCode NVARCHAR(350),
    @Year    INT = 0,
    @Month   INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS DateOfService,
            CAST(NULL AS NVARCHAR(300)) AS PanelName,
            CAST(NULL AS NVARCHAR(100)) AS NewStatus,
            CAST(NULL AS NVARCHAR(100)) AS BillCategory,
            CAST(NULL AS NVARCHAR(100)) AS ResultStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    -- ───────────────────────────────────────────────────────────────────────
    --  Auto-detect dbo.LIMSMaster column names for each logical field
    --  (identical candidate lists/order to 19_VariantX_ExecutiveSummary_LIS_Alt.sql).
    -- ───────────────────────────────────────────────────────────────────────
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('DateOfCollection','RequestCollectDate','CollectionDate','DateofService','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'DateOfCollection'   THEN 0
            WHEN 'RequestCollectDate' THEN 1
            WHEN 'CollectionDate'     THEN 2
            WHEN 'DateofService'      THEN 3
            WHEN 'ServiceDate'        THEN 4
            WHEN 'AccessionDate'      THEN 5
            ELSE 6 END);

    DECLARE @NewStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('NewStatus','Status','SampleStatus')
        ORDER BY CASE name WHEN 'NewStatus' THEN 0 WHEN 'Status' THEN 1 WHEN 'SampleStatus' THEN 2 ELSE 3 END);

    DECLARE @BillCategoryCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillCategory','Bill_Category','BillingCategory','BillStatus')
        ORDER BY CASE name WHEN 'BillCategory' THEN 0 WHEN 'Bill_Category' THEN 1 WHEN 'BillingCategory' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

    DECLARE @ResultStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ResultStatus','Result_Status','ResultedStatus','RessultedStatus','IsResulted')
        ORDER BY CASE name
            WHEN 'ResultStatus' THEN 0 WHEN 'Result_Status' THEN 1
            WHEN 'ResultedStatus' THEN 2 WHEN 'RessultedStatus' THEN 3
            WHEN 'IsResulted' THEN 4 ELSE 5 END);

    -- Extra display-only columns (auto-detected, fall back to '').
    DECLARE @PanelCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelCategory','PanelName','Panelname','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname','TestType')
        ORDER BY CASE name
            WHEN 'PanelCategory' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'TestPanelName' THEN 3 WHEN 'TestPanelname' THEN 4 WHEN 'TestPanel' THEN 5
            WHEN 'Panel' THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName' THEN 8 WHEN 'TestType' THEN 9 ELSE 10 END);

    DECLARE @PatientCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PatientName','Patient_Name','Patient')
        ORDER BY CASE name WHEN 'PatientName' THEN 0 WHEN 'Patient_Name' THEN 1 WHEN 'Patient' THEN 2 ELSE 3 END);

    DECLARE @PayerCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PayerName','InsuranceName','Payer','PrimaryPayer','InsurancePayer','InsuranceCategory','PrimaryInsurance')
        ORDER BY CASE name WHEN 'PayerName' THEN 0 WHEN 'InsuranceName' THEN 1 WHEN 'Payer' THEN 2 WHEN 'PrimaryPayer' THEN 3 WHEN 'InsurancePayer' THEN 4 ELSE 5 END);

    DECLARE @ClinicCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ClinicName','Clinic','FacilityName','Facility')
        ORDER BY CASE name WHEN 'ClinicName' THEN 0 WHEN 'Clinic' THEN 1 WHEN 'FacilityName' THEN 2 ELSE 3 END);

    DECLARE @ProviderCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingProvider','Provider','OrderingProvider','RenderingProvider','PhysicianName')
        ORDER BY CASE name WHEN 'BillingProvider' THEN 0 WHEN 'Provider' THEN 1 WHEN 'OrderingProvider' THEN 2 ELSE 3 END);

    IF @AccCol IS NULL OR @DateCol IS NULL OR @NewStatusCol IS NULL OR @BillCategoryCol IS NULL OR @ResultStatusCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(100)) AS Accession,
            CAST(NULL AS DATE)          AS DateOfService,
            CAST(NULL AS NVARCHAR(300)) AS PanelName,
            CAST(NULL AS NVARCHAR(100)) AS NewStatus,
            CAST(NULL AS NVARCHAR(100)) AS BillCategory,
            CAST(NULL AS NVARCHAR(100)) AS ResultStatus,
            CAST(NULL AS NVARCHAR(300)) AS PatientName,
            CAST(NULL AS NVARCHAR(300)) AS PayerName,
            CAST(NULL AS NVARCHAR(300)) AS ClinicName,
            CAST(NULL AS NVARCHAR(300)) AS BillingProvider
        WHERE 1 = 0;
        RETURN;
    END

    DECLARE @AccExpr      NVARCHAR(300) = N'LTRIM(RTRIM(CONVERT(NVARCHAR(100), [' + @AccCol + N'])))';
    DECLARE @DateExpr     NVARCHAR(300) = N'TRY_CAST([' + @DateCol + N'] AS DATE)';
    DECLARE @NewStatusExpr    NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @NewStatusCol    + N']), '''')))';
    DECLARE @BillCategoryExpr NVARCHAR(300) = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @BillCategoryCol + N']), '''')))';
    DECLARE @PanelExpr    NVARCHAR(400) = CASE WHEN @PanelCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PanelCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @PatientExpr  NVARCHAR(400) = CASE WHEN @PatientCol  IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PatientCol  + N']), '''')))' ELSE N'''''' END;
    DECLARE @PayerExpr    NVARCHAR(400) = CASE WHEN @PayerCol    IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @PayerCol    + N']), '''')))' ELSE N'''''' END;
    DECLARE @ClinicExpr   NVARCHAR(400) = CASE WHEN @ClinicCol   IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ClinicCol   + N']), '''')))' ELSE N'''''' END;
    DECLARE @ProviderExpr NVARCHAR(400) = CASE WHEN @ProviderCol IS NOT NULL THEN N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), [' + @ProviderCol + N']), '''')))' ELSE N'''''' END;

    -- IsResulted is sometimes a bit/flag column rather than a status string;
    -- normalize it to 'Resulted' / 'Not Resulted' (same as file 19) so the
    -- D.1 filter (ResultStatus = 'Resulted') works regardless of type.
    DECLARE @ResultExpr NVARCHAR(400);
    IF @ResultStatusCol = 'IsResulted'
        SET @ResultExpr = N'(CASE WHEN TRY_CAST([' + @ResultStatusCol + N'] AS INT) = 1 THEN ''Resulted''
                                   WHEN CONVERT(NVARCHAR(20), [' + @ResultStatusCol + N']) IN (''Y'',''Yes'',''True'',''Resulted'') THEN ''Resulted''
                                   ELSE ''Not Resulted'' END)';
    ELSE
        SET @ResultExpr = N'LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), [' + @ResultStatusCol + N']), '''')))';

    -- ───────────────────────────────────────────────────────────────────────
    --  Pull the matching LIMSMaster rows for the requested period into a
    --  real temp table (must be CREATE TABLE, not SELECT...INTO inside
    --  sp_executesql, so it survives past the EXEC call).
    -- ───────────────────────────────────────────────────────────────────────
    DROP TABLE IF EXISTS #LisBase;
    CREATE TABLE #LisBase
    (
        Accession       NVARCHAR(100) NOT NULL,
        DateOfService   DATE          NULL,
        PanelName       NVARCHAR(300) NOT NULL,
        NewStatus       NVARCHAR(100) NOT NULL,
        BillCategory    NVARCHAR(100) NOT NULL,
        ResultStatus    NVARCHAR(100) NOT NULL,
        PatientName     NVARCHAR(300) NOT NULL,
        PayerName       NVARCHAR(300) NOT NULL,
        ClinicName      NVARCHAR(300) NOT NULL,
        BillingProvider NVARCHAR(300) NOT NULL,
        ESYear          INT           NOT NULL,
        ESMonth         INT           NOT NULL
    );

    DECLARE @LisSql NVARCHAR(MAX) = N'
        INSERT INTO #LisBase
            (Accession, DateOfService, PanelName, NewStatus, BillCategory, ResultStatus,
             PatientName, PayerName, ClinicName, BillingProvider, ESYear, ESMonth)
        SELECT
            ' + @AccExpr          + N',
            ' + @DateExpr         + N',
            ' + @PanelExpr        + N',
            ' + @NewStatusExpr    + N',
            ' + @BillCategoryExpr + N',
            ' + @ResultExpr       + N',
            ' + @PatientExpr      + N',
            ' + @PayerExpr        + N',
            ' + @ClinicExpr       + N',
            ' + @ProviderExpr     + N',
            YEAR (' + @DateExpr + N'),
            MONTH(' + @DateExpr + N')
        FROM dbo.LIMSMaster
        WHERE ' + @DateExpr + N' IS NOT NULL
          AND NULLIF(' + @AccExpr + N', '''') IS NOT NULL
          AND (@iYear  = 0 OR YEAR (' + @DateExpr + N') = @iYear)
          AND (@iMonth = 0 OR MONTH(' + @DateExpr + N') = @iMonth);';

    EXEC sp_executesql @LisSql, N'@iYear INT, @iMonth INT', @iYear = @Year, @iMonth = @Month;

    SELECT
        b.Accession        AS Accession,
        b.DateOfService     AS DateOfService,
        b.PanelName         AS PanelName,
        b.NewStatus         AS NewStatus,
        b.BillCategory      AS BillCategory,
        b.ResultStatus      AS ResultStatus,
        b.PatientName       AS PatientName,
        b.PayerName         AS PayerName,
        b.ClinicName        AS ClinicName,
        b.BillingProvider   AS BillingProvider
    FROM #LisBase b
    WHERE
        -- A  Total Samples
        (@RowCode = 'A')
     OR -- B  Billable Samples
        (@RowCode = 'B'   AND b.NewStatus = 'Billable')
     OR -- C  Billed
        (@RowCode = 'C'   AND b.NewStatus = 'Billable' AND b.BillCategory = 'Billed')
     OR -- D  Unbilled
        (@RowCode = 'D'   AND b.NewStatus = 'Billable' AND b.BillCategory = 'Not Billed')
     OR -- D.1  Resulted yet to be billed
        (@RowCode = 'D.1' AND b.ResultStatus = 'Resulted' AND b.NewStatus = 'Billable' AND b.BillCategory = 'Not Billed')
     OR -- E  Other Samples
        (@RowCode = 'E'   AND b.NewStatus <> 'Billable')
     OR -- E.1  Client Bill
        (@RowCode = 'E.1' AND b.NewStatus = 'Client Bill')
     OR -- E.2  Self Pay
        (@RowCode = 'E.2' AND b.NewStatus = 'Self Pay')
     OR -- E.3  System Test
        (@RowCode = 'E.3' AND b.NewStatus = 'System Test')
     OR -- E.4  Deleted/Rejected
        (@RowCode = 'E.4' AND b.NewStatus = 'Deleted/Rejected')
     OR -- E.5  CIP/Pending
        (@RowCode = 'E.5' AND b.NewStatus = 'CIP/Pending')
     OR -- E.6  Yet to be validated
        (@RowCode = 'E.6' AND b.NewStatus = 'Yet to be validated')
     OR -- Fallback: unrecognized RowCode -> return everything in the period
        (@RowCode NOT IN ('A','B','C','D','D.1','E','E.1','E.2','E.3','E.4','E.5','E.6'))
    ORDER BY b.DateOfService, b.Accession;

    DROP TABLE IF EXISTS #LisBase;
END;
GO

