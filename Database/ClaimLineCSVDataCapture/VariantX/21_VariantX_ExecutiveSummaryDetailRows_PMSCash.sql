/* =============================================================================
   VariantX – Executive Summary PMS/Cash Detail-Rows SP
   Mirrors 16_VariantX_ExecutiveSummary_Aggregate RoleIDs (FirstBilledDate / ClaimID).
   Generic name: dbo.usp_GetExecutiveSummaryDetail_PMSCash
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
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
            ELSE N'CAST('''' AS NVARCHAR(200))'
        END;

    DECLARE @BillStatusExpr NVARCHAR(400) =
        CASE
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'BillStatus') IS NOT NULL
                THEN N'ISNULL(BillStatus, '''')'
            ELSE N'CASE WHEN LTRIM(RTRIM(ISNULL(ClaimStatus, ''''))) IN (''Unbilled'',''Unbilled - PB'') THEN ''Unbilled'' ELSE ''Billed'' END'
        END;

    DROP TABLE IF EXISTS #Base;
    CREATE TABLE #Base
    (
        ClaimKey              NVARCHAR(100)   NULL,
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
        NULLIF(LTRIM(RTRIM(ClaimID)), ''''),
        AccessionNumber,
        ' + @PatientExpr + N' AS PatientName,
        LTRIM(RTRIM(ISNULL(PayerName, ''''))) AS PayerName,
        ISNULL(LTRIM(RTRIM(Panelname)), '''') AS Panelname,
        ' + @ClinicExpr + N' AS ClinicName,
        ' + @ProviderExpr + N' AS BillingProvider,
        DateofService,
        FirstBilledDate,
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
    WHERE TRY_CAST(FirstBilledDate AS DATE) IS NOT NULL
      AND NULLIF(LTRIM(RTRIM(ClaimID)), '''') IS NOT NULL
      AND (@Year = 0  OR YEAR (TRY_CAST(FirstBilledDate AS DATE)) = @Year)
      AND (@Month = 0 OR MONTH(TRY_CAST(FirstBilledDate AS DATE)) = @Month);';

    EXEC sys.sp_executesql @sql,
        N'@Year INT, @Month INT',
        @Year = @Year, @Month = @Month;

    SELECT DISTINCT
        b.ClaimKey         AS VisitNumber,
        b.AccessionNumber,
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
           (@RowCode = 'F')
        OR (@RowCode = 'G')  -- mismatch drill: all billed claims (same as F)
        OR (@RowCode = 'H'   AND b.ClaimStatus = 'Fully Paid')
        OR (@RowCode = 'I'   AND b.ClaimStatus = 'Patient Responsibility')
        OR (@RowCode = 'J'   AND b.ClaimStatus = 'Fully Adjusted')
        OR (@RowCode = 'K'   AND b.ClaimStatus = 'Partially Adjusted')
        OR (@RowCode = 'L'   AND b.ClaimStatus = 'Partially Paid')
        OR (@RowCode = 'M'   AND b.ClaimStatus = 'Patient Payment')
        OR (@RowCode = 'N'   AND b.ClaimStatus IN ('Fully Denied','Denied','Partially Denied','No Response'))
        OR (@RowCode = 'N.1' AND b.ClaimStatus IN ('Fully Denied','Denied'))
        OR (@RowCode = 'N.2' AND b.ClaimStatus = 'Partially Denied')
        OR (@RowCode = 'N.3' AND b.ClaimStatus = 'No Response')
        OR (@RowCode = 'O')
        OR (@RowCode = 'P'   AND b.ClaimStatus = 'Fully Paid')
        OR (@RowCode = 'Q')
        OR (@RowCode = 'R')
        OR (@RowCode = 'S')  -- derived; show all billed-period claims
        OR (@RowCode = 'T'   AND b.ClaimStatus = 'Partially Paid')
        OR (@RowCode = 'U')
        OR (@RowCode = 'U.1' AND b.ClaimStatus IN ('Denied','Fully Denied'))
        OR (@RowCode = 'U.2' AND b.ClaimStatus = 'Partially Denied')
        OR (@RowCode = 'U.3' AND b.ClaimStatus = 'No Response')
    ORDER BY b.FirstBilledDate, b.ClaimKey;

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '21_VariantX_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO
