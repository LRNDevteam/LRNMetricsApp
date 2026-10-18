/* =====================================================================
   Augustus Collection Report — client fixes (NEW SPs, do not drop LIVE)

   Deploy on Augustus_Labs. Existing usp_GetAug_CS_* / usp_RefreshAug_CS_*
   and dbo.usp_Create_CollectionClaimLevelData stay.

     dbo.usp_Create_CollectionClaimLevelData_v2
     dbo.usp_GetAug_CS_Top5ReimbursementPct_v2
     dbo.usp_GetAug_CS_Top5ReimbursementPay_v2
     dbo.usp_GetAug_CS_PanelVsPayment_v2
     dbo.usp_GetAug_CS_InsuranceVsPaymentPct_v2
     dbo.usp_GetAug_CS_InsuranceVsPayment_v2

   Source:
     Top 5              = dbo.ClaimLevelData
                          COUNT(ClaimID), AVG(PaymentPercent), sort by count
     Panel / Insurance  = dbo.CollectionClaimLevelData (Posted Date)
     (CollectionClaimLevelData is built by ingest usp_Create_CollectionClaimLevelData)

   Top 5 check: BCBS IL 5815 / 28%, Aetna Better Health 1875 / 16%
   Panel check: Blood / Jan 2025 = 139 / 17777.62
   ===================================================================== */
SET NOCOUNT ON;
GO

-- ============================================================
-- 0) Collection Claim Level Data v2
--    Excel 7-step using Encounter + PaymentPostedDate
--    Writes dbo.CollectionClaimLevelData_v2 (does not drop LIVE table)
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_Create_CollectionClaimLevelData_v2
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.CollectionClaimLevelData_v2', 'U') IS NOT NULL
        DROP TABLE dbo.CollectionClaimLevelData_v2;

    ;WITH SourceData AS
    (
        SELECT
            lld.*,
            EncKey = NULLIF(LTRIM(RTRIM(lld.EncounterPaymentPostedDate)), '')
        FROM dbo.LineLevelData lld
    ),
    CompareData AS
    (
        SELECT
            sd.*,
            TRUEorFALSE =
                CASE
                    WHEN sd.EncKey IS NOT NULL
                     AND sd.EncKey = LEAD(sd.EncKey) OVER (ORDER BY sd.EncKey, sd.RecordId)
                    THEN 'True'
                    ELSE 'False'
                END
        FROM SourceData sd
    )
    SELECT
        RecordId, FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
        LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
        PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code,
        Global_Payer_ID, PayerType, BillingProvider, ReferringProvider, ClinicName,
        SalesRepname, PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
        Panelname, CPTCode, Units, Modifier, POS, TOS,
        ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
        InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
        TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
        InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
        CheckDate, PostingDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
        ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
        InsertedDateTime, PaymentPostedDate, EncounterPaymentPostedDate, PanelNew,
        Source, UID, Valid, PanelCategory, PatientName, SubscriberId, ClaimAmount,
        [Date], EnteredStatus, BilledStatus, CptWithUnits, [Proc], CheqNo, AdjAmount,
        InsBalance, PatBalance, UpdatedDenial, CombinedDenial, PaymentPercent, Loc,
        BillingStatus, LBilledDate, BProcessDate,
        EncKey AS EncounterPaymentPostedKey,
        TRUEorFALSE
    INTO dbo.CollectionClaimLevelData_v2
    FROM CompareData
    WHERE TRUEorFALSE = 'False';

    ;WITH LineLevelPaymentSum AS
    (
        SELECT
            EncKey = NULLIF(LTRIM(RTRIM(lld.EncounterPaymentPostedDate)), ''),
            TotalInsurancePayment = SUM(
                ISNULL(TRY_CONVERT(decimal(18, 2), REPLACE(REPLACE(lld.InsurancePayment, ',', ''), '$', '')), 0)
            )
        FROM dbo.LineLevelData lld
        WHERE NULLIF(LTRIM(RTRIM(lld.EncounterPaymentPostedDate)), '') IS NOT NULL
        GROUP BY NULLIF(LTRIM(RTRIM(lld.EncounterPaymentPostedDate)), '')
    )
    UPDATE ccld
    SET ccld.InsurancePayment = CAST(lps.TotalInsurancePayment AS nvarchar(500))
    FROM dbo.CollectionClaimLevelData_v2 ccld
    INNER JOIN LineLevelPaymentSum lps
        ON ccld.EncounterPaymentPostedKey = lps.EncKey;

    PRINT 'usp_Create_CollectionClaimLevelData_v2 completed.';
