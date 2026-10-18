-- ============================================================
-- NorthWest – Executive Summary Detail SP
-- File : 32_NW_ExecutiveSummary_Detail.sql
-- DB   : NorthWest_LRN
--
-- usp_GetNW_ExecutiveSummary_Detail(@Category,@RowCode,@Year,@Month)
--   Routes LIS rows to LIMSMaster, PMS/Cash rows to ClaimLevelData.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_ExecutiveSummary_Detail
(
    @Category  NVARCHAR(50)  = '',
    @RowCode   NVARCHAR(100) = '',
    @Year      INT           = 0,
    @Month     INT           = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ════════════════════════════════════════════════════════════════════
    --  LIS  –  route to LIMSMaster
    -- ════════════════════════════════════════════════════════════════════
    IF @Category = 'LIS'
    BEGIN
        -- Dynamic column detection – LIMSMaster
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

        -- Required columns guard
        IF @OrderIDCol IS NULL OR @DateCol IS NULL OR @IncorrectDOSCol IS NULL OR @BilledToCol IS NULL
        BEGIN
            SELECT TOP 0
                CAST(NULL AS NVARCHAR(100)) AS OrderID,
                CAST(NULL AS DATE)          AS ServiceDate,
                CAST(NULL AS NVARCHAR(50))  AS IncorrectDOS,
                CAST(NULL AS NVARCHAR(100)) AS BilledTo,
                CAST(NULL AS NVARCHAR(100)) AS BillStatus,
                CAST(NULL AS NVARCHAR(200)) AS FinalStatus,
                CAST(NULL AS NVARCHAR(100)) AS Source,
                CAST(NULL AS NVARCHAR(200)) AS ChargesNotEnteredStatus,
                CAST(NULL AS NVARCHAR(200)) AS PanelName
            WHERE 1=0;
            RETURN;
        END

        -- Build WHERE clause for RowCode
        DECLARE @LisWhere NVARCHAR(MAX) = N'';
        -- Row A: all active
        IF @RowCode='A'
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')=''''';
        -- Row B: Insurance Bill
        ELSE IF @RowCode='B'
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill''';
        -- Row C: Billed
        ELSE IF @RowCode='C' AND @BillStatusCol IS NOT NULL
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Billed''';
        -- Row D: Unbilled
        ELSE IF @RowCode='D' AND @BillStatusCol IS NOT NULL
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled''';
        -- Row D.1: Charge Not Created
        ELSE IF @RowCode='D.1' AND @BillStatusCol IS NOT NULL AND @FinalStatusCol IS NOT NULL
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''Insurance Bill'' AND ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')=''Unbilled'' AND ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')=''Charge Not Created''';
        -- Row E: ADCS Claims
        ELSE IF @RowCode='E'
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')=''ADCS Claims''';
        -- Row F: Other
        ELSE IF @RowCode='F'
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')='''' AND ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''') NOT IN (''Insurance Bill'',''ADCS Claims'')';
        -- Sub-rows for F
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
            -- default: all active
            SET @LisWhere = N'ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''')=''''';

        DECLARE @PanelExpr    NVARCHAR(300) = CASE WHEN @PanelNameCol IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @PanelNameCol + N'])),'''')' ELSE N'N''''''''''''''' END;
        DECLARE @FsExpr       NVARCHAR(300) = CASE WHEN @FinalStatusCol IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @FinalStatusCol + N'])),'''')' ELSE N'N''''''''''''''' END;
        DECLARE @SrcExpr      NVARCHAR(300) = CASE WHEN @SourceCol IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @SourceCol + N'])),'''')' ELSE N'N''''''''''''''' END;
        DECLARE @CnsExpr      NVARCHAR(300) = CASE WHEN @ChargesNotCol IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @ChargesNotCol + N'])),'''')' ELSE N'N''''''''''''''' END;
        DECLARE @BsExpr       NVARCHAR(300) = CASE WHEN @BillStatusCol IS NOT NULL THEN N'ISNULL(LTRIM(RTRIM([' + @BillStatusCol + N'])),'''')' ELSE N'N''''''''''''''' END;

        DECLARE @LisSql NVARCHAR(MAX) = N'
            SELECT
                LTRIM(RTRIM(ISNULL([' + @OrderIDCol + N'],''''))) AS OrderID,
                TRY_CAST([' + @DateCol + N'] AS DATE)             AS ServiceDate,
                ISNULL(LTRIM(RTRIM([' + @IncorrectDOSCol + N'])),'''') AS IncorrectDOS,
                ISNULL(LTRIM(RTRIM([' + @BilledToCol + N'])),'''')     AS BilledTo,
                ' + @BsExpr + N'                                        AS BillStatus,
                ' + @FsExpr + N'                                        AS FinalStatus,
                ' + @SrcExpr + N'                                       AS Source,
                ' + @CnsExpr + N'                                       AS ChargesNotEnteredStatus,
                ' + @PanelExpr + N'                                     AS PanelName
            FROM dbo.LIMSMaster
            WHERE ' + @LisWhere + N'
              AND TRY_CAST([' + @DateCol + N'] AS DATE) IS NOT NULL
              AND (@yr=0 OR YEAR(TRY_CAST([' + @DateCol + N'] AS DATE))=@yr)
              AND (@mo=0 OR MONTH(TRY_CAST([' + @DateCol + N'] AS DATE))=@mo)
            ORDER BY TRY_CAST([' + @DateCol + N'] AS DATE);';
        EXEC sp_executesql @LisSql, N'@yr INT, @mo INT', @yr=@Year, @mo=@Month;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  PMS / Cash  –  route to ClaimLevelData
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @BilledCol2    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
        AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1 WHEN 'BillingStatus' THEN 2 ELSE 3 END);
    DECLARE @ClaimTypeCol2 SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
        AND name IN ('ClaimType','ClaimCategory')
        ORDER BY CASE name WHEN 'ClaimType' THEN 0 ELSE 1 END);

    IF @BilledCol2 IS NULL OR @ClaimTypeCol2 IS NULL
    BEGIN
        SELECT TOP 0
            CAST(NULL AS NVARCHAR(100)) AS AccessionNumber,
            CAST(NULL AS DATE)          AS DateofService,
            CAST(NULL AS NVARCHAR(50))  AS Billed,
            CAST(NULL AS NVARCHAR(200)) AS ClaimType,
            CAST(NULL AS NVARCHAR(200)) AS ClaimStatus,
            CAST(NULL AS DECIMAL(18,2)) AS ChargeAmount,
            CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
            CAST(NULL AS DECIMAL(18,2)) AS PatientPayment,
            CAST(NULL AS DECIMAL(18,2)) AS InsuranceBalance,
            CAST(NULL AS DECIMAL(18,2)) AS PatientBalance
        WHERE 1=0;
        RETURN;
    END

    -- Build WHERE for PMS/Cash RowCode
    DECLARE @PmsWhere NVARCHAR(MAX) = N'';
    -- PMS rows
    IF @RowCode='G'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE IF @RowCode='G.1'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='G.2'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='G.3'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''Partially Denied'',''FullyDenied'',''Partially Denied'')';
    ELSE IF @RowCode='H'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''') IN ('''',''Unbilled'') AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='J'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N']=''Test Patient Entries''';
    ELSE IF @RowCode='K'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N']=''ADCS - Invoice''';
    ELSE IF @RowCode='M'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='N'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='O'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'')';
    ELSE IF @RowCode='P'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''No Response''';
    ELSE IF @RowCode='Q'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Billed Amount 0''';
    ELSE IF @RowCode='R'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='S'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    -- Cash rows
    ELSE IF @RowCode='T'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE IF @RowCode='U'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''') IN ('''',''Unbilled'') AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='V'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Billed Amount 0''';
    ELSE IF @RowCode='W'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N']=''ADCS - Invoice''';
    ELSE IF @RowCode='X'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode IN ('X.1','AA.1')
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='AA'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE IF @RowCode='AB'
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='AC'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''') IN (''Billed'',''Billed - Client'') AND [' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE
        SET @PmsWhere = N'[' + @ClaimTypeCol2 + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';

    DECLARE @PmsSql NVARCHAR(MAX) = N'
        SELECT
            LTRIM(RTRIM(ISNULL(AccessionNumber,'''')))  AS AccessionNumber,
            TRY_CAST(DateofService AS DATE)              AS DateofService,
            ISNULL(LTRIM(RTRIM([' + @BilledCol2 + N'])),'''') AS Billed,
            ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol2 + N'])),'''') AS ClaimType,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),'''')       AS ClaimStatus,
            ISNULL(TRY_CAST(ChargeAmount AS DECIMAL(18,2)),0)       AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)),0)    AS InsurancePayment,
            ISNULL(TRY_CAST(PatientPayment AS DECIMAL(18,2)),0)      AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceBalance AS DECIMAL(18,2)),0)    AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance AS DECIMAL(18,2)),0)      AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ' + @PmsWhere + N'
          AND TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND (@yr=0 OR YEAR(TRY_CAST(DateofService AS DATE))=@yr)
          AND (@mo=0 OR MONTH(TRY_CAST(DateofService AS DATE))=@mo)
        ORDER BY TRY_CAST(DateofService AS DATE);';
    EXEC sp_executesql @PmsSql, N'@yr INT, @mo INT', @yr=@Year, @mo=@Month;
END;
GO

PRINT '32_NW_ExecutiveSummary_Detail.sql completed.';
GO
