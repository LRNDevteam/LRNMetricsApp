/* =============================================================================
   06_CodingValidation_Diag_2026-07-29.sql
   -----------------------------------------------------------------------------
   DIAGNOSTIC ONLY - creates a log table + procedure that shows exactly where the
   Coding Validation numbers come from for a given set of Visit Numbers.

   Nothing in the live reporting path calls these objects; they are safe to
   deploy and safe to drop.

   WHY THIS EXISTS
   ---------------
   Two different families of numbers are often confused:

     A) The six "Avg" columns
          MissingCPT_AvgAllowedAmount / _AvgPaidAmount / _AvgPatientResponsibilityAmount
          AdditionalCPT_AvgAllowedAmount / _AvgPaidAmount / _AvgPatientResponsibilityAmount
        --> These are NOT calculated by SQL. They are copied verbatim from the
            CodingValidated source workbook produced by LRN.CodingMaster.Runner
            (LRN.CodingMasterValidation.ChargeCalculator). Re-running any SQL or
            EXEC usp_RefreshCodingAggregates can NEVER change them. They only
            change after the Runner is rebuilt, the lab re-run, and the new file
            re-captured into dbo.CodingValidation.

     B) The aggregate columns (Total Billed Charges, Lost Revenue, Revenue at
        Risk, Net Impact, claim counts)
        --> These ARE calculated by usp_RefreshCodingAggregates from the values
            in (A), so they change after an EXEC.

   The procedure below reports BOTH so the two can be told apart at a glance.

   USAGE
   -----
     EXEC dbo.usp_LogCodingValidationDiag;                       -- default 4 visits
     EXEC dbo.usp_LogCodingValidationDiag '19306278,19308144';   -- custom list
     SELECT * FROM dbo.CodingValidationDiagLog ORDER BY DiagId;  -- review later

   REVERT:
     DROP PROCEDURE dbo.usp_LogCodingValidationDiag;
     DROP TABLE dbo.CodingValidationDiagLog;
   ============================================================================= */

SET NOCOUNT ON;
GO

