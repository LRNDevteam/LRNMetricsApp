/* =============================================================================
   WellHealth - Executive Summary (LIS / PMS / Cash / Average)
   Database : WellHealth only. Other labs are unchanged.

   Standing filter: exclude Date of Service after 2026
     (YEAR(RequestCollectDate) / YEAR(DateofService) > 2026).
     Rows with no Date of Service are excluded. A billed-date filter still
     drops those rows.

   Columns : Date of Service month / year
               LIS        -> LIMSMaster.RequestCollectDate
                            (billed-date mode uses BilledDate or FirstBilledDate
                             when that column exists)
               PMS / Cash -> ClaimLevelData.DateofService
                            (billed-date mode uses FirstBilledDate)
   Counting: LIS = count of non-blank Accession. PMS = count of Claim ID.

   LIS Breakdown
     A   Total Samples              every accession
     B   Billable Samples           New Status = Billable
     C     Billed                   Billable AND Bill Category = Billed
     C1      Billed via CMD         same as C
     D     Unbilled                 Billable AND Bill Category = Unbilled
                                    (Not Billed is included; same as the Well Health LIS Summary)
     D1      Ready to bill          D AND the accession has no claim in ClaimLevelData
     D2      Entered not billed     D AND the accession has a claim in ClaimLevelData
                                    (LIMSMaster.SubStatus never carries Ready to Bill /
                                     Entered Not Billed for Well Health; D1 + D2 = D)
     E   Other Samples              New Status <> Billable
     E1    Cancelled/Rejected       New Status = Cancelled/Rejected
     E2    Client Bill              New Status = Client Bill
     E3    Billing Hold             New Status = Billing Hold
     E4    Self Pay                 New Status = Self Pay
     E5    Yet to be validated      New Status = Yet to be validated
     E6    System Test              New Status = System Test
     E7    Duplicate                New Status = Duplicate

   PMS Breakdown  (Bill Status = Billed or Billed - Self Pay, except where noted)
     F   No. of Billed Claims                 Claim Status <> 0 Billed Amount
     F1    Claim Submitted in Collaborate MD  same as F
     G   No. of Unbilled Claims               Unbilled, Unbilled - Client Bill, Unbilled - Self Pay
                                              AND Claim Status <> 0 Billed Amount
     G1    Unbilled                           Unbilled AND Claim Status <> 0 Billed Amount
     G2    Unbilled - Client bill             Unbilled - Client Bill AND Claim Status <> 0 Billed Amount
     G3    Unbilled - Self Pay                Unbilled - Self Pay AND Claim Status <> 0 Billed Amount
     H   Billed Mismatches                    F minus LIS C
     I   Claim Entered With $0 Billed Amount  Bill Status = Billed AND Claim Status = 0 Billed Amount
     J   Fully Paid                           Fully Paid
     K   Fully Patient Responsibility         Patient Responsibility
     L   Adjusted / Written Off               Fully Adjusted
     M   Partially Adjusted                   Partially Adjusted
     N   Partially Paid                       Partially Paid
     O   Patient Paid                         Patient Payment
     P   Insurance Balance                    Fully Denied, No Response, Partially Denied
     P1    Fully Denied / P2 Partially Denied / P3 No Response

   Cash Breakdown
     Q   Total Billed ($)                     SUM(ChargeAmount) Billed or Billed - Self Pay
     Q1    Claim Submitted in Collaborate MD  same as Q
     R   Total Unbilled ($)                   SUM(ChargeAmount) Unbilled, Unbilled - Self Pay,
                                              Unbilled - Client Bill (R = R1 + R2 + R3)
     R1    Unbilled / R2 Unbilled - Self Pay / R3 Unbilled - Client bill
     S   Insurance Payment ($)                SUM(InsurancePayment) Billed AND Fully Paid
     T   Patient Responsibility ($)           SUM(PatientBalance) Billed
     U   Adjustments / Write Off ($)          SUM(TotalAdjustments) Billed
     V   Partially Paid ($)                   SUM(InsurancePayment) Billed AND Claim Status <> Fully Paid
     W   Patient Paid ($)                     SUM(PatientPayment) Billed
     X   Insurance Balance ($)                SUM(TotalInsuranceBalance) Billed
     X1    Denials                            Fully Denied
     X2    Partially Denied                   Claim Status NOT IN (Fully Denied, No Response)
     X3    No Response from Payor             No Response

   Average Payment Per Claim   numerator = S + V + W
     Y   Total Pay / Billed Claims            / F
     Z   Total Pay / Paid Claims              / (J + N)
     AA  Total Pay / Adjudicated Claims       / (J + K + L + M + N + O + P1 + P2)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'WellHealth'
BEGIN
    RAISERROR('Run 36_WellHealth_ExecutiveSummary.sql on the WellHealth database.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.WH_ES_LIS', N'U') IS NULL
CREATE TABLE dbo.WH_ES_LIS
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_WH_ES_LIS_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_WH_ES_LIS_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_WH_ES_LIS_RefreshedAt DEFAULT (GETDATE())
);
GO
IF COL_LENGTH(N'dbo.WH_ES_LIS', N'SortOrder') IS NULL ALTER TABLE dbo.WH_ES_LIS ADD SortOrder INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_WH_ES_LIS_Period' AND object_id = OBJECT_ID(N'dbo.WH_ES_LIS'))
    CREATE NONCLUSTERED INDEX IX_WH_ES_LIS_Period ON dbo.WH_ES_LIS (ESYear, ESMonth, RoleID);
GO

IF OBJECT_ID(N'dbo.WH_ES_PMS', N'U') IS NULL
CREATE TABLE dbo.WH_ES_PMS
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_WH_ES_PMS_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_WH_ES_PMS_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_WH_ES_PMS_RefreshedAt DEFAULT (GETDATE())
);
GO
IF COL_LENGTH(N'dbo.WH_ES_PMS', N'SortOrder') IS NULL ALTER TABLE dbo.WH_ES_PMS ADD SortOrder INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_WH_ES_PMS_Period' AND object_id = OBJECT_ID(N'dbo.WH_ES_PMS'))
    CREATE NONCLUSTERED INDEX IX_WH_ES_PMS_Period ON dbo.WH_ES_PMS (ESYear, ESMonth, RoleID);
GO

IF OBJECT_ID(N'dbo.WH_ES_Cash', N'U') IS NULL
CREATE TABLE dbo.WH_ES_Cash
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_WH_ES_Cash_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_WH_ES_Cash_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_WH_ES_Cash_RefreshedAt DEFAULT (GETDATE())
);
GO
IF COL_LENGTH(N'dbo.WH_ES_Cash', N'SortOrder') IS NULL ALTER TABLE dbo.WH_ES_Cash ADD SortOrder INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_WH_ES_Cash_Period' AND object_id = OBJECT_ID(N'dbo.WH_ES_Cash'))
    CREATE NONCLUSTERED INDEX IX_WH_ES_Cash_Period ON dbo.WH_ES_Cash (ESYear, ESMonth, RoleID);
GO

IF OBJECT_ID(N'dbo.WH_ES_Avg', N'U') IS NULL
CREATE TABLE dbo.WH_ES_Avg
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(20)   NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_WH_ES_Avg_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_WH_ES_Avg_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_WH_ES_Avg_RefreshedAt DEFAULT (GETDATE())
);
GO
IF COL_LENGTH(N'dbo.WH_ES_Avg', N'SortOrder') IS NULL ALTER TABLE dbo.WH_ES_Avg ADD SortOrder INT NULL;
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_WH_ES_Avg_Period' AND object_id = OBJECT_ID(N'dbo.WH_ES_Avg'))
    CREATE NONCLUSTERED INDEX IX_WH_ES_Avg_Period ON dbo.WH_ES_Avg (ESYear, ESMonth, RoleID);
GO

/* -----------------------------------------------------------------------------
   usp_WH_ES_Load fills #EsLis and #EsClaims. The caller creates both.
   Status text is stored upper-case so the compute step can match exactly.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_WH_ES_Load
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

    DECLARE @LisPeriodCol SYSNAME = N'RequestCollectDate';
    IF @UseBilledDate = 1 AND COL_LENGTH(N'dbo.LIMSMaster', N'BilledDate') IS NOT NULL
        SET @LisPeriodCol = N'BilledDate';
    ELSE IF @UseBilledDate = 1 AND COL_LENGTH(N'dbo.LIMSMaster', N'FirstBilledDate') IS NOT NULL
        SET @LisPeriodCol = N'FirstBilledDate';

    -- Every accession that has a claim in PMS (any date, any status).
    CREATE TABLE #PmsAcc (Acc NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
    INSERT INTO #PmsAcc (Acc)
    SELECT DISTINCT UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))))
    FROM dbo.ClaimLevelData c
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))), N'') IS NOT NULL;

    DELETE FROM #EsLis;
    DECLARE @lis NVARCHAR(MAX) = N'
INSERT INTO #EsLis (ESYear, ESMonth, NewStatus, BillCategory, SubStatus, InPms, Cnt)
SELECT YEAR(p.PeriodDate), MONTH(p.PeriodDate),
       UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.NewStatus), N'''')))),
       UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillCategory), N'''')))),
       UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.SubStatus), N'''')))),
       p.InPms,
       COUNT(*)
FROM dbo.LIMSMaster l
CROSS APPLY (
    SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
           TRY_CAST(l.' + QUOTENAME(@LisPeriodCol) + N' AS DATE) AS PeriodDate,
           CASE WHEN EXISTS (SELECT 1 FROM #PmsAcc a
                             WHERE a.Acc = UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(200), l.Accession)))))
                THEN 1 ELSE 0 END AS InPms
) p
WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(100), l.Accession))), N'''') IS NOT NULL
  AND p.Dos IS NOT NULL
  AND YEAR(p.Dos) > 1900
  AND YEAR(p.Dos) <= 2026
  AND p.PeriodDate IS NOT NULL
  AND (@From IS NULL OR p.PeriodDate >= @From)
  AND (@To IS NULL OR p.PeriodDate <= @To)
  AND (@YearFrom IS NULL OR YEAR(p.PeriodDate) >= @YearFrom)
  AND (@YearTo IS NULL OR YEAR(p.PeriodDate) <= @YearTo)
  AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
  AND (@MonthTo IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)
  AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.TestCategory), N''''))) IN (SELECT Val FROM #Filters WHERE Dim = N''Panel''))
  AND (@HasClinic = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.ClinicName), N''''))) IN (SELECT Val FROM #Filters WHERE Dim = N''Clinic''))
  AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.DoctorFullName), N''''))) IN (SELECT Val FROM #Filters WHERE Dim = N''Provider''))
GROUP BY YEAR(p.PeriodDate), MONTH(p.PeriodDate),
         UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.NewStatus), N'''')))),
         UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.BillCategory), N'''')))),
         UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(100), l.SubStatus), N'''')))),
         p.InPms
OPTION (RECOMPILE);';

    EXEC sys.sp_executesql @lis,
        N'@From date, @To date, @YearFrom int, @YearTo int, @MonthFrom int, @MonthTo int, @HasPanel bit, @HasClinic bit, @HasProvider bit',
        @From, @To, @YearFrom, @YearTo, @MonthFrom, @MonthTo, @HasPanel, @HasClinic, @HasProvider;

    DELETE FROM #EsClaims;
    INSERT INTO #EsClaims
        (ESYear, ESMonth, BillStatus, ClaimStatus, ClaimCnt, ChargeAmount, InsurancePayment,
         PatientPayment, PatientBalance, TotalAdjustments, TotalInsuranceBalance)
    SELECT YEAR(n.PeriodDate), MONTH(n.PeriodDate), n.BillStatus, n.ClaimStatus,
           COUNT(*),
           SUM(n.ChargeAmount), SUM(n.InsurancePayment), SUM(n.PatientPayment),
           SUM(n.PatientBalance), SUM(n.TotalAdjustments), SUM(n.TotalInsuranceBalance)
    FROM dbo.ClaimLevelData c
    CROSS APPLY (
        SELECT
            UPPER(LTRIM(RTRIM(REPLACE(REPLACE(REPLACE(REPLACE(
                ISNULL(CONVERT(NVARCHAR(200), c.BilledStatus), N''), N'  ', N' '), N'  ', N' '), N'  ', N' '), N'  ', N' ')))) AS BillStatus,
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N'')))) AS ClaimStatus,
            TRY_CAST(c.DateofService AS DATE) AS Dos,
            CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(c.FirstBilledDate AS DATE)
                 ELSE TRY_CAST(c.DateofService AS DATE) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.ChargeAmount))), N'$', N''), N',', N'')), 0) AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsurancePayment))), N'$', N''), N',', N'')), 0) AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientPayment))), N'$', N''), N',', N'')), 0) AS PatientPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientBalance))), N'$', N''), N',', N'')), 0) AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.TotalAdjustments))), N'$', N''), N',', N'')), 0) AS TotalAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.TotalInsuranceBalance))), N'$', N''), N',', N'')), 0) AS TotalInsuranceBalance
    ) n
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
      AND n.Dos IS NOT NULL
      AND YEAR(n.Dos) > 1900
      AND YEAR(n.Dos) <= 2026
      AND n.PeriodDate IS NOT NULL
      AND (@From IS NULL OR n.PeriodDate >= @From)
      AND (@To IS NULL OR n.PeriodDate <= @To)
      AND (@YearFrom IS NULL OR YEAR(n.PeriodDate) >= @YearFrom)
      AND (@YearTo IS NULL OR YEAR(n.PeriodDate) <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(n.PeriodDate) >= @MonthFrom)
      AND (@MonthTo IS NULL OR MONTH(n.PeriodDate) <= @MonthTo)
      AND (@HasPanel = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.Panelname), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ClinicName), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ReferringProvider), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
      AND (@HasRep = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.SalesRepname), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
    GROUP BY YEAR(n.PeriodDate), MONTH(n.PeriodDate), n.BillStatus, n.ClaimStatus
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   Row logic. Caller supplies #EsLis, #EsClaims and empty #EsOut.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_WH_ES_Compute
AS
BEGIN
    SET NOCOUNT ON;

    DROP TABLE IF EXISTS #LisM;
    SELECT
        ISNULL(ESYear, 0) AS Y,
        CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
        ISNULL(SUM(Cnt), 0) AS L_A,
        ISNULL(SUM(CASE WHEN NewStatus = N'BILLABLE' THEN Cnt END), 0) AS L_B,
        ISNULL(SUM(CASE WHEN NewStatus = N'BILLABLE' AND BillCategory = N'BILLED' THEN Cnt END), 0) AS L_C,
        ISNULL(SUM(CASE WHEN NewStatus = N'BILLABLE' AND BillCategory IN (N'UNBILLED', N'NOT BILLED') THEN Cnt END), 0) AS L_D,
        ISNULL(SUM(CASE WHEN NewStatus = N'BILLABLE' AND BillCategory IN (N'UNBILLED', N'NOT BILLED')
                         AND InPms = 0 THEN Cnt END), 0) AS L_D1,
        ISNULL(SUM(CASE WHEN NewStatus = N'BILLABLE' AND BillCategory IN (N'UNBILLED', N'NOT BILLED')
                         AND InPms = 1 THEN Cnt END), 0) AS L_D2,
        ISNULL(SUM(CASE WHEN NewStatus <> N'BILLABLE' THEN Cnt END), 0) AS L_E,
        ISNULL(SUM(CASE WHEN NewStatus IN (N'CANCELLED/REJECTED', N'CANCELED/REJECTED') THEN Cnt END), 0) AS L_E1,
        ISNULL(SUM(CASE WHEN NewStatus = N'CLIENT BILL' THEN Cnt END), 0) AS L_E2,
        ISNULL(SUM(CASE WHEN NewStatus = N'BILLING HOLD' THEN Cnt END), 0) AS L_E3,
        ISNULL(SUM(CASE WHEN NewStatus = N'SELF PAY' THEN Cnt END), 0) AS L_E4,
        ISNULL(SUM(CASE WHEN NewStatus IN (N'YET TO BE VALIDATED', N'YET TO BE VALIDATE', N'YET BE VALIDATED') THEN Cnt END), 0) AS L_E5,
        ISNULL(SUM(CASE WHEN NewStatus = N'SYSTEM TEST' THEN Cnt END), 0) AS L_E6,
        ISNULL(SUM(CASE WHEN NewStatus IN (N'DUPLICATE', N'DUPLICATES') THEN Cnt END), 0) AS L_E7
    INTO #LisM
    FROM #EsLis
    GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

    DROP TABLE IF EXISTS #ClmM;
    SELECT
        ISNULL(ESYear, 0) AS Y,
        CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY')
                         AND ClaimStatus <> N'0 BILLED AMOUNT' THEN ClaimCnt END), 0) AS P_F,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'UNBILLED', N'UNBILLED - CLIENT BILL', N'UNBILLED - SELF PAY')
                         AND ClaimStatus <> N'0 BILLED AMOUNT' THEN ClaimCnt END), 0) AS P_G,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED' AND ClaimStatus <> N'0 BILLED AMOUNT' THEN ClaimCnt END), 0) AS P_G1,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED - CLIENT BILL' AND ClaimStatus <> N'0 BILLED AMOUNT' THEN ClaimCnt END), 0) AS P_G2,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED - SELF PAY' AND ClaimStatus <> N'0 BILLED AMOUNT' THEN ClaimCnt END), 0) AS P_G3,
        ISNULL(SUM(CASE WHEN BillStatus = N'BILLED' AND ClaimStatus = N'0 BILLED AMOUNT' THEN ClaimCnt END), 0) AS P_I,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'FULLY PAID' THEN ClaimCnt END), 0) AS P_J,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'PATIENT RESPONSIBILITY' THEN ClaimCnt END), 0) AS P_K,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'FULLY ADJUSTED' THEN ClaimCnt END), 0) AS P_L,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'PARTIALLY ADJUSTED' THEN ClaimCnt END), 0) AS P_M,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'PARTIALLY PAID' THEN ClaimCnt END), 0) AS P_N,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'PATIENT PAYMENT' THEN ClaimCnt END), 0) AS P_O,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY')
                         AND ClaimStatus IN (N'FULLY DENIED', N'NO RESPONSE', N'PARTIALLY DENIED') THEN ClaimCnt END), 0) AS P_P,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'FULLY DENIED' THEN ClaimCnt END), 0) AS P_P1,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'PARTIALLY DENIED' THEN ClaimCnt END), 0) AS P_P2,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'NO RESPONSE' THEN ClaimCnt END), 0) AS P_P3,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') THEN ChargeAmount END), 0) AS C_Q,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'UNBILLED', N'UNBILLED - SELF PAY', N'UNBILLED - CLIENT BILL') THEN ChargeAmount END), 0) AS C_R,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED' THEN ChargeAmount END), 0) AS C_R1,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED - SELF PAY' THEN ChargeAmount END), 0) AS C_R2,
        ISNULL(SUM(CASE WHEN BillStatus = N'UNBILLED - CLIENT BILL' THEN ChargeAmount END), 0) AS C_R3,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'FULLY PAID' THEN InsurancePayment END), 0) AS C_S,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') THEN PatientBalance END), 0) AS C_T,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') THEN TotalAdjustments END), 0) AS C_U,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus <> N'FULLY PAID'
                         THEN InsurancePayment END), 0) AS C_V,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') THEN PatientPayment END), 0) AS C_W,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') THEN TotalInsuranceBalance END), 0) AS C_X,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'FULLY DENIED'
                         THEN TotalInsuranceBalance END), 0) AS C_X1,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY')
                         AND ClaimStatus NOT IN (N'FULLY DENIED', N'NO RESPONSE')
                         THEN TotalInsuranceBalance END), 0) AS C_X2,
        ISNULL(SUM(CASE WHEN BillStatus IN (N'BILLED', N'BILLED - SELF PAY') AND ClaimStatus = N'NO RESPONSE'
                         THEN TotalInsuranceBalance END), 0) AS C_X3
    INTO #ClmM
    FROM #EsClaims
    GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

    DROP TABLE IF EXISTS #Per;
    SELECT
        COALESCE(l.Y, c.Y) AS Y, COALESCE(l.M, c.M) AS M,
        ISNULL(l.L_A, 0) L_A, ISNULL(l.L_B, 0) L_B, ISNULL(l.L_C, 0) L_C, ISNULL(l.L_D, 0) L_D,
        ISNULL(l.L_D1, 0) L_D1, ISNULL(l.L_D2, 0) L_D2, ISNULL(l.L_E, 0) L_E,
        ISNULL(l.L_E1, 0) L_E1, ISNULL(l.L_E2, 0) L_E2, ISNULL(l.L_E3, 0) L_E3, ISNULL(l.L_E4, 0) L_E4,
        ISNULL(l.L_E5, 0) L_E5, ISNULL(l.L_E6, 0) L_E6, ISNULL(l.L_E7, 0) L_E7,
        ISNULL(c.P_F, 0) P_F, ISNULL(c.P_G, 0) P_G, ISNULL(c.P_G1, 0) P_G1, ISNULL(c.P_G2, 0) P_G2, ISNULL(c.P_G3, 0) P_G3,
        ISNULL(c.P_I, 0) P_I, ISNULL(c.P_J, 0) P_J, ISNULL(c.P_K, 0) P_K, ISNULL(c.P_L, 0) P_L,
        ISNULL(c.P_M, 0) P_M, ISNULL(c.P_N, 0) P_N, ISNULL(c.P_O, 0) P_O, ISNULL(c.P_P, 0) P_P,
        ISNULL(c.P_P1, 0) P_P1, ISNULL(c.P_P2, 0) P_P2, ISNULL(c.P_P3, 0) P_P3,
        ISNULL(c.C_Q, 0) C_Q, ISNULL(c.C_R, 0) C_R, ISNULL(c.C_R1, 0) C_R1, ISNULL(c.C_R2, 0) C_R2, ISNULL(c.C_R3, 0) C_R3,
        ISNULL(c.C_S, 0) C_S, ISNULL(c.C_T, 0) C_T, ISNULL(c.C_U, 0) C_U, ISNULL(c.C_V, 0) C_V,
        ISNULL(c.C_W, 0) C_W, ISNULL(c.C_X, 0) C_X, ISNULL(c.C_X1, 0) C_X1, ISNULL(c.C_X2, 0) C_X2, ISNULL(c.C_X3, 0) C_X3
    INTO #Per
    FROM #LisM l
    FULL OUTER JOIN #ClmM c ON c.Y = l.Y AND c.M = l.M;

    INSERT INTO #EsOut (Category, RowCode, Description, SortOrder, ESYear, ESMonth, MetricValue, ClaimCount)
    SELECT r.Category, r.RowCode, r.Description, r.SortOrder, p.Y, p.M,
           CAST(r.MetricValue AS DECIMAL(18,2)), r.ClaimCount
    FROM #Per p
    CROSS APPLY (
        SELECT
            CAST(p.C_S + p.C_V + p.C_W AS DECIMAL(38,6)) AS PayDollars,
            CAST(p.P_J + p.P_N AS DECIMAL(38,6)) AS PaidClaims,
            CAST(p.P_J + p.P_K + p.P_L + p.P_M + p.P_N + p.P_O + p.P_P1 + p.P_P2 AS DECIMAL(38,6)) AS AdjudicatedClaims
    ) d
    CROSS APPLY (VALUES
        ('LIS', 'A',  N'Total Samples',                  10,  CAST(p.L_A AS DECIMAL(38,6)), p.L_A),
        ('LIS', 'B',  N'Billable Samples',               20,  CAST(p.L_B AS DECIMAL(38,6)), p.L_B),
        ('LIS', 'C',  N'  Billed',                       30,  CAST(p.L_C AS DECIMAL(38,6)), p.L_C),
        ('LIS', 'C1', N'    Billed via CMD',             40,  CAST(p.L_C AS DECIMAL(38,6)), p.L_C),
        ('LIS', 'D',  N'  Unbilled',                     50,  CAST(p.L_D AS DECIMAL(38,6)), p.L_D),
        ('LIS', 'D1', N'    Ready to bill',              60,  CAST(p.L_D1 AS DECIMAL(38,6)), p.L_D1),
        ('LIS', 'D2', N'    Entered not billed',         70,  CAST(p.L_D2 AS DECIMAL(38,6)), p.L_D2),
        ('LIS', 'E',  N'Other Samples',                  80,  CAST(p.L_E AS DECIMAL(38,6)), p.L_E),
        ('LIS', 'E1', N'  Cancelled/Rejected',           90,  CAST(p.L_E1 AS DECIMAL(38,6)), p.L_E1),
        ('LIS', 'E2', N'  Client Bill',                 100,  CAST(p.L_E2 AS DECIMAL(38,6)), p.L_E2),
        ('LIS', 'E3', N'  Billing Hold',                110,  CAST(p.L_E3 AS DECIMAL(38,6)), p.L_E3),
        ('LIS', 'E4', N'  Self Pay',                    120,  CAST(p.L_E4 AS DECIMAL(38,6)), p.L_E4),
        ('LIS', 'E5', N'  Yet to be validated',         130,  CAST(p.L_E5 AS DECIMAL(38,6)), p.L_E5),
        ('LIS', 'E6', N'  System Test',                 140,  CAST(p.L_E6 AS DECIMAL(38,6)), p.L_E6),
        ('LIS', 'E7', N'  Duplicate',                   150,  CAST(p.L_E7 AS DECIMAL(38,6)), p.L_E7),
        ('PMS', 'F',  N'No. of Billed Claims',                                          210, CAST(p.P_F AS DECIMAL(38,6)), p.P_F),
        ('PMS', 'F1', N'  Claim Submitted in Collaborate MD',                           220, CAST(p.P_F AS DECIMAL(38,6)), p.P_F),
        ('PMS', 'G',  N'No. of Unbilled Claims',                                        230, CAST(p.P_G AS DECIMAL(38,6)), p.P_G),
        ('PMS', 'G1', N'  Unbilled',                                                    240, CAST(p.P_G1 AS DECIMAL(38,6)), p.P_G1),
        ('PMS', 'G2', N'  Unbilled - Client bill',                                      250, CAST(p.P_G2 AS DECIMAL(38,6)), p.P_G2),
        ('PMS', 'G3', N'  Unbilled - Self Pay',                                         260, CAST(p.P_G3 AS DECIMAL(38,6)), p.P_G3),
        ('PMS', 'H',  N'Billed Mismatches - Other samples billed / LIS Accessions NA', 270, CAST(p.P_F - p.L_C AS DECIMAL(38,6)), p.P_F - p.L_C),
        ('PMS', 'I',  N'Claim Entered With $0 Billed Amount',                           280, CAST(p.P_I AS DECIMAL(38,6)), p.P_I),
        ('PMS', 'J',  N'No. of Fully Paid Claims',                                      290, CAST(p.P_J AS DECIMAL(38,6)), p.P_J),
        ('PMS', 'K',  N'No. of Fully Patient Responsibility Claims',                    300, CAST(p.P_K AS DECIMAL(38,6)), p.P_K),
        ('PMS', 'L',  N'No. of Adjusted/ Written Off Claims',                           310, CAST(p.P_L AS DECIMAL(38,6)), p.P_L),
        ('PMS', 'M',  N'No. of Partially Adjusted Claim',                               320, CAST(p.P_M AS DECIMAL(38,6)), p.P_M),
        ('PMS', 'N',  N'No. of Partially Paid Claims',                                  330, CAST(p.P_N AS DECIMAL(38,6)), p.P_N),
        ('PMS', 'O',  N'No. of Patient Paid Claims',                                    340, CAST(p.P_O AS DECIMAL(38,6)), p.P_O),
        ('PMS', 'P',  N'No. of Insurance Balance Claims',                               350, CAST(p.P_P AS DECIMAL(38,6)), p.P_P),
        ('PMS', 'P1', N'  No. of Fully Denied Claims',                                  360, CAST(p.P_P1 AS DECIMAL(38,6)), p.P_P1),
        ('PMS', 'P2', N'  No. of Partially Denied Claims',                              370, CAST(p.P_P2 AS DECIMAL(38,6)), p.P_P2),
        ('PMS', 'P3', N'  No. of No Response from Payor Claims',                        380, CAST(p.P_P3 AS DECIMAL(38,6)), p.P_P3),
        ('Cash', 'Q',  N'Total Billed ($)',                    410, p.C_Q, 0),
        ('Cash', 'Q1', N'  Claim Submitted in Collaborate MD', 420, p.C_Q, 0),
        ('Cash', 'R',  N'Total Unbilled ($)',                  430, p.C_R, 0),
        ('Cash', 'R1', N'  Unbilled',                          440, p.C_R1, 0),
        ('Cash', 'R2', N'  Unbilled - Self Pay',               450, p.C_R2, 0),
        ('Cash', 'R3', N'  Unbilled - Client bill',            460, p.C_R3, 0),
        ('Cash', 'S',  N'Insurance Payment ($)',               470, p.C_S, 0),
        ('Cash', 'T',  N'Patient Responsibility ($)',          480, p.C_T, 0),
        ('Cash', 'U',  N'Adjustments / Write Off ($)',         490, p.C_U, 0),
        ('Cash', 'V',  N'Partially Paid ($)',                  500, p.C_V, 0),
        ('Cash', 'W',  N'Patient Paid ($)',                    510, p.C_W, 0),
        ('Cash', 'X',  N'Insurance Balance ($)',               520, p.C_X, 0),
        ('Cash', 'X1', N'  Denials',                           530, p.C_X1, 0),
        ('Cash', 'X2', N'  Partially Denied',                  540, p.C_X2, 0),
        ('Cash', 'X3', N'  No Response from Payor',            550, p.C_X3, 0),
        ('Avg', 'Y',  N'Average Payment ($) - Total Pay/Billed Claims',      610,
            ISNULL(ROUND(d.PayDollars / NULLIF(CAST(p.P_F AS DECIMAL(38,6)), 0), 2), 0), p.P_F),
        ('Avg', 'Z',  N'Average Payment ($) - Total Pay/Paid Claims',        620,
            ISNULL(ROUND(d.PayDollars / NULLIF(d.PaidClaims, 0), 2), 0), CAST(d.PaidClaims AS INT)),
        ('Avg', 'AA', N'Average Payment ($) - Total Pay/Adjudicated Claims', 630,
            ISNULL(ROUND(d.PayDollars / NULLIF(d.AdjudicatedClaims, 0), 2), 0), CAST(d.AdjudicatedClaims AS INT))
    ) r(Category, RowCode, Description, SortOrder, MetricValue, ClaimCount);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #EsLis
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        NewStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        BillCategory NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        SubStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        InPms BIT NOT NULL,
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
        TotalAdjustments DECIMAL(18,2) NOT NULL,
        TotalInsuranceBalance DECIMAL(18,2) NOT NULL
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

    EXEC dbo.usp_WH_ES_Load;
    EXEC dbo.usp_WH_ES_Compute;

    BEGIN TRANSACTION;
        TRUNCATE TABLE dbo.WH_ES_LIS;
        TRUNCATE TABLE dbo.WH_ES_PMS;
        TRUNCATE TABLE dbo.WH_ES_Cash;
        TRUNCATE TABLE dbo.WH_ES_Avg;

        INSERT INTO dbo.WH_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'LIS';

        INSERT INTO dbo.WH_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'PMS';

        INSERT INTO dbo.WH_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, 0, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Cash';

        INSERT INTO dbo.WH_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Avg';
    COMMIT TRANSACTION;

    PRINT 'usp_RefreshWH_ExecutiveSummary completed.';
END;
GO

/* LIS rows are built with the PMS rows (H is PMS billed minus LIS billed).
   Kept so the capture app's prefix refresh finds this procedure. */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.WH_ES_LIS)
        EXEC dbo.usp_RefreshWH_ExecutiveSummary;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_ExecutiveSummary
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
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue, SortOrder
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue, ISNULL(SortOrder, 9999) AS SortOrder
            FROM dbo.WH_ES_LIS
            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2)), ISNULL(SortOrder, 9999)
            FROM dbo.WH_ES_PMS
            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
            FROM dbo.WH_ES_Cash
            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
            FROM dbo.WH_ES_Avg
        ) t
        ORDER BY SortOrder, BillYear, BillMonth;
        RETURN;
    END;

    CREATE TABLE #EsLis
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        NewStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        BillCategory NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        SubStatus NVARCHAR(100) COLLATE DATABASE_DEFAULT NOT NULL,
        InPms BIT NOT NULL,
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
        TotalAdjustments DECIMAL(18,2) NOT NULL,
        TotalInsuranceBalance DECIMAL(18,2) NOT NULL
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

    EXEC dbo.usp_WH_ES_Load
        @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
        @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
        @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
    EXEC dbo.usp_WH_ES_Compute;

    SELECT RowCode, Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
           CASE WHEN Category IN ('Cash', 'Avg') THEN MetricValue ELSE CAST(ClaimCount AS DECIMAL(18,2)) END AS MetricValue,
           SortOrder
    FROM #EsOut
    ORDER BY SortOrder, ESYear, ESMonth;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetWH_ExecutiveSummary_FilterOptions
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
        WHERE y.Yr > 1900 AND y.Yr <= 2026

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

