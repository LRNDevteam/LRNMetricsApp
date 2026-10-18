-- ============================================================
-- 09_PV_FilterOptions.sql
-- Snapshot of Prediction Analysis dropdown values so large labs
-- (e.g. NorthWest) avoid 10× SELECT DISTINCT on PayerValidationReport.
-- Deploy on each lab DB (NWL_LRN, CoveLRN, ...).
-- Run AFTER 04_PredictionAggregateTables.sql / 05_...RefreshSPs.sql
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PV_FilterOptions', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_FilterOptions
    (
        Id          BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId       NVARCHAR(100)  NOT NULL,
        FilterType  NVARCHAR(100)  NOT NULL,
        FilterValue NVARCHAR(500)  NOT NULL,
        RefreshedAt DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_FilterOptions_Type ON dbo.PV_FilterOptions (FilterType, FilterValue);
    CREATE INDEX IX_PV_FilterOptions_Run  ON dbo.PV_FilterOptions (RunId);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPV_FilterOptions
(
    @RunId NVARCHAR(100) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = RunId
        FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL
        ORDER BY InsertedDateTime DESC;
    END

    IF @RunId IS NULL RETURN;

    DELETE FROM dbo.PV_FilterOptions WHERE RunId = @RunId OR 1 = 1; -- keep only latest snapshot

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'PayerName',
           COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                    NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown')
    FROM dbo.PayerValidationReport WHERE RunId = @RunId;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'ForecastingPayability', LTRIM(RTRIM(ForecastingPayability))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(ForecastingPayability)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'PayStatus',
           COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)')
    FROM dbo.PayerValidationReport WHERE RunId = @RunId;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'ForecastingPayabilitySubstatus', LTRIM(RTRIM(ForecastingPayabilitySubstatus))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(ForecastingPayabilitySubstatus)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'PredictionStatus', LTRIM(RTRIM(PredictionStatus))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(PredictionStatus)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'PayerType', LTRIM(RTRIM(PayerType))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(PayerType)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'PanelName', LTRIM(RTRIM(PanelName))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(PanelName)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'FinalCoverageStatus', LTRIM(RTRIM(FinalCoverageStatus))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(FinalCoverageStatus)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'Payability', LTRIM(RTRIM(Payability))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(Payability)), N'') IS NOT NULL;

    INSERT INTO dbo.PV_FilterOptions (RunId, FilterType, FilterValue)
    SELECT DISTINCT @RunId, N'CPTCode', LTRIM(RTRIM(CPTCode))
    FROM dbo.PayerValidationReport
    WHERE RunId = @RunId AND NULLIF(LTRIM(RTRIM(CPTCode)), N'') IS NOT NULL;
END
GO

-- Fast-read path for the dashboard; falls back to live DISTINCT when snapshot empty.
CREATE OR ALTER PROCEDURE dbo.usp_GetPredictionFilterOptions
(
    @RunId NVARCHAR(100) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;

    IF @RunId IS NULL OR LTRIM(RTRIM(@RunId)) = ''
    BEGIN
        SELECT TOP 1 @RunId = RunId
        FROM dbo.PayerValidationReport
        WHERE RunId IS NOT NULL
        ORDER BY InsertedDateTime DESC;
    END

    IF OBJECT_ID('dbo.PV_FilterOptions', 'U') IS NOT NULL
       AND EXISTS (SELECT 1 FROM dbo.PV_FilterOptions)
    BEGIN
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'PayerName' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'ForecastingPayability' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'PayStatus' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'ForecastingPayabilitySubstatus' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'PredictionStatus' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'PayerType' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'PanelName' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'FinalCoverageStatus' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'Payability' ORDER BY FilterValue;
        SELECT FilterValue FROM dbo.PV_FilterOptions WHERE FilterType = N'CPTCode' ORDER BY FilterValue;
        RETURN;
    END

    -- Legacy live path (expensive on large labs)
    SELECT DISTINCT PayerName = COALESCE(NULLIF(LTRIM(RTRIM(PayerNameNormalized)), N''),
                                         NULLIF(LTRIM(RTRIM(PayerName)), N''), N'Unknown')
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
    ORDER BY 1;

    SELECT DISTINCT ForecastingPayability = LTRIM(RTRIM(ForecastingPayability))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(ForecastingPayability)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PayStatus = COALESCE(NULLIF(LTRIM(RTRIM(PayStatus)), N''), N'(Blank)')
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
    ORDER BY 1;

    SELECT DISTINCT ForecastingPayabilitySubstatus
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(ForecastingPayabilitySubstatus)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PredictionStatus
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(PredictionStatus)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PayerType = LTRIM(RTRIM(PayerType))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(PayerType)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT PanelName = LTRIM(RTRIM(PanelName))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(PanelName)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT FinalCoverageStatus = LTRIM(RTRIM(FinalCoverageStatus))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(FinalCoverageStatus)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT Payability = LTRIM(RTRIM(Payability))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(Payability)), N'') IS NOT NULL
    ORDER BY 1;

    SELECT DISTINCT CPTCode = LTRIM(RTRIM(CPTCode))
    FROM dbo.PayerValidationReport
    WHERE (@RunId IS NULL OR RunId = @RunId)
      AND NULLIF(LTRIM(RTRIM(CPTCode)), N'') IS NOT NULL
    ORDER BY 1;
END
GO
