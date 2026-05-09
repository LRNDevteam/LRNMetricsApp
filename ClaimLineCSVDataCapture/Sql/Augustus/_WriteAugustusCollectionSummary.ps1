param([string]$Target = "ClaimLineCSVDataCapture\Sql\Augustus\13_Augustus_CollectionSummary.sql")

# Resolve absolute path
$root = Split-Path -Parent $PSScriptRoot   # Sql
$root = Split-Path -Parent $root           # ClaimLineCSVDataCapture
$root = Split-Path -Parent $root           # solution root
$f = Join-Path $root $Target
if (-not (Test-Path (Split-Path $f))) { $f = Join-Path $PSScriptRoot "13_Augustus_CollectionSummary.sql" }

$lines = [System.Collections.Generic.List[string]]::new()
function L([string]$s=""){ $lines.Add($s) }
# SEP — GO batch separator.  Used ONLY between stored procedures.
# The table section has NO GO; all 13 DROP/CREATE are in one batch.
function SEP { $lines.Add("GO") ; $lines.Add("") }

# ?? Header ????????????????????????????????????????????????????????????????????
L "-- ============================================================="
L "-- Augustus Labs -- Collection Summary Aggregates"
L "--"
L "-- Column mapping (confirmed from Augustus TVP):"
L "--   Panel row grouping   = PanelNew"
L "--   Date column          = CheckDate  (ClaimLevelData; NOT LineLevelData)"
L "--   Weekly week range    = Wed-Tue  (not Fri-Thu)"
L "--   Pre-computed cols    = Adjudicated/'Adjudicated', AdjudicatedAmount,"
L "--                          Bucket30/'30 Bucket', Bucket30Amount,"
L "--                          Bucket60/'60 Bucket', Bucket60Amount,"
L "--                          FullyPaidCount, FullyPaidAmount"
L "--   No BilledUnbilled / AgingBucket -- aging derived from DaystoDOS."
L "-- ============================================================="
L ""
L "SET NOCOUNT ON;"
L ""
L "-- ----------------------------------------------------------------"
L "-- TABLES  (all 13 in ONE batch -- IF OBJECT_ID pattern, no GO needed)"
L "-- ----------------------------------------------------------------"
L ""

function Table([string]$name, [string[]]$cols) {
    L "IF OBJECT_ID('dbo.$name','U') IS NOT NULL DROP TABLE dbo.$name;"
    L "CREATE TABLE dbo.$name ("
    foreach ($c in $cols) { L "    $c" }
    L ");"
    L ""
}

