/* =============================================================================
   Analyze Pathology - LIS Summary built entirely in SQL
   Database : AnalyzePathology

   Rows, logic, sort order, month / year / grand totals and the KPI cards all come
   from dbo.usp_GetAnP_LISSummary. The dashboard (page, Excel export and the
   ReportWorker LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate).
             'Received' (ReqReceivedDate) and 'Resulted' (ReqReportedDate) stay
             available for the page's date-type selector.
   Counting: one LIMSMaster row = one sample (re-run accessions are separate rows).

   Rows (client logic sheet):
     A  Billable                    New Status = Billable
     1    Billed                    Billable AND Bill Category = Billed
     *      Billed Via CMD          Billable AND Bill Category = Billed
     2    Not Billed                Billable AND Bill Category = Unbilled
     *      Ready to bill           ... AND Sub Status = Ready to Bill
     *      Entered Not Submitted   ... AND Sub Status = Entered Not Submitted
     E  System Test                 New Status = System Test
        Duplicate                   New Status = Duplicate(s)
        Other Samples               New Status = Other Sample(s)
        Yet to Be Validate          New Status = Yet to Be Validate AND Sub Status <> Entered Not Submitted
        Total Samples               all samples (returned as the grand-total row)

   Objects:
     dbo.AnP_LIS_StatusSummary      day x dimension x status aggregate
     dbo.usp_RefreshAnP_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetAnP_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.AnP_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.AnP_LIS_StatusSummary
(
	DateType     VARCHAR(10)    NOT NULL,
	GroupDate    DATE           NOT NULL,
	Panel        NVARCHAR(300)  NOT NULL,
	Clinic       NVARCHAR(300)  NOT NULL,
	RefPhy       NVARCHAR(300)  NOT NULL,
	SalesRep     NVARCHAR(300)  NOT NULL,
	Collector    NVARCHAR(300)  NOT NULL,
	NewStatus    NVARCHAR(100)  NOT NULL,
	BillCategory NVARCHAR(100)  NOT NULL,
	SubStatus    NVARCHAR(100)  NOT NULL,
	SampleCount  INT            NOT NULL,
	RefreshedAt  DATETIME       NOT NULL CONSTRAINT DF_AnP_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_AnP_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.AnP_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_AnP_LIS_StatusSummary_Date
		ON dbo.AnP_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAnP_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.AnP_LIS_StatusSummary;

	INSERT INTO dbo.AnP_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 NewStatus, BillCategory, SubStatus, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   ISNULL(LTRIM(RTRIM(l.PanelName)), N''),
		   ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
		   ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
		   N'',
		   ISNULL(LTRIM(RTRIM(l.Collector)), N''),
		   ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
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
			 ISNULL(LTRIM(RTRIM(l.PanelName)), N''),
			 ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
			 ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
			 ISNULL(LTRIM(RTRIM(l.Collector)), N''),
			 ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N'');

	PRINT 'usp_RefreshAnP_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetAnP_LISSummary
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

	DECLARE @Filters TABLE (Dim VARCHAR(10) NOT NULL, Val NVARCHAR(300) NOT NULL);
	INSERT INTO @Filters (Dim, Val)
	SELECT f.Dim, LTRIM(RTRIM(s.value))
	FROM (VALUES ('Panel', @Panel), ('Clinic', @Clinic), ('RefPhy', @RefPhy),
				 ('SalesRep', @SalesRep), ('Collector', @Collector)) f(Dim, Vals)
	CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N'|') s
	WHERE LTRIM(RTRIM(s.value)) <> N'';

	DROP TABLE IF EXISTS #F;
	SELECT YEAR(a.GroupDate) AS Y, MONTH(a.GroupDate) AS M,
		   a.NewStatus, a.BillCategory, a.SubStatus, SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.AnP_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate), a.NewStatus, a.BillCategory, a.SubStatus;

	-- Month rows, year rows (RowMonth = 0) and the grand total (0, 0).
	DROP TABLE IF EXISTS #M;
	SELECT
		ISNULL(Y, 0) AS RowYear,
		CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' THEN Cnt END), 0) AS Billable,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory = N'Billed' THEN Cnt END), 0) AS Billed,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory IN (N'Unbilled', N'Not Billed') THEN Cnt END), 0) AS NotBilled,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory IN (N'Unbilled', N'Not Billed')
						 AND SubStatus = N'Ready to Bill' THEN Cnt END), 0) AS ReadyToBill,
		ISNULL(SUM(CASE WHEN NewStatus = N'Billable' AND BillCategory IN (N'Unbilled', N'Not Billed')
						 AND SubStatus = N'Entered Not Submitted' THEN Cnt END), 0) AS EnteredNotSubmitted,
		ISNULL(SUM(CASE WHEN NewStatus = N'System Test' THEN Cnt END), 0) AS SystemTest,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Duplicate', N'Duplicates') THEN Cnt END), 0) AS Duplicate,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Other Sample', N'Other Samples') THEN Cnt END), 0) AS OtherSamples,
		ISNULL(SUM(CASE WHEN NewStatus IN (N'Yet to Be Validate', N'Yet to be validated', N'Yet be validated')
						 AND SubStatus <> N'Entered Not Submitted' THEN Cnt END), 0) AS YetToBeValidate,
		ISNULL(SUM(Cnt), 0) AS TotalSamples
	INTO #M
	FROM #F
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT r.SortOrder, r.Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   m.RowYear, m.RowMonth, r.SampleCount
	FROM #M m
	CROSS APPLY (VALUES
		( 10, N'A', N'Billable',              0, N'New Status = Billable', 0, m.Billable),
		( 20, N'1', N'Billed',                1, N'Billable AND Bill Category = Billed', 0, m.Billed),
		( 30, NCHAR(8226), N'Billed Via CMD',        2, N'Billable AND Bill Category = Billed', 0, m.Billed),
		( 40, N'2', N'Not Billed',            1, N'Billable AND Bill Category = Unbilled', 0, m.NotBilled),
		( 50, NCHAR(8226), N'Ready to bill',         2, N'Billable AND Bill Category = Unbilled AND Sub Status = Ready to Bill', 0, m.ReadyToBill),
		( 60, NCHAR(8226), N'Entered Not Submitted', 2, N'Billable AND Bill Category = Unbilled AND Sub Status = Entered Not Submitted', 0, m.EnteredNotSubmitted),
		( 70, N'E', N'System Test',           0, N'New Status = System Test', 0, m.SystemTest),
		( 80, N'',  N'Duplicate',             0, N'New Status = Duplicates', 0, m.Duplicate),
		( 90, N'',  N'Other Samples',         0, N'New Status = Other Samples', 0, m.OtherSamples),
		(100, N'',  N'Yet to Be Validate',    0, N'New Status = Yet to Be Validate AND Sub Status <> Entered Not Submitted', 0, m.YetToBeValidate),
		(999, N'',  N'Total Samples',         0, N'Total Samples', 1, m.TotalSamples)
	) r(SortOrder, Code, Description, RowLevel, Logic, IsGrandTotal, SampleCount)
	ORDER BY r.SortOrder, m.RowYear, m.RowMonth;

	-- Result set 2: KPI cards (AnalyzePathology has no Self Pay status).
	SELECT TotalSamples, Billed AS BilledCount, NotBilled AS UnbilledCount, 0 AS SelfPayCount
	FROM #M
	WHERE RowYear = 0 AND RowMonth = 0;
END;
GO

EXEC dbo.usp_RefreshAnP_LISSummary;
GO

PRINT '26_AnalyzePathology_LISSummary_SP.sql completed.';
GO
