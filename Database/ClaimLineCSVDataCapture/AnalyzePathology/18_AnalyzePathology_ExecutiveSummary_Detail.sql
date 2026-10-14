/* =============================================================================
   Analyze Pathology (prefix AnP_) - GENERATED from Sql/VariantX/18_VariantX_ExecutiveSummary_Detail.sql
   by Generate-FromVariantX.ps1. Edit the VariantX script or the generator, not this file.
   Database: AnalyzePathology

   Analyze Pathology mappings applied on top of the VariantX logic:
     ClaimLevelData.AdjucticatedCount / Bucket30Count / Bucket60Count
         -> Adjudicated / Bucket30 / Bucket60  (AdjucticatedAmount -> AdjudicatedAmount)
     Billed / Unbilled from ClaimLevelData.BilledStatus LIKE 'Unbilled%'
     ClaimStatus 'Fully Denied' counts as 'Denied', '0 Billed Amount' as 'Billed Amount 0'
     LIMSMaster.BillCategory 'Unbilled' counts as 'Not Billed',
         NewStatus 'Yet to Be Validate' as 'Yet to be validated'
     LIMSMaster panel column: PanelName (PanelCategory is never populated)
   Comments further down were written for VariantX ("AnalyzePathology" there
   was substituted for "VariantX").
   ============================================================================= */
/* =============================================================================
   Analyze Pathology — cloned from Elixir (18_Elixir_ExecutiveSummary_Detail.sql)
   Prefix: AnP_ / AnP_CS_ / AnP_ES_
   Refresh: usp_RefreshAnP_*
   Read:    usp_GetAnP_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.

   Display columns auto-detected; missing ClaimLevel columns fall back to ''
   (safe when scripts 02-05 ClaimLevel alters are skipped).
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_ExecutiveSummary_Detail
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
            WHEN COL_LENGTH(N'dbo.ClaimLevelData', N'BilledStatus') IS NOT NULL
                THEN N'CASE WHEN LTRIM(RTRIM(ISNULL(BilledStatus, ''''))) LIKE ''Unbilled%'' THEN ''Unbilled'' ELSE ''Billed'' END'
            ELSE N'CASE WHEN LTRIM(RTRIM(ISNULL(BilledStatus, ''''))) LIKE ''Unbilled%'' THEN ''Unbilled'' ELSE ''Billed'' END'
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
               (@RowCode = 'F'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','0 Billed Amount','Unbilled'))
            OR (@RowCode = 'G'    AND b.BilledUnbilled = 'Unbilled')
            OR (@RowCode = 'H'    AND b.ClaimStatus = 'Voided')
            OR (@RowCode = 'I'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Billed Amount 0','0 Billed Amount','Unbilled'))
            OR (@RowCode = 'J'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
            OR (@RowCode = 'K'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Responsibility')
            OR (@RowCode = 'L'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Patient Payment')
            OR (@RowCode = 'M'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Adjusted')
            OR (@RowCode = 'N'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Adjusted')
            OR (@RowCode = 'O'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
            OR (@RowCode = 'P'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Denied','Fully Denied','No Response','Partially Denied'))
            OR (@RowCode = 'P.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Denied','Fully Denied'))
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
               (@RowCode = 'Q'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0','0 Billed Amount'))
            OR (@RowCode = 'R'    AND b.ClaimStatus = 'Unbilled')
            OR (@RowCode = 'S'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Fully Paid')
            OR (@RowCode = 'T'    AND b.BilledUnbilled = 'Billed')
            OR (@RowCode = 'U'    AND b.BilledUnbilled = 'Billed')
            OR (@RowCode = 'V'    AND b.BilledUnbilled = 'Billed')
            OR (@RowCode = 'W'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'Partially Paid')
            OR (@RowCode = 'X'    AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus NOT IN ('Unbilled','Billed Amount 0','0 Billed Amount'))
            OR (@RowCode = 'X.1'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Denied','Fully Denied'))
            OR (@RowCode = 'X.2'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus IN ('Partially Denied','Partially Paid','Partially Adjusted','Patient Responsibility'))
            OR (@RowCode = 'X.3'  AND b.BilledUnbilled = 'Billed' AND b.ClaimStatus = 'No Response')
        ORDER BY b.DateofService, b.AccessionNumber;
    END

    DROP TABLE IF EXISTS #Base;
END;
GO

PRINT '18_AnalyzePathology_ExecutiveSummary_Detail.sql completed.';
GO
