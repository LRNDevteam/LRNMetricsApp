/* =============================================================================
   Analyze Pathology (prefix AnP_) - Collection Summary on PaymentPostedDate
   Database: AnalyzePathology
   Run after 28_AnalyzePathology_CollectionSummary_NewLogic.sql (which moves
   fn_AnP_CS_Claims - Monthly, Weekly, Panel vs Payment and the other client-logic
   sections - to PaymentPostedDate).

   The client's "Posted Date" is PaymentPostedDate (claim file "Posted Date").
   This script moves the remaining Collection Summary SPs off CheckDate:
     usp_GetAnP_CS_AvgPayments        Check Date filter
     usp_GetAnP_CS_StatusSummary      Check Date filter
     usp_GetAnP_CS_ProviderSummary    Check Date filter
     usp_GetAnP_CS_RepVsPayment       year / month columns + Check Date filter
     usp_RefreshAnP_CS_RepVsPayment   year / month columns
     usp_GetCollection{Claim|Line}LevelExport{Buckets|DataByDateRange}
                                      Check Date filter (queued Collection Report raw sheets)
   Parameter and output column names (@CheckDateFrom/@CheckDateTo, CheckYear/CheckMonth)
   are unchanged so the dashboard contract stays the same.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'AnalyzePathology'
BEGIN
    RAISERROR('Run 31_AnalyzePathology_CollectionSummary_PaymentPostedDate.sql on the AnalyzePathology database.', 16, 1);
    SET NOEXEC ON;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_AvgPayments
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL,
    @LastMonths      INT           = 6
AS
BEGIN
    SET NOCOUNT ON;

    IF ISNULL(@LastMonths, 0) NOT IN (3, 6)
        SET @LastMonths = 6;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 450)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT =
        CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    DECLARE @WindowEnd DATE;

    IF OBJECT_ID(N'dbo.LineClaimFileLogs', N'U') IS NOT NULL
        SELECT @WindowEnd = MAX(TRY_CONVERT(DATE,
            REPLACE(LTRIM(RTRIM(SUBSTRING(WeekFolder, CHARINDEX(' - ', WeekFolder) + 3, 50))), '.', '/'),
            101))
        FROM dbo.LineClaimFileLogs
        WHERE NULLIF(LTRIM(RTRIM(RunId)), '') IS NOT NULL
          AND CHARINDEX(' - ', WeekFolder) > 0;

    IF @WindowEnd IS NULL
        SELECT @WindowEnd = MAX(TRY_CAST(DateOfService AS DATE))
        FROM dbo.ClaimLevelData;

    DECLARE @Cutoff DATE = DATEADD(MONTH, -@LastMonths, @WindowEnd);
    DECLARE @WindowFrom DATE = DATEADD(DAY, 1, @Cutoff);

    ;WITH base AS
    (
        SELECT
            LTRIM(RTRIM(ISNULL(Panelname, 'Unknown')))     AS PanelName,
            LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) AS PayerName,
            ClaimID,
            TRY_CAST(ChargeAmount AS DECIMAL(18,2))        AS Chg,
            TRY_CAST(InsurancePayment AS DECIMAL(18,2))    AS InsPay,
            NULLIF(LTRIM(RTRIM(FullyPaidCount)), '')       AS FullyPaidFlag,
            NULLIF(LTRIM(RTRIM(Adjudicated)), '')    AS AdjudicatedFlag,
            TRY_CAST(AdjudicatedAmount AS DECIMAL(18,2))  AS AdjudicatedAmt,
            NULLIF(LTRIM(RTRIM(Bucket30)), '')        AS Bucket30Flag,
            TRY_CAST(Bucket30Amount AS DECIMAL(18,2))      AS Bucket30Amt,
            NULLIF(LTRIM(RTRIM(Bucket60)), '')        AS Bucket60Flag,
            TRY_CAST(Bucket60Amount AS DECIMAL(18,2))      AS Bucket60Amt
        FROM dbo.ClaimLevelData
        CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) AS PostedDt) pd
        WHERE TRY_CAST(DateOfService AS DATE) >= @WindowFrom
          AND TRY_CAST(DateOfService AS DATE) < @WindowEnd
          AND NULLIF(LTRIM(RTRIM(Panelname)), '') IS NOT NULL
          AND NULLIF(LTRIM(RTRIM(PayerName_Raw)), '') IS NOT NULL
          AND (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname, 'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
          AND (@DosTo IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR pd.PostedDt >= @CheckDateFrom)
          AND (@CheckDateTo IS NULL OR pd.PostedDt <= @CheckDateTo)
    )
    SELECT
        PanelName,
        PayerName,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '')) AS NoOfClaims,
        ISNULL(SUM(Chg), 0) AS TotalCharges,
        ISNULL(SUM(InsPay), 0) AS CarrierPayment,
        COUNT(CASE WHEN FullyPaidFlag IS NOT NULL THEN ClaimID END) AS FullyPaidCount,
        ISNULL(SUM(CASE WHEN FullyPaidFlag IS NOT NULL THEN InsPay ELSE 0 END), 0) AS FullyPaidAmount,
        COUNT(CASE WHEN AdjudicatedFlag IS NOT NULL THEN ClaimID END) AS AdjudicatedCount,
        ISNULL(SUM(CASE WHEN AdjudicatedFlag IS NOT NULL THEN AdjudicatedAmt ELSE 0 END), 0) AS AdjudicatedAmount,
        COUNT(CASE WHEN Bucket30Flag IS NOT NULL THEN ClaimID END) AS Days30Count,
        ISNULL(SUM(CASE WHEN Bucket30Flag IS NOT NULL THEN Bucket30Amt ELSE 0 END), 0) AS Days30Amount,
        COUNT(CASE WHEN Bucket60Flag IS NOT NULL THEN ClaimID END) AS Days60Count,
        ISNULL(SUM(CASE WHEN Bucket60Flag IS NOT NULL THEN Bucket60Amt ELSE 0 END), 0) AS Days60Amount
    FROM base
    GROUP BY PanelName, PayerName
    ORDER BY PanelName, NoOfClaims DESC, PayerName;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_StatusSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
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
        FROM   dbo.AnP_CS_StatusSummary;
        RETURN;
    END;

    DECLARE @PayerList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(450) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    SELECT
        ISNULL(LTRIM(RTRIM(ClaimStatus)),            '(blank)') AS ClaimStatus,
        ISNULL(LTRIM(RTRIM(Panelname)),              '(blank)') AS PanelName,
        ISNULL(LTRIM(RTRIM(CPTCodeXUnitsXModifier)), '(blank)') AS CptCode,
        ISNULL(LTRIM(RTRIM(PayerName_Raw)),          '(blank)') AS PayerName,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''))                    AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)         AS InsurancePayment,
        ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0)         AS InsuranceBalance,
        ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0)         AS PatientBalance
    FROM dbo.ClaimLevelData
    CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) AS PostedDt) pd
    WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
      AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR pd.PostedDt >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR pd.PostedDt <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(ClaimStatus)),
        LTRIM(RTRIM(Panelname)),
        LTRIM(RTRIM(CPTCodeXUnitsXModifier)),
        LTRIM(RTRIM(PayerName_Raw));
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_ProviderSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
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
        SELECT ProviderRank, ReferringProvider, NoOfClaims,
               InsurancePayment AS InsurancePayments,
               InsuranceBalance, PatientBalance
        FROM   dbo.AnP_CS_ProviderSummary
        ORDER  BY ProviderRank;
        RETURN;
    END;

    DECLARE @ProvCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (
                N'ReferringProvider', N'ReferringPhysician',
                N'Provider', N'ProviderName', N'OrderingProvider', N'DoctorFullName', N'BillingProvider')
        ORDER BY CASE c.name
            WHEN N'ReferringProvider' THEN 1
            WHEN N'ReferringPhysician' THEN 2
            WHEN N'Provider' THEN 3
            WHEN N'ProviderName' THEN 4
            WHEN N'OrderingProvider' THEN 5
            WHEN N'DoctorFullName' THEN 6
            WHEN N'BillingProvider' THEN 7
            ELSE 8
        END
    );

    IF @ProvCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS INT) AS ProviderRank,
            CAST(NULL AS NVARCHAR(500)) AS ReferringProvider,
            CAST(NULL AS INT) AS NoOfClaims,
            CAST(NULL AS DECIMAL(18,2)) AS InsurancePayments,
            CAST(NULL AS DECIMAL(18,2)) AS InsuranceBalance,
            CAST(NULL AS DECIMAL(18,2)) AS PatientBalance;
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX) = N'
    ;WITH agg AS (
        SELECT
            LTRIM(RTRIM(' + QUOTENAME(@ProvCol) + N')) AS ReferringProvider,
            COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), '''')) AS NoOfClaims,
            ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayments,
            ISNULL(SUM(TRY_CAST(InsuranceBalance AS DECIMAL(18,2))), 0) AS InsuranceBalance,
            ISNULL(SUM(TRY_CAST(PatientBalance   AS DECIMAL(18,2))), 0) AS PatientBalance
        FROM dbo.ClaimLevelData
        CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) AS PostedDt) pd
        WHERE ' + QUOTENAME(@ProvCol) + N' IS NOT NULL
          AND LTRIM(RTRIM(' + QUOTENAME(@ProvCol) + N')) <> ''''
          AND (@PayerNames IS NULL OR NULLIF(LTRIM(RTRIM(@PayerNames)), '''') IS NULL
               OR LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown''))) IN (
                    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, ''|'')
                    WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL))
          AND (@PanelNames IS NULL OR NULLIF(LTRIM(RTRIM(@PanelNames)), '''') IS NULL
               OR LTRIM(RTRIM(ISNULL(Panelname, ''Unknown''))) IN (
                    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, ''|'')
                    WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR pd.PostedDt >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR pd.PostedDt <= @CheckDateTo)
        GROUP BY LTRIM(RTRIM(' + QUOTENAME(@ProvCol) + N'))
    )
    SELECT
        CAST(ROW_NUMBER() OVER (ORDER BY NoOfClaims DESC) AS INT) AS ProviderRank,
        ReferringProvider, NoOfClaims,
        InsurancePayments, InsuranceBalance, PatientBalance
    FROM agg
    ORDER BY ProviderRank;';

    EXEC sys.sp_executesql @sql,
        N'@PayerNames NVARCHAR(MAX), @PanelNames NVARCHAR(MAX),
          @DosFrom DATE, @DosTo DATE, @FirstBillFrom DATE, @FirstBillTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @CheckDateFrom=@CheckDateFrom, @CheckDateTo=@CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_CS_RepVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
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
        SELECT SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment
        FROM   dbo.AnP_CS_RepVsPayment
        ORDER  BY SalesRepName, CheckYear, CheckMonth;
        RETURN;
    END;

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

    IF @RepCol IS NULL
    BEGIN
        SELECT TOP (0)
            CAST(NULL AS NVARCHAR(500)) AS SalesRepName,
            CAST(NULL AS INT) AS CheckYear,
            CAST(NULL AS INT) AS CheckMonth,
            CAST(NULL AS INT) AS NoOfClaims,
            CAST(NULL AS DECIMAL(18,2)) AS InsurancePayment;
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX) = N'
    SELECT
        LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')) AS SalesRepName,
        CAST(YEAR (pd.PostedDt) AS INT) AS CheckYear,
        CAST(MONTH(pd.PostedDt) AS INT) AS CheckMonth,
        COUNT(NULLIF(LTRIM(RTRIM(ClaimID)), '''')) AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0) AS InsurancePayment
    FROM dbo.ClaimLevelData
    CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) AS PostedDt) pd
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND (' + QUOTENAME(@RepCol) + N' IS NOT NULL AND LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')) <> '''')
      AND (@PayerNames IS NULL OR NULLIF(LTRIM(RTRIM(@PayerNames)), '''') IS NULL
           OR LTRIM(RTRIM(ISNULL(PayerName_Raw, ''Unknown''))) IN (
                SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PayerNames, ''|'')
                WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL))
      AND (@PanelNames IS NULL OR NULLIF(LTRIM(RTRIM(@PanelNames)), '''') IS NULL
           OR LTRIM(RTRIM(ISNULL(Panelname, ''Unknown''))) IN (
                SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@PanelNames, ''|'')
                WHERE NULLIF(LTRIM(RTRIM(value)), '''') IS NOT NULL))
      AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
      AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
      AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
      AND (@CheckDateFrom IS NULL OR pd.PostedDt >= @CheckDateFrom)
      AND (@CheckDateTo   IS NULL OR pd.PostedDt <= @CheckDateTo)
    GROUP BY
        LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')),
        CAST(YEAR (pd.PostedDt) AS INT),
        CAST(MONTH(pd.PostedDt) AS INT)
    ORDER BY SalesRepName, CheckYear, CheckMonth;';

    EXEC sys.sp_executesql @sql,
        N'@PayerNames NVARCHAR(MAX), @PanelNames NVARCHAR(MAX),
          @DosFrom DATE, @DosTo DATE, @FirstBillFrom DATE, @FirstBillTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @CheckDateFrom=@CheckDateFrom, @CheckDateTo=@CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_CS_RepVsPayment
AS
BEGIN
    SET NOCOUNT ON;

    TRUNCATE TABLE dbo.AnP_CS_RepVsPayment;

    DECLARE @RepCol SYSNAME =
    (
        SELECT TOP (1) c.name
        FROM sys.columns c
        WHERE c.object_id = OBJECT_ID(N'dbo.ClaimLevelData')
          AND c.name IN (N'SalesRepname', N'SalesRepName', N'SalesRep', N'Sales Representative', N'SalesRep_Name')
        ORDER BY CASE c.name
            WHEN N'SalesRepname' THEN 1
            WHEN N'SalesRepName' THEN 2
            WHEN N'SalesRep' THEN 3
            ELSE 4
        END
    );

    IF @RepCol IS NULL
    BEGIN
        PRINT 'usp_RefreshAnP_CS_RepVsPayment skipped: no SalesRep* column on dbo.ClaimLevelData.';
        RETURN;
    END;

    DECLARE @sql NVARCHAR(MAX) = N'
    INSERT INTO dbo.AnP_CS_RepVsPayment
        (SalesRepName, CheckYear, CheckMonth, NoOfClaims, InsurancePayment, RefreshedAt)
    SELECT
        LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N'))                    AS SalesRepName,
        YEAR (pd.PostedDt)                                            AS CheckYear,
        CAST(MONTH(pd.PostedDt) AS TINYINT)                           AS CheckMonth,
        COUNT(DISTINCT NULLIF(LTRIM(RTRIM(ClaimID)), ''''))           AS NoOfClaims,
        ISNULL(SUM(TRY_CAST(InsurancePayment AS DECIMAL(18,2))), 0)   AS InsurancePayment,
        GETDATE()
    FROM dbo.ClaimLevelData
    CROSS APPLY (SELECT COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) AS PostedDt) pd
    WHERE ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0) > 0
      AND ' + QUOTENAME(@RepCol) + N' IS NOT NULL AND LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')) <> ''''
      AND pd.PostedDt IS NOT NULL
    GROUP BY
        LTRIM(RTRIM(' + QUOTENAME(@RepCol) + N')),
        YEAR (pd.PostedDt),
        MONTH(pd.PostedDt);';

    EXEC sys.sp_executesql @sql;
    PRINT 'usp_RefreshAnP_CS_RepVsPayment completed using column ' + @RepCol + N'.';
END
GO

/* -----------------------------------------------------------------------------
   Raw Claim / Line sheets of the queued Collection Report (LRN.ReportWorker):
   the Check Date filter reads PaymentPostedDate.
   ----------------------------------------------------------------------------- */