Table "Aug_CS_Top5ReimbursementPct" @(
    "SummaryId           INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PayerRank           TINYINT       NOT NULL,",
    "PayerName           NVARCHAR(500) NOT NULL,",
    "SumInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "SumChargeAmount     DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "UniqueVisitCount    INT           NOT NULL DEFAULT 0,",
    "PaymentPct          DECIMAL(9,4)  NOT NULL DEFAULT 0,",
    "RefreshedAt         DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_Top5ReimbursementPay" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PayerRank        TINYINT       NOT NULL,",
    "PayerName        NVARCHAR(500) NOT NULL,",
    "TotalPayments    DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "UniqueVisitCount INT           NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_MonthlyClaimVolume" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PanelName        NVARCHAR(500) NOT NULL,",
    "PayerName        NVARCHAR(500) NOT NULL,",
    "PayerRank        TINYINT       NOT NULL,",
    "BillYear         INT           NOT NULL,",
    "BillMonth        TINYINT       NOT NULL,",
    "NoOfClaims       INT           NOT NULL DEFAULT 0,",
    "InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_WeeklyClaimVolume" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PanelName        NVARCHAR(500) NOT NULL,",
    "PayerName        NVARCHAR(500) NOT NULL,",
    "PayerRank        TINYINT       NOT NULL,",
    "WeekKey          TINYINT       NOT NULL,",
    "WeekStart        DATE          NOT NULL,",
    "WeekEnd          DATE          NOT NULL,",
    "NoOfClaims       INT           NOT NULL DEFAULT 0,",
    "InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_PanelAverages" @(
    "SummaryId         INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PanelName         NVARCHAR(500) NOT NULL,",
    "PayerName         NVARCHAR(500) NOT NULL,",
    "NoOfClaims        INT           NOT NULL DEFAULT 0,",
    "TotalCharges      DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "CarrierPayment    DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgCarrierPayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "FullyPaidCount    INT           NOT NULL DEFAULT 0,",
    "FullyPaidAmount   DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgFullyPaid      DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "Days30Count       INT           NOT NULL DEFAULT 0,",
    "Days30Amount      DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgDays30         DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "Days60Count       INT           NOT NULL DEFAULT 0,",
    "Days60Amount      DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgDays60         DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt       DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_AvgPayments" @(
    "SummaryId           INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PanelName           NVARCHAR(500) NOT NULL,",
    "PayerName           NVARCHAR(500) NOT NULL,",
    "PayerRank           TINYINT       NOT NULL,",
    "ClaimCount          INT           NOT NULL DEFAULT 0,",
    "TotalCharges        DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgCharges          DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "InsurancePayment    DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "FullyPaidCount      INT           NOT NULL DEFAULT 0,",
    "FullyPaidAmount     DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgFullyPaid        DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AdjudicatedCount    INT           NOT NULL DEFAULT 0,",
    "AdjudicatedAmount   DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgAdjudicated      DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "Over30Count         INT           NOT NULL DEFAULT 0,",
    "Over30Amount        DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgOver30           DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "Over60Count         INT           NOT NULL DEFAULT 0,",
    "Over60Amount        DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "AvgOver60           DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt         DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_InsuranceVsAging" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PayerName        NVARCHAR(500) NOT NULL,",
    "AgingBucket      NVARCHAR(50)  NOT NULL,",
    "ClaimCount       INT           NOT NULL DEFAULT 0,",
    "InsuranceBalance DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_PanelVsPayment" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PanelName        NVARCHAR(500) NOT NULL,",
    "BillYear         INT           NOT NULL,",
    "BillMonth        TINYINT       NOT NULL,",
    "NoOfClaims       INT           NOT NULL DEFAULT 0,",
    "InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_RepVsPayment" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "SalesRepName     NVARCHAR(500) NOT NULL,",
    "CheckYear        INT           NOT NULL,",
    "CheckMonth       TINYINT       NOT NULL,",
    "NoOfClaims       INT           NOT NULL DEFAULT 0,",
    "InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_InsuranceVsPaymentPct" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "PayerName        NVARCHAR(500) NOT NULL,",
    "NoOfPaidClaims   INT           NOT NULL DEFAULT 0,",
    "InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "PaymentPct       DECIMAL(9,4)  NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_CptVsPaymentPct" @(
    "SummaryId            INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "CPTCode              NVARCHAR(50)  NOT NULL,",
    "SumUnits             DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "PaidInsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "PaidChargeAmount     DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "PaymentPct           DECIMAL(9,4)  NOT NULL DEFAULT 0,",
    "RefreshedAt          DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_StatusSummary" @(
    "SummaryId        INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "ClaimStatus      NVARCHAR(200) NOT NULL,",
    "PanelName        NVARCHAR(500) NOT NULL,",
    "CptCode          NVARCHAR(MAX) NOT NULL,",
    "PayerName        NVARCHAR(500) NOT NULL,",
    "NoOfClaims       INT           NOT NULL DEFAULT 0,",
    "InsurancePayment DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "InsuranceBalance DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "PatientBalance   DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt      DATETIME      NOT NULL DEFAULT GETDATE()"
)
Table "Aug_CS_ProviderSummary" @(
    "SummaryId         INT           NOT NULL IDENTITY(1,1) PRIMARY KEY,",
    "ProviderRank      INT           NOT NULL,",
    "ReferringProvider NVARCHAR(500) NOT NULL,",
    "NoOfClaims        INT           NOT NULL DEFAULT 0,",
    "InsurancePayment  DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "InsuranceBalance  DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "PatientBalance    DECIMAL(18,2) NOT NULL DEFAULT 0,",
    "RefreshedAt       DATETIME      NOT NULL DEFAULT GETDATE()"
)

# One GO to end the tables batch before the first CREATE PROCEDURE
SEP

# ?? STORED PROCEDURES (each in its own GO-separated batch) ???????????????????
L "-- ================================================================"
L "-- STORED PROCEDURES"
L "-- ================================================================"
L ""

# SP 1 -------------------------------------------------------------------------
L "-- 1. Top-5 Reimbursement % vs Billed Charge"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_Top5ReimbursementPct"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    ;WITH agg AS ("
L "        SELECT"
L "            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,"
L "            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS SumIns,"
L "            ISNULL(SUM(TRY_CAST(ChargeAmount     AS DECIMAL(18,2))),0) AS SumChg,"
L "            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)),''))   AS Visits"
L "        FROM dbo.ClaimLevelData"
L "        WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''"
L "          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "        GROUP BY LTRIM(RTRIM(PayerName_Raw))"
L "    ),"
L "    grand AS (SELECT NULLIF(SUM(SumIns),0) AS GrandTotal FROM agg),"
L "    ranked AS ("
L "        SELECT TOP 5"
L "               ROW_NUMBER() OVER (ORDER BY a.SumIns DESC) AS Rnk,"
L "               a.PayerName, a.SumIns, a.SumChg, a.Visits,"
L "               CAST(a.SumIns * 100.0 / ISNULL(g.GrandTotal,1) AS DECIMAL(9,4)) AS PayPct"
L "        FROM agg a CROSS JOIN grand g"
L "        ORDER BY a.SumIns DESC"
L "    )"
L "    SELECT * INTO #out FROM ranked;"
L "    TRUNCATE TABLE dbo.Aug_CS_Top5ReimbursementPct;"
L "    INSERT INTO dbo.Aug_CS_Top5ReimbursementPct"
L "        (PayerRank, PayerName, SumInsurancePayment, SumChargeAmount, UniqueVisitCount, PaymentPct, RefreshedAt)"
L "    SELECT CAST(Rnk AS TINYINT), PayerName, SumIns, SumChg, Visits, PayPct, GETDATE()"
L "    FROM #out ORDER BY Rnk;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_Top5ReimbursementPct completed.';"
L "END"
SEP

# SP 2 -------------------------------------------------------------------------
L "-- 2. Top-5 Reimbursement Payments"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_Top5ReimbursementPay"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    ;WITH agg AS ("
L "        SELECT"
L "            LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,"
L "            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS TotalPay,"
L "            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(AccessionNumber)),''))   AS Visits"
L "        FROM dbo.ClaimLevelData"
L "        WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''"
L "          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "        GROUP BY LTRIM(RTRIM(PayerName_Raw))"
L "    ),"
L "    ranked AS ("
L "        SELECT TOP 5 ROW_NUMBER() OVER (ORDER BY TotalPay DESC) AS Rnk,"
L "               PayerName, TotalPay, Visits"
L "        FROM agg ORDER BY TotalPay DESC"
L "    )"
L "    SELECT * INTO #out FROM ranked;"
L "    TRUNCATE TABLE dbo.Aug_CS_Top5ReimbursementPay;"
L "    INSERT INTO dbo.Aug_CS_Top5ReimbursementPay"
L "        (PayerRank, PayerName, TotalPayments, UniqueVisitCount, RefreshedAt)"
L "    SELECT CAST(Rnk AS TINYINT), PayerName, TotalPay, Visits, GETDATE()"
L "    FROM #out ORDER BY Rnk;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_Top5ReimbursementPay completed.';"
L "END"
SEP

# SP 3 -------------------------------------------------------------------------
L "-- 3. Monthly Claim Volume  (ClaimLevelData / CheckDate / Top-3 payer per PanelNew)"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_MonthlyClaimVolume"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    SELECT"
L "        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))              AS PanelName,"
L "        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))              AS PayerName,"
L "        YEAR (TRY_CAST(CheckDate AS DATE))                         AS BillYear,"
L "        MONTH(TRY_CAST(CheckDate AS DATE))                         AS BillMonth,"
L "        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))           AS NoOfClaims,"
L "        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayment"
L "    INTO #raw"
L "    FROM dbo.ClaimLevelData"
L "    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL"
L "      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900"
L "    GROUP BY"
L "        LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))),"
L "        LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))),"
L "        YEAR (TRY_CAST(CheckDate AS DATE)),"
L "        MONTH(TRY_CAST(CheckDate AS DATE));"
L "    SELECT PanelName, PayerName,"
L "           DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank"
L "    INTO #ranks FROM #raw GROUP BY PanelName, PayerName;"
L "    TRUNCATE TABLE dbo.Aug_CS_MonthlyClaimVolume;"
L "    INSERT INTO dbo.Aug_CS_MonthlyClaimVolume"
L "        (PanelName, PayerName, PayerRank, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)"
L "    SELECT r.PanelName, r.PayerName, CAST(k.PayerRank AS TINYINT),"
L "           r.BillYear, CAST(r.BillMonth AS TINYINT), r.NoOfClaims, r.InsurancePayment, GETDATE()"
L "    FROM #raw r JOIN #ranks k ON k.PanelName = r.PanelName AND k.PayerName = r.PayerName"
L "    WHERE k.PayerRank <= 3"
L "    ORDER BY r.PanelName, k.PayerRank, r.BillYear, r.BillMonth;"
L "    DROP TABLE IF EXISTS #raw; DROP TABLE IF EXISTS #ranks;"
L "    PRINT 'usp_RefreshAug_CS_MonthlyClaimVolume completed.';"
L "END"
SEP

# SP 4 -------------------------------------------------------------------------
L "-- 4. Weekly Claim Volume  (ClaimLevelData / CheckDate / Wed-Tue / last 4 complete weeks)"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_WeeklyClaimVolume"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    -- 1900-01-02 was a Tuesday -- used as anchor to calculate days-since-Tuesday"
L "    DECLARE @Today        DATE = CAST(GETDATE() AS DATE);"
L "    DECLARE @DaysSinceTue INT  = ((DATEDIFF(DAY,'1900-01-02',@Today) % 7) + 7) % 7;"
L "    DECLARE @LastTue      DATE = DATEADD(DAY, -@DaysSinceTue, @Today);"
L "    IF @LastTue = @Today SET @LastTue = DATEADD(DAY, -7, @LastTue);"
L "    DECLARE @W4End  DATE = @LastTue,                     @W4Start DATE = DATEADD(DAY,  -6, @LastTue);"
L "    DECLARE @W3End  DATE = DATEADD(DAY,  -7, @LastTue),  @W3Start DATE = DATEADD(DAY, -13, @LastTue);"
L "    DECLARE @W2End  DATE = DATEADD(DAY, -14, @LastTue),  @W2Start DATE = DATEADD(DAY, -20, @LastTue);"
L "    DECLARE @W1End  DATE = DATEADD(DAY, -21, @LastTue),  @W1Start DATE = DATEADD(DAY, -27, @LastTue);"
L "    ;WITH src AS ("
L "        SELECT"
L "            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown'))) AS PanelName,"
L "            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown'))) AS PayerName,"
L "            CASE"
L "              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W1End THEN 1"
L "              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W2Start AND @W2End THEN 2"
L "              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W3Start AND @W3End THEN 3"
L "              WHEN TRY_CAST(CheckDate AS DATE) BETWEEN @W4Start AND @W4End THEN 4"
L "            END AS WeekKey,"
L "            ClaimID,"
L "            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay"
L "        FROM dbo.ClaimLevelData"
L "        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "          AND TRY_CAST(CheckDate AS DATE) BETWEEN @W1Start AND @W4End"
L "    ),"
L "    agg AS ("
L "        SELECT PanelName, PayerName, WeekKey,"
L "               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')) AS NoOfClaims,"
L "               ISNULL(SUM(InsPay),0)                            AS InsurancePayment"
L "        FROM src WHERE WeekKey IS NOT NULL"
L "        GROUP BY PanelName, PayerName, WeekKey"
L "    ),"
L "    ranks AS ("
L "        SELECT PanelName, PayerName,"
L "               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY SUM(NoOfClaims) DESC) AS PayerRank"
L "        FROM agg GROUP BY PanelName, PayerName"
L "    )"
L "    SELECT a.PanelName, a.PayerName, CAST(r.PayerRank AS TINYINT) AS PayerRank,"
L "           CAST(a.WeekKey AS TINYINT) AS WeekKey,"
L "           CASE a.WeekKey WHEN 1 THEN @W1Start WHEN 2 THEN @W2Start"
L "                          WHEN 3 THEN @W3Start ELSE @W4Start END AS WeekStart,"
L "           CASE a.WeekKey WHEN 1 THEN @W1End   WHEN 2 THEN @W2End"
L "                          WHEN 3 THEN @W3End   ELSE @W4End   END AS WeekEnd,"
L "           a.NoOfClaims, a.InsurancePayment"
L "    INTO #out FROM agg a"
L "    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName"
L "    WHERE r.PayerRank <= 3;"
L "    TRUNCATE TABLE dbo.Aug_CS_WeeklyClaimVolume;"
L "    INSERT INTO dbo.Aug_CS_WeeklyClaimVolume"
L "        (PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, RefreshedAt)"
L "    SELECT PanelName, PayerName, PayerRank, WeekKey, WeekStart, WeekEnd, NoOfClaims, InsurancePayment, GETDATE()"
L "    FROM #out ORDER BY PanelName, PayerRank, WeekKey;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_WeeklyClaimVolume completed.';"
L "END"
SEP

# SP 5 -------------------------------------------------------------------------
L "-- 5. Panel Averages"
L "-- Col1: ClaimStatus <> 'No Response'  -> NoOfClaims, TotalCharges, CarrierPayment, Avg"
L "-- Col2: ClaimStatus = 'Fully Paid'    -> FullyPaidCount, FullyPaidAmount, Avg"
L "-- Col3: Bucket30 = '30 Bucket'        -> Days30Count, Days30Amount, Avg"
L "-- Col4: Bucket60 = '60 Bucket'        -> Days60Count, Days60Amount, Avg"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_PanelAverages"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    ;WITH src AS ("
L "        SELECT"
L "            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))           AS PanelName,"
L "            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))           AS PayerName,"
L "            COALESCE(NULLIF(LTRIM(RTRIM(AccessionNumber)),''),"
L "                     LTRIM(RTRIM(ClaimID)))                         AS VisitKey,"
L "            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))             AS Chg,"
L "            TRY_CAST(InsurancePayment AS DECIMAL(18,2))             AS InsPay,"
L "            LTRIM(RTRIM(ClaimStatus))                               AS ClaimStatus,"
L "            LTRIM(RTRIM(Bucket30))                                  AS Bucket30,"
L "            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))               AS Bucket30Amt,"
L "            LTRIM(RTRIM(Bucket60))                                  AS Bucket60,"
L "            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))               AS Bucket60Amt"
L "        FROM dbo.ClaimLevelData"
L "        WHERE PanelNew IS NOT NULL AND LTRIM(RTRIM(PanelNew)) <> ''"
L "    )"
L "    SELECT PanelName, PayerName,"
L "        COUNT(DISTINCT CASE WHEN ClaimStatus <> 'No Response' THEN VisitKey END)      AS NoOfClaims,"
L "        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN Chg    ELSE 0 END),0)  AS TotalCharges,"
L "        ISNULL(SUM(CASE WHEN ClaimStatus <> 'No Response' THEN InsPay ELSE 0 END),0)  AS CarrierPayment,"
L "        COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Paid' THEN VisitKey END)        AS FullyPaidCount,"
L "        ISNULL(SUM(CASE WHEN ClaimStatus = 'Fully Paid' THEN InsPay ELSE 0 END),0)    AS FullyPaidAmount,"
L "        COUNT(DISTINCT CASE WHEN Bucket30 = '30 Bucket' THEN VisitKey END)            AS Days30Count,"
L "        ISNULL(SUM(CASE WHEN Bucket30 = '30 Bucket' THEN Bucket30Amt ELSE 0 END),0)   AS Days30Amount,"
L "        COUNT(DISTINCT CASE WHEN Bucket60 = '60 Bucket' THEN VisitKey END)            AS Days60Count,"
L "        ISNULL(SUM(CASE WHEN Bucket60 = '60 Bucket' THEN Bucket60Amt ELSE 0 END),0)   AS Days60Amount"
L "    INTO #out FROM src GROUP BY PanelName, PayerName;"
L "    TRUNCATE TABLE dbo.Aug_CS_PanelAverages;"
L "    INSERT INTO dbo.Aug_CS_PanelAverages"
L "        (PanelName, PayerName,"
L "         NoOfClaims, TotalCharges, CarrierPayment, AvgCarrierPayment,"
L "         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,"
L "         Days30Count, Days30Amount, AvgDays30,"
L "         Days60Count, Days60Amount, AvgDays60, RefreshedAt)"
L "    SELECT PanelName, PayerName,"
L "        NoOfClaims, TotalCharges, CarrierPayment,"
L "        CASE WHEN NoOfClaims     > 0 THEN CarrierPayment  / NoOfClaims     ELSE 0 END,"
L "        FullyPaidCount, FullyPaidAmount,"
L "        CASE WHEN FullyPaidCount > 0 THEN FullyPaidAmount / FullyPaidCount ELSE 0 END,"
L "        Days30Count, Days30Amount,"
L "        CASE WHEN Days30Count    > 0 THEN Days30Amount    / Days30Count    ELSE 0 END,"
L "        Days60Count, Days60Amount,"
L "        CASE WHEN Days60Count    > 0 THEN Days60Amount    / Days60Count    ELSE 0 END,"
L "        GETDATE()"
L "    FROM #out ORDER BY PanelName, PayerName;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_PanelAverages completed.';"
L "END"
SEP

# SP 6 -------------------------------------------------------------------------
L "-- 6. Avg Payments  (CheckDate last 6 months / Top-3 payer per PanelNew)"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_AvgPayments"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));"
L "    ;WITH base AS ("
L "        SELECT"
L "            LTRIM(RTRIM(ISNULL(PanelNew,     'Unknown')))           AS PanelName,"
L "            LTRIM(RTRIM(ISNULL(PayerName_Raw,'Unknown')))           AS PayerName,"
L "            ClaimID,"
L "            TRY_CAST(ChargeAmount      AS DECIMAL(18,2))            AS Chg,"
L "            TRY_CAST(InsurancePayment  AS DECIMAL(18,2))            AS InsPay,"
L "            LTRIM(RTRIM(ClaimStatus))                               AS ClaimStatus,"
L "            LTRIM(RTRIM(Adjudicated))                               AS Adjudicated,"
L "            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))            AS AdjAmt,"
L "            LTRIM(RTRIM(Bucket30))                                  AS Bucket30,"
L "            TRY_CAST(Bucket30Amount    AS DECIMAL(18,2))            AS Bucket30Amt,"
L "            LTRIM(RTRIM(Bucket60))                                  AS Bucket60,"
L "            TRY_CAST(Bucket60Amount    AS DECIMAL(18,2))            AS Bucket60Amt"
L "        FROM dbo.ClaimLevelData"
L "        WHERE TRY_CAST(CheckDate AS DATE) IS NOT NULL"
L "          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff"
L "          AND PanelNew      IS NOT NULL AND LTRIM(RTRIM(PanelNew))      <> ''"
L "          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''"
L "    ),"
L "    agg AS ("
L "        SELECT PanelName, PayerName,"
L "            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))                             AS ClaimCount,"
L "            ISNULL(SUM(Chg),0)                                                           AS TotalCharges,"
L "            ISNULL(SUM(InsPay),0)                                                        AS InsurancePayment,"
L "            COUNT(DISTINCT CASE WHEN ClaimStatus = 'Fully Paid'  THEN ClaimID END)       AS FullyPaidCount,"
L "            ISNULL(SUM(CASE WHEN ClaimStatus = 'Fully Paid'  THEN InsPay    ELSE 0 END),0) AS FullyPaidAmount,"
L "            COUNT(DISTINCT CASE WHEN Adjudicated = 'Adjudicated' THEN ClaimID END)       AS AdjudicatedCount,"
L "            ISNULL(SUM(CASE WHEN Adjudicated = 'Adjudicated' THEN AdjAmt    ELSE 0 END),0) AS AdjudicatedAmount,"
L "            COUNT(DISTINCT CASE WHEN Bucket30 = '30 Bucket'  THEN ClaimID END)           AS Over30Count,"
L "            ISNULL(SUM(CASE WHEN Bucket30 = '30 Bucket'  THEN Bucket30Amt ELSE 0 END),0) AS Over30Amount,"
L "            COUNT(DISTINCT CASE WHEN Bucket60 = '60 Bucket' THEN ClaimID END)            AS Over60Count,"
L "            ISNULL(SUM(CASE WHEN Bucket60 = '60 Bucket' THEN Bucket60Amt ELSE 0 END),0)  AS Over60Amount"
L "        FROM base GROUP BY PanelName, PayerName"
L "    ),"
L "    ranks AS ("
L "        SELECT PanelName, PayerName,"
L "               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY ClaimCount DESC) AS PayerRank"
L "        FROM agg"
L "    )"
L "    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank"
L "    INTO #out FROM agg a"
L "    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName"
L "    WHERE r.PayerRank <= 3;"
L "    TRUNCATE TABLE dbo.Aug_CS_AvgPayments;"
L "    INSERT INTO dbo.Aug_CS_AvgPayments"
L "        (PanelName, PayerName, PayerRank,"
L "         ClaimCount, TotalCharges, AvgCharges, InsurancePayment, AvgInsurancePayment,"
L "         FullyPaidCount,   FullyPaidAmount,   AvgFullyPaid,"
L "         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,"
L "         Over30Count, Over30Amount, AvgOver30,"
L "         Over60Count, Over60Amount, AvgOver60, RefreshedAt)"
L "    SELECT PanelName, PayerName, PayerRank,"
L "        ClaimCount, TotalCharges,"
L "        CASE WHEN ClaimCount       > 0 THEN TotalCharges      / ClaimCount       ELSE 0 END,"
L "        InsurancePayment,"
L "        CASE WHEN ClaimCount       > 0 THEN InsurancePayment  / ClaimCount       ELSE 0 END,"
L "        FullyPaidCount,   FullyPaidAmount,"
L "        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END,"
L "        AdjudicatedCount, AdjudicatedAmount,"
L "        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,"
L "        Over30Count, Over30Amount,"
L "        CASE WHEN Over30Count      > 0 THEN Over30Amount      / Over30Count      ELSE 0 END,"
L "        Over60Count, Over60Amount,"
L "        CASE WHEN Over60Count      > 0 THEN Over60Amount      / Over60Count      ELSE 0 END,"
L "        GETDATE()"
L "    FROM #out ORDER BY PanelName, PayerRank;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_AvgPayments completed.';"
L "END"
SEP

# SP 7 -------------------------------------------------------------------------
L "-- 7. Insurance vs Aging  (AgingBucket derived from DaystoDOS; exclude No Response)"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_InsuranceVsAging"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    TRUNCATE TABLE dbo.Aug_CS_InsuranceVsAging;"
L "    INSERT INTO dbo.Aug_CS_InsuranceVsAging (PayerName, AgingBucket, ClaimCount, InsuranceBalance, RefreshedAt)"
L "    SELECT"
L "        LTRIM(RTRIM(PayerName_Raw)),"
L "        CASE"
L "          WHEN ISNULL(TRY_CAST(DaystoDOS AS INT),-1) <   0 THEN '(blank)'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             <  30 THEN 'Current'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             <  60 THEN '30 Days'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             <  90 THEN '60 Days'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             < 120 THEN '90 Days'"
L "          ELSE '120+ Days'"
L "        END,"
L "        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), "
L "        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0),"
L "        GETDATE()"
L "    FROM dbo.ClaimLevelData"
L "    WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''"
L "      AND ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)),0) <> 0"
L "      AND LTRIM(RTRIM(ClaimStatus)) <> 'No Response'"
L "    GROUP BY LTRIM(RTRIM(PayerName_Raw)),"
L "        CASE"
L "          WHEN ISNULL(TRY_CAST(DaystoDOS AS INT),-1) <   0 THEN '(blank)'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             <  30 THEN 'Current'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             <  60 THEN '30 Days'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             <  90 THEN '60 Days'"
L "          WHEN TRY_CAST(DaystoDOS AS INT)             < 120 THEN '90 Days'"
L "          ELSE '120+ Days'"
L "        END;"
L "    PRINT 'usp_RefreshAug_CS_InsuranceVsAging completed.';"
L "END"
SEP

# SP 8 -------------------------------------------------------------------------
L "-- 8. Panel vs Payment  (monthly by PanelNew / ClaimLevelData / CheckDate)"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_PanelVsPayment"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    TRUNCATE TABLE dbo.Aug_CS_PanelVsPayment;"
L "    INSERT INTO dbo.Aug_CS_PanelVsPayment (PanelName, BillYear, BillMonth, NoOfClaims, InsurancePayment, RefreshedAt)"
L "    SELECT LTRIM(RTRIM(ISNULL(PanelNew,'Unknown'))),"
L "        YEAR (TRY_CAST(CheckDate AS DATE)),"
L "        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT),"
L "        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), "
L "        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0),"
L "        GETDATE()"
L "    FROM dbo.ClaimLevelData"
L "    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "      AND PanelNew IS NOT NULL AND LTRIM(RTRIM(PanelNew)) <> ''"
L "      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL"
L "      AND YEAR(TRY_CAST(CheckDate AS DATE)) > 1900"
L "    GROUP BY LTRIM(RTRIM(ISNULL(PanelNew,'Unknown'))),"
L "        YEAR (TRY_CAST(CheckDate AS DATE)),"
L "        MONTH(TRY_CAST(CheckDate AS DATE));"
L "    PRINT 'usp_RefreshAug_CS_PanelVsPayment completed.';"
L "END"
SEP

# SP 9 -------------------------------------------------------------------------
L "-- 9. Rep vs Payment"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_RepVsPayment"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    TRUNCATE TABLE dbo.Aug_CS_RepVsPayment;"
L "    INSERT INTO dbo.Aug_CS_RepVsPayment (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)"
L "    SELECT LTRIM(RTRIM(SalesRepname)),"
L "        YEAR (TRY_CAST(CheckDate AS DATE)),"
L "        CAST(MONTH(TRY_CAST(CheckDate AS DATE)) AS TINYINT),"
L "        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), "
L "        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0),"
L "        GETDATE()"
L "    FROM dbo.ClaimLevelData"
L "    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "      AND SalesRepname IS NOT NULL AND LTRIM(RTRIM(SalesRepname)) <> ''"
L "      AND TRY_CAST(CheckDate AS DATE) IS NOT NULL"
L "    GROUP BY LTRIM(RTRIM(SalesRepname)),"
L "        YEAR (TRY_CAST(CheckDate AS DATE)),"
L "        MONTH(TRY_CAST(CheckDate AS DATE));"
L "    PRINT 'usp_RefreshAug_CS_RepVsPayment completed.';"
L "END"
SEP

# SP 10 ------------------------------------------------------------------------
L "-- 10. Insurance vs Payment %"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_InsuranceVsPaymentPct"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    ;WITH agg AS ("
L "        SELECT LTRIM(RTRIM(PayerName_Raw))                                AS PayerName,"
L "               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))           AS NoOfPaidClaims,"
L "               ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0) AS InsurancePayment"
L "        FROM dbo.ClaimLevelData"
L "        WHERE PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''"
L "          AND ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0) > 0"
L "        GROUP BY LTRIM(RTRIM(PayerName_Raw))"
L "    ),"
L "    grand AS (SELECT NULLIF(SUM(InsurancePayment),0) AS Total FROM agg)"
L "    SELECT a.PayerName, a.NoOfPaidClaims, a.InsurancePayment,"
L "           CAST(a.InsurancePayment * 100.0 / ISNULL(g.Total,1) AS DECIMAL(9,4)) AS PaymentPct"
L "    INTO #out FROM agg a CROSS JOIN grand g;"
L "    TRUNCATE TABLE dbo.Aug_CS_InsuranceVsPaymentPct;"
L "    INSERT INTO dbo.Aug_CS_InsuranceVsPaymentPct (PayerName, NoOfPaidClaims, InsurancePayment, PaymentPct, RefreshedAt)"
L "    SELECT PayerName, NoOfPaidClaims, InsurancePayment, PaymentPct, GETDATE()"
L "    FROM #out ORDER BY InsurancePayment DESC;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_InsuranceVsPaymentPct completed.';"
L "END"
SEP

# SP 11 ------------------------------------------------------------------------
L "-- 11. CPT vs Payment %"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_CptVsPaymentPct"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    ;WITH agg AS ("
L "        SELECT LTRIM(RTRIM(CPTCode)) AS CPTCode,"
L "               ISNULL(SUM(TRY_CAST(Units AS DECIMAL(18,2))),0) AS SumUnits,"
L "               ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')"
L "                               THEN TRY_CAST(InsurancePayment AS DECIMAL(18,2)) ELSE 0 END),0) AS PaidIns,"
L "               ISNULL(SUM(CASE WHEN LTRIM(RTRIM(ClaimStatus)) IN ('Fully Paid','Partially Paid')"
L "                               THEN TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) ELSE 0 END),0) AS PaidChg"
L "        FROM dbo.LineLevelData"
L "        WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''"
L "        GROUP BY LTRIM(RTRIM(CPTCode))"
L "    )"
L "    SELECT CPTCode, SumUnits, PaidIns, PaidChg,"
L "           CASE WHEN PaidChg > 0 THEN CAST(PaidIns * 100.0 / PaidChg AS DECIMAL(9,4)) ELSE 0 END AS PaymentPct"
L "    INTO #out FROM agg;"
L "    TRUNCATE TABLE dbo.Aug_CS_CptVsPaymentPct;"
L "    INSERT INTO dbo.Aug_CS_CptVsPaymentPct (CPTCode, SumUnits, PaidInsurancePayment, PaidChargeAmount, PaymentPct, RefreshedAt)"
L "    SELECT CPTCode, SumUnits, PaidIns, PaidChg, PaymentPct, GETDATE()"
L "    FROM #out ORDER BY SumUnits DESC;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_CptVsPaymentPct completed.';"
L "END"
SEP

# SP 12 ------------------------------------------------------------------------
L "-- 12. Status Summary"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_StatusSummary"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    TRUNCATE TABLE dbo.Aug_CS_StatusSummary;"
L "    INSERT INTO dbo.Aug_CS_StatusSummary"
L "        (ClaimStatus, PanelName, CptCode, PayerName,"
L "         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)"
L "    SELECT"
L "        ISNULL(LTRIM(RTRIM(ClaimStatus)),           '(blank)'),"
L "        ISNULL(LTRIM(RTRIM(PanelNew)),              '(blank)'),"
L "        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)),'(blank)'),"
L "        ISNULL(LTRIM(RTRIM(PayerName_Raw)),         '(blank)'),"
L "        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),'')), "
L "        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0),"
L "        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0),"
L "        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))),0),"
L "        GETDATE()"
L "    FROM dbo.ClaimLevelData"
L "    GROUP BY LTRIM(RTRIM(ClaimStatus)), LTRIM(RTRIM(PanelNew)),"
L "             LTRIM(RTRIM(CPTCodeXUnitsXModifier)), LTRIM(RTRIM(PayerName_Raw));"
L "    PRINT 'usp_RefreshAug_CS_StatusSummary completed.';"
L "END"
SEP

# SP 13 ------------------------------------------------------------------------
L "-- 13. Provider Summary"
L "CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_CS_ProviderSummary"
L "AS"
L "BEGIN"
L "    SET NOCOUNT ON;"
L "    ;WITH agg AS ("
L "        SELECT LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,"
L "               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))             AS NoOfClaims,"
L "               ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))),0)   AS InsurancePayment,"
L "               ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))),0)   AS InsuranceBalance,"
L "               ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))),0)   AS PatientBalance"
L "        FROM dbo.ClaimLevelData"
L "        WHERE ReferringProvider IS NOT NULL AND LTRIM(RTRIM(ReferringProvider)) <> ''"
L "        GROUP BY LTRIM(RTRIM(ReferringProvider))"
L "    )"
L "    SELECT ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,"
L "           ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance"
L "    INTO #out FROM agg;"
L "    TRUNCATE TABLE dbo.Aug_CS_ProviderSummary;"
L "    INSERT INTO dbo.Aug_CS_ProviderSummary"
L "        (ProviderRank, ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)"
L "    SELECT ProviderRank, ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()"
L "    FROM #out ORDER BY ProviderRank;"
L "    DROP TABLE IF EXISTS #out;"
L "    PRINT 'usp_RefreshAug_CS_ProviderSummary completed.';"
L "END"
SEP

L "PRINT '13_Augustus_CollectionSummary.sql completed.';"
L ""
L "-- TEST BLOCK (uncomment to validate)"
L "/*"
L "EXEC dbo.usp_RefreshAug_CS_Top5ReimbursementPct;  EXEC dbo.usp_RefreshAug_CS_Top5ReimbursementPay;"
L "EXEC dbo.usp_RefreshAug_CS_MonthlyClaimVolume;    EXEC dbo.usp_RefreshAug_CS_WeeklyClaimVolume;"
L "EXEC dbo.usp_RefreshAug_CS_PanelAverages;         EXEC dbo.usp_RefreshAug_CS_AvgPayments;"
L "EXEC dbo.usp_RefreshAug_CS_InsuranceVsAging;      EXEC dbo.usp_RefreshAug_CS_PanelVsPayment;"
L "EXEC dbo.usp_RefreshAug_CS_RepVsPayment;          EXEC dbo.usp_RefreshAug_CS_InsuranceVsPaymentPct;"
L "EXEC dbo.usp_RefreshAug_CS_CptVsPaymentPct;       EXEC dbo.usp_RefreshAug_CS_StatusSummary;"
L "EXEC dbo.usp_RefreshAug_CS_ProviderSummary;"
L "*/"

# Write without BOM
$utf8NoBom = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllLines($f, $lines, $utf8NoBom)
Write-Host "Written : $f"
Write-Host "Lines   : $($lines.Count)"
$goCount = ($lines | Where-Object { $_ -eq "GO" } | Measure-Object).Count
Write-Host "GO count: $goCount  (should be 14 -- 1 after tables + 13 after each SP)"
