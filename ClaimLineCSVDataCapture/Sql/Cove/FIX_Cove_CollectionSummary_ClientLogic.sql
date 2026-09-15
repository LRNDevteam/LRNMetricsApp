/* =====================================================================
   COVE Collection Summary — client logic fixes (NEW SPs)
   DB  : CoveLRN

   Writes existing snapshot tables. Does not alter legacy Refresh/Get names
   except Capture/UI will call these ClientLogic SPs for Cove.

   1) Insurance vs Aging (No Response)
      Filter : ClaimStatus = 'No Response'
      Row    : PayerName_Raw
      Column : AgingDOS (as stored)
      Values : COUNT(ClaimID)  — NOT DISTINCT
               SUM(InsuranceBalance)

   2) Panel Averages (CheckDate last 6 months)
      Filter : CheckDate in last 6 months through MAX(CheckDate)
      Row    : Panelname + Top 3 PayerName_Raw (by claim count)
      Values : COUNT(ClaimID) not DISTINCT; flag columns NOT blank
               FullyPaid / Adjudicated / Bucket30 / Bucket60

   3) Panel vs Payment (month grain retained)
      Refresh keeps Panel × CheckDate Year/Month with COUNT(ClaimID)

   Wire:
      ClaimLineDbService RefreshCoveCollectionReports → ClientLogic refresh SPs
      Dashboard prefers usp_GetCove_*_ClientLogic when present
   ===================================================================== */
SET NOCOUNT ON;
GO