END
GO

-- Shared live source for GET v2 SPs: CollectionClaimLevelData (ingest),
-- or CollectionClaimLevelData_v2 when that table has been built.
-- Each GET inlines the same WHERE so we do not depend on a view.

-- ============================================================
-- 1) Top 5 Reimbursement % — client Excel (Claim Level Data)
--    Filter = InsurancePayment > 0
--             PayerName_Raw NOT IN (None, ClientBill, Selfpay)
--    Row    = PayerName_Raw
--    Values = COUNT(ClaimID), AVG(PaymentPercent)
--    Sort   = Count of ClaimID DESC, Top 5
--    Check: BCBS IL 5815 / 28%, Aetna Better Health 1875 / 16%
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_Top5ReimbursementPct_v2
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
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))    AS Chg,
            TRY_CAST(REPLACE(REPLACE(PaymentPercent, '%', ''), ',', '') AS DECIMAL(18,6)) AS PayPctRaw
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND LTRIM(RTRIM(ISNULL(PayerName_Raw, ''))) NOT IN ('None', 'ClientBill', 'Selfpay')
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT TOP 5
        CAST(ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, ISNULL(SUM(InsPay), 0) DESC) AS INT) AS PayerRank,
        PayerName,
        ISNULL(SUM(InsPay), 0) AS SumInsurancePayment,
        ISNULL(SUM(Chg),    0) AS SumChargeAmount,
        COUNT(*)               AS UniqueVisitCount,
        CAST(ROUND(
            AVG(CASE WHEN PayPctRaw IS NULL THEN NULL
                     WHEN PayPctRaw <= 1 THEN PayPctRaw * 100
                     ELSE PayPctRaw END),
            0) AS DECIMAL(9,4)) AS PaymentPct
    FROM src
    GROUP BY PayerName
    ORDER BY UniqueVisitCount DESC, SumInsurancePayment DESC;
END
GO

-- ============================================================
-- 2) Top 5 Total Payments — same Claim Level grain, rank by Count of ClaimID
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_Top5ReimbursementPay_v2
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
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT TOP 5
        CAST(ROW_NUMBER() OVER (ORDER BY COUNT(*) DESC, ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) DESC) AS INT) AS PayerRank,
        LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))                         AS PayerName,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)            AS TotalPayments,
        COUNT(*)                                                               AS UniqueVisitCount
    FROM dbo.ClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND LTRIM(RTRIM(ISNULL(PayerName_Raw, ''))) NOT IN ('None', 'ClientBill', 'Selfpay')
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))
    ORDER BY UniqueVisitCount DESC, TotalPayments DESC;
END
GO

-- ============================================================
-- 3) Panel vs Payment — monthly Count of PanelNew + Sum Ins. Pay
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_PanelVsPayment_v2
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
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), 'Unknown'))) AS PanelName,
        COUNT(*)                                                            AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayments,
        YEAR (TRY_CAST(PostingDate AS DATE))                                AS BilledYear,
        CAST(MONTH(TRY_CAST(PostingDate AS DATE)) AS TINYINT)               AS BilledMonth
    FROM dbo.CollectionClaimLevelData
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND TRY_CAST(PostingDate AS DATE) IS NOT NULL
      AND YEAR(TRY_CAST(PostingDate AS DATE)) > 1900
      AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), 'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate     AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate     AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ISNULL(NULLIF(LTRIM(RTRIM(PanelNew)), ''), 'Unknown'))),
        YEAR (TRY_CAST(PostingDate AS DATE)),
        MONTH(TRY_CAST(PostingDate AS DATE))
    ORDER BY BilledYear, BilledMonth, NoOfClaims DESC, InsurancePayments DESC;
