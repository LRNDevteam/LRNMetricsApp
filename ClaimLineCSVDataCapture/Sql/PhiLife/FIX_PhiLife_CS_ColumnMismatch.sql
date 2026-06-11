-- ============================================================
-- PhiLife Collection Summary — Column mismatch fixes
-- Run on PhiLife_LRN database.
-- Fixes 3 issues:
--   1. Phi_CS_AvgPayments   : ClaimCount→NoOfClaims, InsurancePayment→CarrierPayment,
--                              Over30/60→Days30/60
--   2. Phi_CS_ProviderSummary: InsurancePayment→InsurancePayments
--   3. StatusSummary SPs    : CPTCodeXUnitsXModifier (not in LineLevelData)
--                              → built from CPTCode + Units + Modifier
-- ============================================================

SET NOCOUNT ON;
GO

-- ── 1. Rename columns in Phi_CS_AvgPayments ──────────────────────────────────
PRINT 'Renaming Phi_CS_AvgPayments columns...';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'ClaimCount')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.ClaimCount',          'NoOfClaims',     'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'InsurancePayment')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.InsurancePayment',    'CarrierPayment',  'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'AvgInsurancePayment')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.AvgInsurancePayment', 'AvgCarrierPayment','COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'Over30Count')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.Over30Count',         'Days30Count',    'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'Over30Amount')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.Over30Amount',        'Days30Amount',   'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'AvgOver30')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.AvgOver30',           'AvgDays30',      'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'Over60Count')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.Over60Count',         'Days60Count',    'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'Over60Amount')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.Over60Amount',        'Days60Amount',   'COLUMN';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_AvgPayments') AND name = 'AvgOver60')
    EXEC sp_rename 'dbo.Phi_CS_AvgPayments.AvgOver60',           'AvgDays60',      'COLUMN';

PRINT 'Phi_CS_AvgPayments columns renamed.';
GO


-- ── 2. Rename InsurancePayment → InsurancePayments in Phi_CS_ProviderSummary ─
PRINT 'Renaming Phi_CS_ProviderSummary.InsurancePayment...';

IF EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('dbo.Phi_CS_ProviderSummary') AND name = 'InsurancePayment')
    EXEC sp_rename 'dbo.Phi_CS_ProviderSummary.InsurancePayment', 'InsurancePayments', 'COLUMN';

PRINT 'Phi_CS_ProviderSummary column renamed.';
GO


