/* =============================================================================
   CoreBio - Executive Summary (LIS / PMS / Cash / Average)
   Database : CoreBio        Prefix : CB

   Columns : Date of Service month / year
               LIS        -> LIMSMaster.RequestCollectDate (billed-date mode: BilledDate)
               PMS / Cash -> ClaimLevelData.DateofService  (billed-date mode: FirstBilledDate)
   Counting: LIS = count of non-blank Accession. PMS = count of Claim ID.

   LIS Breakdown (LIMSMaster). "Billed" = BillCategory = Billed OR BillingStatus = Billed;
   a sample that is Billed in either column is not counted as Unbilled (same as the
   CoreBio LIS Summary).
     A   Total Samples              every sample
     B   Billable Samples           NewStatus = Billable
     C     Billed                   Billable AND Billed
     C1      Billed via CMD         same as C
     D     Unbilled                 Billable AND (BillCategory = Unbilled OR BillingStatus = Unbilled)
     D1      Entered but not billed D AND SubStatus = Entered but not billed
     D2      Ready to Bill          D AND SubStatus = Ready to Bill
     E   Other Samples              NewStatus <> Billable
     E1    Cancelled/Rejected       E2 Client Bills        E3 Newly Received Samples
     E4    System Test              E5 Yet to be validated E6 CIP/Pending

   PMS Breakdown (ClaimLevelData)
     F   No. of Billed Claims                 BilledStatus = Billed
     F1    Claim Submitted in Collaborate MD  same as F
     G   No. of Unbilled Claims               BilledStatus = Unbilled
     H   Billed Mismatches                    F minus LIS C
     I   Fully Paid                           Billed AND ClaimStatus = Fully Paid
     J   Fully Patient Responsibility         Billed AND Patient Responsibility
     K   Adjusted / Written Off               Billed AND Fully Adjusted
     L   Partially Adjusted                   Billed AND Partially Adjusted
     M   Partially Paid                       Billed AND Partially Paid
     N   Patient Paid                         Billed AND Patient Payment
     O   Insurance Balance Claims             ClaimStatus IN (Denied, Fully Denied, No Response, Partially Denied)
     O1    Fully Denied (Denied, Fully Denied) / O2 Partially Denied / O3 No Response

   Cash Breakdown (BilledStatus = Billed unless noted)
     P   Total Billed ($)                     SUM(ChargeAmount)
     P1    Claim Submitted in Collaborate MD  same as P
     Q   Total Unbilled ($)                   SUM(ChargeAmount) BilledStatus = Unbilled
     R   Insurance Payment ($)                SUM(InsurancePayment) AND Fully Paid
     S   Patient Responsibility ($)           SUM(PatientBalance)
     T   Adjustments / Write Off ($)          P - R - U - V - W - S
     U   Partially Paid ($)                   SUM(InsurancePayment) AND Partially Paid
     V   Patient Paid ($)                     SUM(PatientPayment)
     W   Insurance Balance ($)                SUM(InsuranceBalance) Billed / Billed - Self Pay
                                              (TotalInsuranceBalance is empty on this file)
     W1    Denials                            W AND ClaimStatus IN (Denied, Fully Denied)
     W2    Partially Denied                   W AND ClaimStatus NOT IN (Denied, Fully Denied, No Response)
     W3    No Response from Payor             W AND ClaimStatus = No Response

   Average Payment Per Claim
     X   Total Pay / Billed Claims            (R + V) / F
     Y   Total Pay / Paid Claims              (R + U) / (I + M)
     Z   Total Pay / Adjudicated Claims       (R + U) / (I + M + J + K + L + N + O1 + O2)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
    RAISERROR('Run 36_CoreBio_ExecutiveSummary.sql on the CoreBio database.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.CB_ES_LIS', N'U') IS NULL
CREATE TABLE dbo.CB_ES_LIS
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_CB_ES_LIS_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_CB_ES_LIS_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_CB_ES_LIS_RefreshedAt DEFAULT (GETDATE())
);
GO

IF OBJECT_ID(N'dbo.CB_ES_PMS', N'U') IS NULL
CREATE TABLE dbo.CB_ES_PMS
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_CB_ES_PMS_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_CB_ES_PMS_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_CB_ES_PMS_RefreshedAt DEFAULT (GETDATE())
);
GO

IF OBJECT_ID(N'dbo.CB_ES_Cash', N'U') IS NULL
CREATE TABLE dbo.CB_ES_Cash
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_CB_ES_Cash_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_CB_ES_Cash_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_CB_ES_Cash_RefreshedAt DEFAULT (GETDATE())
);
GO

IF OBJECT_ID(N'dbo.CB_ES_Avg', N'U') IS NULL
CREATE TABLE dbo.CB_ES_Avg
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_CB_ES_Avg_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_CB_ES_Avg_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_CB_ES_Avg_RefreshedAt DEFAULT (GETDATE())
);
GO

/* -----------------------------------------------------------------------------
   usp_CB_ES_Load fills #EsLis and #EsClaims. The caller creates both.
   #EsLis carries the sample's status key (St), billed flag (Bill 'B' / 'U' / '')
   and sub status key (Sub), so compute and cell rows share one classification.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_CB_ES_Load
(
    @YearFrom   INT           = NULL,
    @YearTo     INT           = NULL,
    @MonthFrom  INT           = NULL,
    @MonthTo    INT           = NULL,
    @DosFrom    DATE          = NULL,
    @DosTo      DATE          = NULL,
    @BilledFrom DATE          = NULL,
    @BilledTo   DATE          = NULL,
    @Panels     NVARCHAR(MAX) = NULL,
    @Clinics    NVARCHAR(MAX) = NULL,
    @Providers  NVARCHAR(MAX) = NULL,
    @Reps       NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @UseBilledDate BIT = CASE WHEN (@BilledFrom IS NOT NULL OR @BilledTo IS NOT NULL)
                                        AND @DosFrom IS NULL AND @DosTo IS NULL THEN 1 ELSE 0 END;
    DECLARE @From DATE = CASE WHEN @UseBilledDate = 1 THEN @BilledFrom ELSE @DosFrom END;
    DECLARE @To   DATE = CASE WHEN @UseBilledDate = 1 THEN @BilledTo   ELSE @DosTo   END;

    CREATE TABLE #Filters (Dim VARCHAR(10) NOT NULL, Val NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL);
    INSERT INTO #Filters (Dim, Val)
    SELECT f.Dim, LTRIM(RTRIM(s.value))
    FROM (VALUES ('Panel', @Panels), ('Clinic', @Clinics), ('Provider', @Providers), ('Rep', @Reps)) f(Dim, Vals)
    CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N',') s
    WHERE LTRIM(RTRIM(s.value)) <> N'';

    DECLARE @HasPanel    BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Panel')    THEN 1 ELSE 0 END;
    DECLARE @HasClinic   BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Clinic')   THEN 1 ELSE 0 END;
    DECLARE @HasProvider BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Provider') THEN 1 ELSE 0 END;
    DECLARE @HasRep      BIT = CASE WHEN EXISTS (SELECT 1 FROM #Filters WHERE Dim = 'Rep')      THEN 1 ELSE 0 END;

    DELETE FROM #EsLis;
    INSERT INTO #EsLis (ESYear, ESMonth, St, Bill, Sub, Cnt)
    SELECT YEAR(p.PeriodDate), MONTH(p.PeriodDate), k.St, k.Bill, k.Sub, COUNT(*)
    FROM dbo.LIMSMaster l
    CROSS APPLY (
        SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
               CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                    ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.NewStatus), N''))))     AS NS,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillCategory), N'')))) AS BC,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillingStatus), N''))))AS BS,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.SubStatus), N''))))    AS SS
    ) p
    CROSS APPLY (
        SELECT CAST(CASE
                   WHEN p.NS = N'BILLABLE' THEN 'INS'
                   WHEN p.NS IN (N'CANCELLED/REJECTED', N'CANCELED/REJECTED') THEN 'CAN'
                   WHEN p.NS IN (N'CLIENT BILL', N'CLIENT BILLS') THEN 'CLIENT'
                   WHEN p.NS IN (N'NEWLY RECEIVED CLAIMS', N'NEWLY RECEIVED SAMPLES') THEN 'NEW'
                   WHEN p.NS = N'SYSTEM TEST' THEN 'SYS'
                   WHEN p.NS IN (N'YET TO BE VALIDATED', N'YEST TO BE VALIDATED', N'YET TO BE VALIDATE', N'YET BE VALIDATED') THEN 'YET'
                   WHEN p.NS IN (N'CIP/PENDING', N'CIP / PENDING') THEN 'CIP'
                   ELSE 'OTH' END AS VARCHAR(10)) AS St,
               CAST(CASE
                   WHEN p.BC = N'BILLED' OR p.BS = N'BILLED' THEN 'B'
                   WHEN p.BC IN (N'UNBILLED', N'NOT BILLED') OR p.BS IN (N'UNBILLED', N'NOT BILLED') THEN 'U'
                   ELSE '' END AS CHAR(1)) AS Bill,
               CAST(CASE
                   WHEN p.SS = N'ENTERED BUT NOT BILLED' THEN 'ENTERED'
                   WHEN p.SS = N'READY TO BILL' THEN 'READY'
                   ELSE '' END AS VARCHAR(10)) AS Sub
    ) k
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.Accession))), N'') IS NOT NULL
      AND p.Dos IS NOT NULL
      AND YEAR(p.Dos) > 1900
      AND p.PeriodDate IS NOT NULL
      AND (@From IS NULL OR p.PeriodDate >= @From)
      AND (@To   IS NULL OR p.PeriodDate <= @To)
      AND (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)
      AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.TestCategory), N'')))   IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.ClinicName), N'')))     IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.DoctorFullName), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
    GROUP BY YEAR(p.PeriodDate), MONTH(p.PeriodDate), k.St, k.Bill, k.Sub
    OPTION (RECOMPILE);

    DELETE FROM #EsClaims;
    INSERT INTO #EsClaims
        (ESYear, ESMonth, BillStatus, ClaimStatus, ClaimCnt, ChargeAmount, InsurancePayment,
         PatientPayment, PatientBalance, InsuranceBalance)
    SELECT YEAR(n.PeriodDate), MONTH(n.PeriodDate), n.BillStatus, n.ClaimStatus,
           COUNT(*),
           SUM(n.ChargeAmount), SUM(n.InsurancePayment), SUM(n.PatientPayment),
           SUM(n.PatientBalance), SUM(n.InsuranceBalance)
    FROM dbo.ClaimLevelData c
    CROSS APPLY (
        SELECT
            UPPER(LTRIM(RTRIM(REPLACE(REPLACE(ISNULL(CONVERT(NVARCHAR(200), c.BilledStatus), N''), N'  ', N' '), N'  ', N' ')))) AS BillStatus,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N'')))) AS ClaimStatus,
            TRY_CAST(c.DateofService AS DATE) AS Dos,
            CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(c.FirstBilledDate AS DATE)
                 ELSE TRY_CAST(c.DateofService AS DATE) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.ChargeAmount))), N'$', N''), N',', N'')), 0) AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsurancePayment))), N'$', N''), N',', N'')), 0) AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientPayment))), N'$', N''), N',', N'')), 0) AS PatientPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientBalance))), N'$', N''), N',', N'')), 0) AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), N'$', N''), N',', N'')), 0) AS InsuranceBalance
    ) n
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
      AND n.Dos IS NOT NULL
      AND YEAR(n.Dos) > 1900
      AND n.PeriodDate IS NOT NULL
      AND (@From IS NULL OR n.PeriodDate >= @From)
      AND (@To   IS NULL OR n.PeriodDate <= @To)
      AND (@YearFrom  IS NULL OR YEAR(n.PeriodDate)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(n.PeriodDate)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(n.PeriodDate) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(n.PeriodDate) <= @MonthTo)
      AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.Panelname), N'')))         IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ClinicName), N'')))        IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ReferringProvider), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
      AND (@HasRep      = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.SalesRepname), N'')))      IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
    GROUP BY YEAR(n.PeriodDate), MONTH(n.PeriodDate), n.BillStatus, n.ClaimStatus
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   Row logic. Caller supplies #EsLis, #EsClaims and empty #EsOut.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_CB_ES_Compute
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #LisM;
    SELECT
        ISNULL(ESYear, 0) AS Y,
        CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
        ISNULL(SUM(Cnt), 0) AS L_A,
        ISNULL(SUM(CASE WHEN St = 'INS' THEN Cnt END), 0) AS L_B,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'B' THEN Cnt END), 0) AS L_C,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'U' THEN Cnt END), 0) AS L_D,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'U' AND Sub = 'ENTERED' THEN Cnt END), 0) AS L_D1,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'U' AND Sub = 'READY' THEN Cnt END), 0) AS L_D2,
        ISNULL(SUM(CASE WHEN St <> 'INS' THEN Cnt END), 0) AS L_E,
        ISNULL(SUM(CASE WHEN St = 'CAN' THEN Cnt END), 0) AS L_E1,
        ISNULL(SUM(CASE WHEN St = 'CLIENT' THEN Cnt END), 0) AS L_E2,
        ISNULL(SUM(CASE WHEN St = 'NEW' THEN Cnt END), 0) AS L_E3,
        ISNULL(SUM(CASE WHEN St = 'SYS' THEN Cnt END), 0) AS L_E4,
        ISNULL(SUM(CASE WHEN St = 'YET' THEN Cnt END), 0) AS L_E5,
        ISNULL(SUM(CASE WHEN St = 'CIP' THEN Cnt END), 0) AS L_E6
    INTO #LisM
    FROM #EsLis
    GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

    DROP TABLE IF EXISTS #ClmM;
    SELECT
        ISNULL(ESYear, 0) AS Y,
        CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' THEN ClaimCnt END), 0) AS P_F,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED' THEN ClaimCnt END), 0) AS P_G,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'FULLY PAID' THEN ClaimCnt END), 0) AS P_I,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'PATIENT RESPONSIBILITY' THEN ClaimCnt END), 0) AS P_J,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'FULLY ADJUSTED' THEN ClaimCnt END), 0) AS P_K,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'PARTIALLY ADJUSTED' THEN ClaimCnt END), 0) AS P_L,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'PARTIALLY PAID' THEN ClaimCnt END), 0) AS P_M,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'PATIENT PAYMENT' THEN ClaimCnt END), 0) AS P_N,
        ISNULL(SUM(CASE WHEN ClaimStatus IN (N'DENIED', N'FULLY DENIED', N'NO RESPONSE', N'PARTIALLY DENIED') THEN ClaimCnt END), 0) AS P_O,
        ISNULL(SUM(CASE WHEN ClaimStatus IN (N'DENIED', N'FULLY DENIED') THEN ClaimCnt END), 0) AS P_O1,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'PARTIALLY DENIED' THEN ClaimCnt END), 0) AS P_O2,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'NO RESPONSE' THEN ClaimCnt END), 0) AS P_O3,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' THEN ChargeAmount END), 0) AS C_P,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED' THEN ChargeAmount END), 0) AS C_Q,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'FULLY PAID' THEN InsurancePayment END), 0) AS C_R,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' THEN PatientBalance END), 0) AS C_S,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'PARTIALLY PAID' THEN InsurancePayment END), 0) AS C_U,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' THEN PatientPayment END), 0) AS C_V,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') THEN InsuranceBalance END), 0) AS C_W,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus IN (N'DENIED', N'FULLY DENIED')
                         THEN InsuranceBalance END), 0) AS C_W1,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY')
                         AND ClaimStatus NOT IN (N'DENIED', N'FULLY DENIED', N'NO RESPONSE')
                         THEN InsuranceBalance END), 0) AS C_W2,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'NO RESPONSE'
                         THEN InsuranceBalance END), 0) AS C_W3
    INTO #ClmM
    FROM #EsClaims
    GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

    DROP TABLE IF EXISTS #Per;
    SELECT
        COALESCE(l.Y, c.Y) AS Y, COALESCE(l.M, c.M) AS M,
        ISNULL(l.L_A, 0) L_A, ISNULL(l.L_B, 0) L_B, ISNULL(l.L_C, 0) L_C, ISNULL(l.L_D, 0) L_D,
        ISNULL(l.L_D1, 0) L_D1, ISNULL(l.L_D2, 0) L_D2, ISNULL(l.L_E, 0) L_E,
        ISNULL(l.L_E1, 0) L_E1, ISNULL(l.L_E2, 0) L_E2, ISNULL(l.L_E3, 0) L_E3, ISNULL(l.L_E4, 0) L_E4,
        ISNULL(l.L_E5, 0) L_E5, ISNULL(l.L_E6, 0) L_E6,
        ISNULL(c.P_F, 0) P_F, ISNULL(c.P_G, 0) P_G, ISNULL(c.P_I, 0) P_I, ISNULL(c.P_J, 0) P_J,
        ISNULL(c.P_K, 0) P_K, ISNULL(c.P_L, 0) P_L, ISNULL(c.P_M, 0) P_M, ISNULL(c.P_N, 0) P_N,
        ISNULL(c.P_O, 0) P_O, ISNULL(c.P_O1, 0) P_O1, ISNULL(c.P_O2, 0) P_O2, ISNULL(c.P_O3, 0) P_O3,
        ISNULL(c.C_P, 0) C_P, ISNULL(c.C_Q, 0) C_Q, ISNULL(c.C_R, 0) C_R, ISNULL(c.C_S, 0) C_S,
        ISNULL(c.C_U, 0) C_U, ISNULL(c.C_V, 0) C_V, ISNULL(c.C_W, 0) C_W,
        ISNULL(c.C_W1, 0) C_W1, ISNULL(c.C_W2, 0) C_W2, ISNULL(c.C_W3, 0) C_W3
    INTO #Per
    FROM #LisM l
    FULL OUTER JOIN #ClmM c ON c.Y = l.Y AND c.M = l.M;

    INSERT INTO #EsOut (Category, RowCode, Description, SortOrder, ESYear, ESMonth, MetricValue, ClaimCount)
    SELECT r.Category, r.RowCode, r.Description, r.SortOrder, p.Y, p.M,
           CAST(r.MetricValue AS DECIMAL(18,2)), r.ClaimCount
    FROM #Per p
    CROSS APPLY (
        SELECT
            CAST(p.C_R + p.C_V AS DECIMAL(38,6)) AS PayBilled,
            CAST(p.C_R + p.C_U AS DECIMAL(38,6)) AS PayPaid,
            CAST(p.P_I + p.P_M AS DECIMAL(38,6)) AS PaidClaims,
            CAST(p.P_I + p.P_M + p.P_J + p.P_K + p.P_L + p.P_N + p.P_O1 + p.P_O2 AS DECIMAL(38,6)) AS AdjudicatedClaims
    ) d
    CROSS APPLY (VALUES
        ('LIS', 'A',  N'Total Samples',                  10,  CAST(p.L_A AS DECIMAL(38,6)), p.L_A),
        ('LIS', 'B',  N'Billable Samples',               20,  CAST(p.L_B AS DECIMAL(38,6)), p.L_B),
        ('LIS', 'C',  N'  Billed',                       30,  CAST(p.L_C AS DECIMAL(38,6)), p.L_C),
        ('LIS', 'C1', N'    Billed via CMD',             40,  CAST(p.L_C AS DECIMAL(38,6)), p.L_C),
        ('LIS', 'D',  N'  Unbilled',                     50,  CAST(p.L_D AS DECIMAL(38,6)), p.L_D),
        ('LIS', 'D1', N'    Entered but not billed',     60,  CAST(p.L_D1 AS DECIMAL(38,6)), p.L_D1),
        ('LIS', 'D2', N'    Ready to Bill',              70,  CAST(p.L_D2 AS DECIMAL(38,6)), p.L_D2),
        ('LIS', 'E',  N'Other Samples',                  80,  CAST(p.L_E AS DECIMAL(38,6)), p.L_E),
        ('LIS', 'E1', N'  Cancelled/Rejected',           90,  CAST(p.L_E1 AS DECIMAL(38,6)), p.L_E1),
        ('LIS', 'E2', N'  Client Bills',                100,  CAST(p.L_E2 AS DECIMAL(38,6)), p.L_E2),
        ('LIS', 'E3', N'  Newly Received Samples',      110,  CAST(p.L_E3 AS DECIMAL(38,6)), p.L_E3),
        ('LIS', 'E4', N'  System Test',                 120,  CAST(p.L_E4 AS DECIMAL(38,6)), p.L_E4),
        ('LIS', 'E5', N'  Yet to be validated',         130,  CAST(p.L_E5 AS DECIMAL(38,6)), p.L_E5),
        ('LIS', 'E6', N'  CIP/Pending',                 140,  CAST(p.L_E6 AS DECIMAL(38,6)), p.L_E6),
        ('PMS', 'F',  N'No. of Billed Claims',                                          210, CAST(p.P_F AS DECIMAL(38,6)), p.P_F),
        ('PMS', 'F1', N'  Claim Submitted in Collaborate MD',                           220, CAST(p.P_F AS DECIMAL(38,6)), p.P_F),
        ('PMS', 'G',  N'No. of Unbilled Claims',                                        230, CAST(p.P_G AS DECIMAL(38,6)), p.P_G),
        ('PMS', 'H',  N'Billed Mismatches - Other samples billed / LIS Accessions NA', 240, CAST(p.P_F - p.L_C AS DECIMAL(38,6)), p.P_F - p.L_C),
        ('PMS', 'I',  N'No. of Fully Paid Claims',                                      250, CAST(p.P_I AS DECIMAL(38,6)), p.P_I),
        ('PMS', 'J',  N'No. of Fully Patient Responsibility Claims',                    260, CAST(p.P_J AS DECIMAL(38,6)), p.P_J),
        ('PMS', 'K',  N'No. of Adjusted/ Written Off Claims',                           270, CAST(p.P_K AS DECIMAL(38,6)), p.P_K),
        ('PMS', 'L',  N'No. of Partially Adjusted Claim',                               280, CAST(p.P_L AS DECIMAL(38,6)), p.P_L),
        ('PMS', 'M',  N'No. of Partially Paid Claims',                                  290, CAST(p.P_M AS DECIMAL(38,6)), p.P_M),
        ('PMS', 'N',  N'No. of Patient Paid Claims',                                    300, CAST(p.P_N AS DECIMAL(38,6)), p.P_N),
        ('PMS', 'O',  N'No. of Insurance Balance Claims',                               310, CAST(p.P_O AS DECIMAL(38,6)), p.P_O),
        ('PMS', 'O1', N'  No. of Fully Denied Claims',                                  320, CAST(p.P_O1 AS DECIMAL(38,6)), p.P_O1),
        ('PMS', 'O2', N'  No. of Partially Denied Claims',                              330, CAST(p.P_O2 AS DECIMAL(38,6)), p.P_O2),
        ('PMS', 'O3', N'  No. of No Response from Payor Claims',                        340, CAST(p.P_O3 AS DECIMAL(38,6)), p.P_O3),
        ('Cash', 'P',  N'Total Billed ($)',                    410, p.C_P, 0),
        ('Cash', 'P1', N'  Claim Submitted in Collaborate MD', 420, p.C_P, 0),
        ('Cash', 'Q',  N'Total Unbilled ($)',                  430, p.C_Q, 0),
        ('Cash', 'R',  N'Insurance Payment ($)',               440, p.C_R, 0),
        ('Cash', 'S',  N'Patient Responsibility ($)',          450, p.C_S, 0),
        ('Cash', 'T',  N'Adjustments / Write Off ($)',         460, p.C_P - p.C_R - p.C_U - p.C_V - p.C_W - p.C_S, 0),
        ('Cash', 'U',  N'Partially Paid ($)',                  470, p.C_U, 0),
        ('Cash', 'V',  N'Patient Paid ($)',                    480, p.C_V, 0),
        ('Cash', 'W',  N'Insurance Balance ($)',               490, p.C_W, 0),
        ('Cash', 'W1', N'  Denials',                           500, p.C_W1, 0),
        ('Cash', 'W2', N'  Partially Denied',                  510, p.C_W2, 0),
        ('Cash', 'W3', N'  No Response from Payor',            520, p.C_W3, 0),
        ('Avg', 'X',  N'Average Payment ($) - Total Pay/Billed Claims',      610,
            ISNULL(ROUND(d.PayBilled / NULLIF(CAST(p.P_F AS DECIMAL(38,6)), 0), 2), 0), p.P_F),
        ('Avg', 'Y',  N'Average Payment ($) - Total Pay/Paid Claims',        620,
            ISNULL(ROUND(d.PayPaid / NULLIF(d.PaidClaims, 0), 2), 0), CAST(d.PaidClaims AS INT)),
        ('Avg', 'Z',  N'Average Payment ($) - Total Pay/Adjudicated Claims', 630,
            ISNULL(ROUND(d.PayPaid / NULLIF(d.AdjudicatedClaims, 0), 2), 0), CAST(d.AdjudicatedClaims AS INT))
    ) r(Category, RowCode, Description, SortOrder, MetricValue, ClaimCount);
END;
GO

/* Temp tables shared by refresh / read / cell rows (created by each caller). */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCB_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #EsLis
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        St VARCHAR(10) NOT NULL, Bill CHAR(1) NOT NULL, Sub VARCHAR(10) NOT NULL,
        Cnt INT NOT NULL
    );
    CREATE TABLE #EsClaims
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        BillStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimCnt INT NOT NULL,
        ChargeAmount DECIMAL(18,2) NOT NULL,
        InsurancePayment DECIMAL(18,2) NOT NULL,
        PatientPayment DECIMAL(18,2) NOT NULL,
        PatientBalance DECIMAL(18,2) NOT NULL,
        InsuranceBalance DECIMAL(18,2) NOT NULL
    );
    CREATE TABLE #EsOut
    (
        Category VARCHAR(10) NOT NULL,
        RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        SortOrder INT NOT NULL,
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL,
        ClaimCount INT NOT NULL
    );

    EXEC dbo.usp_CB_ES_Load;
    EXEC dbo.usp_CB_ES_Compute;

    BEGIN TRANSACTION;
        TRUNCATE TABLE dbo.CB_ES_LIS;
        TRUNCATE TABLE dbo.CB_ES_PMS;
        TRUNCATE TABLE dbo.CB_ES_Cash;
        TRUNCATE TABLE dbo.CB_ES_Avg;

        INSERT INTO dbo.CB_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'LIS';

        INSERT INTO dbo.CB_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'PMS';

        INSERT INTO dbo.CB_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, 0, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Cash';

        INSERT INTO dbo.CB_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Avg';
    COMMIT TRANSACTION;

    PRINT 'usp_RefreshCB_ExecutiveSummary completed.';
