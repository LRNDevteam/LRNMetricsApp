/*
    Elixir - Unbilled x Aging payer-row correction

    Rows    : PayerName_Raw
    Columns : AgingDOS (returned as AgingBucket)
    Values  : COUNT(DISTINCT visit/accession), SUM(ChargeAmount)
    Filter  : FirstBilledDate is blank and PayerName_Raw is not blank

    The output column remains named PanelName for compatibility with the
    existing dashboard reader; its value is now PayerName_Raw.
*/
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshElix_UnbilledAging
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        LTRIM(RTRIM(PayerName_Raw)) AS PanelName,
        ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), 'Unknown') AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        )) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    INTO #Result
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), 'Unknown');

    TRUNCATE TABLE dbo.Elix_UnbilledAging;

    INSERT INTO dbo.Elix_UnbilledAging
        (PanelName, AgingBucket, ClaimCount, TotalCharges, RefreshedAt)
    SELECT
        PanelName,
        AgingBucket,
        ClaimCount,
        TotalCharges,
        GETDATE()
    FROM #Result;

    DROP TABLE IF EXISTS #Result;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetElix_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom IS NOT NULL OR @DosTo IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @FirstBilledFrom IS NOT NULL OR @FirstBilledTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, AgingBucket, ClaimCount, TotalCharges
        FROM dbo.Elix_UnbilledAging
        ORDER BY PanelName, AgingBucket;
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

    DECLARE @HasPayerFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(PayerName_Raw)) AS PanelName,
        ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), 'Unknown') AS AgingBucket,
        COUNT(DISTINCT COALESCE(
            NULLIF(LTRIM(RTRIM(AccessionNumber)), ''),
            NULLIF(LTRIM(RTRIM(ClaimID)), '')
        )) AS ClaimCount,
        ISNULL(SUM(TRY_CAST(ChargeAmount AS DECIMAL(18,2))), 0) AS TotalCharges
    FROM dbo.ClaimLevelData
    WHERE (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
      AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
      AND (@HasPayerFilter = 0
           OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0
           OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
      AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBilledFrom)
      AND (@FirstBilledTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBilledTo)
    GROUP BY
        LTRIM(RTRIM(PayerName_Raw)),
        ISNULL(NULLIF(LTRIM(RTRIM(AgingDOS)), ''), 'Unknown')
    ORDER BY PanelName, AgingBucket;
END;
GO

-- Apply the correction to the current snapshot.
EXEC dbo.usp_RefreshElix_UnbilledAging;
GO

-- Verification.
SELECT
    PanelName AS PayerName_Raw,
    AgingBucket,
    ClaimCount AS VisitCount,
    TotalCharges
FROM dbo.Elix_UnbilledAging
ORDER BY PanelName, AgingBucket;
GO