-- ── 3. Fix usp_RefreshPhi_CS_AvgPayments ─────────────────────────────────────
PRINT 'Recreating usp_RefreshPhi_CS_AvgPayments...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_AvgPayments
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -6, CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown')))  AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown')))  AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2))     AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))     AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                       AS Status,
            ISNULL(TRY_CAST(DaystoDOS AS INT), 9999)        AS Days
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) IS NOT NULL
          AND TRY_CAST(CheckDate AS DATE) >= @Cutoff
          AND Panelname   IS NOT NULL AND LTRIM(RTRIM(Panelname))   <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
               ISNULL(SUM(Chg),    0) AS TotalCharges,
               ISNULL(SUM(InsPay), 0) AS CarrierPayment,
               COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END) AS FullyPaidCount,
               ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
               COUNT(DISTINCT CASE WHEN Status IN
                   ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
                    'Fully Denied','Denied','Partially Denied','Partially Adjusted',
                    'Patient Responsibility')
                 THEN ClaimID END) AS AdjudicatedCount,
               ISNULL(SUM(CASE WHEN Status IN
                   ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted',
                    'Fully Denied','Denied','Partially Denied','Partially Adjusted',
                    'Patient Responsibility')
                 THEN InsPay ELSE 0 END), 0) AS AdjudicatedAmount,
               COUNT(DISTINCT CASE WHEN Days <= 30 THEN ClaimID END) AS Days30Count,
               ISNULL(SUM(CASE WHEN Days <= 30 THEN InsPay ELSE 0 END), 0) AS Days30Amount,
               COUNT(DISTINCT CASE WHEN Days <= 60 THEN ClaimID END) AS Days60Count,
               ISNULL(SUM(CASE WHEN Days <= 60 THEN InsPay ELSE 0 END), 0) AS Days60Amount
        FROM base GROUP BY PanelName, PayerName
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY NoOfClaims DESC) AS PayerRank
        FROM agg
    )
    SELECT a.*, CAST(r.PayerRank AS TINYINT) AS PayerRank
    INTO #out
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3;

    TRUNCATE TABLE dbo.Phi_CS_AvgPayments;
    INSERT INTO dbo.Phi_CS_AvgPayments
        (PanelName, PayerName, PayerRank,
         NoOfClaims, TotalCharges, AvgCharges,
         CarrierPayment, AvgCarrierPayment,
         FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
         AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
         Days30Count, Days30Amount, AvgDays30,
         Days60Count, Days60Amount, AvgDays60,
         RefreshedAt)
    SELECT
        PanelName, PayerName, PayerRank,
        NoOfClaims, TotalCharges,
        CASE WHEN NoOfClaims > 0 THEN TotalCharges   / NoOfClaims ELSE 0 END,
        CarrierPayment,
        CASE WHEN NoOfClaims > 0 THEN CarrierPayment / NoOfClaims ELSE 0 END,
        FullyPaidCount, FullyPaidAmount,
        CASE WHEN FullyPaidCount   > 0 THEN FullyPaidAmount   / FullyPaidCount   ELSE 0 END,
        AdjudicatedCount, AdjudicatedAmount,
        CASE WHEN AdjudicatedCount > 0 THEN AdjudicatedAmount / AdjudicatedCount ELSE 0 END,
        Days30Count, Days30Amount,
        CASE WHEN Days30Count > 0 THEN Days30Amount / Days30Count ELSE 0 END,
        Days60Count, Days60Amount,
        CASE WHEN Days60Count > 0 THEN Days60Amount / Days60Count ELSE 0 END,
        GETDATE()
    FROM #out ORDER BY PanelName, PayerRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_AvgPayments completed.';
END
GO