/* ---- 1) Collection ClaimLevel Buckets ----------------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionClaimLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    -- Temp tables (not table variables) so the dynamic panel-column SELECT can see them.
    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    -- Full filtered set (INCLUDES rows with a NULL/blank/unparseable FirstBilledDate so
    -- the sheet split never drops them). Panel predicate uses the lab-specific column,
    -- hence dynamic SQL. #Base / #PayerList / #PanelList are visible inside sp_executesql.
    CREATE TABLE #Base (FirstBilledDate DATE NULL, ClaimId NVARCHAR(100) NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #Base (FirstBilledDate, ClaimId)
        SELECT TRY_CAST(FirstBilledDate AS DATE), CAST(ClaimID AS NVARCHAR(100))
        FROM dbo.ClaimLevelData
        WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) <= @CheckDateTo);';

    EXEC sp_executesql @sql,
        N'@HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;

    DECLARE @cntClaim   INT = 0;
    DECLARE @cntUndated INT = 0;
    SELECT @cntClaim   = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntClaim <= @Threshold)
    BEGIN
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntClaim, 'All_Claim');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Claim'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Claim'
        FROM MonthCounts mc;

        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Claim');
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END

GO

/* ---- 2) Collection ClaimLevel Data By Date Range ------------------------ */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionClaimLevelExportDataByDateRange
    @FromDate         DATE          = NULL,
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'  -- 'ALL' = every row, 'UNDATED' = null-date rows, else date range
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        RETURN;   -- backward-compat: no dates + a non-ALL/UNDATED bucket -> empty set, not an error
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;

    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    -- SELECT * (every column); the C# writer drops RecordId / FileLogId from the sheet.
    -- Panel predicate uses the lab-specific column -> dynamic SQL.
    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT *
        FROM dbo.ClaimLevelData
        WHERE (
                  @BucketType = ''ALL''
               OR (@BucketType = ''UNDATED'' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
               OR (@BucketType NOT IN (''ALL'',''UNDATED'')
                   AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
                   AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
              )
          AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) <= @CheckDateTo)
        ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimID;';

    EXEC sp_executesql @sql,
        N'@BucketType VARCHAR(20), @FromDate DATE, @ToDate DATE,
          @HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @BucketType, @FromDate, @ToDate,
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;
END

