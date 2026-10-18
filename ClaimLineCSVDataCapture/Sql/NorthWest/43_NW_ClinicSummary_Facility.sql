/* =============================================================================
   NorthWest - Clinic Summary: By Facility and Facility vs Payment (%)
   File     : 43_NW_ClinicSummary_Facility.sql
   Database : NWL_LRN

   Source Claim Level. Claim Count = Count of unique Claim ID; rows sorted by Claim Count.

   By Facility               Filter : none
                             Rows   : ClinicName > PayerName_Raw > ReferringProvider
                             Values : Claims, Sum ChargeAmount, Sum InsuranceBalance, Sum PatientBalance
   Facility vs Payment (%)   Filter : InsurancePayment > 0
                             Rows   : ClinicName
                             Values : Claims, Average(Payment %)  (Payment % = PaymentPercent x 100)

   RowLevel: 0 = grand total, 1 = clinic, 2 = clinic + payer, 3 = clinic + payer + provider.
   Each counts unique ClaimIDs at its own level.

   usp_GetNW_CLS_* returns its snapshot table when no filter is passed; with filters
   (or @Live = 1) it computes from ClaimLevelData. usp_RefreshNW_CLS_* stores the @Live = 1 result.
   Filter lists are pipe-delimited.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'43_NW_ClinicSummary_Facility.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

/* -----------------------------------------------------------------------------
   Shared claim rows + Clinic Summary filters
   ----------------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_NW_CLS_Claims
(
    @ClinicNames   NVARCHAR(MAX),
    @SalesRepNames NVARCHAR(MAX),
    @PayerNames    NVARCHAR(MAX),
    @PanelNames    NVARCHAR(MAX),
    @DosFrom       DATE,
    @DosTo         DATE,
    @FirstBillFrom DATE,
    @FirstBillTo   DATE
)
RETURNS TABLE
AS
RETURN
    SELECT
        ClaimKey          = NULLIF(LTRIM(RTRIM(c.ClaimID)), N''),
        n.ClinicName,
        n.PayerName,
        n.ReferringProvider,
        ChargeAmt         = ISNULL(TRY_CAST(c.ChargeAmount     AS DECIMAL(18,2)), 0),
        InsPay            = ISNULL(TRY_CAST(c.InsurancePayment AS DECIMAL(18,2)), 0),
        InsBalance        = ISNULL(TRY_CAST(c.InsuranceBalance AS DECIMAL(18,2)), 0),
        PatientBalance    = ISNULL(TRY_CAST(c.PatientBalance   AS DECIMAL(18,2)), 0),
        PaymentPct        = TRY_CAST(c.PaymentPercent AS DECIMAL(18,6)) * 100
    FROM dbo.ClaimLevelData c
    CROSS APPLY (SELECT
        ClinicName        = ISNULL(NULLIF(LTRIM(RTRIM(c.ClinicName)),        N''), N'(Blank)'),
        PayerName         = ISNULL(NULLIF(LTRIM(RTRIM(c.PayerName_Raw)),     N''), N'(Blank)'),
        ReferringProvider = ISNULL(NULLIF(LTRIM(RTRIM(c.ReferringProvider)), N''), N'(Blank)')) n
    CROSS APPLY (SELECT
        Dos       = COALESCE(TRY_CONVERT(DATE, c.DateOfService,   101), TRY_CAST(c.DateOfService   AS DATE)),
        FirstBill = COALESCE(TRY_CONVERT(DATE, c.FirstBilledDate, 101), TRY_CAST(c.FirstBilledDate AS DATE))) p
    -- 12/31/1899 is the file's blank-date placeholder.
    CROSS APPLY (SELECT
        Dos       = CASE WHEN p.Dos       >= '19010101' THEN p.Dos       END,
        FirstBill = CASE WHEN p.FirstBill >= '19010101' THEN p.FirstBill END) d
    WHERE (NULLIF(LTRIM(RTRIM(@ClinicNames)), N'') IS NULL
           OR n.ClinicName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@ClinicNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@SalesRepNames)), N'') IS NULL
           OR LTRIM(RTRIM(c.SalesRepName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@SalesRepNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PayerNames)), N'') IS NULL
           OR n.PayerName IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|'))
           OR LTRIM(RTRIM(c.PayerName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, N'|')))
      AND (NULLIF(LTRIM(RTRIM(@PanelNames)), N'') IS NULL
           OR LTRIM(RTRIM(c.PanelType)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|'))
           OR LTRIM(RTRIM(c.PanelName)) IN (SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, N'|')))
      AND (@DosFrom       IS NULL OR d.Dos       >= @DosFrom)
      AND (@DosTo         IS NULL OR d.Dos       <= @DosTo)
      AND (@FirstBillFrom IS NULL OR d.FirstBill >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR d.FirstBill <= @FirstBillTo);
GO

/* -----------------------------------------------------------------------------
   1. By Facility
   ----------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.NW_CLS_ByFacility', N'U') IS NULL
CREATE TABLE dbo.NW_CLS_ByFacility
(
    SummaryId         INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowLevel          TINYINT        NOT NULL,
    ClinicName        NVARCHAR(500)  NOT NULL,
    PayerName         NVARCHAR(500)  NOT NULL,
    ReferringProvider NVARCHAR(500)  NOT NULL,
    NoOfClaims        INT            NOT NULL DEFAULT 0,
    ChargeAmount      DECIMAL(18,2)  NOT NULL DEFAULT 0,
    InsuranceBalance  DECIMAL(18,2)  NOT NULL DEFAULT 0,
    PatientBalance    DECIMAL(18,2)  NOT NULL DEFAULT 0,
    RefreshedAt       DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CLS_ByFacility
    @ClinicNames   NVARCHAR(MAX) = NULL,
    @SalesRepNames NVARCHAR(MAX) = NULL,
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@ClinicNames)), N'')   IS NULL
       AND NULLIF(LTRIM(RTRIM(@SalesRepNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')    IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'')    IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo) IS NULL
    BEGIN
        SELECT RowLevel, ClinicName, PayerName, ReferringProvider,
               NoOfClaims, ChargeAmount, InsuranceBalance, PatientBalance
        FROM dbo.NW_CLS_ByFacility
        ORDER BY RowLevel, NoOfClaims DESC;
        RETURN;
    END;

    SELECT ClaimKey, ClinicName, PayerName, ReferringProvider, ChargeAmt, InsBalance, PatientBalance
    INTO #b
    FROM dbo.fn_NW_CLS_Claims(@ClinicNames, @SalesRepNames, @PayerNames, @PanelNames,
                              @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo)
    OPTION (RECOMPILE);

    SELECT RowLevel          = CAST(CASE WHEN GROUPING(ClinicName) = 1        THEN 0
                                         WHEN GROUPING(PayerName) = 1         THEN 1
                                         WHEN GROUPING(ReferringProvider) = 1 THEN 2
                                         ELSE 3 END AS TINYINT),
           ClinicName        = CASE WHEN GROUPING(ClinicName) = 1        THEN N'' ELSE ClinicName        END,
           PayerName         = CASE WHEN GROUPING(PayerName) = 1         THEN N'' ELSE PayerName         END,
           ReferringProvider = CASE WHEN GROUPING(ReferringProvider) = 1 THEN N'' ELSE ReferringProvider END,
           NoOfClaims        = CAST(COUNT(DISTINCT ClaimKey) AS INT),
           ChargeAmount      = CAST(SUM(ChargeAmt)      AS DECIMAL(18,2)),
           InsuranceBalance  = CAST(SUM(InsBalance)     AS DECIMAL(18,2)),
           PatientBalance    = CAST(SUM(PatientBalance) AS DECIMAL(18,2))
    FROM #b
    GROUP BY GROUPING SETS ((), (ClinicName), (ClinicName, PayerName), (ClinicName, PayerName, ReferringProvider))
    ORDER BY RowLevel, NoOfClaims DESC;
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CLS_ByFacility
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        RowLevel          TINYINT,
        ClinicName        NVARCHAR(500),
        PayerName         NVARCHAR(500),
        ReferringProvider NVARCHAR(500),
        NoOfClaims        INT,
        ChargeAmount      DECIMAL(18,2),
        InsuranceBalance  DECIMAL(18,2),
        PatientBalance    DECIMAL(18,2)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CLS_ByFacility @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CLS_ByFacility;
        INSERT INTO dbo.NW_CLS_ByFacility
            (RowLevel, ClinicName, PayerName, ReferringProvider, NoOfClaims, ChargeAmount, InsuranceBalance, PatientBalance, RefreshedAt)
        SELECT RowLevel, ClinicName, PayerName, ReferringProvider, NoOfClaims, ChargeAmount, InsuranceBalance, PatientBalance, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

/* -----------------------------------------------------------------------------
   2. Facility vs Payment (%)
   ----------------------------------------------------------------------------- */