-- ── 4. Fix usp_GetPhi_CS_AvgPayments ─────────────────────────────────────────
PRINT 'Recreating usp_GetPhi_CS_AvgPayments...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_CS_AvgPayments
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    -- No-filter: serve from snapshot
    IF @HasFilter = 0
    BEGIN
        SELECT  PanelName, PayerName, PayerRank,
                NoOfClaims, TotalCharges, AvgCharges,
                CarrierPayment, AvgCarrierPayment,
                FullyPaidCount, FullyPaidAmount, AvgFullyPaid,
                AdjudicatedCount, AdjudicatedAmount, AvgAdjudicated,
                Days30Count, Days30Amount, AvgDays30,
                Days60Count, Days60Amount, AvgDays60
        FROM    dbo.Phi_CS_AvgPayments
        ORDER   BY PanelName, PayerRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;
    DECLARE @Cutoff   DATE = ISNULL(@CheckDateFrom, DATEADD(MONTH, -6, CAST(GETDATE() AS DATE)));
    DECLARE @CutoffTo DATE = ISNULL(@CheckDateTo,   CAST(GETDATE() AS DATE));

    ;WITH base AS (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount     AS DECIMAL(18,2)) AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2)) AS InsPay,
            LTRIM(RTRIM(ClaimStatus))                   AS Status,
            ISNULL(TRY_CAST(DaystoDOS AS INT), 9999)    AS Days
        FROM dbo.ClaimLevelData
        WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
          AND TRY_CAST(CheckDate AS DATE) BETWEEN @Cutoff AND @CutoffTo
          AND Panelname   IS NOT NULL AND LTRIM(RTRIM(Panelname))   <> ''
          AND PayerName_Raw IS NOT NULL AND LTRIM(RTRIM(PayerName_Raw)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
    ),
    agg AS (
        SELECT PanelName, PayerName,
               COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))                AS NoOfClaims,
               ISNULL(SUM(Chg),    0)                                          AS TotalCharges,
               ISNULL(SUM(InsPay), 0)                                          AS CarrierPayment,
               COUNT(DISTINCT CASE WHEN Status = 'Fully Paid' THEN ClaimID END) AS FullyPaidCount,
               ISNULL(SUM(CASE WHEN Status = 'Fully Paid' THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
               COUNT(DISTINCT CASE WHEN Status IN ('Fully Paid','Partially Paid','Complete W/O',
                   'Fully Adjusted','Fully Denied','Denied','Partially Denied',
                   'Partially Adjusted','Patient Responsibility') THEN ClaimID END) AS AdjudicatedCount,
               ISNULL(SUM(CASE WHEN Status IN ('Fully Paid','Partially Paid','Complete W/O',
                   'Fully Adjusted','Fully Denied','Denied','Partially Denied',
                   'Partially Adjusted','Patient Responsibility') THEN InsPay ELSE 0 END), 0) AS AdjudicatedAmount,
               COUNT(DISTINCT CASE WHEN Days <= 30 THEN ClaimID END)           AS Days30Count,
               ISNULL(SUM(CASE WHEN Days <= 30 THEN InsPay ELSE 0 END), 0)     AS Days30Amount,
               COUNT(DISTINCT CASE WHEN Days <= 60 THEN ClaimID END)           AS Days60Count,
               ISNULL(SUM(CASE WHEN Days <= 60 THEN InsPay ELSE 0 END), 0)     AS Days60Amount
        FROM base GROUP BY PanelName, PayerName
    ),
    ranks AS (
        SELECT PanelName, PayerName,
               CAST(DENSE_RANK() OVER (PARTITION BY PanelName ORDER BY NoOfClaims DESC) AS TINYINT) AS PayerRank
        FROM agg
    )
    SELECT
        a.PanelName, a.PayerName, r.PayerRank,
        a.NoOfClaims, a.TotalCharges,
        CAST(CASE WHEN a.NoOfClaims > 0 THEN a.TotalCharges    / a.NoOfClaims ELSE 0 END AS DECIMAL(18,2)) AS AvgCharges,
        a.CarrierPayment,
        CAST(CASE WHEN a.NoOfClaims > 0 THEN a.CarrierPayment  / a.NoOfClaims ELSE 0 END AS DECIMAL(18,2)) AS AvgCarrierPayment,
        a.FullyPaidCount, a.FullyPaidAmount,
        CAST(CASE WHEN a.FullyPaidCount   > 0 THEN a.FullyPaidAmount   / a.FullyPaidCount   ELSE 0 END AS DECIMAL(18,2)) AS AvgFullyPaid,
        a.AdjudicatedCount, a.AdjudicatedAmount,
        CAST(CASE WHEN a.AdjudicatedCount > 0 THEN a.AdjudicatedAmount / a.AdjudicatedCount ELSE 0 END AS DECIMAL(18,2)) AS AvgAdjudicated,
        a.Days30Count, a.Days30Amount,
        CAST(CASE WHEN a.Days30Count > 0 THEN a.Days30Amount / a.Days30Count ELSE 0 END AS DECIMAL(18,2)) AS AvgDays30,
        a.Days60Count, a.Days60Amount,
        CAST(CASE WHEN a.Days60Count > 0 THEN a.Days60Amount / a.Days60Count ELSE 0 END AS DECIMAL(18,2)) AS AvgDays60
    FROM agg a
    JOIN ranks r ON r.PanelName = a.PanelName AND r.PayerName = a.PayerName
    WHERE r.PayerRank <= 3
    ORDER BY a.PanelName, r.PayerRank;
END
GO


-- ── 5. Fix usp_RefreshPhi_CS_StatusSummary ───────────────────────────────────
PRINT 'Recreating usp_RefreshPhi_CS_StatusSummary...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Phi_CS_StatusSummary;

    INSERT INTO dbo.Phi_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),  '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),    '(blank)') AS PanelName,
        ISNULL(NULLIF(LTRIM(RTRIM(
            ISNULL(LTRIM(RTRIM(CPTCode)), '') +
            CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
            CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END
        )), ''), '(blank)')                            AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),'(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))             AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance,
        GETDATE()
    FROM dbo.LineLevelData
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(ISNULL(CPTCode, '') +
            CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
            CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END)),
        LTRIM(RTRIM(PayerName_Raw));

    PRINT 'usp_RefreshPhi_CS_StatusSummary completed.';
