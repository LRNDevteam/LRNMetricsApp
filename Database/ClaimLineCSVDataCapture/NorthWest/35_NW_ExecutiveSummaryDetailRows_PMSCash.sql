-- ============================================================
-- NorthWest – PMS/Cash Detail Rows SP  (generic name, NW DB copy)
-- File : 35_NW_ExecutiveSummaryDetailRows_PMSCash.sql
-- DB   : NorthWest_LRN
--
-- dbo.usp_GetExecutiveSummaryDetail_PMSCash
--   Returns raw ClaimLevelData rows for a given RowCode / period.
--   NW-specific columns: Billed, ClaimType, ActualPayment, DuplicatePayment.
-- ============================================================
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetExecutiveSummaryDetail_PMSCash
(
    @RowCode  NVARCHAR(100) = '',
    @Year     INT           = 0,
    @Month    INT           = 0
)
AS
BEGIN
    SET NOCOUNT ON;

    -- ════════════════════════════════════════════════════════════════════
    --  Dynamic column detection – ClaimLevelData
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @BilledCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
        AND name IN ('Billed','BillStatus','BillingStatus','BilledStatus')
        ORDER BY CASE name WHEN 'Billed' THEN 0 WHEN 'BillStatus' THEN 1 WHEN 'BillingStatus' THEN 2 ELSE 3 END);
    DECLARE @ClaimTypeCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
        AND name IN ('ClaimType','ClaimCategory')
        ORDER BY CASE name WHEN 'ClaimType' THEN 0 ELSE 1 END);
    DECLARE @ActualPayCol SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
        AND name IN ('ActualPayment','ActualPay')
        ORDER BY CASE name WHEN 'ActualPayment' THEN 0 ELSE 1 END);
    DECLARE @DupPayCol    SYSNAME = (SELECT TOP 1 name FROM sys.columns WHERE object_id=OBJECT_ID('dbo.ClaimLevelData')
        AND name IN ('DuplicatePayment','DuplicatePay')
        ORDER BY CASE name WHEN 'DuplicatePayment' THEN 0 ELSE 1 END);

    -- Required columns guard
    IF @BilledCol IS NULL OR @ClaimTypeCol IS NULL
    BEGIN
        SELECT TOP 0
            CAST(NULL AS NVARCHAR(100)) AS AccessionNumber,
            CAST(NULL AS DATE)          AS DateofService,
            CAST(NULL AS NVARCHAR(50))  AS Billed,
            CAST(NULL AS NVARCHAR(200)) AS ClaimType,
            CAST(NULL AS NVARCHAR(200)) AS ClaimStatus,
            CAST(NULL AS DECIMAL(18,2)) AS ChargeAmount,
            CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment,
            CAST(NULL AS DECIMAL(18,2)) AS ActualPayment,
            CAST(NULL AS DECIMAL(18,2)) AS DuplicatePayment,
            CAST(NULL AS DECIMAL(18,2)) AS PatientPayment,
            CAST(NULL AS DECIMAL(18,2)) AS InsuranceAdjustments,
            CAST(NULL AS DECIMAL(18,2)) AS PatientAdjustments,
            CAST(NULL AS DECIMAL(18,2)) AS InsuranceBalance,
            CAST(NULL AS DECIMAL(18,2)) AS PatientBalance
        WHERE 1=0;
        RETURN;
    END

    -- ════════════════════════════════════════════════════════════════════
    --  WHERE clause by RowCode
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @PmsWhere NVARCHAR(MAX) = N'';

    -- ── PMS rows ─────────────────────────────────────────────────────────
    IF @RowCode='G'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE IF @RowCode='G.1'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='G.2'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='G.3'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'')';
    ELSE IF @RowCode='H'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''') IN ('''',''Unbilled'') AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='H.1'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed - Client'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='H.2'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Self Pay'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='H.3'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Yet to be validate'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='H.4'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Test Patient'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='H.5'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Rejections'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='J'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N']=''Test Patient Entries''';
    ELSE IF @RowCode='K'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N']=''ADCS - Invoice''';
    ELSE IF @RowCode='M'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='N'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='O'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'')';
    ELSE IF @RowCode='P'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''No Response''';
    ELSE IF @RowCode='Q'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Billed Amount 0''';
    ELSE IF @RowCode='R'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='S'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='S.1'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] IN (''Claim Submitted in Webpm'',''Claim Submitted in Daqbilling'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='S.2'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Partially Denied''';
    ELSE IF @RowCode='S.3'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'')';
    -- ── Cash rows ─────────────────────────────────────────────────────────
    ELSE IF @RowCode='T'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE IF @RowCode='T.1'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='T.2'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='T.3'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'')';
    ELSE IF @RowCode='U'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''') IN ('''',''Unbilled'') AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='U.1'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed - Client'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='U.2'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Self Pay'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='U.3'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Yet to be validate'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='U.4'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Rejections'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='V'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Billed Amount 0''';
    ELSE IF @RowCode='W'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N']=''ADCS - Invoice''';
    ELSE IF @RowCode='X'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='X.1'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='X.2'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='Y'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='Z'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] IN (''Claim Submitted in Webpm'',''Claim Submitted in Daqbilling'')';
    ELSE IF @RowCode='AA'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE IF @RowCode='AA.1'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Fully Paid''';
    ELSE IF @RowCode='AA.2'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Partially Paid'',''Patient Responsibility'',''Patient Payment'',''Complete W/O'')';
    ELSE IF @RowCode='AB'
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='AC'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''') IN (''Billed'',''Billed - Client'') AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';
    ELSE IF @RowCode='AC.1'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] IN (''Claim Submitted in Webpm'',''Claim Submitted in Daqbilling'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'',''Partially Denied'',''No Response'')';
    ELSE IF @RowCode='AC.2'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus=''Partially Denied''';
    ELSE IF @RowCode='AC.3'
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ClaimStatus IN (''Fully Denied'',''FullyDenied'')';
    -- ── Avg rows – show same base data as AD ─────────────────────────────
    ELSE IF @RowCode IN ('AD','AE','AF')
        SET @PmsWhere = N'ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')=''Billed'' AND [' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'') AND ISNULL(ClaimStatus,'''')<>''Billed Amount 0''';
    ELSE
        SET @PmsWhere = N'[' + @ClaimTypeCol + N'] NOT IN (''ADCS - Invoice'',''Test Patient Entries'')';

    -- ════════════════════════════════════════════════════════════════════
    --  Optional column expressions
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @ActExpr NVARCHAR(300) = CASE WHEN @ActualPayCol IS NOT NULL
        THEN N'ISNULL(TRY_CAST([' + @ActualPayCol + N'] AS DECIMAL(18,2)),0)' ELSE N'CAST(0 AS DECIMAL(18,2))' END;
    DECLARE @DupExpr NVARCHAR(300) = CASE WHEN @DupPayCol IS NOT NULL
        THEN N'ISNULL(TRY_CAST([' + @DupPayCol   + N'] AS DECIMAL(18,2)),0)' ELSE N'CAST(0 AS DECIMAL(18,2))' END;

    -- ════════════════════════════════════════════════════════════════════
    --  Execute
    -- ════════════════════════════════════════════════════════════════════
    DECLARE @Sql NVARCHAR(MAX) = N'
        SELECT
            LTRIM(RTRIM(ISNULL(AccessionNumber,'''')))              AS AccessionNumber,
            TRY_CAST(DateofService AS DATE)                          AS DateofService,
            ISNULL(LTRIM(RTRIM([' + @BilledCol + N'])),'''')        AS Billed,
            ISNULL(LTRIM(RTRIM([' + @ClaimTypeCol + N'])),'''')     AS ClaimType,
            ISNULL(LTRIM(RTRIM(ClaimStatus)),'''')                   AS ClaimStatus,
            ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)),0) AS ChargeAmount,
            ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)),0) AS InsurancePayment,
            ' + @ActExpr + N'                                          AS ActualPayment,
            ' + @DupExpr + N'                                          AS DuplicatePayment,
            ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)),0) AS PatientPayment,
            ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)),0) AS InsuranceAdjustments,
            ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)),0) AS PatientAdjustments,
            ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)),0) AS InsuranceBalance,
            ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)),0) AS PatientBalance
        FROM dbo.ClaimLevelData
        WHERE ' + @PmsWhere + N'
          AND TRY_CAST(DateofService AS DATE) IS NOT NULL
          AND (@yr=0 OR YEAR(TRY_CAST(DateofService AS DATE))=@yr)
          AND (@mo=0 OR MONTH(TRY_CAST(DateofService AS DATE))=@mo)
        ORDER BY TRY_CAST(DateofService AS DATE);';

    EXEC sp_executesql @Sql, N'@yr INT, @mo INT', @yr=@Year, @mo=@Month;
END;
GO

PRINT '35_NW_ExecutiveSummaryDetailRows_PMSCash.sql completed.';
GO
