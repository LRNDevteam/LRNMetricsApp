-- ============================================================
-- 08_EnsureDenialDescriptionOnAggregate.sql
-- Ensures PV_DenialBreakdown.DenialDescription exists (idempotent).
-- Deploy on each lab database (e.g. CoveLRN, NWL_LRN).
--
-- Multi-code rows (e.g. "CO-11, CO-252, N56/16") stay as ONE row.
-- Description = each code's DenialMapperSuperMaster text joined with ", ".
--
-- IMPORTANT:
--   - Split ONLY on comma / semicolon. Do NOT split on "/" (N56/16 is one code).
--   - Match master with normalized keys (CO-11 = CO11).
--   - Truncate / widen DenialDescription so updates never Msg 2628.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- PV_DenialBreakdown.DenialDescription
IF OBJECT_ID('dbo.PV_DenialBreakdown', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.PV_DenialBreakdown', 'DenialDescription') IS NULL
        ALTER TABLE dbo.PV_DenialBreakdown ADD DenialDescription NVARCHAR(1000) NULL;
    ELSE IF COL_LENGTH('dbo.PV_DenialBreakdown', 'DenialDescription') > 0
         AND COL_LENGTH('dbo.PV_DenialBreakdown', 'DenialDescription') < 2000  -- < 1000 nvarchar chars
        ALTER TABLE dbo.PV_DenialBreakdown ALTER COLUMN DenialDescription NVARCHAR(1000) NULL;
END
GO

-- PayerValidationReport.DenialDescription (often NVARCHAR(100/255) on older labs)
IF OBJECT_ID('dbo.PayerValidationReport', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.PayerValidationReport', 'DenialDescription') IS NOT NULL
   AND COL_LENGTH('dbo.PayerValidationReport', 'DenialDescription') > 0
   AND COL_LENGTH('dbo.PayerValidationReport', 'DenialDescription') < 2000  -- < 1000 nvarchar chars
BEGIN
    ALTER TABLE dbo.PayerValidationReport
        ALTER COLUMN DenialDescription NVARCHAR(1000) NULL;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_EnrichPV_DenialDescriptionFromMaster
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID(N'LRNMaster.dbo.DenialMapperSuperMaster', N'U') IS NULL
        RETURN;

    -- Max chars allowed on each column (COL_LENGTH is bytes for nvarchar; -1 = MAX)
    DECLARE @PvMax  INT =
        CASE
            WHEN COL_LENGTH(N'dbo.PV_DenialBreakdown', N'DenialDescription') IS NULL THEN 1000
            WHEN COL_LENGTH(N'dbo.PV_DenialBreakdown', N'DenialDescription') < 0 THEN 4000
            ELSE COL_LENGTH(N'dbo.PV_DenialBreakdown', N'DenialDescription') / 2
        END;
    DECLARE @PvrMax INT =
        CASE
            WHEN COL_LENGTH(N'dbo.PayerValidationReport', N'DenialDescription') IS NULL THEN 1000
            WHEN COL_LENGTH(N'dbo.PayerValidationReport', N'DenialDescription') < 0 THEN 4000
            ELSE COL_LENGTH(N'dbo.PayerValidationReport', N'DenialDescription') / 2
        END;

    IF @PvMax  < 1 SET @PvMax  = 1000;
    IF @PvrMax < 1 SET @PvrMax = 1000;

    ------------------------------------------------------------------
    -- Master map: exact code + normalized (no hyphen/space) for matching
    ------------------------------------------------------------------
    ;WITH MasterRaw AS
    (
        SELECT
            DenialCode        = LTRIM(RTRIM(DenialCode)),
            DenialDescription = LTRIM(RTRIM(DenialDescription)),
            rn = ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(DenialCode))
                ORDER BY ModifiedOn DESC)
        FROM LRNMaster.dbo.DenialMapperSuperMaster
        WHERE IsActive = 1
          AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
    ),
    MasterDesc AS
    (
        SELECT
            DenialCode,
            DenialDescription,
            NormCode = UPPER(REPLACE(REPLACE(DenialCode, N'-', N''), N' ', N''))
        FROM MasterRaw
        WHERE rn = 1
    )
    ------------------------------------------------------------------
    -- 1) Single-code rows (no comma/semicolon): fill blank descriptions
    ------------------------------------------------------------------
    UPDATE d
    SET d.DenialDescription = LEFT(m.DenialDescription, @PvMax)
    FROM dbo.PV_DenialBreakdown d
    CROSS APPLY
    (
        SELECT TOP (1) md.DenialDescription
        FROM MasterDesc md
        WHERE md.DenialCode = LTRIM(RTRIM(d.DenialCode))
           OR md.NormCode = UPPER(REPLACE(REPLACE(LTRIM(RTRIM(d.DenialCode)), N'-', N''), N' ', N''))
        ORDER BY CASE WHEN md.DenialCode = LTRIM(RTRIM(d.DenialCode)) THEN 0 ELSE 1 END
    ) m
    WHERE NULLIF(LTRIM(RTRIM(d.DenialDescription)), '') IS NULL
      AND NULLIF(LTRIM(RTRIM(d.DenialCode)), '') IS NOT NULL
      AND d.DenialCode <> N'(Blank)'
      AND d.DenialCode NOT LIKE N'%,%'
      AND d.DenialCode NOT LIKE N'%;%';

    ------------------------------------------------------------------
    -- 2) Multi-code rows → one row, joined master descriptions
    --    Split ONLY on , and ;   (keep N56/16 intact)
    ------------------------------------------------------------------
    ;WITH Target AS
    (
        SELECT DISTINCT
            DenialCode = LTRIM(RTRIM(d.DenialCode)),
            Cleaned = LTRIM(RTRIM(REPLACE(d.DenialCode, N';', N',')))
        FROM dbo.PV_DenialBreakdown d
        WHERE NULLIF(LTRIM(RTRIM(d.DenialCode)), '') IS NOT NULL
          AND d.DenialCode <> N'(Blank)'
          AND (d.DenialCode LIKE N'%,%' OR d.DenialCode LIKE N'%;%')
    ),
    Split AS
    (
        SELECT
            t.DenialCode,
            PartCode = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', t.Cleaned) > 0
                     THEN LEFT(t.Cleaned, CHARINDEX(N',', t.Cleaned) - 1)
                     ELSE t.Cleaned END)),
            Rest = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', t.Cleaned) > 0
                     THEN SUBSTRING(t.Cleaned, CHARINDEX(N',', t.Cleaned) + 1, 4000)
                     ELSE N'' END)),
            Ord = 1
        FROM Target t

        UNION ALL

        SELECT
            s.DenialCode,
            PartCode = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', s.Rest) > 0
                     THEN LEFT(s.Rest, CHARINDEX(N',', s.Rest) - 1)
                     ELSE s.Rest END)),
            Rest = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', s.Rest) > 0
                     THEN SUBSTRING(s.Rest, CHARINDEX(N',', s.Rest) + 1, 4000)
                     ELSE N'' END)),
            Ord = s.Ord + 1
        FROM Split s
        WHERE NULLIF(s.Rest, N'') IS NOT NULL
    ),
    MasterRaw AS
    (
        SELECT
            DenialCode        = LTRIM(RTRIM(DenialCode)),
            DenialDescription = LTRIM(RTRIM(DenialDescription)),
            rn = ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(DenialCode))
                ORDER BY ModifiedOn DESC)
        FROM LRNMaster.dbo.DenialMapperSuperMaster
        WHERE IsActive = 1
          AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
    ),
    MasterDesc AS
    (
        SELECT
            DenialCode,
            DenialDescription,
            NormCode = UPPER(REPLACE(REPLACE(DenialCode, N'-', N''), N' ', N''))
        FROM MasterRaw
        WHERE rn = 1
    ),
    PartResolved AS
    (
        SELECT
            s.DenialCode,
            s.Ord,
            s.PartCode,
            ResolvedDesc = m.DenialDescription
        FROM Split s
        CROSS APPLY
        (
            SELECT TOP (1) md.DenialDescription
            FROM MasterDesc md
            WHERE NULLIF(s.PartCode, N'') IS NOT NULL
              AND (
                    md.DenialCode = s.PartCode
                 OR md.NormCode = UPPER(REPLACE(REPLACE(s.PartCode, N'-', N''), N' ', N''))
                  )
            ORDER BY CASE WHEN md.DenialCode = s.PartCode THEN 0 ELSE 1 END
        ) m
    ),
    Joined AS
    (
        SELECT
            DenialCode,
            JoinedDesc = STRING_AGG(ResolvedDesc, N', ')
                         WITHIN GROUP (ORDER BY Ord)
        FROM PartResolved
        GROUP BY DenialCode
        HAVING COUNT_BIG(*) >= 1
    )
    UPDATE d
    SET d.DenialDescription = LEFT(j.JoinedDesc, @PvMax)
    FROM dbo.PV_DenialBreakdown d
    INNER JOIN Joined j
        ON j.DenialCode = LTRIM(RTRIM(d.DenialCode))
    OPTION (MAXRECURSION 50);

    ------------------------------------------------------------------
    -- 3) PayerValidationReport — single-code blanks
    ------------------------------------------------------------------
    ;WITH MasterRaw AS
    (
        SELECT
            DenialCode        = LTRIM(RTRIM(DenialCode)),
            DenialDescription = LTRIM(RTRIM(DenialDescription)),
            rn = ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(DenialCode))
                ORDER BY ModifiedOn DESC)
        FROM LRNMaster.dbo.DenialMapperSuperMaster
        WHERE IsActive = 1
          AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
    ),
    MasterDesc AS
    (
        SELECT
            DenialCode,
            DenialDescription,
            NormCode = UPPER(REPLACE(REPLACE(DenialCode, N'-', N''), N' ', N''))
        FROM MasterRaw
        WHERE rn = 1
    )
    UPDATE r
    SET r.DenialDescription = LEFT(m.DenialDescription, @PvrMax)
    FROM dbo.PayerValidationReport r
    CROSS APPLY
    (
        SELECT TOP (1) md.DenialDescription
        FROM MasterDesc md
        WHERE md.DenialCode = LTRIM(RTRIM(r.DenialCode))
           OR md.NormCode = UPPER(REPLACE(REPLACE(LTRIM(RTRIM(r.DenialCode)), N'-', N''), N' ', N''))
        ORDER BY CASE WHEN md.DenialCode = LTRIM(RTRIM(r.DenialCode)) THEN 0 ELSE 1 END
    ) m
    WHERE NULLIF(LTRIM(RTRIM(r.DenialDescription)), '') IS NULL
      AND NULLIF(LTRIM(RTRIM(r.DenialCode)), '') IS NOT NULL
      AND r.DenialCode NOT LIKE N'%,%'
      AND r.DenialCode NOT LIKE N'%;%'
      AND LTRIM(RTRIM(ISNULL(r.PayStatus, N''))) = N'Denied';

    ------------------------------------------------------------------
    -- 4) PayerValidationReport — multi-code joined descriptions
    ------------------------------------------------------------------
    ;WITH Target AS
    (
        SELECT
            r.ReportId,
            DenialCode = LTRIM(RTRIM(r.DenialCode)),
            Cleaned = LTRIM(RTRIM(REPLACE(r.DenialCode, N';', N',')))
        FROM dbo.PayerValidationReport r
        WHERE NULLIF(LTRIM(RTRIM(r.DenialCode)), '') IS NOT NULL
          AND LTRIM(RTRIM(ISNULL(r.PayStatus, N''))) = N'Denied'
          AND (r.DenialCode LIKE N'%,%' OR r.DenialCode LIKE N'%;%')
    ),
    Split AS
    (
        SELECT
            t.ReportId,
            PartCode = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', t.Cleaned) > 0
                     THEN LEFT(t.Cleaned, CHARINDEX(N',', t.Cleaned) - 1)
                     ELSE t.Cleaned END)),
            Rest = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', t.Cleaned) > 0
                     THEN SUBSTRING(t.Cleaned, CHARINDEX(N',', t.Cleaned) + 1, 4000)
                     ELSE N'' END)),
            Ord = 1
        FROM Target t

        UNION ALL

        SELECT
            s.ReportId,
            PartCode = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', s.Rest) > 0
                     THEN LEFT(s.Rest, CHARINDEX(N',', s.Rest) - 1)
                     ELSE s.Rest END)),
            Rest = LTRIM(RTRIM(
                CASE WHEN CHARINDEX(N',', s.Rest) > 0
                     THEN SUBSTRING(s.Rest, CHARINDEX(N',', s.Rest) + 1, 4000)
                     ELSE N'' END)),
            Ord = s.Ord + 1
        FROM Split s
        WHERE NULLIF(s.Rest, N'') IS NOT NULL
    ),
    MasterRaw AS
    (
        SELECT
            DenialCode        = LTRIM(RTRIM(DenialCode)),
            DenialDescription = LTRIM(RTRIM(DenialDescription)),
            rn = ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(DenialCode))
                ORDER BY ModifiedOn DESC)
        FROM LRNMaster.dbo.DenialMapperSuperMaster
        WHERE IsActive = 1
          AND NULLIF(LTRIM(RTRIM(DenialCode)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(DenialDescription)), '') IS NOT NULL
    ),
    MasterDesc AS
    (
        SELECT
            DenialCode,
            DenialDescription,
            NormCode = UPPER(REPLACE(REPLACE(DenialCode, N'-', N''), N' ', N''))
        FROM MasterRaw
        WHERE rn = 1
    ),
    PartResolved AS
    (
        SELECT
            s.ReportId,
            s.Ord,
            ResolvedDesc = m.DenialDescription
        FROM Split s
        CROSS APPLY
        (
            SELECT TOP (1) md.DenialDescription
            FROM MasterDesc md
            WHERE NULLIF(s.PartCode, N'') IS NOT NULL
              AND (
                    md.DenialCode = s.PartCode
                 OR md.NormCode = UPPER(REPLACE(REPLACE(s.PartCode, N'-', N''), N' ', N''))
                  )
            ORDER BY CASE WHEN md.DenialCode = s.PartCode THEN 0 ELSE 1 END
        ) m
    ),
    Joined AS
    (
        SELECT
            ReportId,
            JoinedDesc = STRING_AGG(ResolvedDesc, N', ')
                         WITHIN GROUP (ORDER BY Ord)
        FROM PartResolved
        GROUP BY ReportId
        HAVING COUNT_BIG(*) >= 1
    )
    UPDATE r
    SET r.DenialDescription = LEFT(j.JoinedDesc, @PvrMax)
    FROM dbo.PayerValidationReport r
    INNER JOIN Joined j ON j.ReportId = r.ReportId
    OPTION (MAXRECURSION 50);
END
GO
