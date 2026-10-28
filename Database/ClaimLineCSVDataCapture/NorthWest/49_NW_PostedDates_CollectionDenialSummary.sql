/* =============================================================================
   NorthWest - Collection Summary / Denial Summary on the posted-date fields
   File     : 49_NW_PostedDates_CollectionDenialSummary.sql
   Database : NWL_LRN
   Requires : 40_NW_ClaimLevelData_BilledUnbilled.sql (NWLCollectionPostedDate,
              NWLDenialPostedDate), 39 / 42 / 45 / 48 NorthWest scripts.

   Collection Summary (Claim Level, Claim Count = unique ClaimID)
     Monthly           InsurancePayment > 0; PanelType + Top 5 PayerName_Raw;
                       columns = NWLCollectionPostedDate month (was CheckDate).
     Weekly            InsurancePayment > 0; PanelType + Top 5 PayerName_Raw;
                       4 Thursday-Wednesday weeks. A claim's week:
                         PostedWeek "Week 1".."Week 4"            -> that week (Week 1 = oldest)
                         PostedWeek "MM.dd.yyyy - MM.dd.yyyy"     -> the week holding its start
                         otherwise                                -> the week of its CheckDate
     Payer vs Payment  InsurancePayment > 0 AND NWLCollectionPostedDate is a date;
                       PayerName_Raw x NWLCollectionPostedDate year (stored by month).
     Other tabs are unchanged (39 / 42 / 47).

   Denial Summary (Claim Level; DenialCodeNormalized not blank, InsuranceBalance > 0)
     Monthly           columns = NWLDenialPostedDate month (was CheckDate).
     Weekly            PostedWeek as above, otherwise the week of NWLDenialPostedDate.
     @DenialFrom / @DenialTo on the Monthly / Weekly engine filter NWLDenialPostedDate;
     the other denial tabs keep their CheckDate filter.
     Tiles: UndatedGroups / LoadedThrough use NWLDenialPostedDate.
     The snapshot tables, refresh SPs and read SPs of 45_NW_DenialSummary.sql are kept
     (ClaimLineCSVDataCapture refreshes them after each new claim file).

   The 12/31/1899 placeholder date is treated as blank, as in fn_NW_CS_Claims.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'49_NW_PostedDates_CollectionDenialSummary.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'NWLCollectionPostedDate') IS NULL
   OR COL_LENGTH(N'dbo.ClaimLevelData', N'NWLDenialPostedDate') IS NULL
BEGIN
    RAISERROR(N'NWLCollectionPostedDate / NWLDenialPostedDate missing - run 40_NW_ClaimLevelData_BilledUnbilled.sql first.', 16, 1);
    SET NOEXEC ON;
END;
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

/* =============================================================================
   COLLECTION SUMMARY
   ============================================================================= */

