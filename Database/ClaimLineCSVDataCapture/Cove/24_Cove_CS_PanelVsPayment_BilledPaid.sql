/* =============================================================================
   Cove - Collection Summary > Panel Vs Payment (client logic 20 Oct 2026)
   File     : 24_Cove_CS_PanelVsPayment_BilledPaid.sql
   Database : CoveLRN
   Source   : Cove Collection Panel Vs Payment Logic 10202026.xlsx

   Rows    : Panelname (sorted by Billed Claim Count)
   Columns : FirstBilledDate year / month
   Values  : Billed Claim Count   = Count unique ClaimID where BillStatus = Billed / Billed - Client Bill
             Total Billed Charges = Sum ChargeAmount  where BillStatus = Billed / Billed - Client Bill
             Paid Claim Count     = Count unique ClaimID where InsurancePayment > 0 and CheckDate not blank
             Insurance Payment    = Sum InsurancePayment where InsurancePayment > 0 and CheckDate not blank
   Paid claims sit in their FirstBilledDate month (was CheckDate month).

   Client check (ClaimLevelData loaded 2026-10-16): Grand Total 38,622 billed claims, $54,698,854.80
   billed charges, 25,065 paid claims, $15,629,842.51 insurance payment; UTI Nov 2025 = 1,099 /
   $2,197,720.00 / 957 / $887,350.16.

   usp_RefreshCove_CS_PanelVsPayment_ClientLogic (the SP ClaimLineCSVDataCapture runs after each
   Cove load) now calls usp_RefreshCove_CS_PanelVsPayment. Safe to re-run.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF COL_LENGTH(N'dbo.Cove_CS_PanelVsPayment', N'BilledClaims') IS NULL
    ALTER TABLE dbo.Cove_CS_PanelVsPayment ADD BilledClaims INT NOT NULL
        CONSTRAINT DF_Cove_CS_PanelVsPayment_BilledClaims DEFAULT 0;
GO
IF COL_LENGTH(N'dbo.Cove_CS_PanelVsPayment', N'BilledCharges') IS NULL
    ALTER TABLE dbo.Cove_CS_PanelVsPayment ADD BilledCharges DECIMAL(18,2) NOT NULL
        CONSTRAINT DF_Cove_CS_PanelVsPayment_BilledCharges DEFAULT 0;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCove_CS_PanelVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL,
    @Live            BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo, @CheckDateFrom, @CheckDateTo) IS NULL
    BEGIN
        SELECT PanelName, BilledYear, BilledMonth, BilledClaims, BilledCharges,
               NoOfClaims, InsurancePayment AS InsurancePayments
        FROM   dbo.Cove_CS_PanelVsPayment
        ORDER BY PanelName, BilledYear, BilledMonth;
        RETURN;
    END;

    WITH c AS
    (
        SELECT PanelName = LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))),
               ClaimKey  = NULLIF(LTRIM(RTRIM(ClaimID)), ''),
               FirstBill = TRY_CAST(FirstBilledDate AS DATE),
               IsBilled  = CASE WHEN LTRIM(RTRIM(BillStatus)) IN (N'Billed', N'Billed - Client Bill') THEN 1 ELSE 0 END,
               IsPaid    = CASE WHEN ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
                                 AND NULLIF(LTRIM(RTRIM(CheckDate)), '') IS NOT NULL THEN 1 ELSE 0 END,
               ChargeAmt = ISNULL(TRY_CAST(ChargeAmount     AS DECIMAL(18,2)), 0),
               InsPay    = ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0)
        FROM   dbo.ClaimLevelData
        WHERE (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
               OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
          AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
               OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT PanelName,
           BilledYear        = YEAR(FirstBill),
           BilledMonth       = CAST(MONTH(FirstBill) AS TINYINT),
           BilledClaims      = COUNT(DISTINCT CASE WHEN IsBilled = 1 THEN ClaimKey END),
           BilledCharges     = CAST(ISNULL(SUM(CASE WHEN IsBilled = 1 THEN ChargeAmt END), 0) AS DECIMAL(18,2)),
           NoOfClaims        = COUNT(DISTINCT CASE WHEN IsPaid = 1 THEN ClaimKey END),
           InsurancePayments = CAST(ISNULL(SUM(CASE WHEN IsPaid = 1 THEN InsPay END), 0) AS DECIMAL(18,2))
    FROM   c
    WHERE  FirstBill IS NOT NULL
      AND  YEAR(FirstBill) > 1900
      AND  (IsBilled = 1 OR IsPaid = 1)
    GROUP BY PanelName, YEAR(FirstBill), MONTH(FirstBill)
    ORDER BY PanelName, BilledYear, BilledMonth
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelVsPayment
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        PanelName         NVARCHAR(500),
        BilledYear        INT,
        BilledMonth       TINYINT,
        BilledClaims      INT,
        BilledCharges     DECIMAL(18,2),
        NoOfClaims        INT,
        InsurancePayments DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetCove_CS_PanelVsPayment @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.Cove_CS_PanelVsPayment;
        INSERT INTO dbo.Cove_CS_PanelVsPayment
            (PanelName, BilledYear, BilledMonth, BilledClaims, BilledCharges, NoOfClaims, InsurancePayment, RefreshedAt)
        SELECT PanelName, BilledYear, BilledMonth, BilledClaims, BilledCharges, NoOfClaims, InsurancePayments, GETDATE()
        FROM #R;
    COMMIT;

    PRINT 'usp_RefreshCove_CS_PanelVsPayment completed.';
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCove_CS_PanelVsPayment_ClientLogic
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_RefreshCove_CS_PanelVsPayment;
END;
GO

EXEC dbo.usp_RefreshCove_CS_PanelVsPayment;
GO

SELECT DB_NAME()                 AS CurrentDatabase,
       COUNT(*)                  AS SnapshotRows,
       SUM(BilledClaims)         AS BilledClaims,
       SUM(BilledCharges)        AS BilledCharges,
       SUM(NoOfClaims)           AS PaidClaims,
       SUM(InsurancePayment)     AS InsurancePayment,
       MAX(RefreshedAt)          AS RefreshedAt
FROM   dbo.Cove_CS_PanelVsPayment;
GO
