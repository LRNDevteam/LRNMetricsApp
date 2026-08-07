# Generates "{NN}_{Lab}_CollectionSummary_ReadSPs.sql" for each lab so that
# the Collection Summary page can drive its Monthly Claim Volume and Weekly
# Claim Volume tabs through stored procedures that mirror the NorthWest pattern.
#
# The generated SPs:
#   * Read from the pre-aggregated dbo.{Prefix}_CS_MonthlyClaimVolume /
#     dbo.{Prefix}_CS_WeeklyClaimVolume snapshot tables when no filters are
#     supplied.
#   * Aggregate live from the lab's claim/line tables when any filter is set.
#
# Re-run this script whenever a new lab is onboarded.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$sqlRoot = Join-Path $root 'ClaimLineCSVDataCapture\Sql'

$labs = @(
    [pscustomobject]@{ Folder='Augustus';         File='15_Augustus_CollectionSummary_ReadSPs.sql';         Prefix='Aug';  PanelCol='PanelNew';  DateCol='CheckDate';   Source='ClaimLevelData' },
    [pscustomobject]@{ Folder='BeechTree';        File='14_BeechTree_CollectionSummary_ReadSPs.sql';        Prefix='BT';   PanelCol='Panelname'; DateCol='PostingDate'; Source='LineLevelData'  },
    [pscustomobject]@{ Folder='Certus';           File='13_Certus_CollectionSummary_ReadSPs.sql';           Prefix='Cert'; PanelCol='Panelname'; DateCol='PostingDate'; Source='LineLevelData'  },
    [pscustomobject]@{ Folder='Cove';             File='14_Cove_CollectionSummary_ReadSPs.sql';             Prefix='Cove'; PanelCol='Panelname'; DateCol='CheckDate';   Source='LineLevelData'  },
    [pscustomobject]@{ Folder='Elixir';           File='14_Elixir_CollectionSummary_ReadSPs.sql';           Prefix='Elix'; PanelCol='Panelname'; DateCol='PostingDate'; Source='LineLevelData'  },
    [pscustomobject]@{ Folder='PCRLabsofAmerica'; File='13_PCRLabsofAmerica_CollectionSummary_ReadSPs.sql'; Prefix='PCR';  PanelCol='Panelname'; DateCol='PostingDate'; Source='LineLevelData'  },
    [pscustomobject]@{ Folder='RisingTides';      File='14_RisingTides_CollectionSummary_ReadSPs.sql';      Prefix='RT';   PanelCol='Panelname'; DateCol='PostingDate'; Source='LineLevelData'  }
)

$template = @'
-- =====================================================================
-- {LabFolder} - Collection Summary READ Stored Procedures
-- Used by LabMetricsDashboard Collection Summary page (Monthly + Weekly
-- Claim Volume tabs) and the related Excel export.
--
-- Pattern mirrors dbo.usp_GetNW_CS_MonthlyClaimVolume / WeeklyClaimVolume:
--   1) No filters  -> read pre-aggregated dbo.{Prefix}_CS_* snapshot tables.
--   2) Any filters -> aggregate live from dbo.{Source}.
--
-- List parameters use '|' delimiter.
-- =====================================================================

SET NOCOUNT ON;
GO

