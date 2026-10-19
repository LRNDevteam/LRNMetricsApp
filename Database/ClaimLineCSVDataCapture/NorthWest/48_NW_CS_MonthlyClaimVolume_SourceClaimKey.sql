/* =============================================================================
   NorthWest - Collection Summary - Monthly Claim Volume unique claim count
   File     : 48_NW_CS_MonthlyClaimVolume_SourceClaimKey.sql
   Database : NWL_LRN

   Issue : NoOfClaims was COUNT(DISTINCT ClaimID) per Panel x Payer x CheckDate month.
           Daq and WebPM number ClaimID independently, so a Daq and a WebPM claim
           with the same ClaimID, payer and check month were counted once:
             SELECT COUNT(ClaimID) FROM ClaimLevelData
             WHERE TRY_CONVERT(DECIMAL(18,2), InsurancePayment) > 0 AND CheckDate <> ''
               AND PanelType = 'Toxicology'      -- 97,531 (page showed 97,530)
           Blood: 80,155 (page showed 80,153).
   Fix   : Unique claim = Source (AdditionalFields) + ClaimID, in the snapshot refresh
           and the filtered read. Same code as 11b_NorthWest_CS_MonthlyClaimVolume_NullCheckDate_Fix.sql
           and 15_NorthWest_CollectionSummary_ReadSPs.sql.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'48_NW_CS_MonthlyClaimVolume_SourceClaimKey.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_MonthlyClaimVolume
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(ISNULL(PanelType,        'Unknown')))               AS PanelName,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))               AS PayerName,
        YEAR (TRY_CAST(CheckDate AS DATE))                           AS BillYear,
        MONTH(TRY_CAST(CheckDate AS DATE))                           AS BillMonth,
        COUNT(DISTINCT CASE WHEN NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
                            THEN CONCAT(UPPER(LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(AdditionalFields, 'Source'), '')))),
                                        N'|', LTRIM(RTRIM(ClaimID))) END) AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment
    INTO #raw
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL   -- BillYear/BillMonth are NOT NULL
    GROUP BY
        LTRIM(RTRIM(ISNULL(PanelType,        'Unknown'))),
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
        YEAR (TRY_CAST(CheckDate AS DATE)),
        MONTH(TRY_CAST(CheckDate AS DATE));

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
            LTRIM(RTRIM(ISNULL(PanelType,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            YEAR (TRY_CAST(CheckDate AS DATE))             AS BillYear,
            MONTH(TRY_CAST(CheckDate AS DATE))             AS BillMonth,
            COUNT(DISTINCT CASE WHEN NULLIF(LTRIM(RTRIM(ClaimID)), '') IS NOT NULL
                                THEN CONCAT(UPPER(LTRIM(RTRIM(ISNULL(dbo.GetAdditionalField(AdditionalFields, 'Source'), '')))),
                                            N'|', LTRIM(RTRIM(ClaimID))) END) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelType,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PanelType,     'Unknown'))),
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

EXEC dbo.usp_RefreshNW_CS_MonthlyClaimVolume;
GO

SET NOEXEC OFF;
GO

PRINT '48_NW_CS_MonthlyClaimVolume_SourceClaimKey.sql completed.';
GO