/* ---- 1) Log table ---------------------------------------------------------- */
IF OBJECT_ID('dbo.CodingValidationDiagLog', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.CodingValidationDiagLog
    (
        DiagId          INT IDENTITY(1,1) NOT NULL
            CONSTRAINT PK_CodingValidationDiagLog PRIMARY KEY CLUSTERED,
        LoggedOn        DATETIME       NOT NULL CONSTRAINT DF_CodingValidationDiagLog_LoggedOn DEFAULT GETDATE(),

        -- identity
        VisitNumber     NVARCHAR(500)  NULL,
        AccessionNo     NVARCHAR(500)  NULL,
        PanelName       NVARCHAR(500)  NULL,
        WeekFolder      NVARCHAR(500)  NULL,
        DateofService   NVARCHAR(500)  NULL,
        FirstBillDate   NVARCHAR(500)  NULL,
        PayerName_Raw   NVARCHAR(500)  NULL,
        PayerCommonCode NVARCHAR(500)  NULL,

        -- source-of-truth for the period bucketing (CVBILL-1.4)
        BillDate        DATE           NULL,
        BillYear        INT            NULL,
        BillWeek        NVARCHAR(50)   NULL,   -- Fri->Thu label when inside the WTD window
        Scope           VARCHAR(10)    NULL,   -- WTD | YTD | (NULL = outside both)

        -- (A) values copied VERBATIM from the source workbook - SQL never computes these
        MissingCPTCodes                 NVARCHAR(MAX) NULL,
        AdditionalCPTCodes              NVARCHAR(MAX) NULL,
        TotalCharge                     NVARCHAR(500) NULL,
        MissingCPT_Charges              NVARCHAR(500) NULL,
        AdditionalCPT_Charges           NVARCHAR(500) NULL,
        MissingCPT_AvgAllowedAmount     NVARCHAR(500) NULL,
        MissingCPT_AvgPaidAmount        NVARCHAR(500) NULL,
        MissingCPT_AvgPtRespAmount      NVARCHAR(500) NULL,
        AdditionalCPT_AvgAllowedAmount  NVARCHAR(500) NULL,
        AdditionalCPT_AvgPaidAmount     NVARCHAR(500) NULL,
        AdditionalCPT_AvgPtRespAmount   NVARCHAR(500) NULL,

        -- (B) what the aggregates derive from this row
        Agg_TotalBilledCharges  DECIMAL(18,2) NULL,   -- SUM(TotalCharge) for the panel/period
        Agg_LostRevenue         DECIMAL(18,2) NULL,   -- SUM(MissingCPT_AvgAllowedAmount)
        Agg_RevenueAtRisk       DECIMAL(18,2) NULL,   -- SUM(AdditionalCPT_AvgAllowedAmount)
        Agg_NetImpact           DECIMAL(18,2) NULL,   -- AtRisk - Lost
        Agg_DistinctClaims      INT           NULL,   -- COUNT(DISTINCT VisitNumber)

        SourceRunId     NVARCHAR(500)  NULL,   -- which loaded file this row came from
        Notes           NVARCHAR(400)  NULL
    );
END
GO

/* ---- 2) Diagnostic procedure ---------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_LogCodingValidationDiag
    @VisitNumbers NVARCHAR(MAX) = '19306278,19308144,19307765,19308149',
    @ClearFirst   BIT           = 1
AS
BEGIN
    SET NOCOUNT ON;

    IF @ClearFirst = 1
        DELETE FROM dbo.CodingValidationDiagLog;

    DECLARE @Visits TABLE (VisitNumber NVARCHAR(500) NOT NULL);
    INSERT INTO @Visits (VisitNumber)
    SELECT DISTINCT LTRIM(RTRIM(value))
    FROM STRING_SPLIT(@VisitNumbers, ',')
    WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    /* Rebuild the SAME billed-date window the refresh proc uses (CVBILL-1.4):
       WTD = the latest 2 Friday->Thursday weeks; YTD = everything billed earlier. */
    DECLARE @WtdWeeks INT = 2;
    DECLARE @MaxBill DATE =
        (SELECT MAX(TRY_CAST(FirstBillDate AS DATE))
         FROM dbo.CodingValidation
         WHERE PanelName IS NOT NULL AND PanelName <> '');
    DECLARE @WtdEnd   DATE = DATEADD(DAY, (3 - (DATEDIFF(DAY, '19000101', @MaxBill) % 7) + 7) % 7, @MaxBill);
    DECLARE @WtdStart DATE = DATEADD(DAY, -(7 * @WtdWeeks - 1), @WtdEnd);

    INSERT INTO dbo.CodingValidationDiagLog
    (
        VisitNumber, AccessionNo, PanelName, WeekFolder, DateofService, FirstBillDate,
        PayerName_Raw, PayerCommonCode,
        BillDate, BillYear, BillWeek, Scope,
        MissingCPTCodes, AdditionalCPTCodes, TotalCharge,
        MissingCPT_Charges, AdditionalCPT_Charges,
        MissingCPT_AvgAllowedAmount, MissingCPT_AvgPaidAmount, MissingCPT_AvgPtRespAmount,
        AdditionalCPT_AvgAllowedAmount, AdditionalCPT_AvgPaidAmount, AdditionalCPT_AvgPtRespAmount,
        Agg_TotalBilledCharges, Agg_LostRevenue, Agg_RevenueAtRisk, Agg_NetImpact, Agg_DistinctClaims,
        SourceRunId, Notes
    )
    SELECT
        cv.VisitNumber, cv.AccessionNo, cv.PanelName, cv.WeekFolder, cv.DateofService, cv.FirstBillDate,
        cv.PayerName_Raw, cv.PayerCommonCode,
        b.BillDate,
        YEAR(b.BillDate),
        CASE WHEN b.BillDate BETWEEN @WtdStart AND @WtdEnd
             THEN CONVERT(NVARCHAR(10), DATEADD(DAY, -6, we.WeekEnd), 101) + ' to ' +
                  CONVERT(NVARCHAR(10), we.WeekEnd, 101) END,
        CASE WHEN b.BillDate BETWEEN @WtdStart AND @WtdEnd THEN 'WTD'
             WHEN b.BillDate < @WtdStart                   THEN 'YTD' END,

        cv.MissingCPTCodes, cv.AdditionalCPTCodes, cv.TotalCharge,
        cv.MissingCPT_Charges, cv.AdditionalCPT_Charges,
        cv.MissingCPT_AvgAllowedAmount, cv.MissingCPT_AvgPaidAmount, cv.MissingCPT_AvgPatientResponsibilityAmount,
        cv.AdditionalCPT_AvgAllowedAmount, cv.AdditionalCPT_AvgPaidAmount, cv.AdditionalCPT_AvgPatientResponsibilityAmount,

        agg.TotalBilledCharges, agg.LostRevenue, agg.RevenueAtRisk,
        ISNULL(agg.RevenueAtRisk,0) - ISNULL(agg.LostRevenue,0),
        agg.DistinctClaims,

        cv.RunNumber,
        'Avg* columns are copied from the source workbook - SQL does not compute them.'
    FROM dbo.CodingValidation cv
    INNER JOIN @Visits v ON v.VisitNumber = LTRIM(RTRIM(cv.VisitNumber))
    CROSS APPLY (SELECT BillDate = TRY_CAST(cv.FirstBillDate AS DATE)) b
    CROSS APPLY (SELECT WeekEnd = DATEADD(DAY, (3 - (DATEDIFF(DAY, '19000101', b.BillDate) % 7) + 7) % 7, b.BillDate)) we
    OUTER APPLY (
        /* Panel + billed-year totals this row contributes to - mirrors the refresh proc. */
        SELECT
            TotalBilledCharges = SUM(TRY_CAST(x.TotalCharge AS DECIMAL(18,2))),
            LostRevenue        = SUM(TRY_CAST(x.MissingCPT_AvgAllowedAmount    AS DECIMAL(18,2))),
            RevenueAtRisk      = SUM(TRY_CAST(x.AdditionalCPT_AvgAllowedAmount AS DECIMAL(18,2))),
            DistinctClaims     = COUNT(DISTINCT x.VisitNumber)
        FROM dbo.CodingValidation x
        WHERE x.PanelName = cv.PanelName
          AND YEAR(TRY_CAST(x.FirstBillDate AS DATE)) = YEAR(b.BillDate)
    ) agg;

    /* ---- Result 1: the per-visit detail ---- */
    SELECT * FROM dbo.CodingValidationDiagLog ORDER BY DiagId;

    /* ---- Result 2: which source file each visit came from ---- */
    SELECT DISTINCT
        cv.VisitNumber, cv.RunNumber AS SourceFile, f.RunId, f.FileName, f.InsertedDateTime
    FROM dbo.CodingValidation cv
    INNER JOIN @Visits v ON v.VisitNumber = LTRIM(RTRIM(cv.VisitNumber))
    LEFT JOIN dbo.CodingValidationFileLog f ON f.RunId = cv.FileLogId
    ORDER BY cv.VisitNumber;

    /* ---- Result 3: window context used above ---- */
    SELECT MaxBillDate = @MaxBill, WtdStart = @WtdStart, WtdEnd = @WtdEnd, WtdWeeks = @WtdWeeks;
END
GO

PRINT '06_CodingValidation_Diag_2026-07-29.sql completed.';
GO
