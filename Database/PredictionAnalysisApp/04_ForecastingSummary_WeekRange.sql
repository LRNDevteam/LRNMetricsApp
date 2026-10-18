-- ============================================================
-- 04_ForecastingSummary_WeekRange.sql
-- SP : usp_GetForecastingSummaryByWeekRange
--
-- Forecasting Summary driven by the source file's WeekFolder
-- (NOT by today's date, which is what the dashboard C# does today).
--
-- Buckets (based on ExpectedPaymentDate):
--   0   YTD        : ExpectedPaymentDate <  WeekFolder start.
--                    Displayed as "Prior to <weekfolder range>"
--                    e.g.  YTD - Prior to 06/29/2026 - 07/05/2026
--   1-5 Week 1..5  : Week 1 = the WeekFolder week ITSELF
--                    (e.g. 06/29/2026 - 07/05/2026), then the next
--                    4 weeks — 5 weeks total. Each is a 7-day block,
--                    so every week keeps the SAME weekday span as the
--                    WeekFolder (Mon-Sun stays Mon-Sun, Thu-Wed stays
--                    Thu-Wed, etc.)
--   6   Beyond     : after Week-5 end (so totals always reconcile)
--
-- WeekFolder formats handled: "06.29.2026 - 07.05.2026"
--                             "06.29.2026 to 07.05.2026"
--
-- Only unresolved forecast-payable rows are counted, matching the dashboard:
--   ForecastingPayability IN ('Payable','Potentially Payable')
--   AND PayStatus IN ('Denied','No Response')
--
-- Result sets:
--   RS1 : week/bucket definitions (for building column headers)
--   RS2 : Payer x Bucket summary  (Median & Mode, Allowed & Paid)
--   RS3 : Bucket totals row
--
-- Deploy to the PCRLabsofAmerica prediction database.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetForecastingSummaryByWeekRange
(
    @LabName NVARCHAR(255) = NULL,   -- optional; per-lab DBs usually don't need it
    @RunId   NVARCHAR(100) = NULL    -- NULL = latest run
)
AS
BEGIN
    SET NOCOUNT ON;

    ------------------------------------------------------------
    -- 1. Resolve latest RunId + its WeekFolder
    ------------------------------------------------------------
    DECLARE @WeekFolder NVARCHAR(255);

    IF @RunId IS NULL
    BEGIN
        SELECT TOP (1) @RunId = RunId, @WeekFolder = WeekFolder
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
          AND (@LabName IS NULL OR LabName = @LabName)
        ORDER BY InsertedDateTime DESC;
    END
    ELSE
    BEGIN
        SELECT TOP (1) @WeekFolder = WeekFolder
        FROM   dbo.PayerValidationReport
        WHERE  RunId = @RunId
          AND (@LabName IS NULL OR LabName = @LabName)
        ORDER BY InsertedDateTime DESC;
    END

    ------------------------------------------------------------
    -- 2. Parse WeekFolder -> @WfStart / @WfEnd
    --    "MM.dd.yyyy - MM.dd.yyyy"  or  "MM.dd.yyyy to MM.dd.yyyy"
    ------------------------------------------------------------
    DECLARE @wf NVARCHAR(255) =
        REPLACE(REPLACE(REPLACE(ISNULL(@WeekFolder, N''),
            N' to ', N'-'), NCHAR(8211), N'-'), NCHAR(8212), N'-');

    DECLARE @dashPos INT = CHARINDEX(N'-', @wf);

    DECLARE @WfStart DATE = TRY_CONVERT(date,
        REPLACE(LTRIM(RTRIM(LEFT(@wf, NULLIF(@dashPos,0) - 1))), N'.', N'/'), 101);
    DECLARE @WfEnd   DATE = TRY_CONVERT(date,
        REPLACE(LTRIM(RTRIM(SUBSTRING(@wf, @dashPos + 1, 50))),  N'.', N'/'), 101);

    IF @WfStart IS NULL OR @WfEnd IS NULL
    BEGIN
        RAISERROR(N'Could not parse WeekFolder ''%s'' for RunId ''%s''.',
                  16, 1, @WeekFolder, @RunId);
        RETURN;
    END

    ------------------------------------------------------------
    -- 3. Build the bucket table
    --    Week 1 = the WeekFolder week itself; Weeks 2-4 follow it.
    --    Week N = WfStart + 7*(N-1)  ..  WfEnd + 7*(N-1)
    --    -> same weekday span as the WeekFolder for every week.
    ------------------------------------------------------------
    DECLARE @wfLabel NVARCHAR(60) =
        FORMAT(@WfStart, 'MM/dd/yyyy') + N' - ' + FORMAT(@WfEnd, 'MM/dd/yyyy');

    DECLARE @Buckets TABLE
    (
        SortOrder  INT           NOT NULL,
        BucketKey  VARCHAR(20)   NOT NULL,
        WeekStart  DATE          NULL,      -- NULL = open-ended (YTD lower bound)
        WeekEnd    DATE          NULL,      -- NULL = open-ended (Beyond upper bound)
        BucketLabel NVARCHAR(120) NOT NULL
    );

    INSERT INTO @Buckets (SortOrder, BucketKey, WeekStart, WeekEnd, BucketLabel)
    VALUES
        (0, 'YTD', NULL, DATEADD(day, -1, @WfStart),
            N'YTD - Prior to ' + @wfLabel);

    DECLARE @i INT = 1;
    WHILE @i <= 5
    BEGIN
        INSERT INTO @Buckets (SortOrder, BucketKey, WeekStart, WeekEnd, BucketLabel)
        SELECT  @i,
                'WEEK' + CAST(@i AS VARCHAR(2)),
                DATEADD(day, 7 * (@i - 1), @WfStart),
                DATEADD(day, 7 * (@i - 1), @WfEnd),
                FORMAT(DATEADD(day, 7 * (@i - 1), @WfStart), 'MM/dd/yyyy')
                    + N' - '
                    + FORMAT(DATEADD(day, 7 * (@i - 1), @WfEnd), 'MM/dd/yyyy');
        SET @i += 1;
    END

    INSERT INTO @Buckets (SortOrder, BucketKey, WeekStart, WeekEnd, BucketLabel)
    VALUES (6, 'BEYOND', DATEADD(day, 29, @WfEnd), NULL,
            N'Beyond ' + FORMAT(DATEADD(day, 28, @WfEnd), 'MM/dd/yyyy'));

    ------------------------------------------------------------
    -- 4. Normalise the report rows
    --    ExpectedPaymentDate may be a date string OR an Excel OA serial.
    ------------------------------------------------------------
    ;WITH Src AS
    (
        SELECT
            PayerName           = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                           NULLIF(LTRIM(RTRIM(PayerName)), N''),
                                           N'Unknown'),
            VisitNumber,
            ExpPmtDate =
                COALESCE(
                    TRY_CONVERT(date, LTRIM(RTRIM(ExpectedPaymentDate)), 101),
                    TRY_CONVERT(date, LTRIM(RTRIM(ExpectedPaymentDate))),
                    CASE WHEN TRY_CONVERT(float, ExpectedPaymentDate)
                              BETWEEN 2 AND 2958465
                         THEN DATEADD(day,
                              CAST(TRY_CONVERT(float, ExpectedPaymentDate) AS INT),
                              '18991230')
                    END),
            MedianAllowed = ISNULL(TRY_CONVERT(decimal(18,2), MedianAllowedAmountSameLab), 0),
            MedianPaid    = ISNULL(TRY_CONVERT(decimal(18,2), MedianInsurancePaidSameLab), 0),
            ModeAllowed   = ISNULL(TRY_CONVERT(decimal(18,2), ModeAllowedAmountSameLab),   0),
            ModePaid      = ISNULL(TRY_CONVERT(decimal(18,2), ModeInsurancePaidSameLab),   0)
        FROM dbo.PayerValidationReport
        WHERE RunId = @RunId
          AND (@LabName IS NULL OR LabName = @LabName)
          AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N'')))
              IN (N'Payable', N'Potentially Payable')
          AND LTRIM(RTRIM(ISNULL(PayStatus, N'')))
              IN (N'Denied', N'No Response')
    ),
    Binned AS
    (
        SELECT s.*, b.SortOrder, b.BucketKey, b.BucketLabel, b.WeekStart, b.WeekEnd
        FROM Src s
        JOIN @Buckets b
          ON s.ExpPmtDate IS NOT NULL
         AND (b.WeekStart IS NULL OR s.ExpPmtDate >= b.WeekStart)
         AND (b.WeekEnd   IS NULL OR s.ExpPmtDate <= b.WeekEnd)
    )

    ------------------------------------------------------------
    -- RS2 : Payer x Bucket summary
    ------------------------------------------------------------
    SELECT
        PayerName,
        SortOrder,
        BucketKey,
        BucketLabel,
        WeekStart,
        WeekEnd,
        ClaimLineCount     = COUNT(*),
        DistinctVisitCount = COUNT(DISTINCT VisitNumber),
        MedianAllowedTotal = SUM(MedianAllowed),
        MedianPaidTotal    = SUM(MedianPaid),
        ModeAllowedTotal   = SUM(ModeAllowed),
        ModePaidTotal      = SUM(ModePaid)
    INTO #Summary
    FROM Binned
    GROUP BY PayerName, SortOrder, BucketKey, BucketLabel, WeekStart, WeekEnd;

    ------------------------------------------------------------
    -- RS1 : bucket definitions (column headers for the UI)
    ------------------------------------------------------------
    SELECT
        RunId      = @RunId,
        WeekFolder = @WeekFolder,
        SortOrder, BucketKey, WeekStart, WeekEnd, BucketLabel
    FROM @Buckets
    ORDER BY SortOrder;

    -- RS2
    SELECT *
    FROM   #Summary
    ORDER BY PayerName, SortOrder;

    ------------------------------------------------------------
    -- RS3 : totals per bucket
    ------------------------------------------------------------
    SELECT
        PayerName          = N'Total',
        SortOrder, BucketKey, BucketLabel, WeekStart, WeekEnd,
        ClaimLineCount     = SUM(ClaimLineCount),
        DistinctVisitCount = SUM(DistinctVisitCount),
        MedianAllowedTotal = SUM(MedianAllowedTotal),
        MedianPaidTotal    = SUM(MedianPaidTotal),
        ModeAllowedTotal   = SUM(ModeAllowedTotal),
        ModePaidTotal      = SUM(ModePaidTotal)
    FROM #Summary
    GROUP BY SortOrder, BucketKey, BucketLabel, WeekStart, WeekEnd
    ORDER BY SortOrder;

    DROP TABLE #Summary;
