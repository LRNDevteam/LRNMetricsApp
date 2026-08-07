SET NOCOUNT ON;
DECLARE @DateCol SYSNAME = 'Entry_DateCreated';
DECLARE @AccCol SYSNAME = 'Accession';
DECLARE @PanelExpr NVARCHAR(MAX) = N'CAST(N''All Panels'' AS nvarchar(4000))';
DECLARE @ClientExpr NVARCHAR(MAX) = N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), [SubStatus]))), ''''), ''Unspecified'')';
DECLARE @ResultedPred NVARCHAR(MAX) = N'LTRIM(RTRIM(CONVERT(nvarchar(4000), [NA]))) <> @BillableVal';
DECLARE @NotResultedPred NVARCHAR(MAX) = N'(1 = 0)';
DECLARE @dt  NVARCHAR(300) = N'TRY_CONVERT(date, ' + QUOTENAME(@DateCol) + N')';
DECLARE @acc NVARCHAR(300) = N'NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ' + QUOTENAME(@AccCol) + N'))), '''')';
DECLARE @sql NVARCHAR(MAX) = N'
SELECT TOP 5
    YEAR('  + @dt + N'),
    MONTH(' + @dt + N'),
    DAY('   + @dt + N'),
    ' + @acc + N',
    ' + @PanelExpr + N',
    ' + @ClientExpr + N',
    MAX(CASE WHEN ' + @ResultedPred    + N' THEN 1 ELSE 0 END),
    MAX(CASE WHEN ' + @NotResultedPred + N' THEN 1 ELSE 0 END)
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE ' + @dt + N' IS NOT NULL
  AND YEAR(' + @dt + N') > 1900
  AND ' + @acc + N' IS NOT NULL
  AND (@Year = 0 OR YEAR(' + @dt + N') = @Year)
GROUP BY
    YEAR('  + @dt + N'),
    MONTH(' + @dt + N'),
    DAY('   + @dt + N'),
    ' + @acc + N',
    ' + @PanelExpr + N',
    ' + @ClientExpr + N';
BEGIN TRY
  EXEC sys.sp_executesql @sql,
    N'@Year INT, @BillableVal NVARCHAR(200), @NotResultedVal NVARCHAR(200), @Val2 NVARCHAR(200), @Val3 NVARCHAR(200), @Val4 NVARCHAR(200)',
    @Year=0, @BillableVal=N'', @NotResultedVal=NULL, @Val2=NULL, @Val3=NULL, @Val4=NULL;
  SELECT 'REPRO_OK' AS r;
END TRY
BEGIN CATCH
  SELECT ERROR_MESSAGE() AS msg;
END CATCH
GO

-- Also try with LRNPanelName instead of constant panel
DECLARE @DateCol SYSNAME = 'Entry_DateCreated';
DECLARE @AccCol SYSNAME = 'Accession';
DECLARE @PanelExpr NVARCHAR(MAX) = N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), [LRNPanelName]))), ''''), ''Unspecified'')';
DECLARE @ClientExpr NVARCHAR(MAX) = N'ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), [SubStatus]))), ''''), ''Unspecified'')';
DECLARE @ResultedPred NVARCHAR(MAX) = N'LTRIM(RTRIM(CONVERT(nvarchar(4000), [NA]))) <> @BillableVal';
DECLARE @NotResultedPred NVARCHAR(MAX) = N'(1 = 0)';
DECLARE @dt  NVARCHAR(300) = N'TRY_CONVERT(date, ' + QUOTENAME(@DateCol) + N')';
DECLARE @acc NVARCHAR(300) = N'NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ' + QUOTENAME(@AccCol) + N'))), '''')';
DECLARE @sql NVARCHAR(MAX) = N'
SELECT TOP 5
    YEAR('  + @dt + N'), MONTH(' + @dt + N'), DAY(' + @dt + N'),
    ' + @acc + N', ' + @PanelExpr + N', ' + @ClientExpr + N',
    MAX(CASE WHEN ' + @ResultedPred + N' THEN 1 ELSE 0 END),
    MAX(CASE WHEN ' + @NotResultedPred + N' THEN 1 ELSE 0 END)
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE ' + @dt + N' IS NOT NULL AND YEAR(' + @dt + N') > 1900 AND ' + @acc + N' IS NOT NULL
  AND (@Year = 0 OR YEAR(' + @dt + N') = @Year)
GROUP BY YEAR(' + @dt + N'), MONTH(' + @dt + N'), DAY(' + @dt + N'),
    ' + @acc + N', ' + @PanelExpr + N', ' + @ClientExpr + N';
BEGIN TRY
  EXEC sys.sp_executesql @sql,
    N'@Year INT, @BillableVal NVARCHAR(200), @NotResultedVal NVARCHAR(200), @Val2 NVARCHAR(200), @Val3 NVARCHAR(200), @Val4 NVARCHAR(200)',
    @Year=0, @BillableVal=N'', @NotResultedVal=NULL, @Val2=NULL, @Val3=NULL, @Val4=NULL;
  SELECT 'REPRO2_OK' AS r;
END TRY
BEGIN CATCH
  SELECT 'REPRO2:' + ERROR_MESSAGE() AS msg;
END CATCH
GO