END
GO

-- ============================================================
-- 4) Insurance vs Payment % — FLAT Claim Level (client Input Report)
--    Filter = InsurancePayment > 0
--             PayerName_Raw NOT IN (None, ClientBill, Selfpay)
--    Row    = PayerName_Raw
--    Values = COUNT(ClaimID), AVG(PaymentPercent)
--    Sort   = Count of ClaimID DESC
--    Check: BCBS IL 5815 / 28%, Aetna Better Health 1875 / 16%
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPaymentPct_v2
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
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH src AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(REPLACE(REPLACE(PaymentPercent, '%', ''), ',', '') AS DECIMAL(18,6)) AS PayPctRaw
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND LTRIM(RTRIM(ISNULL(PayerName_Raw, ''))) NOT IN ('None', 'ClientBill', 'Selfpay')
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        PayerName,
        CAST(NULL AS INT) AS BillYear,
        CAST(NULL AS INT) AS BillMonth,
        COUNT(*) AS NoOfPaidClaims,
        ISNULL(SUM(InsPay), 0) AS InsurancePayment,
        CAST(ROUND(
            AVG(CASE WHEN PayPctRaw IS NULL THEN NULL
                     WHEN PayPctRaw <= 1 THEN PayPctRaw * 100
                     ELSE PayPctRaw END),
            0) AS DECIMAL(9,4)) AS PaymentPct
    FROM src
    GROUP BY PayerName
    ORDER BY NoOfPaidClaims DESC, InsurancePayment DESC;
END
GO

-- ============================================================
-- 5) Insurance vs Payment — same Collection Claim Level grain
-- ============================================================
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_CS_InsuranceVsPayment_v2
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
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))              AS PayerName,
            CAST(YEAR (TRY_CAST(PostingDate AS DATE)) AS INT)           AS BillYear,
            CAST(MONTH(TRY_CAST(PostingDate AS DATE)) AS TINYINT)       AS BillMonth,
            COUNT(*)                                                    AS NoOfPaidClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
        FROM dbo.CollectionClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(PostingDate AS DATE) IS NOT NULL
          AND YEAR(TRY_CAST(PostingDate AS DATE)) > 1900
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(PanelNew,      'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateofService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateofService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(PostingDate     AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(PostingDate     AS DATE) <= @CheckDateTo)
        GROUP BY
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))),
            CAST(YEAR (TRY_CAST(PostingDate AS DATE)) AS INT),
            CAST(MONTH(TRY_CAST(PostingDate AS DATE)) AS TINYINT)
    ),
    grand AS
    (
        SELECT BillYear, BillMonth, NULLIF(SUM(InsurancePayment), 0) AS Total
        FROM agg
        GROUP BY BillYear, BillMonth
    )
    SELECT a.PayerName, a.BillYear, a.BillMonth, a.NoOfPaidClaims,
           a.InsurancePayment,
           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total, 1) AS DECIMAL(9,4)) AS PaymentPct
    FROM agg a
    INNER JOIN grand g ON a.BillYear = g.BillYear AND a.BillMonth = g.BillMonth
    ORDER BY a.BillYear, a.BillMonth, a.NoOfPaidClaims DESC, a.InsurancePayment DESC;
END
GO

PRINT '15b_Augustus_CollectionSummary_Fixes.sql completed.';
PRINT '  usp_Create_CollectionClaimLevelData_v2';
PRINT '  usp_GetAug_CS_Top5ReimbursementPct_v2';
PRINT '  usp_GetAug_CS_Top5ReimbursementPay_v2';
PRINT '  usp_GetAug_CS_PanelVsPayment_v2';
PRINT '  usp_GetAug_CS_InsuranceVsPaymentPct_v2';
PRINT '  usp_GetAug_CS_InsuranceVsPayment_v2';
GO
