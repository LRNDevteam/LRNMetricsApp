-- =====================================================================
-- InHealthDTR -- Collection Summary > Panel vs Payment (14 Oct 2026)
-- Deploy on: InHealthDTRLRN
--
-- Client layout: Panel Name | No of Claims | Carrier Payment, one row per panel,
-- filter InsurancePayment > 0 only (no CheckDate filter), sorted by payment DESC.
--   Toxicology 45,512 | UTI Panel 41 | STI Panel 6 | RPP Panel 3 | Wound Panel 2
--   Grand Total 45,564 / $6,893,662.86
--
-- Was: InsurancePayment <> 0 AND CheckDate not blank, one row per panel x CheckDate month
-- (25,212 paid claims / $3,795,047.76 with a blank CheckDate were left out).
-- Rows are stored with BilledYear = 0 / BilledMonth = 0, so the page and Excel show
-- the flat per-panel table. Panel = PanelNameBasedOnCPT (Panelname is blank for this lab).
-- Safe to rerun.
-- =====================================================================
USE InHealthDTRLRN;
GO

-- 8. Panel vs Payment
CREATE OR ALTER PROCEDURE dbo.usp_RefreshIHD_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.IHD_CS_PanelVsPayment;

    INSERT INTO dbo.IHD_CS_PanelVsPayment
        (PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))            AS PanelName,
        0                                                               AS BilledYear,
        CAST(0 AS TINYINT)                                              AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))               AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)     AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
    GROUP BY LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')));

    PRINT 'usp_RefreshIHD_CS_PanelVsPayment completed.';
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetIHD_CS_PanelVsPayment
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)),  '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)),  '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT PanelName, BilledYear, BilledMonth, NoOfClaims, InsurancePayment
        FROM   dbo.IHD_CS_PanelVsPayment
        ORDER  BY InsurancePayment DESC, PanelName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))           AS PanelName,
        0                                                              AS BilledYear,
        CAST(0 AS TINYINT)                                             AS BilledMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))              AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)    AS InsurancePayment
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(ISNULL(PanelNameBasedOnCPT, 'Unknown')))
    ORDER BY InsurancePayment DESC, PanelName;
END
GO

EXEC dbo.usp_RefreshIHD_CS_PanelVsPayment;
GO

SELECT PanelName, NoOfClaims, InsurancePayment FROM dbo.IHD_CS_PanelVsPayment ORDER BY InsurancePayment DESC;
SELECT SUM(NoOfClaims) AS GrandClaims, SUM(InsurancePayment) AS GrandPayment FROM dbo.IHD_CS_PanelVsPayment;
GO