GO

/* ---- 3) Collection LineLevel Buckets ------------------------------------ */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionLineLevelExportBuckets
    @Threshold        INT           = 50000,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',   -- line table uses Panelname for every lab
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    CREATE TABLE #Base (FirstBilledDate DATE NULL, ClaimId NVARCHAR(100) NULL);

    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #Base (FirstBilledDate, ClaimId)
        SELECT TRY_CAST(FirstBilledDate AS DATE), CAST(ClaimID AS NVARCHAR(100))
        FROM dbo.LineLevelData
        WHERE (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) <= @CheckDateTo);';

    EXEC sp_executesql @sql,
        N'@HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;

    DECLARE @cntLine    INT = 0;
    DECLARE @cntUndated INT = 0;
    SELECT @cntLine    = COUNT(*) FROM #Base;
    SELECT @cntUndated = COUNT(*) FROM #Base WHERE FirstBilledDate IS NULL;

    CREATE TABLE #Buckets
    (
        BucketType   VARCHAR(20),
        YearNo       INT           NULL,
        MonthNo      INT           NULL,
        FromDate     DATE          NULL,
        ToDate       DATE          NULL,
        RecordCount  INT,
        SheetName    NVARCHAR(50)
    );

    IF (@cntLine <= @Threshold)
    BEGIN
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        VALUES ('ALL', NULL, NULL, NULL, NULL, @cntLine, 'All_Line');
    END
    ELSE
    BEGIN
        ;WITH YearCounts AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo, COUNT(*) AS RecordCount
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'YEAR', yc.YearNo, NULL,
               DATEFROMPARTS(yc.YearNo, 1, 1),
               DATEFROMPARTS(yc.YearNo, 12, 31),
               yc.RecordCount,
               CASE WHEN yc.YearNo <= 1900 THEN 'Other' ELSE CAST(yc.YearNo AS VARCHAR(4)) END + '_Line'
        FROM YearCounts yc
        WHERE yc.RecordCount <= @Threshold;

        ;WITH LargeYears AS
        (
            SELECT YEAR(FirstBilledDate) AS YearNo
            FROM #Base
            WHERE FirstBilledDate IS NOT NULL
            GROUP BY YEAR(FirstBilledDate)
            HAVING COUNT(*) > @Threshold
        ),
        MonthCounts AS
        (
            SELECT YEAR(b.FirstBilledDate) AS YearNo,
                   MONTH(b.FirstBilledDate) AS MonthNo,
                   COUNT(*) AS RecordCount
            FROM #Base b
            INNER JOIN LargeYears y ON YEAR(b.FirstBilledDate) = y.YearNo
            GROUP BY YEAR(b.FirstBilledDate), MONTH(b.FirstBilledDate)
        )
        INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
        SELECT 'MONTH', mc.YearNo, mc.MonthNo,
               DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1),
               EOMONTH(DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)),
               mc.RecordCount,
               LEFT(DATENAME(MONTH, DATEFROMPARTS(mc.YearNo, mc.MonthNo, 1)), 3)
                   + CAST(mc.YearNo AS VARCHAR(4)) + '_Line'
        FROM MonthCounts mc;

        IF (@cntUndated > 0)
            INSERT INTO #Buckets (BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName)
            VALUES ('UNDATED', NULL, NULL, NULL, NULL, @cntUndated, 'Undated_Line');
    END

    SELECT BucketType, YearNo, MonthNo, FromDate, ToDate, RecordCount, SheetName
    FROM #Buckets
    ORDER BY CASE WHEN YearNo IS NULL THEN 1 ELSE 0 END, YearNo DESC, MonthNo ASC;
