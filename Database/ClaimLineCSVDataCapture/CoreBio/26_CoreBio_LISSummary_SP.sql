/* =============================================================================
   CoreBio - LIS Summary built entirely in SQL
   Database : CoreBio

   Same design as Analyze Pathology (26_AnalyzePathology_LISSummary_SP.sql): rows,
   logic, sort order, month / year / grand totals and the KPI cards all come from
   dbo.usp_GetCB_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate).
             'Received' (ReqReceivedDate) and 'Resulted' (ReqReportedDate) stay
             available for the page's date-type selector.
   Counting: one LIMSMaster row = one sample.
   Filters : Panel = TestCategory, Clinic = ClinicName, Ref Phy = DoctorFullName
             (PanelName and Collector are empty on CoreBio).

   Rows (client logic sheet). A billed test is BillCategory = Billed OR
   BillingStatus = Billed. BillingStatus is empty on the current file, so
   BillCategory decides. When the two columns disagree, Billed wins so a sample
   is not counted in both Billed and Not Billed.
     A  Insurance Bill              NewStatus = Billable
     1    Billed                    ... AND (BillCategory = Billed OR BillingStatus = Billed)
     2    Not Billed                ... AND (BillCategory = Unbilled OR BillingStatus = Unbilled)
     *      Entered but not billed  ... AND SubStatus = Entered but not billed
     *      Ready to Bill           ... AND SubStatus = Ready to Bill
     B  Cancelled/Rejected          NewStatus = Cancelled/Rejected
     1    Billed                    ... AND billed
     C  Client Bill                 NewStatus = Client Bill OR Client Bills
     D  Newly Received Claims       NewStatus = Newly Received Claims
                                    OR Newly Received Samples (the value on the file)
     E  System Test                 NewStatus = System Test
     1    Billed                    ... AND billed
     F  Yet to be Validated         NewStatus = Yet to be Validated
                                    (sheet text "Yest to be Validated" included)
     G  CIP/Pending                 NewStatus = CIP/Pending
     1    Billed                    ... AND billed
        Total Samples               all samples (returned as the grand-total row)

   Objects:
     dbo.CB_LIS_StatusSummary      day x dimension x status aggregate
     dbo.usp_RefreshCB_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetCB_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
	RAISERROR('Run 26_CoreBio_LISSummary_SP.sql on the CoreBio database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.CB_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.CB_LIS_StatusSummary
(
	DateType      VARCHAR(10)    NOT NULL,
	GroupDate     DATE           NOT NULL,
	Panel         NVARCHAR(400)  NOT NULL,
	Clinic        NVARCHAR(400)  NOT NULL,
	RefPhy        NVARCHAR(400)  NOT NULL,
	SalesRep      NVARCHAR(400)  NOT NULL,
	Collector     NVARCHAR(400)  NOT NULL,
	NewStatus     NVARCHAR(100)  NOT NULL,
	BillCategory  NVARCHAR(100)  NOT NULL,
	BillingStatus NVARCHAR(100)  NOT NULL,
	SubStatus     NVARCHAR(100)  NOT NULL,
	SampleCount   INT            NOT NULL,
	RefreshedAt   DATETIME       NOT NULL CONSTRAINT DF_CB_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF COL_LENGTH(N'dbo.CB_LIS_StatusSummary', N'BillingStatus') IS NULL
	ALTER TABLE dbo.CB_LIS_StatusSummary ADD BillingStatus NVARCHAR(100) NOT NULL
		CONSTRAINT DF_CB_LIS_StatusSummary_BillingStatus DEFAULT (N'');
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_CB_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.CB_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_CB_LIS_StatusSummary_Date
		ON dbo.CB_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshCB_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.CB_LIS_StatusSummary;

	INSERT INTO dbo.CB_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 NewStatus, BillCategory, BillingStatus, SubStatus, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   ISNULL(LTRIM(RTRIM(l.TestCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
		   ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
		   N'',
		   N'',
		   ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillingStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
		   COUNT(*),
		   GETDATE()
	FROM dbo.LIMSMaster l
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
			 ISNULL(LTRIM(RTRIM(l.BillingStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N'');

	PRINT 'usp_RefreshCB_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetCB_LISSummary
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
		   a.NewStatus, a.BillCategory, a.BillingStatus, a.SubStatus, SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.CB_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate),
			 a.NewStatus, a.BillCategory, a.BillingStatus, a.SubStatus;

	-- Month rows, year rows (RowMonth = 0) and the grand total (0, 0).
	DROP TABLE IF EXISTS #M;
	SELECT
		ISNULL(Y, 0) AS RowYear,
		CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth,
		ISNULL(SUM(CASE WHEN s.St = 'INS' THEN Cnt END), 0) AS InsuranceBill,
		ISNULL(SUM(CASE WHEN s.St = 'INS' AND s.Billed = 1 THEN Cnt END), 0) AS InsuranceBilled,
		ISNULL(SUM(CASE WHEN s.St = 'INS' AND s.Unbilled = 1 THEN Cnt END), 0) AS InsuranceNotBilled,
		ISNULL(SUM(CASE WHEN s.St = 'INS' AND s.Unbilled = 1 AND s.Sub = 'ENTERED' THEN Cnt END), 0) AS EnteredNotBilled,
		ISNULL(SUM(CASE WHEN s.St = 'INS' AND s.Unbilled = 1 AND s.Sub = 'READY' THEN Cnt END), 0) AS ReadyToBill,
		ISNULL(SUM(CASE WHEN s.St = 'CAN' THEN Cnt END), 0) AS Cancelled,
		ISNULL(SUM(CASE WHEN s.St = 'CAN' AND s.Billed = 1 THEN Cnt END), 0) AS CancelledBilled,
		ISNULL(SUM(CASE WHEN s.St = 'CLIENT' THEN Cnt END), 0) AS ClientBill,
		ISNULL(SUM(CASE WHEN s.St = 'NEW' THEN Cnt END), 0) AS NewlyReceived,
		ISNULL(SUM(CASE WHEN s.St = 'SYS' THEN Cnt END), 0) AS SystemTest,
		ISNULL(SUM(CASE WHEN s.St = 'SYS' AND s.Billed = 1 THEN Cnt END), 0) AS SystemTestBilled,
		ISNULL(SUM(CASE WHEN s.St = 'YET' THEN Cnt END), 0) AS YetToBeValidated,
		ISNULL(SUM(CASE WHEN s.St = 'CIP' THEN Cnt END), 0) AS CipPending,
		ISNULL(SUM(CASE WHEN s.St = 'CIP' AND s.Billed = 1 THEN Cnt END), 0) AS CipPendingBilled,
		ISNULL(SUM(Cnt), 0) AS TotalSamples
	INTO #M
	FROM #F
	CROSS APPLY (SELECT
		St = CASE
				WHEN NewStatus = N'Billable' THEN 'INS'
				WHEN NewStatus IN (N'Cancelled/Rejected', N'Canceled/Rejected') THEN 'CAN'
				WHEN NewStatus IN (N'Client Bill', N'Client Bills') THEN 'CLIENT'
				WHEN NewStatus IN (N'Newly Received Claims', N'Newly Received Samples') THEN 'NEW'
				WHEN NewStatus = N'System Test' THEN 'SYS'
				WHEN NewStatus IN (N'Yet to be Validated', N'Yet to be validated', N'Yest to be Validated', N'Yet to Be Validate', N'Yet be validated') THEN 'YET'
				WHEN NewStatus IN (N'CIP/Pending', N'CIP / Pending') THEN 'CIP'
				ELSE ''
			 END,
		Billed = CASE
				WHEN BillCategory = N'Billed' OR BillingStatus = N'Billed' THEN 1
				ELSE 0
			 END,
		Unbilled = CASE
				WHEN BillCategory = N'Billed' OR BillingStatus = N'Billed' THEN 0
				WHEN BillCategory IN (N'Unbilled', N'Not Billed') OR BillingStatus IN (N'Unbilled', N'Not Billed') THEN 1
				ELSE 0
			 END,
		Sub = CASE
				WHEN SubStatus = N'Entered but not billed' THEN 'ENTERED'
				WHEN SubStatus = N'Ready to Bill' THEN 'READY'
				ELSE ''
			 END) s
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT r.SortOrder, r.Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   m.RowYear, m.RowMonth, r.SampleCount
	FROM #M m
	CROSS APPLY (VALUES
		( 10, N'A',        N'Insurance Bill',         0, N'NewStatus = Billable', 0, m.InsuranceBill),
		( 20, N'1',        N'Billed',                 1, N'NewStatus = Billable AND (BillCategory = Billed OR BillingStatus = Billed)', 0, m.InsuranceBilled),
		( 30, N'2',        N'Not Billed',             1, N'NewStatus = Billable AND (BillCategory = Unbilled OR BillingStatus = Unbilled)', 0, m.InsuranceNotBilled),
		( 40, NCHAR(8226), N'Entered but not billed', 2, N'NewStatus = Billable AND (BillCategory = Unbilled OR BillingStatus = Unbilled) AND SubStatus = Entered but not billed', 0, m.EnteredNotBilled),
		( 50, NCHAR(8226), N'Ready to Bill',          2, N'NewStatus = Billable AND (BillCategory = Unbilled OR BillingStatus = Unbilled) AND SubStatus = Ready to Bill', 0, m.ReadyToBill),
		( 60, N'B',        N'Cancelled/Rejected',     0, N'NewStatus = Cancelled/Rejected', 0, m.Cancelled),
		( 70, N'1',        N'Billed',                 1, N'NewStatus = Cancelled/Rejected AND (BillCategory = Billed OR BillingStatus = Billed)', 0, m.CancelledBilled),
		( 80, N'C',        N'Client Bill',            0, N'NewStatus = Client Bill OR Client Bills', 0, m.ClientBill),
		( 90, N'D',        N'Newly Received Claims',  0, N'NewStatus = Newly Received Claims OR Newly Received Samples', 0, m.NewlyReceived),
		(100, N'E',        N'System Test',            0, N'NewStatus = System Test', 0, m.SystemTest),
		(110, N'1',        N'Billed',                 1, N'NewStatus = System Test AND (BillCategory = Billed OR BillingStatus = Billed)', 0, m.SystemTestBilled),
		(120, N'F',        N'Yet to be Validated',    0, N'NewStatus = Yet to be Validated', 0, m.YetToBeValidated),
		(130, N'G',        N'CIP/Pending',            0, N'NewStatus = CIP/Pending', 0, m.CipPending),
		(140, N'1',        N'Billed',                 1, N'NewStatus = CIP/Pending AND (BillCategory = Billed OR BillingStatus = Billed)', 0, m.CipPendingBilled),
		(999, N'',         N'Total Samples',          0, N'Total Samples', 1, m.TotalSamples)
	) r(SortOrder, Code, Description, RowLevel, Logic, IsGrandTotal, SampleCount)
	ORDER BY r.SortOrder, m.RowYear, m.RowMonth;

	-- Result set 2: KPI cards. CoreBio has no Self Pay status.
	SELECT TotalSamples,
		   InsuranceBilled AS BilledCount,
		   InsuranceNotBilled AS UnbilledCount,
		   0 AS SelfPayCount
	FROM #M
	WHERE RowYear = 0 AND RowMonth = 0;
END;
GO

EXEC dbo.usp_RefreshCB_LISSummary;
GO

PRINT '26_CoreBio_LISSummary_SP.sql completed.';
GO