/* -----------------------------------------------------------------------------
   Shared claim rows + dashboard filters (adds CollectionPosted and PostedWeek)
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_CS_Claims
(
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE,
    @CheckDateFrom DATE,
    @CheckDateTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimKey          = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        n.PayerName,
        n.PanelName,
        ClaimStatus       = ISNULL(NULLIF(LTRIM(RTRIM(c.ClaimStatus)), N''), N'(blank)'),
        Adjudicated       = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30          = LTRIM(RTRIM(c.Bucket30)),
        Bucket60          = LTRIM(RTRIM(c.Bucket60)),
        Aging             = NULLIF(LTRIM(RTRIM(c.Aging)), N''),
        d.Dos,
        d.CheckDt,
        d.FirstBill,
        d.ChargeEntered,
        d.CollectionPosted,
        PostedWeek        = NULLIF(LTRIM(RTRIM(c.PostedWeek)), N''),
        BilledUnbilled    = LTRIM(RTRIM(c.BilledUnbilled)),
        InsPay            = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        ChargeAmt         = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct        = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance        = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        PatientBalance    = ISNULL(TRY_CAST(c.PatientBalance   AS DECIMAL(18,2)), 0),
        CptCode           = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''), N'(blank)'),
        ReferringProvider = NULLIF(LTRIM(RTRIM(c.ReferringProvider)), N'')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.PanelType)),     N''), N'Unknown')) n
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateOfService,   101), TRY_CAST(c.DateOfService   AS DATE)),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate,       101), TRY_CAST(c.CheckDate       AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE)),
        ChargeEntered = COALESCE(TRY_CONVERT(DATE, c.ChargeEnteredDate, 101), TRY_CAST(c.ChargeEnteredDate AS DATE)),
        CollectionPosted = TRY_CONVERT(DATE, c.NWLCollectionPostedDate, 101)) p
    -- 12/31/1899 is the file's blank-date placeholder.
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        CheckDt   = CASE WHEN p.CheckDt   >= '19010101' THEN p.CheckDt   END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END,
        ChargeEntered = CASE WHEN p.ChargeEntered >= '19010101' THEN p.ChargeEntered END,
        CollectionPosted = CASE WHEN p.CollectionPosted >= '19010101' THEN p.CollectionPosted END) d
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR d.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR d.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR d.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR d.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR d.CheckDt   >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR d.CheckDt   <= @CheckDateTo);
GO

/* -----------------------------------------------------------------------------
   1. Monthly - PanelType + payers (the app shows PayerRank 1-5) x
      NWLCollectionPostedDate month. Unique claim = Source + ClaimID (see script 48).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(c.PanelType,     'Unknown')))                AS PanelName,
        LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown')))                AS PayerName,
        YEAR (p.PostedDt)                                               AS BillYear,
        MONTH(p.PostedDt)                                               AS BillMonth,
        COUNT(DISTINCT CASE WHEN NULLIF(LTRIM(RTRIM(c.ClaimID)), '') IS NOT NULL
                            THEN CONCAT(UPPER(LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(c.AdditionalFields, 'Source'), '')))),
                                        N'|', LTRIM(RTRIM(c.ClaimID))) END) AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2))), 0)   AS InsurancePayment
    INTO #raw
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT PostedDt = TRY_CONVERT(DATE, c.NWLCollectionPostedDate, 101)) p
    WHERE ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND p.PostedDt >= '19010101'
    GROUP BY
        LTRIM(RTRIM(ISNULL(c.PanelType,     'Unknown'))),
        LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown'))),
        YEAR (p.PostedDt),
        MONTH(p.PostedDt);

    SELECT
        PanelName, PayerName,
        DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
    INTO #ranks
    FROM #raw
    GROUP BY PanelName, PayerName;

    TRUNCATE TABLE dbo.NW_CS_MonthlyClaimVolume;
    INSERT INTO dbo.NW_CS_MonthlyClaimVolume
        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),
           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()
    FROM #raw r
    JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName
    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;

    DROP TABLE IF EXISTS #raw;
    DROP TABLE IF EXISTS #ranks;
    PRINT 'usp_RefreshNW_CS_MonthlyClaimVolume completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_MonthlyClaimVolume
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
        FROM    dbo.NW_CS_MonthlyClaimVolume
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
            LTRIM(RTRIM(ISNULL(c.PanelType,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (p.PostedDt)                                AS BillYear,
            MONTH(p.PostedDt)                                AS BillMonth,
            COUNT(DISTINCT CASE WHEN NULLIF(LTRIM(RTRIM(c.ClaimID)), '') IS NOT NULL
                                THEN CONCAT(UPPER(LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(c.AdditionalFields, 'Source'), '')))),
                                            N'|', LTRIM(RTRIM(c.ClaimID))) END) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData c
        CROSS APPLY (SELECT PostedDt = TRY_CONVERT(DATE, c.NWLCollectionPostedDate, 101)) p
        WHERE ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND p.PostedDt >= '19010101'
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(c.PanelType,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(c.DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(c.DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(c.FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(c.CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(c.CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(c.PanelType,     'Unknown'))),
            LTRIM(RTRIM(ISNULL(c.PayerName_Raw, 'Unknown'))),
            YEAR (p.PostedDt),
            MONTH(p.PostedDt)
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
   2. Weekly - PanelType + Top 5 payers; four Thursday-Wednesday weeks, Week 4 ending
      on the Wednesday on/after the billed week-range end date (latest CheckDate when
      there is no week folder). Week = PostedWeek, otherwise the CheckDate week.
      Every payer is returned so panel totals include all payers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_WeeklyClaimVolume
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment,
               AveragePaidAmount = CAST(InsurancePayment / NULLIF(NoOfClaims, 0) AS DECIMAL(18,2))
        FROM dbo.NW_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    DECLARE @Anchor DATE = dbo.fn_NW_CS_LatestWeekFolderEnd();
    IF @Anchor IS NULL
        SELECT @Anchor = MAX(CheckDt)
        FROM dbo.fn_NW_CS_Claims(NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL)
        WHERE InsPay > 0 AND CheckDt <= CAST(GETDATE() AS DATE);

    -- 1900-01-03 was a Wednesday.
    DECLARE @W4End   DATE = DATEADD(DAY, (7 - DATEDIFF(DAY, '19000103', @Anchor) % 7) % 7, @Anchor);
    DECLARE @W1Start DATE = DATEADD(DAY, -27, @W4End);

    SELECT c.PanelName, c.PayerName,
           WeekKey = wk.WeekIdx,
           c.ClaimKey, c.InsPay
    INTO #w
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) c
    CROSS APPLY (SELECT PostedStart = TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(
                            LEFT(c.PostedWeek, NULLIF(CHARINDEX(N'-', c.PostedWeek), 0) - 1))), N'.', N'/'), 101)) pw
    CROSS APPLY (SELECT WeekIdx = CASE
                            WHEN c.PostedWeek LIKE N'Week [1-4]'
                                THEN CAST(RIGHT(c.PostedWeek, 1) AS INT)
                            WHEN pw.PostedStart BETWEEN @W1Start AND @W4End
                                THEN 4 - DATEDIFF(DAY, pw.PostedStart, @W4End) / 7
                            WHEN c.PostedWeek IS NULL AND c.CheckDt BETWEEN @W1Start AND @W4End
                                THEN 4 - DATEDIFF(DAY, c.CheckDt, @W4End) / 7
                         END) wk
    WHERE c.InsPay > 0
      AND wk.WeekIdx IS NOT NULL
    OPTION (RECOMPILE);

    SELECT PanelName, PayerName, WeekKey,
           NoOfClaims       = COUNT(DISTINCT ClaimKey),
           InsurancePayment = SUM(InsPay)
    INTO #a
    FROM #w
    GROUP BY PanelName, PayerName, WeekKey;

    SELECT PanelName, PayerName,
           PayerRank = ROW_NUMBER() OVER (PARTITION BY PanelName
                                          ORDER BY SUM(NoOfClaims) DESC, SUM(InsurancePayment) DESC, PayerName)
    INTO #r
    FROM #a
    GROUP BY PanelName, PayerName;

    SELECT a.PanelName,
           a.PayerName,
           PayerRank         = CAST(CASE WHEN r.PayerRank > 255 THEN 255 ELSE r.PayerRank END AS TINYINT),
           WeekKey           = CAST(a.WeekKey AS TINYINT),
           WeekStart         = DATEADD(DAY, -6 - 7 * (4 - a.WeekKey), @W4End),
           WeekEnd           = DATEADD(DAY,     -7 * (4 - a.WeekKey), @W4End),
           a.NoOfClaims,
           InsurancePayment  = CAST(a.InsurancePayment AS DECIMAL(18,2)),
           AveragePaidAmount = CAST(a.InsurancePayment / NULLIF(a.NoOfClaims, 0) AS DECIMAL(18,2))
    FROM #a a
    JOIN #r r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    ORDER BY a.PanelName, r.PayerRank, a.WeekKey;
END;
GO

/* -----------------------------------------------------------------------------
   10. Payer vs Payment - InsurancePayment > 0 AND NWLCollectionPostedDate is a date;
       PayerName_Raw x NWLCollectionPostedDate year / month (the page shows year totals);
       Claims + Sum(InsurancePayment). PaymentPct = payer share of the month.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_InsuranceVsPayment
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PayerName, BillYear, BillMonth, NoOfPaidClaims, InsurancePayment, PaymentPct
        FROM dbo.NW_CS_InsuranceVsPayment
        ORDER BY BillYear, BillMonth, NoOfPaidClaims DESC;
        RETURN;
    END;

    WITH agg AS (
        SELECT PayerName,
               BillYear         = YEAR(CollectionPosted),
               BillMonth        = MONTH(CollectionPosted),
               NoOfPaidClaims   = COUNT(ClaimKey),
               InsurancePayment = SUM(InsPay)
        FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                                 @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
        WHERE InsPay > 0
          AND CollectionPosted IS NOT NULL
        GROUP BY PayerName, YEAR(CollectionPosted), MONTH(CollectionPosted)
    ),
    grand AS (
        SELECT BillYear, BillMonth, TotalInsurancePayment = NULLIF(SUM(InsurancePayment), 0)
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName,
           BillYear         = CAST(a.BillYear  AS SMALLINT),
           BillMonth        = CAST(a.BillMonth AS TINYINT),
           a.NoOfPaidClaims,
           InsurancePayment = CAST(a.InsurancePayment AS DECIMAL(18,2)),
           PaymentPct       = CAST(a.InsurancePayment * 100.0 / ISNULL(g.TotalInsurancePayment, 1) AS DECIMAL(9,4))
    FROM agg a
    JOIN grand g ON g.BillYear = a.BillYear AND g.BillMonth = a.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.NoOfPaidClaims DESC
    OPTION (RECOMPILE);
END;
GO

/* =============================================================================
   DENIAL SUMMARY
   ============================================================================= */