END;
GO

/* LIS rows are built with the PMS rows (H is PMS billed minus LIS billed).
   Kept so the capture app's prefix refresh finds this procedure. */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshCB_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.CB_ES_LIS)
        EXEC dbo.usp_RefreshCB_ExecutiveSummary;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_ExecutiveSummary
(
    @YearFrom   INT           = NULL,
    @YearTo     INT           = NULL,
    @MonthFrom  INT           = NULL,
    @MonthTo    INT           = NULL,
    @DosFrom    DATE          = NULL,
    @DosTo      DATE          = NULL,
    @BilledFrom DATE          = NULL,
    @BilledTo   DATE          = NULL,
    @Panels     NVARCHAR(MAX) = NULL,
    @Clinics    NVARCHAR(MAX) = NULL,
    @Providers  NVARCHAR(MAX) = NULL,
    @Reps       NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @YearFrom IS NULL AND @YearTo IS NULL AND @MonthFrom IS NULL AND @MonthTo IS NULL
       AND @DosFrom IS NULL AND @DosTo IS NULL AND @BilledFrom IS NULL AND @BilledTo IS NULL
       AND NULLIF(LTRIM(RTRIM(@Panels)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@Clinics)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@Providers)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@Reps)), N'') IS NULL
       AND EXISTS (SELECT 1 FROM dbo.CB_ES_PMS)
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue, SortOrder
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue, ISNULL(SortOrder, 9999) AS SortOrder
            FROM dbo.CB_ES_LIS
            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2)), ISNULL(SortOrder, 9999)
            FROM dbo.CB_ES_PMS
            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
            FROM dbo.CB_ES_Cash
            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
            FROM dbo.CB_ES_Avg
        ) t
        ORDER BY SortOrder, BillYear, BillMonth;
        RETURN;
    END;

    CREATE TABLE #EsLis
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        St VARCHAR(10) NOT NULL, Bill CHAR(1) NOT NULL, Sub VARCHAR(10) NOT NULL,
        Cnt INT NOT NULL
    );
    CREATE TABLE #EsClaims
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        BillStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimCnt INT NOT NULL,
        ChargeAmount DECIMAL(18,2) NOT NULL,
        InsurancePayment DECIMAL(18,2) NOT NULL,
        PatientPayment DECIMAL(18,2) NOT NULL,
        PatientBalance DECIMAL(18,2) NOT NULL,
        InsuranceBalance DECIMAL(18,2) NOT NULL
    );
    CREATE TABLE #EsOut
    (
        Category VARCHAR(10) NOT NULL,
        RowCode NVARCHAR(20) COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        SortOrder INT NOT NULL,
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL,
        ClaimCount INT NOT NULL
    );

    EXEC dbo.usp_CB_ES_Load
        @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
        @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
        @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
    EXEC dbo.usp_CB_ES_Compute;

    SELECT RowCode, Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
           CASE WHEN Category IN ('Cash', 'Avg') THEN MetricValue ELSE CAST(ClaimCount AS DECIMAL(18,2)) END AS MetricValue,
           SortOrder
    FROM #EsOut
    ORDER BY SortOrder, ESYear, ESMonth;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetCB_ExecutiveSummary_FilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT FilterType, FilterValue, SortOrder
    FROM
    (
        SELECT N'Year' AS FilterType,
               CAST(y.Yr AS NVARCHAR(50)) AS FilterValue,
               y.Yr AS SortOrder
        FROM
        (
            SELECT YEAR(TRY_CAST(DateofService AS DATE)) AS Yr
            FROM dbo.ClaimLevelData
            WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
            UNION
            SELECT YEAR(TRY_CAST(RequestCollectDate AS DATE))
            FROM dbo.LIMSMaster
            WHERE TRY_CAST(RequestCollectDate AS DATE) IS NOT NULL
        ) y
        WHERE y.Yr > 1900

        UNION ALL
        SELECT N'Panel', LTRIM(RTRIM(Panelname)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(Panelname)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(Panelname))

        UNION ALL
        SELECT N'Panel', LTRIM(RTRIM(TestCategory)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(TestCategory)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(TestCategory))

        UNION ALL
        SELECT N'Clinic', LTRIM(RTRIM(ClinicName)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(ClinicName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ClinicName))

        UNION ALL
        SELECT N'Clinic', LTRIM(RTRIM(ClinicName)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(ClinicName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ClinicName))

        UNION ALL
        SELECT N'Provider', LTRIM(RTRIM(ReferringProvider)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(ReferringProvider)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ReferringProvider))

        UNION ALL
        SELECT N'Provider', LTRIM(RTRIM(DoctorFullName)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(DoctorFullName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(DoctorFullName))

        UNION ALL
        SELECT N'Rep', LTRIM(RTRIM(SalesRepname)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(SalesRepname)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(SalesRepname))
    ) f
    ORDER BY FilterType, SortOrder DESC, FilterValue;
END;
GO

EXEC dbo.usp_RefreshCB_ExecutiveSummary;
GO

PRINT '36_CoreBio_ExecutiveSummary.sql completed.';
GO

SET NOEXEC OFF;
GO