IF OBJECT_ID(N'dbo.LisDrillRowDef', N'U') IS NOT NULL
BEGIN
    DELETE FROM dbo.LisDrillRowDef WHERE LabPrefix = N'WH';

    INSERT INTO dbo.LisDrillRowDef
        (LabPrefix, RowCode, RowTitle, DateCol, Source, AmountCol,
         Col1, Op1, Val1, Col2, Op2, Val2, Col3, Op3, Val3)
    VALUES
    (N'WH', N'A',  N'Total Samples',         N'RequestCollectDate', N'LIS', NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'B',  N'Billable Samples',      N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'C',  N'Billed',                N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', N'BillCategory', N'=', N'Billed', NULL, NULL, NULL),
    (N'WH', N'C1', N'Billed via CMD',        N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', N'BillCategory', N'=', N'Billed', NULL, NULL, NULL),
    (N'WH', N'D',  N'Unbilled',              N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billable', N'BillCategory', N'IN', N'Unbilled,Not Billed', NULL, NULL, NULL),
    (N'WH', N'E',  N'Other Samples',         N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'<>', N'Billable', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E1', N'Cancelled/Rejected',    N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'IN', N'Cancelled/Rejected,Canceled/Rejected', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E2', N'Client Bill',           N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Client Bill', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E3', N'Billing Hold',          N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Billing Hold', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E4', N'Self Pay',              N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E5', N'Yet to be validated',   N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'IN', N'Yet to be validated,Yet to Be Validate,Yet be validated', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E6', N'System Test',           N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'=', N'System Test', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'E7', N'Duplicate',             N'RequestCollectDate', N'LIS', NULL, N'NewStatus', N'IN', N'Duplicate,Duplicates', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'F',  N'No. of Billed Claims',                         N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'<>', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'F1', N'Claim Submitted in Collaborate MD',            N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'<>', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'G',  N'No. of Unbilled Claims',                       N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Unbilled,Unbilled - Client Bill,Unbilled -  Client Bill,Unbilled - Self Pay,Unbilled -  Self Pay', N'ClaimStatus', N'<>', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'G1', N'Unbilled',                                     N'DateofService', N'PMS', NULL, N'BilledStatus', N'=', N'Unbilled', N'ClaimStatus', N'<>', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'G2', N'Unbilled - Client bill',                       N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Unbilled - Client Bill,Unbilled -  Client Bill', N'ClaimStatus', N'<>', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'G3', N'Unbilled - Self Pay',                          N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Unbilled - Self Pay,Unbilled -  Self Pay', N'ClaimStatus', N'<>', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'H',  N'Billed Mismatches - Other samples billed / LIS Accessions NA', N'DateofService', N'PMS', NULL, N'BilledStatus', N'MISMATCH', NULL, NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'I',  N'Claim Entered With $0 Billed Amount',          N'DateofService', N'PMS', NULL, N'BilledStatus', N'=', N'Billed', N'ClaimStatus', N'=', N'0 Billed Amount', NULL, NULL, NULL),
    (N'WH', N'J',  N'No. of Fully Paid Claims',                     N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Fully Paid', NULL, NULL, NULL),
    (N'WH', N'K',  N'No. of Fully Patient Responsibility Claims',   N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Patient Responsibility', NULL, NULL, NULL),
    (N'WH', N'L',  N'No. of Adjusted/ Written Off Claims',          N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Fully Adjusted', NULL, NULL, NULL),
    (N'WH', N'M',  N'No. of Partially Adjusted Claim',              N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Partially Adjusted', NULL, NULL, NULL),
    (N'WH', N'N',  N'No. of Partially Paid Claims',                 N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Partially Paid', NULL, NULL, NULL),
    (N'WH', N'O',  N'No. of Patient Paid Claims',                   N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Patient Payment', NULL, NULL, NULL),
    (N'WH', N'P',  N'No. of Insurance Balance Claims',              N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'IN', N'Fully Denied,No Response,Partially Denied', NULL, NULL, NULL),
    (N'WH', N'P1', N'No. of Fully Denied Claims',                   N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Fully Denied', NULL, NULL, NULL),
    (N'WH', N'P2', N'No. of Partially Denied Claims',               N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Partially Denied', NULL, NULL, NULL),
    (N'WH', N'P3', N'No. of No Response from Payor Claims',         N'DateofService', N'PMS', NULL, N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'No Response', NULL, NULL, NULL),
    (N'WH', N'Q',  N'Total Billed ($)',                    N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'Q1', N'Claim Submitted in Collaborate MD',   N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'R',  N'Total Unbilled ($)',                  N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Unbilled,Unbilled - Self Pay,Unbilled -  Self Pay,Unbilled - Client Bill,Unbilled -  Client Bill', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'R1', N'Unbilled',                            N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'=', N'Unbilled', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'R2', N'Unbilled - Self Pay',                 N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Unbilled - Self Pay,Unbilled -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'R3', N'Unbilled - Client bill',              N'DateofService', N'Cash', N'ChargeAmount',          N'BilledStatus', N'IN', N'Unbilled - Client Bill,Unbilled -  Client Bill', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'S',  N'Insurance Payment ($)',               N'DateofService', N'Cash', N'InsurancePayment',      N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Fully Paid', NULL, NULL, NULL),
    (N'WH', N'T',  N'Patient Responsibility ($)',          N'DateofService', N'Cash', N'PatientBalance',        N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'U',  N'Adjustments / Write Off ($)',         N'DateofService', N'Cash', N'TotalAdjustments',      N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'V',  N'Partially Paid ($)',                  N'DateofService', N'Cash', N'InsurancePayment',      N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'<>', N'Fully Paid', NULL, NULL, NULL),
    (N'WH', N'W',  N'Patient Paid ($)',                    N'DateofService', N'Cash', N'PatientPayment',        N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'X',  N'Insurance Balance ($)',               N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', NULL, NULL, NULL, NULL, NULL, NULL),
    (N'WH', N'X1', N'Denials',                             N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'Fully Denied', NULL, NULL, NULL),
    (N'WH', N'X2', N'Partially Denied',                    N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'NOT IN', N'Fully Denied,No Response', NULL, NULL, NULL),
    (N'WH', N'X3', N'No Response from Payor',              N'DateofService', N'Cash', N'TotalInsuranceBalance', N'BilledStatus', N'IN', N'Billed,Billed - Self Pay,Billed -  Self Pay', N'ClaimStatus', N'=', N'No Response', NULL, NULL, NULL);
END;
GO

EXEC dbo.usp_RefreshWH_ExecutiveSummary;
GO

PRINT '36_WellHealth_ExecutiveSummary.sql completed.';
GO

SET NOEXEC OFF;
GO
