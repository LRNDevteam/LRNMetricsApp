/* =============================================================================
   VariantX Labs — cloned from Elixir (22_Elixir_ExecutiveSummary_FilterOptions.sql)
   Prefix: VarX_ / VarX_CS_ / VarX_ES_
   Refresh: usp_RefreshVarX_*
   Read:    usp_GetVarX_*
   Source tables: dbo.ClaimLevelData, dbo.LineLevelData, dbo.LIMSMaster
   No inline UI queries — dashboard/ReportWorker must call these SPs only.

   Auto-detects Panel/Clinic/Provider/Rep columns. Missing columns omit that
   filter branch (safe when ClaimLevel alters 02-05 are skipped).
   Panel prefers Panelname (not PanelType) — matches Certus/PhiLife fix.
   ============================================================================= */
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_ExecutiveSummary_FilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PanelCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (N'Panelname', N'PanelName', N'PanelType', N'Panel')
        ORDER BY CASE c.name
            WHEN N'Panelname' THEN 1
            WHEN N'PanelName' THEN 2
            WHEN N'PanelType' THEN 3
            ELSE 4
        END
    );

    DECLARE @ClinicCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (N'ClinicName', N'Facility', N'ServiceLocationName', N'Clinic')
        ORDER BY CASE c.name
            WHEN N'ClinicName' THEN 1
            WHEN N'Facility' THEN 2
            WHEN N'ServiceLocationName' THEN 3
            ELSE 4
        END
    );

    DECLARE @ProviderCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (
                N'ReferringProvider', N'ReferringPhysician', N'Provider',
                N'ProviderName', N'OrderingProvider', N'BillingProvider')
        ORDER BY CASE c.name
            WHEN N'ReferringProvider' THEN 1
            WHEN N'ReferringPhysician' THEN 2
            WHEN N'Provider' THEN 3
            WHEN N'ProviderName' THEN 4
            WHEN N'OrderingProvider' THEN 5
            WHEN N'BillingProvider' THEN 6
            ELSE 7
        END
    );

    DECLARE @RepCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (N'SalesRepname', N'SalesRepName', N'SalesRep', N'SalesRep_Name')
        ORDER BY CASE c.name
            WHEN N'SalesRepname' THEN 1
            WHEN N'SalesRepName' THEN 2
            WHEN N'SalesRep' THEN 3
            ELSE 4
        END
    );

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        ''Year'' AS FilterType,
        CAST(YEAR(TRY_CAST(DateofService AS DATE)) AS NVARCHAR(50)) AS FilterValue,
        YEAR(TRY_CAST(DateofService AS DATE)) AS SortOrder
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL
    GROUP BY YEAR(TRY_CAST(DateofService AS DATE))
    ';

    IF @PanelCol IS NOT NULL
        SET @sql += N'
    UNION ALL
    SELECT ''Panel'', LTRIM(RTRIM(' + QUOTENAME(@PanelCol) + N')), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(' + QUOTENAME(@PanelCol) + N')), '''') IS NOT NULL
    GROUP BY LTRIM(RTRIM(' + QUOTENAME(@PanelCol) + N'))
    ';

    IF @ClinicCol IS NOT NULL
        SET @sql += N'
    UNION ALL
    SELECT ''Clinic'', LTRIM(RTRIM(' + QUOTENAME(@ClinicCol) + N')), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(' + QUOTENAME(@ClinicCol) + N')), '''') IS NOT NULL
    GROUP BY LTRIM(RTRIM(' + QUOTENAME(@ClinicCol) + N'))
    ';

    IF @ProviderCol IS NOT NULL
        SET @sql += N'
    UNION ALL
    SELECT ''Provider'', LTRIM(RTRIM(' + QUOTENAME(@ProviderCol) + N')), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(' + QUOTENAME(@ProviderCol) + N')), '''') IS NOT NULL
    GROUP BY LTRIM(RTRIM(' + QUOTENAME(@ProviderCol) + N'))
    ';

    IF @RepCol IS NOT NULL
        SET @sql += N'
    UNION ALL
    SELECT ''Rep'', LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')), 0
    FROM dbo.ClaimLevelData
    WHERE NULLIF(LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')), '''') IS NOT NULL
    GROUP BY LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N'))
    ';

    SET @sql += N'
    ORDER BY FilterType, SortOrder DESC, FilterValue;';

    EXEC sys.sp_executesql @sql;
END;
GO

PRINT '22_VariantX_ExecutiveSummary_FilterOptions.sql completed.';
GO