END

GO

/* ---- 4) Collection LineLevel Data By Date Range ------------------------- */
CREATE OR ALTER PROCEDURE dbo.usp_GetCollectionLineLevelExportDataByDateRange
    @FromDate         DATE          = NULL,
    @ToDate           DATE          = NULL,
    @PayerNames       NVARCHAR(MAX) = NULL,
    @PanelNames       NVARCHAR(MAX) = NULL,
    @PanelColumn      SYSNAME       = N'PanelName',
    @DosFrom          DATE          = NULL,
    @DosTo            DATE          = NULL,
    @CEDFrom          DATE          = NULL,   -- ChargeEnteredDate; unused by Collection, kept for C# param compat
    @CEDTo            DATE          = NULL,
    @FirstBilledFrom  DATE          = NULL,
    @FirstBilledTo    DATE          = NULL,
    @CheckDateFrom    DATE          = NULL,
    @CheckDateTo      DATE          = NULL,
    @BucketType       VARCHAR(20)   = 'RANGE'
AS
BEGIN
    SET NOCOUNT ON;

    IF NULLIF(LTRIM(RTRIM(@PanelColumn)), '') IS NULL SET @PanelColumn = N'PanelName';

    IF @BucketType NOT IN ('ALL','UNDATED') AND (@FromDate IS NULL OR @ToDate IS NULL)
    BEGIN
        RETURN;
    END;

    IF @BucketType NOT IN ('ALL','UNDATED') AND @FromDate > @ToDate
    BEGIN
        RAISERROR('FromDate cannot be greater than ToDate.', 16, 1);
        RETURN;
    END;

    -- COLLATE DATABASE_DEFAULT: temp tables otherwise take tempdb's collation, which can differ
    -- from the lab DB's column collation and cause "Cannot resolve the collation conflict" in the
    -- IN (...) comparisons below. DATABASE_DEFAULT forces the lab DB's collation to match the columns.
    CREATE TABLE #PayerList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);
    CREATE TABLE #PanelList (Value NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO #PayerList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PayerNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO #PanelList(Value)
        SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 200)
        FROM STRING_SPLIT(@PanelNames, '|')
        WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM #PanelList) THEN 1 ELSE 0 END;

    DECLARE @sql NVARCHAR(MAX) = N'
        SELECT *
        FROM dbo.LineLevelData
        WHERE (
                  @BucketType = ''ALL''
               OR (@BucketType = ''UNDATED'' AND TRY_CAST(FirstBilledDate AS DATE) IS NULL)
               OR (@BucketType NOT IN (''ALL'',''UNDATED'')
                   AND TRY_CAST(FirstBilledDate AS DATE) >= @FromDate
                   AND TRY_CAST(FirstBilledDate AS DATE) < DATEADD(DAY, 1, @ToDate))
              )
          AND (@HasPayerFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(PayerName_Raw,''Unknown''))),200) IN (SELECT Value FROM #PayerList))
          AND (@HasPanelFilter = 0 OR LEFT(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@PanelColumn) + N',''Unknown''))),200) IN (SELECT Value FROM #PanelList))
          AND (@DosFrom         IS NULL OR TRY_CAST(DateOfService     AS DATE) >= @DosFrom)
          AND (@DosTo           IS NULL OR TRY_CAST(DateOfService     AS DATE) <= @DosTo)
          AND (@CEDFrom         IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @CEDFrom)
          AND (@CEDTo           IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @CEDTo)
          AND (@FirstBilledFrom IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) >= @FirstBilledFrom)
          AND (@FirstBilledTo   IS NULL OR TRY_CAST(FirstBilledDate   AS DATE) <= @FirstBilledTo)
          AND (@CheckDateFrom   IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) >= @CheckDateFrom)
          AND (@CheckDateTo     IS NULL OR COALESCE(TRY_CONVERT(DATE, PaymentPostedDate, 101), TRY_CAST(PaymentPostedDate AS DATE)) <= @CheckDateTo)
        ORDER BY TRY_CAST(FirstBilledDate AS DATE), ClaimID;';

    EXEC sp_executesql @sql,
        N'@BucketType VARCHAR(20), @FromDate DATE, @ToDate DATE,
          @HasPayerFilter BIT, @HasPanelFilter BIT, @DosFrom DATE, @DosTo DATE,
          @CEDFrom DATE, @CEDTo DATE, @FirstBilledFrom DATE, @FirstBilledTo DATE,
          @CheckDateFrom DATE, @CheckDateTo DATE',
        @BucketType, @FromDate, @ToDate,
        @HasPayerFilter, @HasPanelFilter, @DosFrom, @DosTo,
        @CEDFrom, @CEDTo, @FirstBilledFrom, @FirstBilledTo, @CheckDateFrom, @CheckDateTo;
END

GO

EXEC dbo.usp_RefreshAnP_CS_RepVsPayment;
GO

PRINT '31_AnalyzePathology_CollectionSummary_PaymentPostedDate.sql completed.';
GO