-- =====================================================================
-- Monthly Claim Volume - Collection Summary
-- Source: dbo.{Source} / dbo.{Prefix}_CS_MonthlyClaimVolume
-- Filter: InsurancePayment > 0, valid {DateCol}
-- Rows: {PanelCol}, PayerName_Raw with PayerRank
-- Columns: Year/Month from {DateCol}
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Get{Prefix}_CS_MonthlyClaimVolume
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
        FROM    dbo.{Prefix}_CS_MonthlyClaimVolume
        ORDER BY PanelName, PayerRank, BillYear, BillMonth;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

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
            LTRIM(RTRIM(ISNULL({PanelCol},     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (TRY_CAST({DateCol} AS DATE))             AS BillYear,
            MONTH(TRY_CAST({DateCol} AS DATE))             AS BillMonth,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.{Source}
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST({DateCol} AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST({DateCol} AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL({PanelCol},     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST({DateCol}       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST({DateCol}       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL({PanelCol},     'Unknown'))),
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            YEAR (TRY_CAST({DateCol} AS DATE)),
            MONTH(TRY_CAST({DateCol} AS DATE))
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

-- =====================================================================
-- Weekly Claim Volume - Collection Summary
-- Source: dbo.{Source} / dbo.{Prefix}_CS_WeeklyClaimVolume
-- Filter: InsurancePayment > 0, valid {DateCol}
-- No-filter path reads aggregate values.
-- Filter path calculates last 4 weeks from latest {DateCol} in filtered data.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_Get{Prefix}_CS_WeeklyClaimVolume
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
        FROM    dbo.{Prefix}_CS_WeeklyClaimVolume
        ORDER BY PanelName, PayerRank, WeekKey;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

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

    DECLARE @LatestCheckDate DATE;

    SELECT @LatestCheckDate = MAX(TRY_CAST({DateCol} AS DATE))
    FROM dbo.{Source}
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST({DateCol} AS DATE) IS NOT NULL
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL({PanelCol},     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST({DateCol}       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST({DateCol}       AS DATE) <= @CheckDateTo);

    IF @LatestCheckDate IS NULL
    BEGIN
        SELECT  CAST(NULL AS NVARCHAR(500)) AS PanelName,
                CAST(NULL AS NVARCHAR(500)) AS PayerName,
                CAST(NULL AS INT) AS PayerRank,
                CAST(NULL AS TINYINT)       AS WeekKey,
                CAST(NULL AS DATE)          AS WeekStart,
                CAST(NULL AS DATE)          AS WeekEnd,
                CAST(NULL AS INT)           AS NoOfClaims,
                CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
                CAST(NULL AS DECIMAL(18,2)) AS AveragePaidAmount
        WHERE 1 = 0;
        RETURN;
    END;

    -- Sunday-ending weeks, with Week 4 ending on the latest data point's week end.
    DECLARE @DaysSinceSun INT = ((DATEDIFF(DAY, '1900-01-07', @LatestCheckDate) % 7) + 7) % 7;
    DECLARE @W4End DATE = DATEADD(DAY, 6 - @DaysSinceSun, @LatestCheckDate);
    DECLARE @W4Start DATE = DATEADD(DAY, -6, @W4End);
    DECLARE @W3End DATE = DATEADD(DAY, -7, @W4End),  @W3Start DATE = DATEADD(DAY, -13, @W4End);
    DECLARE @W2End DATE = DATEADD(DAY,-14, @W4End),  @W2Start DATE = DATEADD(DAY, -20, @W4End);
    DECLARE @W1End DATE = DATEADD(DAY,-21, @W4End),  @W1Start DATE = DATEADD(DAY, -27, @W4End);

    ;WITH Src AS (
        SELECT
            LTRIM(RTRIM(ISNULL({PanelCol},     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            CASE
                WHEN TRY_CAST({DateCol} AS DATE) BETWEEN @W1Start AND @W1End THEN 1
                WHEN TRY_CAST({DateCol} AS DATE) BETWEEN @W2Start AND @W2End THEN 2
                WHEN TRY_CAST({DateCol} AS DATE) BETWEEN @W3Start AND @W3End THEN 3
                WHEN TRY_CAST({DateCol} AS DATE) BETWEEN @W4Start AND @W4End THEN 4
            END AS WeekKey,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsurancePayment
        FROM dbo.{Source}
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST({DateCol} AS DATE) BETWEEN @W1Start AND @W4End
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL({PanelCol},     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST({DateCol}       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST({DateCol}       AS DATE) <= @CheckDateTo)
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
'@

foreach ($lab in $labs) {
    $body = $template `
        -replace '\{LabFolder\}', $lab.Folder `
        -replace '\{Prefix\}',    $lab.Prefix `
        -replace '\{PanelCol\}',  $lab.PanelCol `
        -replace '\{DateCol\}',   $lab.DateCol `
        -replace '\{Source\}',    $lab.Source
    $target = Join-Path $sqlRoot (Join-Path $lab.Folder $lab.File)
    [System.IO.File]::WriteAllText($target, $body, [System.Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $target"
}
