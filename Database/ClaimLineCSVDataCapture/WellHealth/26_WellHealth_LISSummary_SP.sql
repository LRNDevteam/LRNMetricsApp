/* =============================================================================
   WellHealth - LIS Summary built entirely in SQL
   Database : WellHealth

   Same design as Analyze Pathology (26_AnalyzePathology_LISSummary_SP.sql): rows,
   logic, sort order, month / year / grand totals and the KPI cards all come from
   dbo.usp_GetWH_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate).
             'Received' (ReqReceivedDate) and 'Resulted' (ReqReportedDate) stay
             available for the page's date-type selector.
   Counting: Count (Accession Number) - non-blank Accession per LIMSMaster row.
   Filters : Panel = TestCategory, Clinic = ClinicName, Ref Phy = DoctorFullName
             (the populated WellHealth LIMS columns; same values as the page's dropdowns).

   Rows (client logic sheet):
     A  Billable                  New Status = Billable
     1    Billed                  Billable AND Bill Category = Billed
     *      Billed Via CMD        Billable AND Bill Category = Billed
     2    Not Billed              Billable AND Bill Category = Unbilled
     *      Ready to bill         ... AND the accession has no claim in ClaimLevelData
     *      Entered not billed    ... AND the accession has a claim in ClaimLevelData
          (Same as the Executive Summary D1 / D2. LIMSMaster.SubStatus never carries
           Ready to Bill / Entered Not Billed for Well Health; Ready + Entered = Not Billed.)
     B  Cancelled/Rejected        New Status = Cancelled/Rejected (+ Billed / Unbilled)
     C  Client Bill               New Status = Client Bill        (+ Billed / Unbilled)
     D  Billing Hold              New Status = Billing Hold       (+ Billed / Unbilled)
     E  Self Pay                  New Status = Self Pay           (+ Billed / Unbilled)
     F  Yet to be validated       New Status = Yet to be validated
     G  System Test               New Status = System Test
     H  Duplicate                 New Status = Duplicate
        Total Samples             all samples (returned as the grand-total row)

   Objects:
     dbo.WH_LIS_StatusSummary      day x dimension x status aggregate
     dbo.usp_RefreshWH_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetWH_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'WellHealth'
BEGIN
	RAISERROR('Run 26_WellHealth_LISSummary_SP.sql on the WellHealth database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.WH_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.WH_LIS_StatusSummary
(
	DateType     VARCHAR(10)    NOT NULL,
	GroupDate    DATE           NOT NULL,
	Panel        NVARCHAR(400)  NOT NULL,
	Clinic       NVARCHAR(400)  NOT NULL,
	RefPhy       NVARCHAR(400)  NOT NULL,
	SalesRep     NVARCHAR(400)  NOT NULL,
	Collector    NVARCHAR(400)  NOT NULL,
	NewStatus    NVARCHAR(100)  NOT NULL,
	BillCategory NVARCHAR(100)  NOT NULL,
	SubStatus    NVARCHAR(100)  NOT NULL,
	InPms        BIT            NOT NULL CONSTRAINT DF_WH_LIS_StatusSummary_InPms DEFAULT (0),
	SampleCount  INT            NOT NULL,
	RefreshedAt  DATETIME       NOT NULL CONSTRAINT DF_WH_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF COL_LENGTH('dbo.WH_LIS_StatusSummary', 'InPms') IS NULL
	ALTER TABLE dbo.WH_LIS_StatusSummary
		ADD InPms BIT NOT NULL CONSTRAINT DF_WH_LIS_StatusSummary_InPms DEFAULT (0);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_WH_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.WH_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_WH_LIS_StatusSummary_Date
		ON dbo.WH_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshWH_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	-- Every accession with a claim in PMS (any date, any status) - same set as the Executive Summary.
	DROP TABLE IF EXISTS #PmsAcc;
	CREATE TABLE #PmsAcc (Acc NVARCHAR(200) COLLATE DATABASE_DEFAULT NOT NULL PRIMARY KEY);
	INSERT INTO #PmsAcc (Acc)
	SELECT DISTINCT UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))))
	FROM dbo.ClaimLevelData c
	WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(200), c.AccessionNumber))), N'') IS NOT NULL;

	TRUNCATE TABLE dbo.WH_LIS_StatusSummary;

	INSERT INTO dbo.WH_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 NewStatus, BillCategory, SubStatus, InPms, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   ISNULL(LTRIM(RTRIM(l.TestCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
		   ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
		   N'',
		   N'',
		   ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
		   p.InPms,
		   COUNT(NULLIF(LTRIM(RTRIM(l.Accession)), N'')),
		   GETDATE()
	FROM dbo.LIMSMaster l
	CROSS APPLY (SELECT InPms = CAST(CASE WHEN EXISTS (
			SELECT 1 FROM #PmsAcc a
			WHERE a.Acc = UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(200), l.Accession))))) THEN 1 ELSE 0 END AS BIT)) p
	CROSS APPLY (VALUES
		('Collected', TRY_CAST(l.RequestCollectDate AS DATE)),
		('Received',  TRY_CAST(l.ReqReceivedDate    AS DATE)),
		('Resulted',  TRY_CAST(l.ReqReportedDate    AS DATE))
	) d(DateType, GroupDate)
	WHERE d.GroupDate IS NOT NULL
	  AND YEAR(d.GroupDate) > 1900
	GROUP BY d.DateType, d.GroupDate,
			 ISNULL(LTRIM(RTRIM(l.TestCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
			 ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
			 ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
			 p.InPms;

	PRINT 'usp_RefreshWH_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetWH_LISSummary
(
	@DateType  VARCHAR(10)   = 'Collected',
	@DateFrom  DATE          = NULL,
	@DateTo    DATE          = NULL,
	@Panel     NVARCHAR(MAX) = NULL,
	@Clinic    NVARCHAR(MAX) = NULL,
	@RefPhy    NVARCHAR(MAX) = NULL,
	@SalesRep  NVARCHAR(MAX) = NULL,
	@Collector NVARCHAR(MAX) = NULL
)
AS
BEGIN
	SET NOCOUNT ON;

	SET @DateType = CASE WHEN @DateType IN ('Received', 'Resulted') THEN @DateType ELSE 'Collected' END;

	DECLARE @Filters TABLE (Dim VARCHAR(10) NOT NULL, Val NVARCHAR(400) NOT NULL);
	INSERT INTO @Filters (Dim, Val)
	SELECT f.Dim, LTRIM(RTRIM(s.value))
	FROM (VALUES ('Panel', @Panel), ('Clinic', @Clinic), ('RefPhy', @RefPhy),
				 ('SalesRep', @SalesRep), ('Collector', @Collector)) f(Dim, Vals)
	CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N'|') s
	WHERE LTRIM(RTRIM(s.value)) <> N'';

	DROP TABLE IF EXISTS #F;
	SELECT YEAR(a.GroupDate) AS Y, MONTH(a.GroupDate) AS M,
		   a.NewStatus, a.BillCategory, a.InPms, SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.WH_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate), a.NewStatus, a.BillCategory, a.InPms;

	-- Month rows, year rows (RowMonth = 0) and the grand total (0, 0).
	DROP TABLE IF EXISTS #M;
	SELECT
		ISNULL(Y, 0) AS RowYear,
		CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' THEN Cnt END), 0) AS Billable,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Cat = 'B' THEN Cnt END), 0) AS Billed,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Cat = 'U' THEN Cnt END), 0) AS NotBilled,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Cat = 'U' AND InPms = 0 THEN Cnt END), 0) AS ReadyToBill,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Cat = 'U' AND InPms = 1 THEN Cnt END), 0) AS EnteredNotBilled,
		ISNULL(SUM(CASE WHEN s.St = 'CANCELLED' THEN Cnt END), 0) AS Cancelled,
		ISNULL(SUM(CASE WHEN s.St = 'CANCELLED' AND s.Cat = 'B' THEN Cnt END), 0) AS CancelledBilled,
		ISNULL(SUM(CASE WHEN s.St = 'CANCELLED' AND s.Cat = 'U' THEN Cnt END), 0) AS CancelledUnbilled,
		ISNULL(SUM(CASE WHEN s.St = 'CLIENTBILL' THEN Cnt END), 0) AS ClientBill,
		ISNULL(SUM(CASE WHEN s.St = 'CLIENTBILL' AND s.Cat = 'B' THEN Cnt END), 0) AS ClientBillBilled,
		ISNULL(SUM(CASE WHEN s.St = 'CLIENTBILL' AND s.Cat = 'U' THEN Cnt END), 0) AS ClientBillUnbilled,
		ISNULL(SUM(CASE WHEN s.St = 'HOLD' THEN Cnt END), 0) AS BillingHold,
		ISNULL(SUM(CASE WHEN s.St = 'HOLD' AND s.Cat = 'B' THEN Cnt END), 0) AS BillingHoldBilled,
		ISNULL(SUM(CASE WHEN s.St = 'HOLD' AND s.Cat = 'U' THEN Cnt END), 0) AS BillingHoldUnbilled,
		ISNULL(SUM(CASE WHEN s.St = 'SELFPAY' THEN Cnt END), 0) AS SelfPay,
		ISNULL(SUM(CASE WHEN s.St = 'SELFPAY' AND s.Cat = 'B' THEN Cnt END), 0) AS SelfPayBilled,
		ISNULL(SUM(CASE WHEN s.St = 'SELFPAY' AND s.Cat = 'U' THEN Cnt END), 0) AS SelfPayUnbilled,
		ISNULL(SUM(CASE WHEN s.St = 'YTBV' THEN Cnt END), 0) AS YetToBeValidated,
		ISNULL(SUM(CASE WHEN s.St = 'SYSTEMTEST' THEN Cnt END), 0) AS SystemTest,
		ISNULL(SUM(CASE WHEN s.St = 'DUPLICATE' THEN Cnt END), 0) AS Duplicate,
		ISNULL(SUM(Cnt), 0) AS TotalSamples
	INTO #M
	FROM #F
	CROSS APPLY (SELECT
		St = CASE
				WHEN NewStatus = N'Billable' THEN 'BILLABLE'
				WHEN NewStatus IN (N'Cancelled/Rejected', N'Canceled/Rejected') THEN 'CANCELLED'
				WHEN NewStatus = N'Client Bill' THEN 'CLIENTBILL'
				WHEN NewStatus = N'Billing Hold' THEN 'HOLD'
				WHEN NewStatus = N'Self Pay' THEN 'SELFPAY'
				WHEN NewStatus IN (N'Yet to be validated', N'Yet to Be Validate', N'Yet be validated') THEN 'YTBV'
				WHEN NewStatus = N'System Test' THEN 'SYSTEMTEST'
				WHEN NewStatus IN (N'Duplicate', N'Duplicates') THEN 'DUPLICATE'
				ELSE ''
			 END,
		Cat = CASE
				WHEN BillCategory = N'Billed' THEN 'B'
				WHEN BillCategory IN (N'Unbilled', N'Not Billed') THEN 'U'
				ELSE ''
			  END) s
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT r.SortOrder, r.Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   m.RowYear, m.RowMonth, r.SampleCount
	FROM #M m
	CROSS APPLY (VALUES
		( 10, N'A',        N'Billable',            0, N'New Status = Billable', 0, m.Billable),
		( 20, N'1',        N'Billed',              1, N'New Status = Billable AND Bill Category = Billed', 0, m.Billed),
		( 30, NCHAR(8226), N'Billed Via CMD',      2, N'New Status = Billable AND Bill Category = Billed', 0, m.Billed),
		( 40, N'2',        N'Not Billed',          1, N'New Status = Billable AND Bill Category = Unbilled', 0, m.NotBilled),
		( 50, NCHAR(8226), N'Ready to bill',       2, N'New Status = Billable AND Bill Category = Unbilled AND Accession not in ClaimLevelData', 0, m.ReadyToBill),
		( 60, NCHAR(8226), N'Entered not billed',  2, N'New Status = Billable AND Bill Category = Unbilled AND Accession in ClaimLevelData', 0, m.EnteredNotBilled),
		( 70, N'B',        N'Cancelled/Rejected',  0, N'New Status = Cancelled/Rejected', 0, m.Cancelled),
		( 72, N'1',        N'Billed',              1, N'New Status = Cancelled/Rejected AND Bill Category = Billed', 0, m.CancelledBilled),
		( 74, N'2',        N'Unbilled',            1, N'New Status = Cancelled/Rejected AND Bill Category = Unbilled', 0, m.CancelledUnbilled),
		( 80, N'C',        N'Client Bill',         0, N'New Status = Client Bill', 0, m.ClientBill),
		( 82, N'1',        N'Billed',              1, N'New Status = Client Bill AND Bill Category = Billed', 0, m.ClientBillBilled),
		( 84, N'2',        N'Unbilled',            1, N'New Status = Client Bill AND Bill Category = Unbilled', 0, m.ClientBillUnbilled),
		( 90, N'D',        N'Billing Hold',        0, N'New Status = Billing Hold', 0, m.BillingHold),
		( 92, N'1',        N'Billed',              1, N'New Status = Billing Hold AND Bill Category = Billed', 0, m.BillingHoldBilled),
		( 94, N'2',        N'Unbilled',            1, N'New Status = Billing Hold AND Bill Category = Unbilled', 0, m.BillingHoldUnbilled),
		(100, N'E',        N'Self Pay',            0, N'New Status = Self Pay', 0, m.SelfPay),
		(102, N'1',        N'Billed',              1, N'New Status = Self Pay AND Bill Category = Billed', 0, m.SelfPayBilled),
		(104, N'2',        N'Unbilled',            1, N'New Status = Self Pay AND Bill Category = Unbilled', 0, m.SelfPayUnbilled),
		(110, N'F',        N'Yet to be validated', 0, N'New Status = Yet to be validated', 0, m.YetToBeValidated),
		(120, N'G',        N'System Test',         0, N'New Status = System Test', 0, m.SystemTest),
		(130, N'H',        N'Duplicate',           0, N'New Status = Duplicate', 0, m.Duplicate),
		(999, N'',         N'Total Samples',       0, N'Count (Accession Number)', 1, m.TotalSamples)
	) r(SortOrder, Code, Description, RowLevel, Logic, IsGrandTotal, SampleCount)
	ORDER BY r.SortOrder, m.RowYear, m.RowMonth;

	-- Result set 2: KPI cards.
	SELECT TotalSamples, Billed AS BilledCount, NotBilled AS UnbilledCount, SelfPay AS SelfPayCount
	FROM #M
	WHERE RowYear = 0 AND RowMonth = 0;
END;
GO

EXEC dbo.usp_RefreshWH_LISSummary;
GO

PRINT '26_WellHealth_LISSummary_SP.sql completed.';
GO
