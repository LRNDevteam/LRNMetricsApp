-- ============================================================
-- 08_EnsureDenialDescriptionOnAggregate.sql
-- Ensures PV_DenialBreakdown.DenialDescription exists (idempotent).
-- Deploy on each lab database (e.g. CoveLRN, NWL_LRN).
--
-- usp_EnrichPV_DenialDescriptionFromMaster is executed automatically
-- by usp_RefreshAllPredictionAggregates after PV_DenialBreakdown refresh.
-- Same-server path: LRNMaster.dbo.DenialMapperSuperMaster via 3-part name.
-- Cross-server labs also use C# DenialDescriptionEnricher (MasterDbConnectionString).
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PV_DenialBreakdown', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.PV_DenialBreakdown', 'DenialDescription') IS NULL
BEGIN
    ALTER TABLE dbo.PV_DenialBreakdown
        ADD DenialDescription NVARCHAR(1000) NULL;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_EnrichPV_DenialDescriptionFromMaster
AS
BEGIN
    SET NOCOUNT ON;

    -- No-op when LRNMaster is not reachable from this database/server.
    IF OBJECT_ID(N'LRNMaster.dbo.DenialMapperSuperMaster', N'U') IS NULL
        RETURN;

    ;WITH MasterDesc AS
    (
        SELECT
            DenialCode = LTRIM(RTRIM(DenialCode)),
            DenialDescription = LTRIM(RTRIM(DenialDescription)),
            rn = ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(DenialCode))
                ORDER BY ModifiedOn DESC)
        FROM LRNMaster.dbo.DenialMapperSuperMaster
        WHERE IsActive = 1
          AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
    )
    UPDATE d
    SET d.DenialDescription = m.DenialDescription
    FROM dbo.PV_DenialBreakdown d
    INNER JOIN MasterDesc m
        ON m.DenialCode = LTRIM(RTRIM(d.DenialCode))
       AND m.rn = 1
    WHERE NULLIF(LTRIM(RTRIM(d.DenialDescription)), '') IS NULL;

    -- Also backfill blank descriptions on the source report rows (Denied only).
    ;WITH MasterDesc AS
    (
        SELECT
            DenialCode = LTRIM(RTRIM(DenialCode)),
            DenialDescription = LTRIM(RTRIM(DenialDescription)),
            rn = ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(DenialCode))
                ORDER BY ModifiedOn DESC)
        FROM LRNMaster.dbo.DenialMapperSuperMaster
        WHERE IsActive = 1
          AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
    )
    UPDATE r
    SET r.DenialDescription = m.DenialDescription
    FROM dbo.PayerValidationReport r
    INNER JOIN MasterDesc m
        ON m.DenialCode = LTRIM(RTRIM(r.DenialCode))
       AND m.rn = 1
    WHERE NULLIF(LTRIM(RTRIM(r.DenialDescription)), '') IS NULL
      AND NULLIF(LTRIM(RTRIM(r.DenialCode)), '') IS NOT NULL
      AND LTRIM(RTRIM(ISNULL(r.PayStatus, N''))) = N'Denied';
END
GO
