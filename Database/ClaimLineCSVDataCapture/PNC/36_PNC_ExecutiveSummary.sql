/* =============================================================================
   PNC - Executive Summary (LIS / PMS / Cash / Average)
   Database : PNC        Prefix : PNC

   Same design as TexasDiagnostic (36_TexasDiagnostic_ExecutiveSummary.sql): every row, total and
   sort order is computed here; the page, Excel and the cell popup only lay the result out.

   Columns : Date of Service month / year
               LIS        -> LIMSMaster.RequestCollectDate (billed-date mode: BilledDate)
               PMS / Cash -> ClaimLevelData.DateofService  (billed-date mode: FirstBilledDate)
   Counting: LIS = count of non-blank Accession. PMS = count of Claim ID (every claim - the PNC sheet
             has no duplicate rule; its billed + unbilled claims equal the claim file's rows).
   Billed claim = ClaimStatus NOT IN (Unbilled, Unbilled - Patient Balance).

   LIS Breakdown (LIMSMaster; same NewStatus / BillCategory / SubStatus values as the LIS Summary)
     A   Total Samples              every sample
     B   Billable Samples           NewStatus = Billable
     B.{PANEL} one row per PanelName (dynamic; blank PanelName has no row), largest Total first
     C   Billed                     Billable AND BillCategory = Billed
     C1    Claim Submitted in Historical Lab   C AND SubStatus = Claim Submitted in Historical Lab
     C2    Claim Submitted in PNC Lab          C AND SubStatus = Claim Submitted in PNC Lab
     D   Unbilled                   Billable AND BillCategory = Unbilled
     D1    Ready to Bill            D AND SubStatus = Ready to Bill
     D2    Missing Insurance Info   D AND SubStatus IN (No Insurance Info, Missing Insurance Info)
     E   Other Samples              NewStatus <> Billable
     E1 Deleted / Rejected  E2 Client Bill  E3 System Test  E4 Self Pay  E5 Missing Accession
     E6 Yet to be Validated  E7 Duplicate (the sheet spells it Dublicate)

   Billable Samples - PMS Breakdown (ClaimLevelData)
     F   No. of Billed Claims               billed claims
     G   Billed Mismatches - Duplicates     F minus LIS C
     I   No. of UnBilled Claims             ClaimStatus IN (Unbilled, Unbilled - Patient Balance)
     J   No. of Fully Paid Claims           ClaimStatus = Fully Paid
     K   No. of Partially Paid Claims       ClaimStatus = Partially Paid
     L   No. of Patient Responsibility      ClaimStatus = Pat Responsibility (or Patient Responsibility)
     M   No. of Fully Adjusted Claims       ClaimStatus = Fully Adjusted
     MP  No. of Partially Adjusted Claims   ClaimStatus = Partially Adjusted
     N   No. of Patient Paid Claims         ClaimStatus = Patient Payment
     O   No. of Insurance Balance Claims    O1 + O2 + O3
     O1    Fully Denied                     ClaimStatus = Fully Denied
     O2    Partially Denied                 ClaimStatus = Partially Denied
     O3    No Response from Payor           ClaimStatus = No Response

   Cash Breakdown
     P   Total Billed ($)                   SUM(ChargeAmount)         billed claims
     Q   Insurance Payment ($)              SUM(InsurancePayment)     ClaimStatus = Fully Paid
     R   Partially Paid ($)                 SUM(InsurancePayment)     ClaimStatus = Partially Paid
     RP  Patient Paid ($)                   SUM(PatientPayment)       FirstBilledDate is a date
     S   Total Payments ($)                 Q + R + RP
     T   Total Adjustments ($)              SUM(InsuranceAdjustments) ClaimStatus = Fully Adjusted
     U   Contractual Obligation W/O         SUM(InsuranceAdjustments) ClaimStatus NOT IN (Fully Adjusted, Unbilled,
                                                                                         Unbilled - Patient Balance)
     V   Total Patient Responsibility       SUM(PatientBalance)       billed claims
     W   Total Insurance Balance ($)        W1 + W2 + W3
     W1    Denials                          SUM(InsuranceBalance)     ClaimStatus = Fully Denied
     W2    Partially Denied                 SUM(InsuranceBalance)     ClaimStatus IN (Partially Adjusted, Partially Paid,
                                                                                     Partially Denied)
     W3    No Response from Payor           SUM(InsuranceBalance)     ClaimStatus = No Response
   (W / W2 are marked "Doubt" on the sheet; the sheet's own figures equal W1 + W2 + W3 and the
    Partially Paid balance, which is what these rules return.)

   Average Payment Per Claim
     AK  Total Pay / Billed Claims          S / F
     AL  Total Pay / Paid Claims            Q / J
     AM  Total Pay / Adjudicated Claims     S / (F - O3)  = S / (J + K + L + M + MP + N + O1 + O2)
         (marked "Doubt" on the sheet; the sheet's monthly figures equal S / (F - O3))

   {PANEL} = UPPER(TRIM(PanelName)); the row shows the name as written in the data.
   SortOrder = the row's position x 100; panel rows follow B (2000 + rank).
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
    RAISERROR('Run 36_PNC_ExecutiveSummary.sql on the PNC database.', 16, 1);
    SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.PNC_ES_LIS', N'U') IS NULL
CREATE TABLE dbo.PNC_ES_LIS
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(320)  NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_PNC_ES_LIS_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PNC_ES_LIS_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_PNC_ES_LIS_RefreshedAt DEFAULT (GETDATE())
);
GO

IF OBJECT_ID(N'dbo.PNC_ES_PMS', N'U') IS NULL
CREATE TABLE dbo.PNC_ES_PMS
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(320)  NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_PNC_ES_PMS_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PNC_ES_PMS_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_PNC_ES_PMS_RefreshedAt DEFAULT (GETDATE())
);
GO

IF OBJECT_ID(N'dbo.PNC_ES_Cash', N'U') IS NULL
CREATE TABLE dbo.PNC_ES_Cash
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(320)  NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_PNC_ES_Cash_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PNC_ES_Cash_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_PNC_ES_Cash_RefreshedAt DEFAULT (GETDATE())
);
GO

IF OBJECT_ID(N'dbo.PNC_ES_Avg', N'U') IS NULL
CREATE TABLE dbo.PNC_ES_Avg
(
    Id                  INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RoleID              NVARCHAR(320)  NOT NULL,
    Description         NVARCHAR(300)  NOT NULL,
    ESYear              INT            NOT NULL,
    ESMonth             INT            NOT NULL,
    ESMonthClaimCount   INT            NOT NULL CONSTRAINT DF_PNC_ES_Avg_Cnt DEFAULT (0),
    ESMonthChargeAmount DECIMAL(18,2)  NOT NULL CONSTRAINT DF_PNC_ES_Avg_Amt DEFAULT (0),
    SortOrder           INT            NULL,
    RefreshedAt         DATETIME       NOT NULL CONSTRAINT DF_PNC_ES_Avg_RefreshedAt DEFAULT (GETDATE())
);
GO

/* -----------------------------------------------------------------------------
   usp_PNC_ES_Load fills #EsLis and #EsClaims. The caller creates both.
   #EsLis carries the sample's status key (St), billed flag (Bill 'B' / 'U' / ''),
   sub status key (Sub), panel key (Panel = UPPER(TRIM(PanelName)), '' when blank) and the
   panel name as written (PanelLabel).
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_ES_Load
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
    INSERT INTO #EsLis (ESYear, ESMonth, St, Bill, Sub, Panel, PanelLabel, Cnt)
    SELECT YEAR(p.PeriodDate), MONTH(p.PeriodDate), k.St, k.Bill, k.Sub, k.Panel, k.PanelLabel, COUNT(*)
    FROM dbo.LIMSMaster l
    CROSS APPLY (
        SELECT TRY_CAST(l.RequestCollectDate AS DATE) AS Dos,
               CASE WHEN @UseBilledDate = 1 THEN TRY_CAST(l.BilledDate AS DATE)
                    ELSE TRY_CAST(l.RequestCollectDate AS DATE) END AS PeriodDate,
               UPPER(REPLACE(REPLACE(ISNULL(CONVERT(NVARCHAR(255), l.NewStatus), N''), N' ', N''), N'-', N'')) AS NS,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.BillCategory), N'')))) AS BC,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(255), l.SubStatus), N''))))    AS SS,
               UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), l.PanelName), N''))))    AS PN
    ) p
    CROSS APPLY (
        SELECT CAST(CASE
                   WHEN p.NS = N'BILLABLE' THEN 'INS'
                   WHEN p.NS IN (N'DELETED/REJECTED', N'REJECTED/DELETED') THEN 'DELREJ'
                   WHEN p.NS IN (N'CLIENTBILL', N'CLIENTBILLS') THEN 'CLIENT'
                   WHEN p.NS = N'SYSTEMTEST' THEN 'SYS'
                   WHEN p.NS = N'SELFPAY' THEN 'SELF'
                   WHEN p.NS = N'MISSINGACCESSION' THEN 'MISSACC'
                   WHEN p.NS IN (N'YETTOBEVALIDATED', N'YESTTOBEVALIDATED', N'YETTOBEVALIDATE', N'YETBEVALIDATED') THEN 'YET'
                   WHEN p.NS IN (N'DUPLICATE', N'DUBLICATE') THEN 'DUP'
                   ELSE 'OTH' END AS VARCHAR(10)) AS St,
               CAST(CASE
                   WHEN p.BC = N'BILLED' THEN 'B'
                   WHEN p.BC IN (N'UNBILLED', N'NOT BILLED') THEN 'U'
                   ELSE '' END AS CHAR(1)) AS Bill,
               CAST(CASE
                   WHEN p.SS = N'CLAIM SUBMITTED IN HISTORICAL LAB' THEN 'HIST'
                   WHEN p.SS = N'CLAIM SUBMITTED IN PNC LAB' THEN 'PNCLAB'
                   WHEN p.SS = N'READY TO BILL' THEN 'READY'
                   WHEN p.SS IN (N'NO INSURANCE INFO', N'MISSING INSURANCE INFO') THEN 'MISSINS'
                   ELSE '' END AS VARCHAR(10)) AS Sub,
               CAST(p.PN AS NVARCHAR(300)) AS Panel,
               CAST(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(500), l.PanelName), N''))) AS NVARCHAR(300)) AS PanelLabel
    ) k
    WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(500), l.Accession))), N'') IS NOT NULL
      AND p.Dos IS NOT NULL
      AND YEAR(p.Dos) > 1900
      AND p.PeriodDate IS NOT NULL
      AND (@From IS NULL OR p.PeriodDate >= @From)
      AND (@To   IS NULL OR p.PeriodDate <= @To)
      AND (@YearFrom  IS NULL OR YEAR(p.PeriodDate)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(p.PeriodDate)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(p.PeriodDate) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(p.PeriodDate) <= @MonthTo)
      AND (@HasPanel    = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.PanelName), N'')))      IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic   = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.ClinicName), N'')))     IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.DoctorFullName), N''))) IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
      AND (@HasRep      = 0 OR LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), l.SalesRepName), N'')))   IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
    GROUP BY YEAR(p.PeriodDate), MONTH(p.PeriodDate), k.St, k.Bill, k.Sub, k.Panel, k.PanelLabel
    OPTION (RECOMPILE);

    DELETE FROM #EsClaims;
    ;WITH c AS
    (
        SELECT
            UPPER(LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(200), c.ClaimStatus), N''))))  AS ClaimStatus,
            COALESCE(TRY_CONVERT(DATE, c.DateofService, 101), TRY_CAST(c.DateofService AS DATE)) AS Dos,
            COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE)) AS FirstBill,
            CASE WHEN @UseBilledDate = 1
                 THEN COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE))
                 ELSE COALESCE(TRY_CONVERT(DATE, c.DateofService, 101), TRY_CAST(c.DateofService AS DATE)) END AS PeriodDate,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.ChargeAmount))), N'$', N''), N',', N'')), 0)         AS ChargeAmount,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsurancePayment))), N'$', N''), N',', N'')), 0)     AS InsurancePayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientPayment))), N'$', N''), N',', N'')), 0)       AS PatientPayment,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceAdjustments))), N'$', N''), N',', N'')), 0) AS InsuranceAdjustments,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.PatientBalance))), N'$', N''), N',', N'')), 0)       AS PatientBalance,
            ISNULL(TRY_CONVERT(DECIMAL(18,2), REPLACE(REPLACE(LTRIM(RTRIM(CONVERT(NVARCHAR(100), c.InsuranceBalance))), N'$', N''), N',', N'')), 0)     AS InsuranceBalance,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.Panelname), N'')))         AS PanelFilter,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ClinicName), N'')))        AS ClinicFilter,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.ReferringProvider), N''))) AS ProviderFilter,
            LTRIM(RTRIM(ISNULL(CONVERT(NVARCHAR(300), c.SalesRepname), N'')))      AS RepFilter
        FROM dbo.ClaimLevelData c
        WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(255), c.ClaimID))), N'') IS NOT NULL
    )
    INSERT INTO #EsClaims
        (ESYear, ESMonth, IsBilled, ClaimStatus, ClaimCnt, ChargeAmount, InsurancePayment, PatientPaymentBilled,
         InsuranceAdjustments, PatientBalance, InsuranceBalance)
    SELECT YEAR(n.PeriodDate), MONTH(n.PeriodDate), b.IsBilled, n.ClaimStatus,
           COUNT(*),
           SUM(n.ChargeAmount), SUM(n.InsurancePayment),
           SUM(CASE WHEN n.FirstBill IS NOT NULL THEN n.PatientPayment ELSE 0 END),
           SUM(n.InsuranceAdjustments), SUM(n.PatientBalance), SUM(n.InsuranceBalance)
    FROM c n
    CROSS APPLY (SELECT CAST(CASE WHEN n.ClaimStatus IN (N'UNBILLED', N'UNBILLED - PATIENT BALANCE') THEN 0 ELSE 1 END AS BIT) AS IsBilled) b
    WHERE n.Dos IS NOT NULL
      AND YEAR(n.Dos) > 1900
      AND n.PeriodDate IS NOT NULL
      AND (@From IS NULL OR n.PeriodDate >= @From)
      AND (@To   IS NULL OR n.PeriodDate <= @To)
      AND (@YearFrom  IS NULL OR YEAR(n.PeriodDate)  >= @YearFrom)
      AND (@YearTo    IS NULL OR YEAR(n.PeriodDate)  <= @YearTo)
      AND (@MonthFrom IS NULL OR MONTH(n.PeriodDate) >= @MonthFrom)
      AND (@MonthTo   IS NULL OR MONTH(n.PeriodDate) <= @MonthTo)
      AND (@HasPanel    = 0 OR n.PanelFilter    IN (SELECT Val FROM #Filters WHERE Dim = 'Panel'))
      AND (@HasClinic   = 0 OR n.ClinicFilter   IN (SELECT Val FROM #Filters WHERE Dim = 'Clinic'))
      AND (@HasProvider = 0 OR n.ProviderFilter IN (SELECT Val FROM #Filters WHERE Dim = 'Provider'))
      AND (@HasRep      = 0 OR n.RepFilter      IN (SELECT Val FROM #Filters WHERE Dim = 'Rep'))
    GROUP BY YEAR(n.PeriodDate), MONTH(n.PeriodDate), b.IsBilled, n.ClaimStatus
    OPTION (RECOMPILE);
END;
GO

/* -----------------------------------------------------------------------------
   Row logic. Caller supplies #EsLis, #EsClaims and empty #EsOut.
   ----------------------------------------------------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_PNC_ES_Compute
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
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'B' AND Sub = 'HIST'    THEN Cnt END), 0) AS L_C1,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'B' AND Sub = 'PNCLAB'  THEN Cnt END), 0) AS L_C2,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'U' THEN Cnt END), 0) AS L_D,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'U' AND Sub = 'READY'   THEN Cnt END), 0) AS L_D1,
        ISNULL(SUM(CASE WHEN St = 'INS' AND Bill = 'U' AND Sub = 'MISSINS' THEN Cnt END), 0) AS L_D2,
        ISNULL(SUM(CASE WHEN St <> 'INS' THEN Cnt END), 0) AS L_E,
        ISNULL(SUM(CASE WHEN St = 'DELREJ'  THEN Cnt END), 0) AS L_E1,
        ISNULL(SUM(CASE WHEN St = 'CLIENT'  THEN Cnt END), 0) AS L_E2,
        ISNULL(SUM(CASE WHEN St = 'SYS'     THEN Cnt END), 0) AS L_E3,
        ISNULL(SUM(CASE WHEN St = 'SELF'    THEN Cnt END), 0) AS L_E4,
        ISNULL(SUM(CASE WHEN St = 'MISSACC' THEN Cnt END), 0) AS L_E5,
        ISNULL(SUM(CASE WHEN St = 'YET'     THEN Cnt END), 0) AS L_E6,
        ISNULL(SUM(CASE WHEN St = 'DUP'     THEN Cnt END), 0) AS L_E7
    INTO #LisM
    FROM #EsLis
    GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

    DROP TABLE IF EXISTS #ClmM;
    SELECT
        ISNULL(ESYear, 0) AS Y,
        CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
        ISNULL(SUM(CASE WHEN IsBilled = 1 THEN ClaimCnt END), 0) AS P_F,
        ISNULL(SUM(CASE WHEN IsBilled = 0 THEN ClaimCnt END), 0) AS P_I,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'FULLY PAID' THEN ClaimCnt END), 0) AS P_J,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'PARTIALLY PAID' THEN ClaimCnt END), 0) AS P_K,
        ISNULL(SUM(CASE WHEN ClaimStatus IN (N'PAT RESPONSIBILITY', N'PATIENT RESPONSIBILITY') THEN ClaimCnt END), 0) AS P_L,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'FULLY ADJUSTED' THEN ClaimCnt END), 0) AS P_M,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'PARTIALLY ADJUSTED' THEN ClaimCnt END), 0) AS P_MP,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'PATIENT PAYMENT' THEN ClaimCnt END), 0) AS P_N,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'FULLY DENIED' THEN ClaimCnt END), 0) AS P_O1,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'PARTIALLY DENIED' THEN ClaimCnt END), 0) AS P_O2,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'NO RESPONSE' THEN ClaimCnt END), 0) AS P_O3,
        ISNULL(SUM(CASE WHEN IsBilled = 1 THEN ChargeAmount END), 0) AS C_P,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'FULLY PAID' THEN InsurancePayment END), 0) AS C_Q,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'PARTIALLY PAID' THEN InsurancePayment END), 0) AS C_R,
        ISNULL(SUM(PatientPaymentBilled), 0) AS C_RP,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'FULLY ADJUSTED' THEN InsuranceAdjustments END), 0) AS C_T,
        ISNULL(SUM(CASE WHEN IsBilled = 1 AND ClaimStatus <> N'FULLY ADJUSTED' THEN InsuranceAdjustments END), 0) AS C_U,
        ISNULL(SUM(CASE WHEN IsBilled = 1 THEN PatientBalance END), 0) AS C_V,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'FULLY DENIED' THEN InsuranceBalance END), 0) AS C_W1,
        ISNULL(SUM(CASE WHEN ClaimStatus IN (N'PARTIALLY ADJUSTED', N'PARTIALLY PAID', N'PARTIALLY DENIED') THEN InsuranceBalance END), 0) AS C_W2,
        ISNULL(SUM(CASE WHEN ClaimStatus = N'NO RESPONSE' THEN InsuranceBalance END), 0) AS C_W3
    INTO #ClmM
    FROM #EsClaims
    GROUP BY GROUPING SETS ((ESYear, ESMonth), (ESYear), ());

    DROP TABLE IF EXISTS #Per;
    SELECT COALESCE(l.Y, c.Y) AS Y, COALESCE(l.M, c.M) AS M,
           ISNULL(l.L_A, 0) L_A, ISNULL(l.L_B, 0) L_B,
           ISNULL(l.L_C, 0) L_C, ISNULL(l.L_C1, 0) L_C1, ISNULL(l.L_C2, 0) L_C2,
           ISNULL(l.L_D, 0) L_D, ISNULL(l.L_D1, 0) L_D1, ISNULL(l.L_D2, 0) L_D2,
           ISNULL(l.L_E, 0) L_E, ISNULL(l.L_E1, 0) L_E1, ISNULL(l.L_E2, 0) L_E2, ISNULL(l.L_E3, 0) L_E3,
           ISNULL(l.L_E4, 0) L_E4, ISNULL(l.L_E5, 0) L_E5, ISNULL(l.L_E6, 0) L_E6, ISNULL(l.L_E7, 0) L_E7,
           ISNULL(c.P_F, 0) P_F, ISNULL(c.P_I, 0) P_I, ISNULL(c.P_J, 0) P_J, ISNULL(c.P_K, 0) P_K,
           ISNULL(c.P_L, 0) P_L, ISNULL(c.P_M, 0) P_M, ISNULL(c.P_MP, 0) P_MP, ISNULL(c.P_N, 0) P_N,
           ISNULL(c.P_O1, 0) P_O1, ISNULL(c.P_O2, 0) P_O2, ISNULL(c.P_O3, 0) P_O3,
           ISNULL(c.C_P, 0) C_P, ISNULL(c.C_Q, 0) C_Q, ISNULL(c.C_R, 0) C_R, ISNULL(c.C_RP, 0) C_RP,
           ISNULL(c.C_Q, 0) + ISNULL(c.C_R, 0) + ISNULL(c.C_RP, 0) C_S,
           ISNULL(c.C_T, 0) C_T, ISNULL(c.C_U, 0) C_U, ISNULL(c.C_V, 0) C_V,
           ISNULL(c.C_W1, 0) + ISNULL(c.C_W2, 0) + ISNULL(c.C_W3, 0) C_W,
           ISNULL(c.C_W1, 0) C_W1, ISNULL(c.C_W2, 0) C_W2, ISNULL(c.C_W3, 0) C_W3
    INTO #Per
    FROM #LisM l
    FULL OUTER JOIN #ClmM c ON c.Y = l.Y AND c.M = l.M;

    INSERT INTO #EsOut (Category, RowCode, Description, SortOrder, ESYear, ESMonth, MetricValue, ClaimCount)
    SELECT r.Category, r.RowCode, r.Description, r.SortOrder * 100, p.Y, p.M,
           CAST(r.MetricValue AS DECIMAL(18,2)), r.ClaimCount
    FROM #Per p
    CROSS APPLY (
        SELECT CAST(p.P_F - p.P_O3 AS DECIMAL(38,6)) AS AdjudicatedClaims
    ) d
    CROSS APPLY (VALUES
        ('LIS', 'A',   N'Total Samples',                          10, CAST(p.L_A AS DECIMAL(38,6)), p.L_A),
        ('LIS', 'B',   N'Billable Samples',                       20, CAST(p.L_B AS DECIMAL(38,6)), p.L_B),
        ('LIS', 'C',   N'Billed',                                 40, CAST(p.L_C AS DECIMAL(38,6)), p.L_C),
        ('LIS', 'C1',  N'  Claim Submitted in Historical Lab',    41, CAST(p.L_C1 AS DECIMAL(38,6)), p.L_C1),
        ('LIS', 'C2',  N'  Claim Submitted in PNC Lab',           42, CAST(p.L_C2 AS DECIMAL(38,6)), p.L_C2),
        ('LIS', 'D',   N'Unbilled',                               50, CAST(p.L_D AS DECIMAL(38,6)), p.L_D),
        ('LIS', 'D1',  N'  Ready to Bill',                        60, CAST(p.L_D1 AS DECIMAL(38,6)), p.L_D1),
        ('LIS', 'D2',  N'  Missing Insurance Info',               70, CAST(p.L_D2 AS DECIMAL(38,6)), p.L_D2),
        ('LIS', 'E',   N'Other Samples',                          80, CAST(p.L_E AS DECIMAL(38,6)), p.L_E),
        ('LIS', 'E1',  N'  Deleted / Rejected',                   90, CAST(p.L_E1 AS DECIMAL(38,6)), p.L_E1),
        ('LIS', 'E2',  N'  Client Bill',                         100, CAST(p.L_E2 AS DECIMAL(38,6)), p.L_E2),
        ('LIS', 'E3',  N'  System Test',                         110, CAST(p.L_E3 AS DECIMAL(38,6)), p.L_E3),
        ('LIS', 'E4',  N'  Self Pay',                            120, CAST(p.L_E4 AS DECIMAL(38,6)), p.L_E4),
        ('LIS', 'E5',  N'  Missing Accession',                   130, CAST(p.L_E5 AS DECIMAL(38,6)), p.L_E5),
        ('LIS', 'E6',  N'  Yet to be Validated',                 140, CAST(p.L_E6 AS DECIMAL(38,6)), p.L_E6),
        ('LIS', 'E7',  N'  Duplicate',                           150, CAST(p.L_E7 AS DECIMAL(38,6)), p.L_E7),

        ('PMS', 'F',   N'No. of Billed Claims',                   210, CAST(p.P_F AS DECIMAL(38,6)), p.P_F),
        ('PMS', 'G',   N'Billed Mismatches - Duplicates',         220, CAST(p.P_F - p.L_C AS DECIMAL(38,6)), p.P_F - p.L_C),
        ('PMS', 'I',   N'No. of UnBilled Claims',                 240, CAST(p.P_I AS DECIMAL(38,6)), p.P_I),
        ('PMS', 'J',   N'No. of Fully Paid Claims',               250, CAST(p.P_J AS DECIMAL(38,6)), p.P_J),
        ('PMS', 'K',   N'No. of Partially Paid Claims',           260, CAST(p.P_K AS DECIMAL(38,6)), p.P_K),
        ('PMS', 'L',   N'No. of Patient Responsibility',          270, CAST(p.P_L AS DECIMAL(38,6)), p.P_L),
        ('PMS', 'M',   N'No. of Fully Adjusted Claims',           280, CAST(p.P_M AS DECIMAL(38,6)), p.P_M),
        ('PMS', 'MP',  N'No. of Partially Adjusted Claims',       285, CAST(p.P_MP AS DECIMAL(38,6)), p.P_MP),
        ('PMS', 'N',   N'No. of Patient Paid Claims',             290, CAST(p.P_N AS DECIMAL(38,6)), p.P_N),
        ('PMS', 'O',   N'No. of Insurance Balance Claims',        300, CAST(p.P_O1 + p.P_O2 + p.P_O3 AS DECIMAL(38,6)), p.P_O1 + p.P_O2 + p.P_O3),
        ('PMS', 'O1',  N'  No. of Fully Denied Claims',           310, CAST(p.P_O1 AS DECIMAL(38,6)), p.P_O1),
        ('PMS', 'O2',  N'  No. of Partially Denied Claims',       320, CAST(p.P_O2 AS DECIMAL(38,6)), p.P_O2),
        ('PMS', 'O3',  N'  No. of No Response from Payor Claims', 330, CAST(p.P_O3 AS DECIMAL(38,6)), p.P_O3),

        ('Cash', 'P',   N'Total Billed ($)',                      410, p.C_P, 0),
        ('Cash', 'Q',   N'Insurance Payment ($)',                 420, p.C_Q, 0),
        ('Cash', 'R',   N'Partially Paid ($)',                    430, p.C_R, 0),
        ('Cash', 'RP',  N'Patient Paid ($)',                      440, p.C_RP, 0),
        ('Cash', 'S',   N'Total Payments ($)',                    450, p.C_S, 0),
        ('Cash', 'T',   N'Total Adjustments ($)',                 460, p.C_T, 0),
        ('Cash', 'U',   N'Contractual Obligation W/O',            470, p.C_U, 0),
        ('Cash', 'V',   N'Total Patient Responsibility',          480, p.C_V, 0),
        ('Cash', 'W',   N'Total Insurance Balance ($)',           490, p.C_W, 0),
        ('Cash', 'W1',  N'  Denials',                             500, p.C_W1, 0),
        ('Cash', 'W2',  N'  Partially Denied',                    510, p.C_W2, 0),
        ('Cash', 'W3',  N'  No Response from Payor',              520, p.C_W3, 0),

        ('Avg', 'AK',  N'Average Payment ($) - Total Pay/Billed Claims',      710,
            ISNULL(ROUND(CAST(p.C_S AS DECIMAL(38,6)) / NULLIF(CAST(p.P_F AS DECIMAL(38,6)), 0), 2), 0), p.P_F),
        ('Avg', 'AL',  N'Average Payment ($) - Total Pay/Paid Claims',        720,
            ISNULL(ROUND(CAST(p.C_Q AS DECIMAL(38,6)) / NULLIF(CAST(p.P_J AS DECIMAL(38,6)), 0), 2), 0), p.P_J),
        ('Avg', 'AM',  N'Average Payment ($) - Total Pay/Adjudicated Claims', 730,
            ISNULL(ROUND(CAST(p.C_S AS DECIMAL(38,6)) / NULLIF(d.AdjudicatedClaims, 0), 2), 0), CAST(d.AdjudicatedClaims AS INT))
    ) r(Category, RowCode, Description, SortOrder, MetricValue, ClaimCount);

    /* ---- Billable panel rows (dynamic, B.{PANEL}) - largest Grand Total first ---------- */
    DROP TABLE IF EXISTS #PanelLabel;
    SELECT Panel, MIN(PanelLabel) AS Label
    INTO #PanelLabel
    FROM #EsLis
    WHERE Panel <> N''
    GROUP BY Panel;

    DROP TABLE IF EXISTS #LisP;
    SELECT ISNULL(ESYear, 0) AS Y, CASE WHEN GROUPING(ESMonth) = 1 THEN 0 ELSE ESMonth END AS M,
           Panel, SUM(Cnt) AS Cnt
    INTO #LisP
    FROM #EsLis
    WHERE St = 'INS' AND Panel <> N''
    GROUP BY GROUPING SETS ((Panel, ESYear, ESMonth), (Panel, ESYear), (Panel));

    DROP TABLE IF EXISTS #Pnl;
    SELECT l.Panel, ROW_NUMBER() OVER (ORDER BY l.Cnt DESC, pl.Label) AS Rnk
    INTO #Pnl
    FROM #LisP l
    JOIN #PanelLabel pl ON pl.Panel = l.Panel
    WHERE l.Y = 0 AND l.M = 0;

    -- Every panel row gets every period of #Per, so its month / year / total cells are all present.
    INSERT INTO #EsOut (Category, RowCode, Description, SortOrder, ESYear, ESMonth, MetricValue, ClaimCount)
    SELECT 'LIS', N'B.' + n.Panel, N'  ' + LEFT(pl.Label, 298), 2000 + n.Rnk,
           p.Y, p.M, CAST(ISNULL(l.Cnt, 0) AS DECIMAL(18,2)), ISNULL(l.Cnt, 0)
    FROM #Pnl n
    JOIN #PanelLabel pl ON pl.Panel = n.Panel
    CROSS JOIN (SELECT Y, M FROM #Per) p
    LEFT JOIN #LisP l ON l.Panel = n.Panel AND l.Y = p.Y AND l.M = p.M;
END;
GO

/* Temp tables shared by the refresh, read and cell-rows SPs. */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #EsLis
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        St VARCHAR(10) NOT NULL, Bill CHAR(1) NOT NULL, Sub VARCHAR(10) NOT NULL,
        Panel NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelLabel NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        Cnt INT NOT NULL
    );
    CREATE TABLE #EsClaims
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        IsBilled BIT NOT NULL,
        ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimCnt INT NOT NULL,
        ChargeAmount DECIMAL(18,2) NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
        PatientPaymentBilled DECIMAL(18,2) NOT NULL, InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientBalance DECIMAL(18,2) NOT NULL, InsuranceBalance DECIMAL(18,2) NOT NULL
    );
    CREATE TABLE #EsOut
    (
        Category VARCHAR(10) NOT NULL,
        RowCode NVARCHAR(320) COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        SortOrder INT NOT NULL,
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL,
        ClaimCount INT NOT NULL
    );

    EXEC dbo.usp_PNC_ES_Load;
    EXEC dbo.usp_PNC_ES_Compute;

    BEGIN TRANSACTION;
        TRUNCATE TABLE dbo.PNC_ES_LIS;
        TRUNCATE TABLE dbo.PNC_ES_PMS;
        TRUNCATE TABLE dbo.PNC_ES_Cash;
        TRUNCATE TABLE dbo.PNC_ES_Avg;

        INSERT INTO dbo.PNC_ES_LIS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'LIS';

        INSERT INTO dbo.PNC_ES_PMS (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, 0, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'PMS';

        INSERT INTO dbo.PNC_ES_Cash (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, 0, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Cash';

        INSERT INTO dbo.PNC_ES_Avg (RoleID, Description, ESYear, ESMonth, ESMonthClaimCount, ESMonthChargeAmount, SortOrder, RefreshedAt)
        SELECT RowCode, Description, ESYear, ESMonth, ClaimCount, MetricValue, SortOrder, GETDATE() FROM #EsOut WHERE Category = 'Avg';
    COMMIT TRANSACTION;

    PRINT 'usp_RefreshPNC_ExecutiveSummary completed.';
END;
GO

/* LIS rows are built with the PMS rows (G is PMS billed minus LIS billed).
   Kept so the capture app's prefix refresh finds this procedure. */
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_ExecutiveSummary_LIS_Alt
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM dbo.PNC_ES_LIS)
        EXEC dbo.usp_RefreshPNC_ExecutiveSummary;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_ExecutiveSummary
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
       AND EXISTS (SELECT 1 FROM dbo.PNC_ES_PMS)
    BEGIN
        SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue, SortOrder
        FROM
        (
            SELECT RoleID AS RowCode, 'LIS' AS Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
                   CAST(ESMonthClaimCount AS DECIMAL(18,2)) AS MetricValue, ISNULL(SortOrder, 9999) AS SortOrder
            FROM dbo.PNC_ES_LIS
            UNION ALL
            SELECT RoleID, 'PMS', Description, ESYear, ESMonth, CAST(ESMonthClaimCount AS DECIMAL(18,2)), ISNULL(SortOrder, 9999)
            FROM dbo.PNC_ES_PMS
            UNION ALL
            SELECT RoleID, 'Cash', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
            FROM dbo.PNC_ES_Cash
            UNION ALL
            SELECT RoleID, 'Avg', Description, ESYear, ESMonth, ESMonthChargeAmount, ISNULL(SortOrder, 9999)
            FROM dbo.PNC_ES_Avg
        ) t
        ORDER BY SortOrder, BillYear, BillMonth;
        RETURN;
    END;

    CREATE TABLE #EsLis
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        St VARCHAR(10) NOT NULL, Bill CHAR(1) NOT NULL, Sub VARCHAR(10) NOT NULL,
        Panel NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        PanelLabel NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        Cnt INT NOT NULL
    );
    CREATE TABLE #EsClaims
    (
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        IsBilled BIT NOT NULL,
        ClaimStatus NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL,
        ClaimCnt INT NOT NULL,
        ChargeAmount DECIMAL(18,2) NOT NULL, InsurancePayment DECIMAL(18,2) NOT NULL,
        PatientPaymentBilled DECIMAL(18,2) NOT NULL, InsuranceAdjustments DECIMAL(18,2) NOT NULL,
        PatientBalance DECIMAL(18,2) NOT NULL, InsuranceBalance DECIMAL(18,2) NOT NULL
    );
    CREATE TABLE #EsOut
    (
        Category VARCHAR(10) NOT NULL,
        RowCode NVARCHAR(320) COLLATE DATABASE_DEFAULT NOT NULL,
        Description NVARCHAR(300) COLLATE DATABASE_DEFAULT NOT NULL,
        SortOrder INT NOT NULL,
        ESYear INT NOT NULL, ESMonth INT NOT NULL,
        MetricValue DECIMAL(18,2) NOT NULL,
        ClaimCount INT NOT NULL
    );

    EXEC dbo.usp_PNC_ES_Load
        @YearFrom = @YearFrom, @YearTo = @YearTo, @MonthFrom = @MonthFrom, @MonthTo = @MonthTo,
        @DosFrom = @DosFrom, @DosTo = @DosTo, @BilledFrom = @BilledFrom, @BilledTo = @BilledTo,
        @Panels = @Panels, @Clinics = @Clinics, @Providers = @Providers, @Reps = @Reps;
    EXEC dbo.usp_PNC_ES_Compute;

    SELECT RowCode, Category, Description, ESYear AS BillYear, ESMonth AS BillMonth,
           CASE WHEN Category IN ('Cash', 'Avg') THEN MetricValue ELSE CAST(ClaimCount AS DECIMAL(18,2)) END AS MetricValue,
           SortOrder
    FROM #EsOut
    ORDER BY SortOrder, ESYear, ESMonth;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_ExecutiveSummary_FilterOptions
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
            SELECT YEAR(COALESCE(TRY_CONVERT(DATE, DateofService, 101), TRY_CAST(DateofService AS DATE))) AS Yr
            FROM dbo.ClaimLevelData
            WHERE COALESCE(TRY_CONVERT(DATE, DateofService, 101), TRY_CAST(DateofService AS DATE)) IS NOT NULL
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

        UNION
        SELECT N'Panel', LTRIM(RTRIM(PanelName)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(PanelName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(PanelName))

        UNION
        SELECT N'Clinic', LTRIM(RTRIM(ClinicName)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(ClinicName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ClinicName))

        UNION
        SELECT N'Clinic', LTRIM(RTRIM(ClinicName)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(ClinicName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ClinicName))

        UNION
        SELECT N'Provider', LTRIM(RTRIM(ReferringProvider)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(ReferringProvider)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(ReferringProvider))

        UNION
        SELECT N'Provider', LTRIM(RTRIM(DoctorFullName)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(DoctorFullName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(DoctorFullName))

        UNION
        SELECT N'Rep', LTRIM(RTRIM(SalesRepname)), 0
        FROM dbo.ClaimLevelData
        WHERE NULLIF(LTRIM(RTRIM(SalesRepname)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(SalesRepname))

        UNION
        SELECT N'Rep', LTRIM(RTRIM(SalesRepName)), 0
        FROM dbo.LIMSMaster
        WHERE NULLIF(LTRIM(RTRIM(SalesRepName)), N'') IS NOT NULL
        GROUP BY LTRIM(RTRIM(SalesRepName))
    ) f
    ORDER BY FilterType, SortOrder DESC, FilterValue;
END;
GO

EXEC dbo.usp_RefreshPNC_ExecutiveSummary;
GO

PRINT '36_PNC_ExecutiveSummary.sql completed.';
GO

SET NOEXEC OFF;
GO
