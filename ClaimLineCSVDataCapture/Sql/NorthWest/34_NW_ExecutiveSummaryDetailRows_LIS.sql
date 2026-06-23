-- ============================================================
-- NorthWest – LIS Detail Rows SP  (generic name, NW DB copy)
-- File : 34_NW_ExecutiveSummaryDetailRows_LIS.sql
-- DB   : NorthWest_LRN
--
-- dbo.usp_GetExecutiveSummaryDetail_LIS
--   Returns raw LIMSMaster rows for a given RowCode / period.
--   Uses NW-specific columns: IncorrectDOS, BilledTo, BillStatus,
--   FinalStatus, Source, ChargesNotEnteredStatus.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_LIS
(
    @RowCode  NVARCHAR(100) = '',
    @Year     INT           = 0,
    @Month    INT           = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ════════════════════════════════════════════════════════════════════
    --  Dynamic column detection – LIMSMaster
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @OrderIDCol  SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('OrderID','OrderId','AccessionNumber','Accession')
        ORDER BY CASE name WHEN 'OrderID' THEN 0 WHEN 'OrderId' THEN 1 WHEN 'AccessionNumber' THEN 2 ELSE 3 END);
    DECLARE @DateCol     SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('ReqCollectDate','Entry_DateCreated','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name WHEN 'ReqCollectDate' THEN 0 WHEN 'Entry_DateCreated' THEN 1 WHEN 'RequestCollectDate' THEN 2
            WHEN 'DateOfCollection' THEN 3 WHEN 'DateofService' THEN 4 WHEN 'CollectionDate' THEN 5
            WHEN 'ServiceDate' THEN 6 WHEN 'AccessionDate' THEN 7 ELSE 8 END);
    DECLARE @IncorrectDOSCol  SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('IncorrectDOS','IncorrectDos','Incorrect_DOS','BadDOS')
        ORDER BY CASE name WHEN 'IncorrectDOS' THEN 0 WHEN 'IncorrectDos' THEN 1 WHEN 'Incorrect_DOS' THEN 2 ELSE 3 END);
    DECLARE @BilledToCol      SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('BilledTo','BillTo','Billed_To')
        ORDER BY CASE name WHEN 'BilledTo' THEN 0 WHEN 'BillTo' THEN 1 ELSE 2 END);
    DECLARE @BillStatusCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('BillStatus','BillingStatus','Bill_Status')
        ORDER BY CASE name WHEN 'BillStatus' THEN 0 WHEN 'BillingStatus' THEN 1 ELSE 2 END);
    DECLARE @FinalStatusCol   SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('FinalStatus','Final_Status','SubStatus','Status')
        ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'Final_Status' THEN 1 WHEN 'SubStatus' THEN 2 ELSE 3 END);
    DECLARE @SourceCol        SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('Source','ClaimSource','System_Source')
        ORDER BY CASE name WHEN 'Source' THEN 0 WHEN 'ClaimSource' THEN 1 ELSE 2 END);
    DECLARE @ChargesNotCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('ChargesNotEnteredStatus','ChargesNotEntered','NotEnteredStatus')
        ORDER BY CASE name WHEN 'ChargesNotEnteredStatus' THEN 0 WHEN 'ChargesNotEntered' THEN 1 ELSE 2 END);
    DECLARE @PanelNameCol     SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.LIMSMaster')
        AND name IN ('LRNPanelName','PanelName','Panelname','PanelType','Panel','TestPanel')
        ORDER BY CASE name WHEN 'LRNPanelName' THEN 0 WHEN 'PanelName' THEN 1 WHEN 'Panelname' THEN 2
            WHEN 'PanelType' THEN 3 WHEN 'Panel' THEN 4 ELSE 5 END);

    -- Required columns guard – return empty schema so UI shows "No records" gracefully
    IF @OrderIDCol IS NULL OR @DateCol IS NULL OR @IncorrectDOSCol IS NULL OR @BilledToCol IS NULL
    BEGIN
        SELECT TOP 0
            CAST(NULL AS NVARCHAR(100)) AS OrderID,
            CAST(NULL AS DATE)          AS ServiceDate,
            CAST(NULL AS NVARCHAR(50))  AS IncorrectDOS,
            CAST(NULL AS NVARCHAR(200)) AS BilledTo,
            CAST(NULL AS NVARCHAR(100)) AS BillStatus,
            CAST(NULL AS NVARCHAR(200)) AS FinalStatus,
            CAST(NULL AS NVARCHAR(100)) AS Source,
            CAST(NULL AS NVARCHAR(200)) AS ChargesNotEnteredStatus,
            CAST(NULL AS NVARCHAR(200)) AS PanelName
        WHERE 1=0;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  Build WHERE clause from RowCode
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @LisWhere NVARCHAR(MAX) = N'';

    IF @RowCode='A'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')=''''';
    ELSE IF @RowCode='B'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill''';
    ELSE IF @RowCode LIKE 'B.%'   -- panel sub-row e.g. B.Urine Drug Screen
    BEGIN
        DECLARE @PanelFilter NVARCHAR(200) = REPLACE(@RowCode, 'B.', '');
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'''
            + CASE WHEN @PanelNameCol IS NOT NULL THEN N' AND ISNULL(LTRIM(RTRIM([' + @PanelNameCol + N'])),'''')=''' + REPLACE(@PanelFilter,'''','''''') + N'''' ELSE N'' END;
    END
    ELSE IF @RowCode='C' AND @BillStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed''';
    ELSE IF @RowCode='C.1' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Claim Submitted in Webpm''';
    ELSE IF @RowCode='C.2' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Claim Submitted in Daqbilling''';
    ELSE IF @RowCode='C.3' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Claim Submitted in Daq & Webpm''';
    ELSE IF @RowCode='C.4' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Non Billable - Excluded Organizations''';
    ELSE IF @RowCode='C.5' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Manually Pushed in Emedix''';
    ELSE IF @RowCode='D' AND @BillStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled''';
    ELSE IF @RowCode='D.1' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charge Not Created''';
    ELSE IF @RowCode='D.1.W' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL AND @SourceCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charge Not Created'' AND ISNULL(LTRIM(RTRIM([' + @SourceCol + N'])),'''')=''Webpm''';
    ELSE IF @RowCode='D.1.NC' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL AND @ChargesNotCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charge Not Created'' AND ISNULL(LTRIM(RTRIM([' + @ChargesNotCol + N'])),'''')=''No Charges found in Webpm''';
    ELSE IF @RowCode='D.1.UP' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL AND @ChargesNotCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charge Not Created'' AND ISNULL(LTRIM(RTRIM([' + @ChargesNotCol + N'])),'''')=''Unposted Charges in Webpm''';
    ELSE IF @RowCode='D.1.DQ' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL AND @SourceCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charge Not Created'' AND ISNULL(LTRIM(RTRIM([' + @SourceCol + N'])),'''')=''Daqbilling''';
    ELSE IF @RowCode='D.2' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Non Billable - Excluded PAP Codes''';
    ELSE IF @RowCode='D.3' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Non Billable - Excluded Validity Codes''';
    ELSE IF @RowCode='D.4' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Non Billable - Excluded Organizations''';
    ELSE IF @RowCode='D.5' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charges Created and Not Submitted''';
    ELSE IF @RowCode='D.5.W' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL AND @SourceCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charges Created and Not Submitted'' AND ISNULL(LTRIM(RTRIM([' + @SourceCol + N'])),'''')=''Webpm''';
    ELSE IF @RowCode='D.5.DQ' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL AND @SourceCol IS NOT NULL
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charges Created and Not Submitted'' AND ISNULL(LTRIM(RTRIM([' + @SourceCol + N'])),'''')=''Daqbilling''';
    ELSE IF @RowCode='E'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''ADCS Claims''';
    ELSE IF @RowCode='F'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''') NOT IN (''Insurance Bill'',''ADCS Claims'')';
    ELSE IF @RowCode='F.1'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Yet to be validate''';
    ELSE IF @RowCode='F.2'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Self pay''';
    ELSE IF @RowCode='F.3'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Client Bills''';
    ELSE IF @RowCode='F.4'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''System Test''';
    ELSE IF @RowCode='F.5'
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Rejections''';
    ELSE
        SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')=''''';

    -- ════════════════════════════════════════════════════════════════════
    --  Build optional column expressions
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @BsExpr  NVARCHAR(300) = CASE WHEN @BillStatusCol IS NOT NULL  THEN N'ISNULL(LTRIM(RTRIM([' + @BillStatusCol  + N'])),'''')' ELSE N'''''' END;
    DECLARE @FsExpr  NVARCHAR(300) = CASE WHEN @FinalStatusCol IS NOT NULL  THEN N'ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')' ELSE N'''''' END;
    DECLARE @SrcExpr NVARCHAR(300) = CASE WHEN @SourceCol IS NOT NULL       THEN N'ISNULL(LTRIM(RTRIM([' + @SourceCol     + N'])),'''')' ELSE N'''''' END;
    DECLARE @CnsExpr NVARCHAR(300) = CASE WHEN @ChargesNotCol IS NOT NULL   THEN N'ISNULL(LTRIM(RTRIM([' + @ChargesNotCol + N'])),'''')' ELSE N'''''' END;
    DECLARE @PnExpr  NVARCHAR(300) = CASE WHEN @PanelNameCol IS NOT NULL    THEN N'ISNULL(LTRIM(RTRIM([' + @PanelNameCol  + N'])),'''')' ELSE N'''''' END;

    -- ════════════════════════════════════════════════════════════════════
    --  Execute
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @Sql NVARCHAR(MAX) = N'
        SELECT
            LTRIM(RTRIM(ISNULL([' + @OrderIDCol + N'],''''))) AS OrderID,
            TRY_CAST([' + @DateCol + N'] AS DATE)             AS ServiceDate,
            ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''') AS IncorrectDOS,
            ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')     AS BilledTo,
            ' + @BsExpr + N'                                        AS BillStatus,
            ' + @FsExpr + N'                                        AS FinalStatus,
            ' + @SrcExpr + N'                                       AS Source,
            ' + @CnsExpr + N'                                       AS ChargesNotEnteredStatus,
            ' + @PnExpr + N'                                        AS PanelName
        FROM dbo.LIMSMaster
        WHERE ' + @LisWhere + N'
          AND TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
          AND (@yr=0 OR YEAR(TRY_CAST([' + @DateCol + N'] AS DATE))=@yr)
          AND (@mo=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE))=@mo)
        ORDER BY TRY_CAST([' + @DateCol + N'] AS DATE);';

    EXEC sp_executesql @Sql, N'@yr INT, @mo INT', @yr=@Year, @mo=@Month;
END;
GO

PRINT '34_NW_ExecutiveSummaryDetailRows_LIS.sql completed.';
GO