/* ---------- 1) Insurance vs Aging — No Response / AgingDOS / Count(ClaimID) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_InsuranceVsAging_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_CS_InsuranceVsAging;

    INSERT INTO dbo.Cove_CS_InsuranceVsAging
        (PayerName, AgingBucket, VisitCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)'))) AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS VisitCount, -- Count(ClaimID), not DISTINCT
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)')));

    PRINT 'usp_RefreshCove_CS_InsuranceVsAging_ClientLogic completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_InsuranceVsAging_ClientLogic
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
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PayerName, AgingBucket, VisitCount, InsuranceBalance
        FROM dbo.Cove_CS_InsuranceVsAging
        ORDER BY PayerName, AgingBucket;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)'))) AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS VisitCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo IS NULL OR TRY_CAST(CheckDate AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), '(blank)')))
    ORDER BY PayerName, AgingBucket;
END
GO

/* ---------- 2) Panel Averages — CheckDate 6 months, Top 3, Count(ClaimID), flags not blank ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelAverages_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @MaxCheck DATE =
        (SELECT MAX(TRY_CAST(CheckDate AS DATE)) FROM dbo.ClaimLevelData WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL);
    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, @MaxCheck);

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')              AS ClaimId,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            TRY_CAST(FullyPaidAmount AS DECIMAL(18,2))     AS FullyPaidAmt,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')    AS AdjFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))  AS AdjAmt,
            NULLIF(LTRIM(RTRIM(Bucket30Count)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND TRY_CAST(CheckDate AS DATE) <= @MaxCheck
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
    ),
    agg AS (
        SELECT
            PanelName,
            PayerName,
            COUNT(ClaimId) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS CarrierPayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN ClaimId END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IS NOT NULL THEN ClaimId END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN ClaimId END) AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN ClaimId END) AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
        FROM src
        GROUP BY PanelName, PayerName
    ),
    ranked AS (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC, PayerName) AS PayerRank
        FROM agg
    )
    SELECT *
    INTO #out
    FROM ranked
    WHERE PayerRank <= 3;

    TRUNCATE TABLE dbo.Cove_CS_PanelAverages;

    INSERT INTO dbo.Cove_CS_PanelAverages
        (PanelName, PayerName,
         ClaimCount, TotalCharges, CarrierPayment, AvgCarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count, Days30Amount, AvgDays30,
         Days60Count, Days60Amount, AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName,
        ClaimCount, TotalCharges, CarrierPayment,
        CASE WHEN ClaimCount > 0 THEN CarrierPayment / ClaimCount ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count > 0 THEN Days30Amount / Days30Count ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count > 0 THEN Days60Amount / Days60Count ELSE 0 END,
        GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshCove_CS_PanelAverages_ClientLogic completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelAverages_ClientLogic
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

    -- Snapshot already holds ClientLogic (6-month + Top 3). Filters → live recompute.
    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, PayerName,
               ClaimCount,
               TotalCharges, CarrierPayment,
               FullyPaidCount, FullyPaidAmount,
               AdjudicatedCount, AdjudicatedAmount,
               Days30Count, Days30Amount,
               Days60Count, Days60Amount
        FROM dbo.Cove_CS_PanelAverages
        ORDER BY PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @MaxCheck DATE =
        (SELECT MAX(TRY_CAST(CheckDate AS DATE)) FROM dbo.ClaimLevelData WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL);
    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, @MaxCheck);
    IF @CheckDateFrom IS NOT NULL AND @CheckDateFrom > @Cutoff SET @Cutoff = @CheckDateFrom;
    IF @CheckDateTo IS NOT NULL AND @CheckDateTo < @MaxCheck SET @MaxCheck = @CheckDateTo;

    ;WITH src AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')              AS ClaimId,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            TRY_CAST(AdjucticatedAmount AS DECIMAL(18,2))  AS AdjAmt,
            NULLIF(LTRIM(RTRIM(AdjucticatedCount)), '')    AS AdjFlag,
            NULLIF(LTRIM(RTRIM(Bucket30Count)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60Count)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND TRY_CAST(CheckDate AS DATE) <= @MaxCheck
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    agg AS (
        SELECT
            PanelName, PayerName,
            COUNT(ClaimId) AS ClaimCount,
            ISNULL(SUM(Chg), 0) AS TotalCharges,
            ISNULL(SUM(InsPay), 0) AS CarrierPayment,
            COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN ClaimId END) AS FullyPaidCount,
            ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
            COUNT(CASE WHEN AdjFlag IS NOT NULL THEN ClaimId END) AS AdjudicatedCount,
            ISNULL(SUM(CASE WHEN AdjFlag IS NOT NULL THEN AdjAmt ELSE 0 END), 0) AS AdjudicatedAmount,
            COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN ClaimId END) AS Days30Count,
            ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
            COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN ClaimId END) AS Days60Count,
            ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
        FROM src
        GROUP BY PanelName, PayerName
    ),
    ranked AS (
        SELECT *,
               ROW_NUMBER() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC, PayerName) AS PayerRank
        FROM agg
    )
    SELECT PanelName, PayerName,
           ClaimCount,
           TotalCharges, CarrierPayment,
           FullyPaidCount, FullyPaidAmount,
           AdjudicatedCount, AdjudicatedAmount,
           Days30Count, Days30Amount,
           Days60Count, Days60Amount
    FROM ranked
    WHERE PayerRank <= 3
    ORDER BY PanelName, PayerRank;
END
GO

/* ---------- 3) Panel vs Payment — Count(ClaimID), month grain ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelVsPayment_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Cove_CS_PanelVsPayment;

    INSERT INTO dbo.Cove_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))                  AS PanelName,
        YEAR(TRY_CAST(CheckDate AS DATE))                           AS BilledYear,
        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT)         AS BilledMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims, -- not DISTINCT
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(CheckDate, ''))) <> ''
      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
    GROUP BY
        LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))),
        YEAR(TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

    PRINT 'usp_RefreshCove_CS_PanelVsPayment_ClientLogic completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT 'FIX_Cove_CollectionSummary_ClientLogic.sql — weekly section follows.';
GO

/* ---------- 4) Weekly Claim Volume — same Wed–Tue window as Production ----------
   Production (usp_RefreshCove_WeeklyBilledProductionSummary):
     • Week = Wed–Tue (anchor 1900-01-03)
     • Window anchored on MAX(FirstBilledDate) + completed-week StartIndex
   Collection still measures InsurancePayment by CheckDate, but the 4 week
   columns must match Production so headers line up (e.g. 8/12–8/18 … 9/2–9/8).
   -------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_WeeklyClaimVolume_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today         DATE = CAST(GETDATE() AS DATE);
    DECLARE @DateFromData  DATE;
    DECLARE @ThisWeekStart DATE;
    DECLARE @StartIndex    INT;
    DECLARE @i             INT;
    DECLARE @ws            DATE;
    DECLARE @we            DATE;
    DECLARE @wk            TINYINT;

    -- Same anchor as Production weekly: MAX(FirstBilledDate), Wed-Tue weeks
    SELECT
        @DateFromData  = MAX(TRY_CAST(FirstBilledDate AS DATE)),
        @ThisWeekStart = DATEADD(DAY,
            -(DATEDIFF(DAY, '19000103', ISNULL(MAX(TRY_CAST(FirstBilledDate AS DATE)), @Today)) % 7),
            ISNULL(MAX(TRY_CAST(FirstBilledDate AS DATE)), @Today))
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND TRY_CAST(FirstBilledDate AS DATE) <= @Today;

    IF @DateFromData IS NULL
    BEGIN
        RAISERROR('No valid FirstBilledDate <= today found in ClaimLevelData.', 16, 1);
        RETURN;
    END;

    -- Completed week when max FBD is on/after that week's Tuesday (Wed+6)
    SET @StartIndex = CASE
        WHEN @DateFromData >= DATEADD(DAY, 6, @ThisWeekStart) THEN 0
        ELSE 1
    END;

    CREATE TABLE #Weeks
    (
        WeekKey   TINYINT NOT NULL PRIMARY KEY, -- 1=oldest … 4=newest
        WeekStart DATE    NOT NULL,
        WeekEnd   DATE    NOT NULL
    );

    SET @i = @StartIndex;
    WHILE @i <= @StartIndex + 3
    BEGIN
        SET @ws = DATEADD(WEEK, -@i, @ThisWeekStart);
        SET @we = DATEADD(DAY, 6, @ws);
        -- WeekKey 1 = oldest … 4 = newest (matches Collection UI left→right)
        SET @wk = CAST((@StartIndex + 3 - @i) + 1 AS TINYINT);
        INSERT INTO #Weeks (WeekKey, WeekStart, WeekEnd) VALUES (@wk, @ws, @we);
        SET @i = @i + 1;
    END;

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(cl.Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(cl.PayerName_Raw, 'Unknown'))) AS PayerName,
            w.WeekKey,
            w.WeekStart,
            w.WeekEnd,
            cl.ClaimID,
            TRY_CAST(cl.InsurancePayment AS DECIMAL(18,2))    AS InsPay
        FROM #Weeks w
        INNER JOIN dbo.ClaimLevelData cl
            ON TRY_CAST(cl.CheckDate AS DATE) BETWEEN w.WeekStart AND w.WeekEnd
           AND ISNULL(TRY_CAST(cl.InsurancePayment AS DECIMAL(18,2)), 0) > 0
           AND TRY_CAST(cl.CheckDate AS DATE) IS NOT NULL
           AND TRY_CAST(cl.CheckDate AS DATE) <= @Today
    ),
    agg AS
    (
        SELECT
            PanelName, PayerName, WeekKey, WeekStart, WeekEnd,
            COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(InsPay), 0)                   AS InsurancePayment
        FROM src
        GROUP BY PanelName, PayerName, WeekKey, WeekStart, WeekEnd
    ),
    ranks AS
    (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank
        FROM agg
        GROUP BY PanelName, PayerName
    )
    SELECT
        a.PanelName,
        a.PayerName,
        CAST(r.PayerRank AS TINYINT) AS PayerRank,
        a.WeekKey,
        a.WeekStart,
        a.WeekEnd,
        a.NoOfClaims,
        a.InsurancePayment
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName;

    TRUNCATE TABLE dbo.Cove_CS_WeeklyClaimVolume;

    INSERT INTO dbo.Cove_CS_WeeklyClaimVolume
        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
         NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd,
           NoOfClaims, InsurancePayment, GETDATE()
    FROM #out
    ORDER BY PanelName, PayerRank, WeekKey;

    DROP TABLE IF EXISTS #out;
    DROP TABLE IF EXISTS #Weeks;

    PRINT 'usp_RefreshCove_CS_WeeklyClaimVolume_ClientLogic completed — '
        + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END
GO

PRINT 'FIX_Cove_CollectionSummary_ClientLogic.sql completed (incl. Weekly Claim Volume).';
GO
