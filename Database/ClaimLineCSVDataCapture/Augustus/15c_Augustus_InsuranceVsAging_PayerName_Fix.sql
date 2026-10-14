/* =====================================================================
   Augustus Collection Report — Insurance vs Aging PayerName / Source fix

   Deploy on Augustus_LRN.

   Problem
   -------
   dbo.usp_RefreshAug_CS_InsuranceVsAging grouped the snapshot by
   dbo.ClaimLevelData.Source (always 'IRCM' — the billing source), and
   wrote that value into Aug_CS_InsuranceVsAging.PayerName.
   The read SP's no-filter branch serves that snapshot, so the
   Collection Report "Insurance vs Aging" tab (and the Excel download,
   which uses the same rows) showed a single 'IRCM' row instead of one
   row per payer.

   The client pivot rows are Source > PayerName, so Source is kept as
   its own column instead of being used in place of the payer.

   The read SP's filter branch had two further mismatches with that
   pivot:
     - ClaimStatus <> 'No Response'  (snapshot uses = 'No Response')
     - aging bucket re-derived from DaystoDOS instead of using the
       Aging column the client's pivot columns come from
       (Current / 30+ / 60+ / 90+ / 120+).

   Fix
   ---
     1. Aug_CS_InsuranceVsAging          — add Source column.
     2. usp_RefreshAug_CS_InsuranceVsAging — group by Source + PayerName_Raw.
     3. usp_GetAug_CS_InsuranceVsAging_v2  — NEW read SP (LIVE
        usp_GetAug_CS_InsuranceVsAging is left untouched, same pattern
        as 15b). Reads dbo.ClaimLevelData directly for both the
        no-filter and the filter path, so both always agree:
          Row    = Source + PayerName_Raw  (blank/NULL -> 'Unknown')
          Column = Aging                   (falls back to DaystoDOS buckets)
          Values = COUNT(ClaimID), SUM(InsuranceBalance)
          Filter = ClaimStatus = 'No Response'

   Columns returned: Source, PayerName, AgingBucket, VisitCount,
   InsuranceBalance. The C# reader normalises '30+' -> '30 Days' etc.,
   and treats a missing Source column as blank (other labs' SPs).
   ===================================================================== */
SET NOCOUNT ON;
GO

-- =====================================================================
-- 1) Snapshot table — carry Source alongside the payer.
-- =====================================================================
IF COL_LENGTH('dbo.Aug_CS_InsuranceVsAging', 'Source') IS NULL
    ALTER TABLE dbo.Aug_CS_InsuranceVsAging ADD [Source] NVARCHAR(500) NULL;
GO

-- =====================================================================
-- 2) Snapshot refresh — PayerName must come from PayerName_Raw,
--    Source stays in its own column.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_InsuranceVsAging
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Aug_CS_InsuranceVsAging;
    PRINT 'Aug_CS_InsuranceVsAging table truncated';

    INSERT INTO dbo.Aug_CS_InsuranceVsAging
        ([Source], PayerName, AgingBucket, ClaimCount, InsuranceBalance, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL([Source], '')))                                       AS [Source],
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Aging)), ''), '(blank)')))         AS AgingBucket,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), ''))                                 AS ClaimCount,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)              AS InsuranceBalance,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
    GROUP BY
        LTRIM(RTRIM(ISNULL([Source], ''))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))),
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(Aging)), ''), '(blank)')));

    PRINT 'usp_RefreshAug_CS_InsuranceVsAging completed.';
END
GO

-- =====================================================================
-- 3) Read SP v2 — one row per Source + payer per aging bucket, live
--    from ClaimLevelData so the filtered and unfiltered views agree.
-- =====================================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsAging_v2
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

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL([Source], '')))                                       AS [Source],
            LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) AS PayerName,
            CASE
                WHEN NULLIF(LTRIM(RTRIM(ISNULL(Aging, ''))), '') IS NOT NULL
                    THEN LTRIM(RTRIM(Aging))
                WHEN TRY_CAST(DaystoDOS AS INT) IS NULL  THEN '(blank)'
                WHEN TRY_CAST(DaystoDOS AS INT) < 30     THEN 'Current'
                WHEN TRY_CAST(DaystoDOS AS INT) < 60     THEN '30+'
                WHEN TRY_CAST(DaystoDOS AS INT) < 90     THEN '60+'
                WHEN TRY_CAST(DaystoDOS AS INT) < 120    THEN '90+'
                ELSE '120+'
            END                                                                      AS AgingBucket,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                                        AS ClaimKey,
            TRY_CAST(InsuranceBalance AS DECIMAL(18,2))                              AS InsBalance
        FROM dbo.ClaimLevelData
        WHERE LTRIM(RTRIM(ISNULL(ClaimStatus, ''))) = 'No Response'
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PayerName_Raw)), ''), 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)),      ''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        [Source],
        PayerName,
        AgingBucket,
        COUNT(ClaimKey)                 AS VisitCount,
        ISNULL(SUM(InsBalance), 0)      AS InsuranceBalance
    FROM src
    GROUP BY [Source], PayerName, AgingBucket
    ORDER BY [Source], PayerName, AgingBucket;
END
GO

PRINT '15c_Augustus_InsuranceVsAging_PayerName_Fix.sql completed.';
PRINT '  Aug_CS_InsuranceVsAging.Source';
PRINT '  usp_RefreshAug_CS_InsuranceVsAging (Source + PayerName_Raw)';
PRINT '  usp_GetAug_CS_InsuranceVsAging_v2';
GO

/* ---------------------------------------------------------------------
   Smoke test
   --------------------------------------------------------------------- */
EXEC dbo.usp_RefreshAug_CS_InsuranceVsAging;
GO

-- Snapshot: expect Source = 'IRCM' with real payer names
-- (BLUE CROSS BLUE SHIELD OF IL, MERIDIAN, BCBS COMMUNITY MMCP (XXL), ...).
SELECT TOP (20) [Source], PayerName, AgingBucket, ClaimCount, InsuranceBalance
FROM dbo.Aug_CS_InsuranceVsAging
ORDER BY InsuranceBalance DESC;
GO

-- Read SP, no filters (what the Collection Report / Excel download use).
EXEC dbo.usp_GetAug_CS_InsuranceVsAging_v2;
GO

-- Read SP with a payer filter.
EXEC dbo.usp_GetAug_CS_InsuranceVsAging_v2 @PayerNames = N'BLUE CROSS BLUE SHIELD OF IL';
GO
