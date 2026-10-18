-- ============================================================
-- PhiLife — Fix StatusSummary SPs (GROUP BY mismatch)
-- Run on PhiLife_LRN database.
-- ============================================================
SET NOCOUNT ON;
GO

-- ── Fix usp_RefreshPhi_CS_StatusSummary ──────────────────────────────────────
PRINT 'Recreating usp_RefreshPhi_CS_StatusSummary...';
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_CS_StatusSummary
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.Phi_CS_StatusSummary;

    ;WITH base AS (
        SELECT
            ISNULL(LTRIM(RTRIM(ClaimStatus)),  '(blank)')  AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(Panelname)),    '(blank)')  AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(
                ISNULL(LTRIM(RTRIM(CPTCode)), '') +
                CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
                CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END
            )), ''), '(blank)')                            AS CptCode,
            ISNULL(LTRIM(RTRIM(PayerName_Raw)),'(blank)')  AS PayerName,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(InsuranceBalance AS DECIMAL(18,2))    AS InsBalance,
            TRY_CAST(PatientBalance   AS DECIMAL(18,2))    AS PtBalance
        FROM dbo.LineLevelData
    )
    INSERT INTO dbo.Phi_CS_StatusSummary
        (ClaimStatus, PanelName, CptCode, PayerName,
         NoOfClaims, InsurancePayment, InsuranceBalance, PatientBalance, RefreshedAt)
    SELECT
        ClaimStatus, PanelName, CptCode, PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
        ISNULL(SUM(InsPay),      0)                        AS InsurancePayment,
        ISNULL(SUM(InsBalance),  0)                        AS InsuranceBalance,
        ISNULL(SUM(PtBalance),   0)                        AS PatientBalance,
        GETDATE()
    FROM base
    GROUP BY ClaimStatus, PanelName, CptCode, PayerName;

    PRINT 'usp_RefreshPhi_CS_StatusSummary completed.';
END
GO


-- ── Fix usp_GetPhi_CS_StatusSummary ──────────────────────────────────────────
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

    -- No-filter: serve from snapshot
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

    ;WITH base AS (
        SELECT
            ISNULL(LTRIM(RTRIM(ClaimStatus)),  '(blank)')  AS ClaimStatus,
            ISNULL(LTRIM(RTRIM(Panelname)),    '(blank)')  AS PanelName,
            ISNULL(NULLIF(LTRIM(RTRIM(
                ISNULL(LTRIM(RTRIM(CPTCode)), '') +
                CASE WHEN NULLIF(LTRIM(RTRIM(Units)),    '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Units))    ELSE '' END +
                CASE WHEN NULLIF(LTRIM(RTRIM(Modifier)), '') IS NOT NULL
                     THEN ' x ' + LTRIM(RTRIM(Modifier)) ELSE '' END
            )), ''), '(blank)')                            AS CptCode,
            ISNULL(LTRIM(RTRIM(PayerName_Raw)),'(blank)')  AS PayerName,
            ClaimID,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            TRY_CAST(InsuranceBalance AS DECIMAL(18,2))    AS InsBalance,
            TRY_CAST(PatientBalance   AS DECIMAL(18,2))    AS PtBalance
        FROM dbo.LineLevelData
        WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(PayerName_Raw)) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    )
    SELECT
        ClaimStatus, PanelName, CptCode, PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))  AS NoOfClaims,
        ISNULL(SUM(InsPay),      0)                        AS InsurancePayment,
        ISNULL(SUM(InsBalance),  0)                        AS InsuranceBalance,
        ISNULL(SUM(PtBalance),   0)                        AS PatientBalance
    FROM base
    GROUP BY ClaimStatus, PanelName, CptCode, PayerName
    ORDER BY ClaimStatus, PanelName, PayerName;
END
GO


-- ── Repopulate StatusSummary snapshot ────────────────────────────────────────
EXEC dbo.usp_RefreshPhi_CS_StatusSummary;
PRINT 'FIX_PhiLife_CS_StatusSummary_SPs.sql completed.';
GO