END
GO

-- ============================================================
-- Quick test (PCRLabsofAmerica DB):
--   EXEC dbo.usp_GetForecastingSummaryByWeekRange;                       -- latest run
--   EXEC dbo.usp_GetForecastingSummaryByWeekRange @RunId = N'20260629R0550';
-- ============================================================


-- ============================================================
-- SP : usp_GetForecastingRecords
-- Slim row fetch for the dashboard Forecasting Summary page.
--
-- usp_GetPayerValidationReport returns ~95 columns for EVERY row of
-- the run, which is far too heavy for big labs (CERTUS etc.) — the
-- Forecasting page and its Excel export only need these 16 columns
-- and only the forecast-payable rows. Pre-filtering here cuts both
-- the row count and the payload per row dramatically.
--
-- Business rule (matches the dashboard's IsForecastSummaryRow):
--   ForecastingPayability IN ('Payable','Potentially Payable')
--   AND PayStatus IN ('Denied','No Response')
-- i.e. only unresolved claims are forecast; 'Payable - Need Action'
-- and already-resolved PayStatus values are excluded.
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetForecastingRecords
(
    @RunId NVARCHAR(100) = NULL    -- NULL = latest run
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL
    BEGIN
        SELECT TOP (1) @RunId = RunId
        FROM   dbo.PayerValidationReport
        WHERE  RunId IS NOT NULL
        ORDER BY InsertedDateTime DESC;
    END

    SELECT
        AccessionNo,
        VisitNumber,
        CPTCode,
        PayerName,
        PayerNameNormalized,
        PayerType,
        PayStatus,
        PanelName,
        DateOfService,
        FirstBilledDate,
        DenialCode,
        DenialDescription,
        BilledAmount,
        AllowedAmount,
        InsurancePayment,
        Payability,
        ForecastingPayability,
        FinalCoverageStatus,
        ExpectedPaymentDate,
        MedianAllowedAmountSameLab,
        MedianInsurancePaidSameLab,
        ModeAllowedAmountSameLab,
        ModeInsurancePaidSameLab
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId
      AND LTRIM(RTRIM(ISNULL(ForecastingPayability, N'')))
          IN (N'Payable', N'Potentially Payable')
      AND LTRIM(RTRIM(ISNULL(PayStatus, N'')))
          IN (N'Denied', N'No Response');
END
GO

-- Quick test:
--   EXEC dbo.usp_GetForecastingRecords;   -- latest run, forecast-payable rows only
-- ============================================================