IF OBJECT_ID(N'dbo.NW_CLS_FacilityPaymentPct', N'U') IS NULL
CREATE TABLE dbo.NW_CLS_FacilityPaymentPct
(
    SummaryId     INT            NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowLevel      TINYINT        NOT NULL,
    ClinicName    NVARCHAR(500)  NOT NULL,
    NoOfClaims    INT            NOT NULL DEFAULT 0,
    AvgPaymentPct DECIMAL(9,4)   NULL,
    RefreshedAt   DATETIME       NOT NULL DEFAULT GETDATE()
);
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CLS_FacilityPaymentPct
    @ClinicNames   NVARCHAR(MAX) = NULL,
    @SalesRepNames NVARCHAR(MAX) = NULL,
    @PayerNames    NVARCHAR(MAX) = NULL,
    @PanelNames    NVARCHAR(MAX) = NULL,
    @DosFrom       DATE          = NULL,
    @DosTo         DATE          = NULL,
    @FirstBillFrom DATE          = NULL,
    @FirstBillTo   DATE          = NULL,
    @Live          BIT           = 0
AS
BEGIN
    SET NOCOUNT ON;

    IF @Live = 0
       AND NULLIF(LTRIM(RTRIM(@ClinicNames)), N'')   IS NULL
       AND NULLIF(LTRIM(RTRIM(@SalesRepNames)), N'') IS NULL
       AND NULLIF(LTRIM(RTRIM(@PayerNames)), N'')    IS NULL
       AND NULLIF(LTRIM(RTRIM(@PanelNames)), N'')    IS NULL
       AND COALESCE(@DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo) IS NULL
    BEGIN
        SELECT RowLevel, ClinicName, NoOfClaims, AvgPaymentPct
        FROM dbo.NW_CLS_FacilityPaymentPct
        ORDER BY RowLevel, NoOfClaims DESC;
        RETURN;
    END;

    SELECT RowLevel      = CAST(CASE WHEN GROUPING(ClinicName) = 1 THEN 0 ELSE 1 END AS TINYINT),
           ClinicName    = CASE WHEN GROUPING(ClinicName) = 1 THEN N'' ELSE ClinicName END,
           NoOfClaims    = CAST(COUNT(DISTINCT ClaimKey) AS INT),
           AvgPaymentPct = CAST(AVG(PaymentPct) AS DECIMAL(9,4))
    FROM dbo.fn_NW_CLS_Claims(@ClinicNames, @SalesRepNames, @PayerNames, @PanelNames,
                              @DosFrom, @DosTo, @FirstBillFrom, @FirstBillTo)
    WHERE InsPay > 0
    GROUP BY GROUPING SETS ((), (ClinicName))
    ORDER BY RowLevel, NoOfClaims DESC
    OPTION (RECOMPILE);
END;
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_CLS_FacilityPaymentPct
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    CREATE TABLE #R
    (
        RowLevel      TINYINT,
        ClinicName    NVARCHAR(500),
        NoOfClaims    INT,
        AvgPaymentPct DECIMAL(9,4)
    );

    INSERT INTO #R
    EXEC dbo.usp_GetNW_CLS_FacilityPaymentPct @Live = 1;

    BEGIN TRAN;
        TRUNCATE TABLE dbo.NW_CLS_FacilityPaymentPct;
        INSERT INTO dbo.NW_CLS_FacilityPaymentPct (RowLevel, ClinicName, NoOfClaims, AvgPaymentPct, RefreshedAt)
        SELECT RowLevel, ClinicName, NoOfClaims, AvgPaymentPct, GETDATE()
        FROM #R;
    COMMIT;
END;
GO

EXEC dbo.usp_RefreshNW_CLS_ByFacility;
EXEC dbo.usp_RefreshNW_CLS_FacilityPaymentPct;
GO

PRINT N'43_NW_ClinicSummary_Facility.sql completed.';
GO