/* ---------------------------------------------------------------------------
   Base view: adds DenialPostedDate (NWLDenialPostedDate). Tabs 1 - 5 add:
   DenialCode IS NOT NULL AND TotalInsuranceBalance > 0.
   --------------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_NW_DenialClaims
AS
SELECT
    CAST(NULLIF(LTRIM(RTRIM(c.ClaimID)), '') AS NVARCHAR(200))                          AS ClaimID,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), ''), 'Unknown') AS NVARCHAR(500)) AS PayerName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PayerType)), ''), 'Unknown') AS NVARCHAR(200))     AS PayerType,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.ClinicName)), ''), '(Blank)') AS NVARCHAR(500))    AS ClinicName,
    CAST(ISNULL(NULLIF(LTRIM(RTRIM(c.PanelType)), ''), 'Unknown') AS NVARCHAR(200))     AS PanelType,
    CAST(NULLIF(LTRIM(RTRIM(c.DenialCodeNormalized)), '') AS NVARCHAR(400))             AS DenialCode,
    TRY_CAST(NULLIF(LTRIM(RTRIM(c.CheckDate)), '') AS DATE)                             AS CheckDate,
    CAST(NULLIF(LTRIM(RTRIM(c.PostedWeek)), '') AS NVARCHAR(500))                       AS PostedWeek,
    ISNULL(TRY_CAST(REPLACE(REPLACE(LTRIM(RTRIM(c.InsuranceBalance)), '$', ''), ',', '')
                    AS DECIMAL(18,2)), 0)                                               AS TotalInsuranceBalance,
    CASE WHEN TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(c.NWLDenialPostedDate)), ''), 101) >= '19010101'
         THEN TRY_CONVERT(DATE, NULLIF(LTRIM(RTRIM(c.NWLDenialPostedDate)), ''), 101) END AS DenialPostedDate
FROM dbo.ClaimLevelData c;
GO

-- fn_NW_DenialClaims selects d.*; refresh its column list.
EXEC sys.sp_refreshsqlmodule N'dbo.fn_NW_DenialClaims';
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly / tiles claim rows: one row per claim that passes the common
   denial filter. DenialPostedDate and PostedWeek drive the period axes.
   --------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_DenialSummaryClaims()
RETURNS TABLE
AS
RETURN
    SELECT d.ClaimID                 AS ClaimKey,
           d.PayerName,
           d.PayerType,
           d.ClinicName,
           d.DenialCode,
           d.CheckDate,
           d.DenialPostedDate,
           d.PostedWeek,
           d.TotalInsuranceBalance   AS Bal
    FROM   dbo.vw_NW_DenialClaims d
    WHERE  d.ClaimID IS NOT NULL
      AND  d.DenialCode IS NOT NULL
      AND  d.TotalInsuranceBalance > 0;
GO

/* ---------------------------------------------------------------------------
   Monthly / Weekly engine
   @Grain 'M' = every NWLDenialPostedDate month, with a total per year
          'W' = the 4 Thursday-Wednesday weeks ending on the Wednesday on/after the
                billed week-range end date (latest WeekFolder; latest
                NWLDenialPostedDate up to today when there is no week folder).
                Labelled "dd MMM - dd MMM". A claim's week:
                 - PostedWeek "Week 1".."Week 4" -> that week (Week 1 = oldest)
                 - PostedWeek "MM.dd.yyyy - MM.dd.yyyy" -> the week holding its start
                 - otherwise the week of its NWLDenialPostedDate
                Claims outside the 4 weeks are not in the Weekly tab.
   @DenialFrom / @DenialTo filter NWLDenialPostedDate.
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_NW_DenialAnalysis_Compute
    @Grain       CHAR(1),
    @PayerNames  NVARCHAR(MAX) = NULL,
    @PayerTypes  NVARCHAR(MAX) = NULL,
    @DenialCodes NVARCHAR(MAX) = NULL,
    @DenialFrom  DATE          = NULL,
    @DenialTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF @Grain NOT IN ('M', 'W')
    BEGIN
        RAISERROR('usp_NW_DenialAnalysis_Compute: @Grain must be M or W.', 16, 1);
        RETURN;
    END;

    DECLARE @TopPayers INT = 10, @TopCodes INT = 3, @Weeks INT = 4;

    SELECT d.ClaimKey, d.PayerName, d.DenialCode, d.DenialPostedDate AS PostedDate, d.PostedWeek, d.Bal
    INTO   #c
    FROM   dbo.fn_NW_DenialSummaryClaims() d
    WHERE  (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
            OR d.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@PayerTypes)), N'') IS NULL
            OR d.PayerType IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerTypes, N'|')))
      AND  (NULLIF(LTRIM(RTRIM(@DenialCodes)), N'') IS NULL
            OR d.DenialCode IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@DenialCodes, N'|')))
      AND  (@DenialFrom IS NULL OR d.DenialPostedDate >= @DenialFrom)
      AND  (@DenialTo   IS NULL OR d.DenialPostedDate <= @DenialTo);

    /* Weekly window: 4 Thu-Wed weeks, Week 4 ending on the Wednesday on/after the week-range end */
    DECLARE @Anchor DATE, @W4End DATE, @W1Start DATE;
    IF @Grain = 'W'
    BEGIN
        SELECT @Anchor = MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL;
        IF @Anchor IS NULL
            SELECT @Anchor = MAX(PostedDate) FROM #c WHERE PostedDate <= CAST(GETDATE() AS DATE);

        -- 1900-01-03 was a Wednesday.
        SET @W4End   = DATEADD(DAY, (7 - DATEDIFF(DAY, '19000103', @Anchor) % 7) % 7, @Anchor);
        SET @W1Start = DATEADD(DAY, -27, @W4End);
    END;

    /* Bucket of every claim */
    SELECT c.ClaimKey, c.PayerName, c.DenialCode, c.Bal, c.PostedDate, c.PostedWeek,
           CAST(CASE WHEN @Grain = 'M'
                     THEN CASE WHEN c.PostedDate IS NOT NULL
                               THEN CONVERT(CHAR(10), DATEFROMPARTS(YEAR(c.PostedDate), MONTH(c.PostedDate), 1), 120) END
                     WHEN wk.WeekIdx BETWEEN 1 AND @Weeks
                     THEN N'W|' + CAST(wk.WeekIdx AS NVARCHAR(10))
                END AS NVARCHAR(520)) AS BucketKey
    INTO   #cb
    FROM   #c c
    CROSS  APPLY (SELECT TRY_CONVERT(DATE, REPLACE(LTRIM(RTRIM(
                             LEFT(c.PostedWeek, NULLIF(CHARINDEX(N'-', c.PostedWeek), 0) - 1))), N'.', N'/'), 101) AS PostedStart) pw
    CROSS  APPLY (SELECT CASE WHEN @Grain <> 'W' THEN NULL
                              WHEN c.PostedWeek LIKE N'Week [1-4]'
                                  THEN CAST(RIGHT(c.PostedWeek, 1) AS INT)
                              WHEN pw.PostedStart BETWEEN @W1Start AND @W4End
                                  THEN 4 - DATEDIFF(DAY, pw.PostedStart, @W4End) / 7
                              WHEN c.PostedWeek IS NULL AND c.PostedDate BETWEEN @W1Start AND @W4End
                                  THEN 4 - DATEDIFF(DAY, c.PostedDate, @W4End) / 7
                         END AS WeekIdx) wk;

    DELETE FROM #cb WHERE BucketKey IS NULL;

    /* Period columns */
    CREATE TABLE #per
    (
        BucketKey   NVARCHAR(520) NOT NULL,
        PeriodType  CHAR(1)       NOT NULL,
        PeriodKey   VARCHAR(10)   NOT NULL,
        PeriodLabel NVARCHAR(40)  NOT NULL,
        PeriodStart DATE          NULL,
        PeriodEnd   DATE          NULL,
        PeriodYear  INT           NULL,
        SortKey     INT           NOT NULL
    );

    IF @Grain = 'M'
    BEGIN
        INSERT INTO #per (BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear, SortKey)
        SELECT CONVERT(NVARCHAR(520), CONVERT(CHAR(10), m.MonthStart, 120)),
               'M',
               CONVERT(VARCHAR(10), m.MonthStart, 120),
               CAST(FORMAT(m.MonthStart, 'MMM', 'en-US') AS NVARCHAR(40)),
               m.MonthStart,
               EOMONTH(m.MonthStart),
               YEAR(m.MonthStart),
               DATEDIFF(DAY, '19000101', m.MonthStart)
        FROM  (SELECT DISTINCT DATEFROMPARTS(YEAR(PostedDate), MONTH(PostedDate), 1) AS MonthStart
               FROM   #cb
               WHERE  PostedDate IS NOT NULL) m;
    END
    ELSE
    BEGIN
        -- All four weeks are columns, even a week with no denials.
        INSERT INTO #per (BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear, SortKey)
        SELECT N'W|' + CAST(k.WeekIdx AS NVARCHAR(10)), 'W',
               CONVERT(VARCHAR(10), d.ws, 120),
               CAST(FORMAT(d.ws, 'dd MMM', 'en-US') + N' - ' + FORMAT(d.we, 'dd MMM', 'en-US') AS NVARCHAR(40)),
               d.ws, d.we, YEAR(d.ws), k.WeekIdx
        FROM   (VALUES (1), (2), (3), (4)) k(WeekIdx)
        CROSS  APPLY (SELECT DATEADD(DAY, -6 - 7 * (4 - k.WeekIdx), @W4End) AS ws,
                             DATEADD(DAY,     -7 * (4 - k.WeekIdx), @W4End) AS we) d
        WHERE  @W4End IS NOT NULL;
    END;

    SELECT CAST(BucketKey AS NVARCHAR(520)) AS BucketKey, PeriodType, PeriodKey, PeriodLabel,
           PeriodStart, PeriodEnd, PeriodYear, SortKey
    INTO   #col0
    FROM   #per
    UNION ALL
    SELECT N'', 'Y', CAST('total-' + CAST(PeriodYear AS VARCHAR(4)) AS VARCHAR(10)),
           CAST(CAST(PeriodYear AS VARCHAR(4)) + ' | Total' AS NVARCHAR(40)),
           MIN(PeriodStart), MAX(PeriodEnd), PeriodYear, 0
    FROM   #per
    WHERE  @Grain = 'M'
    GROUP  BY PeriodYear
    UNION ALL
    SELECT N'', 'A', CAST('' AS VARCHAR(10)), CAST(N'Grand Total' AS NVARCHAR(40)), NULL, NULL, NULL, 0;

    SELECT BucketKey, PeriodType, PeriodKey, PeriodLabel, PeriodStart, PeriodEnd, PeriodYear,
           ROW_NUMBER() OVER (ORDER BY CASE WHEN PeriodType = 'A' THEN 1 ELSE 0 END,
                                       CASE WHEN @Grain = 'M' THEN PeriodYear END,
                                       CASE WHEN PeriodType = 'Y' THEN 1 ELSE 0 END,
                                       SortKey) AS ColOrder
    INTO   #col
    FROM   #col0;

    /* Claims the columns hold; totals, ranks and coverage describe these only */
    SELECT n.PayerName, dbo.fn_NW_PayerKey(n.PayerName) AS PayerKey
    INTO   #pk
    FROM  (SELECT DISTINCT PayerName FROM #cb) n;

    SELECT c.ClaimKey, c.PayerName, k.PayerKey, c.DenialCode, c.Bal, p.BucketKey, p.PeriodYear
    INTO   #b
    FROM   #cb c
    JOIN   #per p ON p.BucketKey = c.BucketKey
    JOIN   #pk k  ON k.PayerName = c.PayerName;

    /* Payers by No. of Claims, then balance */
    SELECT PayerKey,
           ISNULL(MIN(NULLIF(PayerName, N'')), N'(no payer)') AS PayerLabel,
           SUM(Bal) AS Bal,
           ROW_NUMBER() OVER (ORDER BY COUNT(ClaimKey) DESC, SUM(Bal) DESC, PayerKey) AS PayerRank
    INTO   #pr
    FROM   #b
    GROUP  BY PayerKey;

    DECLARE @Coverage DECIMAL(9,2) = ISNULL(
        (SELECT CASE WHEN SUM(Bal) > 0
                     THEN ROUND(SUM(CASE WHEN PayerRank <= @TopPayers THEN Bal ELSE 0 END) * 100.0 / SUM(Bal), 0)
                     ELSE 0 END
         FROM   #pr), 0);

    /* Top 3 denial codes per listed payer, by No. of Claims, then balance */
    SELECT b.PayerKey, b.DenialCode,
           ROW_NUMBER() OVER (PARTITION BY b.PayerKey
                              ORDER BY COUNT(b.ClaimKey) DESC, SUM(b.Bal) DESC, b.DenialCode) AS CodeRank
    INTO   #cr
    FROM   #b b
    JOIN   #pr p ON p.PayerKey = b.PayerKey AND p.PayerRank <= @TopPayers
    GROUP  BY b.PayerKey, b.DenialCode;

    DELETE FROM #cr WHERE CodeRank > @TopCodes;

    /* Rows: payer A..J, its codes numbered down the whole table, Grand Total last */
    SELECT 'P' AS RowType, p.PayerKey, CAST(N'' AS NVARCHAR(400)) AS DenialCode, p.PayerRank, 0 AS CodeRank,
           p.PayerRank * 10 AS RowSeq,
           CAST(CHAR(64 + p.PayerRank) AS VARCHAR(10)) AS IndexLabel,
           CAST(p.PayerLabel AS NVARCHAR(4000)) AS RowLabel,
           p.PayerLabel
    INTO   #r
    FROM   #pr p
    WHERE  p.PayerRank <= @TopPayers
    UNION ALL
    SELECT 'C', c.PayerKey, c.DenialCode, p.PayerRank, c.CodeRank,
           p.PayerRank * 10 + c.CodeRank,
           CAST(ROW_NUMBER() OVER (ORDER BY p.PayerRank, c.CodeRank) AS VARCHAR(10)),
           dbo.fn_NW_DenialRowLabel(c.DenialCode, NULL),
           p.PayerLabel
    FROM   #cr c
    JOIN   #pr p ON p.PayerKey = c.PayerKey
    UNION ALL
    SELECT 'T', N'', N'', 0, 0, 2147483647, '', N'Grand Total', N'Grand Total';

    /* Cells: period, year subtotal (Monthly) and grand total of every row */
    ;WITH m AS
    (
        SELECT r.RowSeq, b.ClaimKey, b.Bal, b.BucketKey, b.PeriodYear
        FROM   #b b
        JOIN   #r r ON r.RowType IN ('P', 'C') AND r.PayerKey = b.PayerKey
                   AND (r.RowType = 'P' OR r.DenialCode = b.DenialCode)
        UNION ALL
        SELECT 2147483647, b.ClaimKey, b.Bal, b.BucketKey, b.PeriodYear
        FROM   #b b
    )
    SELECT RowSeq,
           CAST(CASE WHEN GROUPING(BucketKey) = 0 THEN @Grain
                     WHEN GROUPING(PeriodYear) = 0 THEN 'Y'
                     ELSE 'A' END AS CHAR(1)) AS PeriodType,
           BucketKey, PeriodYear,
           COUNT(ClaimKey) AS ClaimCount,
           SUM(Bal)                 AS Bal
    INTO   #cell
    FROM   m
    GROUP  BY GROUPING SETS ((RowSeq, PeriodYear, BucketKey), (RowSeq, PeriodYear), (RowSeq));

    ;WITH grid AS
    (
        SELECT r.RowType, r.DenialCode, r.PayerRank, r.CodeRank, r.RowSeq, r.IndexLabel, r.RowLabel, r.PayerLabel,
               k.PeriodType, k.PeriodKey, k.PeriodLabel, k.ColOrder,
               k.PeriodStart AS ColStart, k.PeriodEnd AS ColEnd, k.PeriodYear AS ColYear,
               x.ClaimCount, x.Bal
        FROM   #r r
        CROSS  JOIN #col k
        LEFT   JOIN #cell x ON x.RowSeq = r.RowSeq
                           AND x.PeriodType = k.PeriodType
                           AND (   k.PeriodType = 'A'
                                OR (k.PeriodType = 'Y' AND x.PeriodYear = k.PeriodYear)
                                OR (k.PeriodType IN ('M', 'W') AND x.BucketKey = k.BucketKey))
        WHERE  r.RowType = 'T' OR x.RowSeq IS NOT NULL
    )
    SELECT CAST(RowType AS CHAR(1))                  AS RowType,
           CAST(PayerLabel AS NVARCHAR(500))         AS PayerName,
           CAST(DenialCode AS NVARCHAR(400))         AS DenialCode,
           PayerRank, CodeRank,
           PeriodType,
           PeriodKey,
           ColYear  AS PeriodYear,
           ColStart AS PeriodStart,
           ColEnd   AS PeriodEnd,
           PeriodLabel,
           ISNULL(ClaimCount, 0)                 AS ClaimCount,
           CAST(ISNULL(Bal, 0) AS DECIMAL(18,2)) AS TotalInsuranceBalance,
           DENSE_RANK() OVER (ORDER BY RowSeq)   AS SortOrder,
           DENSE_RANK() OVER (ORDER BY ColOrder) AS PeriodOrder,
           IndexLabel,
           RowLabel,
           @Coverage AS CoveragePct
    FROM   grid
    ORDER  BY SortOrder, PeriodOrder;
END
GO

/* ---------------------------------------------------------------------------
   Tiles - Denied Claims, Insurance Balance, Denial Codes, Insurances: every claim of
   fn_NW_DenialSummaryClaims. UndatedGroups = insurance / code groups with no
   NWLDenialPostedDate (not in the Monthly tab).
   --------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_NW_DenialSummaryTiles_Compute
AS
BEGIN
    SET NOCOUNT ON;

    SELECT ClaimKey, PayerName, DenialCode, DenialPostedDate AS PostedDate, Bal
    INTO   #c
    FROM   dbo.fn_NW_DenialSummaryClaims();

    DECLARE @WeekFolderEnd DATE =
    (
        SELECT MAX(TRY_CONVERT(DATE, REPLACE(RIGHT(LTRIM(RTRIM(CONVERT(NVARCHAR(100), WeekFolder))), 10), '.', '/'), 101))
        FROM   dbo.ClaimLevelData
        WHERE  WeekFolder IS NOT NULL
    );

    SELECT COUNT(ClaimKey)                                AS DeniedClaims,
           CAST(ISNULL(SUM(Bal), 0) AS DECIMAL(18,2))     AS InsuranceBalance,
           COUNT(DISTINCT DenialCode)                     AS DenialCodes,
           COUNT(DISTINCT NULLIF(PayerName, N''))         AS Insurances,
           (SELECT COUNT(*)
            FROM  (SELECT DISTINCT PayerName, DenialCode
                   FROM   #c
                   WHERE  PostedDate IS NULL) u)          AS UndatedGroups,
           COALESCE(@WeekFolderEnd, MAX(PostedDate))      AS LoadedThrough,
           GETDATE()                                      AS RefreshedAt
    FROM   #c;
END
GO

/* =============================================================================
   Rebuild the affected snapshots
   ============================================================================= */
EXEC dbo.usp_RefreshNW_CS_MonthlyClaimVolume;
GO
EXEC dbo.usp_RefreshNW_CS_WeeklyClaimVolume;
GO
EXEC dbo.usp_RefreshNW_CS_InsuranceVsPayment;
GO
EXEC dbo.usp_RefreshNW_DenialMonthly;      -- also refreshes the tiles
GO
EXEC dbo.usp_RefreshNW_DenialWeekly;
GO

SET NOEXEC OFF;
GO

PRINT '49_NW_PostedDates_CollectionDenialSummary.sql completed.';
GO