END
GO


-- ── 6. Fix usp_GetPhi_CS_StatusSummary (live path) ───────────────────────────
PRINT 'Recreating usp_GetPhi_CS_StatusSummary...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_CS_StatusSummary
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ClaimStatus, PanelName, CptCode, PayerName,
               NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
        FROM   dbo.Phi_CS_StatusSummary
        ORDER  BY ClaimStatus, PanelName, PayerName;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),  '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),    '(blank)') AS PanelName,
        ISNULL(NULLIF(LTRIM(RTRIM(
            ISNULL(LTRIM(RTRIM(CPTCode)), '') +
            CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
            CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END
        )), ''), '(blank)')                            AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),'(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)),''))             AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
    FROM dbo.LineLevelData
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(ISNULL(CPTCode, '') +
            CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
            CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END)),
        LTRIM(RTRIM(PayerName_Raw))
    ORDER BY ClaimStatus, PanelName, PayerName;
END
GO


-- ── 7. Fix usp_RefreshPhi_CS_ProviderSummary ─────────────────────────────────
PRINT 'Recreating usp_RefreshPhi_CS_ProviderSummary...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_ProviderSummary
AS
BEGIN
    SET NOCOUNT ON;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL
          AND LTRIM(RTRIM(ReferringProvider)) <> ''
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS ProviderRank,
        ReferringProvider, NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance
    INTO #out FROM agg;

    TRUNCATE TABLE dbo.Phi_CS_ProviderSummary;
    INSERT INTO dbo.Phi_CS_ProviderSummary
        (ProviderRank, ReferringProvider, NoOfClaims,
         InsurancePayments, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT ProviderRank, ReferringProvider, NoOfClaims,
           InsurancePayment, InsuranceBalance, PatientBalance, GETDATE()
    FROM #out ORDER BY ProviderRank;

    DROP TABLE IF EXISTS #out;
    PRINT 'usp_RefreshPhi_CS_ProviderSummary completed.';
END
GO


-- ── 8. Fix usp_GetPhi_CS_ProviderSummary ─────────────────────────────────────
PRINT 'Recreating usp_GetPhi_CS_ProviderSummary...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPhi_CS_ProviderSummary
    @PayerNames     NVARCHAR(MAX) = NULL,
    @PanelNames     NVARCHAR(MAX) = NULL,
    @DosFrom        DATE          = NULL,
    @DosTo          DATE          = NULL,
    @FirstBillFrom  DATE          = NULL,
    @FirstBillTo    DATE          = NULL,
    @CheckDateFrom  DATE          = NULL,
    @CheckDateTo    DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @HasFilter BIT =
        CASE
            WHEN NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL THEN 1
            WHEN NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL THEN 1
            WHEN @DosFrom       IS NOT NULL OR @DosTo       IS NOT NULL THEN 1
            WHEN @FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL THEN 1
            WHEN @CheckDateFrom IS NOT NULL OR @CheckDateTo IS NOT NULL THEN 1
            ELSE 0
        END;

    IF @HasFilter = 0
    BEGIN
        SELECT ProviderRank, ReferringProvider,
               NoOfClaims, InsurancePayments, InsuranceBalance, PatientBalance
        FROM   dbo.Phi_CS_ProviderSummary
        ORDER  BY ProviderRank;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(ReferringProvider))                              AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))            AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)  AS InsurancePayment,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)  AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)  AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ReferringProvider IS NOT NULL AND LTRIM(RTRIM(ReferringProvider)) <> ''
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(ReferringProvider))
    )
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS INT) AS ProviderRank,
        ReferringProvider, NoOfClaims,
        InsurancePayment AS InsurancePayments,
        InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;
END
GO


-- ── Repopulate snapshots ──────────────────────────────────────────────────────
PRINT 'Repopulating snapshots...';
EXEC dbo.usp_RefreshPhi_CS_AvgPayments;
EXEC dbo.usp_RefreshPhi_CS_StatusSummary;
EXEC dbo.usp_RefreshPhi_CS_ProviderSummary;
PRINT 'FIX_PhiLife_CS_ColumnMismatch.sql completed.';
GO
