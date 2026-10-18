/* =============================================================================
   NorthWest - Collection Summary on ClaimLevelData.BilledUnbilled
   File     : 42_NW_CollectionSummary_BilledUnbilled.sql
   Database : NWL_LRN
   Requires : 40_NW_ClaimLevelData_BilledUnbilled.sql, 39_NW_CollectionSummary_ClientLogic.sql

   Panel Vs Payment   Rows    : PanelType (sorted by Billed Claim Count)
                      Columns : ChargeEnteredDate year / month
                      Values  : Billed Claim Count   = Count unique ClaimID where BilledUnbilled = Billed
                                Total Billed Charges = Sum ChargeAmount  where BilledUnbilled = Billed
                                Paid Claim Count     = Count unique ClaimID where InsurancePayment > 0
                                Insurance Payment    = Sum InsurancePayment where InsurancePayment > 0
   Panel Averages     Filter  : BilledUnbilled = Billed (was FirstBilledDate not blank).

   fn_NW_CS_Claims gains ChargeEntered and BilledUnbilled (same definition as script 39).
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'42_NW_CollectionSummary_BilledUnbilled.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'BilledUnbilled') IS NULL
BEGIN
    RAISERROR(N'ClaimLevelData.BilledUnbilled is missing - run 40_NW_ClaimLevelData_BilledUnbilled.sql first.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* -----------------------------------------------------------------------------
   Shared claim rows + dashboard filters
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_CS_Claims
(
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE,
    @CheckDateFrom DATE,
    @CheckDateTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimKey          = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        n.PayerName,
        n.PanelName,
        ClaimStatus       = ISNULL(NULLIF(LTRIM(RTRIM(c.ClaimStatus)), N''), N'(blank)'),
        Adjudicated       = LTRIM(RTRIM(c.Adjudicated)),
        Bucket30          = LTRIM(RTRIM(c.Bucket30)),
        Bucket60          = LTRIM(RTRIM(c.Bucket60)),
        Aging             = NULLIF(LTRIM(RTRIM(c.Aging)), N''),
        d.Dos,
        d.CheckDt,
        d.FirstBill,
        d.ChargeEntered,
        BilledUnbilled    = LTRIM(RTRIM(c.BilledUnbilled)),
        InsPay            = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        ChargeAmt         = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        PaymentPct        = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100,
        InsBalance        = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        PatientBalance    = ISNULL(TRY_CAST(c.PatientBalance   AS DECIMAL(18,2)), 0),
        CptCode           = ISNULL(NULLIF(LTRIM(RTRIM(c.CPTCodeXUnitsXModifier)), N''), N'(blank)'),
        ReferringProvider = NULLIF(LTRIM(RTRIM(c.ReferringProvider)), N'')
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        PayerName = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)), N''), N'Unknown'),
        PanelName = ISNULL(NULLIF(LTRIM(RTRIM(c.PanelType)),     N''), N'Unknown')) n
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateOfService,   101), TRY_CAST(c.DateOfService   AS DATE)),
        CheckDt   = COALESCE(TRY_CONVERT(DATE, c.CheckDate,       101), TRY_CAST(c.CheckDate       AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE)),
        ChargeEntered = COALESCE(TRY_CONVERT(DATE, c.ChargeEnteredDate, 101), TRY_CAST(c.ChargeEnteredDate AS DATE))) p
    -- 12/31/1899 is the file's blank-date placeholder.
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        CheckDt   = CASE WHEN p.CheckDt   >= '19010101' THEN p.CheckDt   END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END,
        ChargeEntered = CASE WHEN p.ChargeEntered >= '19010101' THEN p.ChargeEntered END) d
    WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR n.PanelName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR d.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR d.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR d.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR d.FirstBill <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR d.CheckDt   >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR d.CheckDt   <= @CheckDateTo);
GO

/* -----------------------------------------------------------------------------
   9. Panel Vs Payment - PanelType x ChargeEnteredDate year / month.
   ----------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.NW_CS_PanelVsPaymentBilled', N'U') IS NULL
CREATE TABLE dbo.NW_CS_PanelVsPaymentBilled
(
    SummaryId         INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    PanelName         NVARCHAR(500)  NOT NULL,
    BilledYear        SMALLINT       NOT NULL,
    BilledMonth       TINYINT        NOT NULL,
    BilledClaims      INT            NOT NULL DEFAULT 0,
    BilledCharges     DECIMAL(18,2)  NOT NULL DEFAULT 0,
    NoOfClaims        INT            NOT NULL DEFAULT 0,
    InsurancePayments DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_PanelVsPayment
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PanelName, BilledYear, BilledMonth, BilledClaims, BilledCharges, NoOfClaims, InsurancePayments
        FROM dbo.NW_CS_PanelVsPaymentBilled
        ORDER BY PanelName, BilledYear, BilledMonth;
        RETURN;
    END;

    SELECT PanelName,
           BilledYear        = CAST(YEAR(ChargeEntered)  AS SMALLINT),
           BilledMonth       = CAST(MONTH(ChargeEntered) AS TINYINT),
           BilledClaims      = CAST(COUNT(DISTINCT CASE WHEN BilledUnbilled = N'Billed' THEN ClaimKey END) AS INT),
           BilledCharges     = CAST(ISNULL(SUM(CASE WHEN BilledUnbilled = N'Billed' THEN ChargeAmt END), 0) AS DECIMAL(18,2)),
           NoOfClaims        = CAST(COUNT(DISTINCT CASE WHEN InsPay > 0 THEN ClaimKey END) AS INT),
           InsurancePayments = CAST(ISNULL(SUM(CASE WHEN InsPay > 0 THEN InsPay END), 0) AS DECIMAL(18,2))
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE ChargeEntered IS NOT NULL
      AND (BilledUnbilled = N'Billed' OR InsPay > 0)
    GROUP BY PanelName, YEAR(ChargeEntered), MONTH(ChargeEntered)
    ORDER BY PanelName, BilledYear, BilledMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelName         NVARCHAR(500),
        BilledYear        SMALLINT,
        BilledMonth       TINYINT,
        BilledClaims      INT,
        BilledCharges     DECIMAL(18,2),
        NoOfClaims        INT,
        InsurancePayments DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CS_PanelVsPayment @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CS_PanelVsPaymentBilled;
        INSERT INTO dbo.NW_CS_PanelVsPaymentBilled
            (PanelName, BilledYear, BilledMonth, BilledClaims, BilledCharges, NoOfClaims, InsurancePayments, RefreshedAt)
        SELECT PanelName, BilledYear, BilledMonth, BilledClaims, BilledCharges, NoOfClaims, InsurancePayments, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   Panel Averages - by DOS / by Check Date (Average Payments tabs).
   BilledUnbilled = Billed; @LastMonths months of DateOfService or CheckDate ending at
   the billed week-range end date (latest date in that column when there is no week
   folder). Returns every payer; the page shows panel totals plus the top 3 payers.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CS_AvgPayments_ClientLogic
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @CheckDateFrom DATE          = NULL,
    @CheckDateTo   DATE          = NULL,
    @DateBasis     VARCHAR(10)   = 'DOS',
    @LastMonths    INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseCheckDate BIT = CASE WHEN @DateBasis = 'CheckDate' THEN 1 ELSE 0 END;
    IF @LastMonths IS NULL OR @LastMonths < 1 SET @LastMonths = 6;

    SELECT PanelName, PayerName, ClaimKey, ChargeAmt, InsPay, ClaimStatus, Adjudicated, Bucket30, Bucket60,
           BasisDt = CASE WHEN @UseCheckDate = 1 THEN CheckDt ELSE Dos END
    INTO #b
    FROM dbo.fn_NW_CS_Claims(@PayerNames, @PanelNames, @DosFrom, @DosTo,
                             @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo)
    WHERE BilledUnbilled = N'Billed'
    OPTION (RECOMPILE);

    DECLARE @WindowTo   DATE = ISNULL(dbo.fn_NW_CS_LatestWeekFolderEnd(), (SELECT MAX(BasisDt) FROM #b));
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, DATEADD(MONTH, -@LastMonths, @WindowTo));

    SELECT PanelName,
           PayerName,
           NoOfClaims        = CAST(COUNT(ClaimKey) AS INT),
           TotalCharges      = CAST(ISNULL(SUM(ChargeAmt), 0) AS DECIMAL(18,2)),
           CarrierPayment    = CAST(ISNULL(SUM(InsPay), 0) AS DECIMAL(18,2)),
           FullyPaidCount    = CAST(COUNT(CASE WHEN ClaimStatus = N'Fully Paid' THEN ClaimKey END) AS INT),
           FullyPaidAmount   = CAST(ISNULL(SUM(CASE WHEN ClaimStatus = N'Fully Paid' THEN InsPay END), 0) AS DECIMAL(18,2)),
           AdjudicatedCount  = CAST(COUNT(CASE WHEN Adjudicated = N'Adjudicated' THEN ClaimKey END) AS INT),
           AdjudicatedAmount = CAST(ISNULL(SUM(CASE WHEN Adjudicated = N'Adjudicated' THEN InsPay END), 0) AS DECIMAL(18,2)),
           Days30Count       = CAST(COUNT(CASE WHEN Bucket30 = N'30 Bucket' THEN ClaimKey END) AS INT),
           Days30Amount      = CAST(ISNULL(SUM(CASE WHEN Bucket30 = N'30 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2)),
           Days60Count       = CAST(COUNT(CASE WHEN Bucket60 = N'60 Bucket' THEN ClaimKey END) AS INT),
           Days60Amount      = CAST(ISNULL(SUM(CASE WHEN Bucket60 = N'60 Bucket' THEN InsPay END), 0) AS DECIMAL(18,2)),
           WindowFrom        = @WindowFrom,
           WindowTo          = @WindowTo
    FROM #b
    WHERE BasisDt BETWEEN @WindowFrom AND @WindowTo
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END;
GO

EXEC dbo.usp_RefreshNW_CS_PanelVsPayment;
GO

PRINT N'42_NW_CollectionSummary_BilledUnbilled.sql completed.';
GO
