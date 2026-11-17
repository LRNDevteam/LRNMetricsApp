/* =============================================================================
   VariantX - LIS Summary built entirely in SQL
   Database : VariantX_LRN

   Same design as PNC (26_PNC_LISSummary_SP.sql): rows, logic, sort order,
   month / year / grand totals and the KPI cards all come from
   dbo.usp_GetVarX_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate).
             'Received' (RequestReceivedDate) stays available for the page's date-type
             selector. VariantX's LIMS has no resulted date.
   Counting: one LIMSMaster row = one sample.
   Filters : Panel = TestType, Clinic = FacilityName, Ref Phy = PhysicianName,
             Sales Rep = SaleRepName. Collector is empty on VariantX.

   Rows (client logic sheet, LISSummary from LIMSMaster):
     A  Billable        LRN Sample Status = Billable
     1    Billed        ... AND LRN Bill Category = Billed
     B  System Test     LRN Sample Status = System Test (or System Tests)
     C+ <other status>  every other LRN Sample Status found (Not Equal to Billable)
        Total Samples   all samples (returned as the grand-total row)

   LRN Sample Status = SampleStatus, LRN Bill Category = BillCategory.
   Statuses other than Billable / System Test get their own lettered row (C, D, ...,
   by total descending) so the lettered rows always add up to Total Samples.

   Objects:
     dbo.VarX_LIS_StatusSummary      day x dimension x status aggregate
     dbo.usp_RefreshVarX_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetVarX_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'VariantX_LRN'
BEGIN
	RAISERROR('Run 26_VariantX_LISSummary_SP.sql on the VariantX_LRN database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.VarX_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.VarX_LIS_StatusSummary
(
	DateType      VARCHAR(10)    NOT NULL,
	GroupDate     DATE           NOT NULL,
	Panel         NVARCHAR(500)  NOT NULL,
	Clinic        NVARCHAR(500)  NOT NULL,
	RefPhy        NVARCHAR(500)  NOT NULL,
	SalesRep      NVARCHAR(500)  NOT NULL,
	Collector     NVARCHAR(150)  NOT NULL,
	SampleStatus  NVARCHAR(255)  NOT NULL,
	BillCategory  NVARCHAR(255)  NOT NULL,
	SubStatus     NVARCHAR(255)  NOT NULL,
	SampleCount   INT            NOT NULL,
	RefreshedAt   DATETIME       NOT NULL CONSTRAINT DF_VarX_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_VarX_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.VarX_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_VarX_LIS_StatusSummary_Date
		ON dbo.VarX_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshVarX_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.VarX_LIS_StatusSummary;

	INSERT INTO dbo.VarX_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 SampleStatus, BillCategory, SubStatus, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   ISNULL(LTRIM(RTRIM(l.TestType)), N''),
		   ISNULL(LTRIM(RTRIM(l.FacilityName)), N''),
		   ISNULL(LTRIM(RTRIM(l.PhysicianName)), N''),
		   ISNULL(LTRIM(RTRIM(l.SaleRepName)), N''),
		   N'',
		   ISNULL(LTRIM(RTRIM(l.SampleStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
		   COUNT(*),
		   GETDATE()
	FROM dbo.LIMSMaster l
	CROSS APPLY (VALUES
		('Collected', TRY_CAST(l.RequestCollectDate  AS DATE)),
		('Received',  TRY_CAST(l.RequestReceivedDate AS DATE))
	) d(DateType, GroupDate)
	WHERE d.GroupDate IS NOT NULL
	  AND YEAR(d.GroupDate) > 1900
	GROUP BY d.DateType, d.GroupDate,
			 ISNULL(LTRIM(RTRIM(l.TestType)), N''),
			 ISNULL(LTRIM(RTRIM(l.FacilityName)), N''),
			 ISNULL(LTRIM(RTRIM(l.PhysicianName)), N''),
			 ISNULL(LTRIM(RTRIM(l.SaleRepName)), N''),
			 ISNULL(LTRIM(RTRIM(l.SampleStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N'');

	PRINT 'usp_RefreshVarX_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetVarX_LISSummary
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

	DECLARE @Filters TABLE (Dim VARCHAR(10) NOT NULL, Val NVARCHAR(500) NOT NULL);
	INSERT INTO @Filters (Dim, Val)
	SELECT f.Dim, LTRIM(RTRIM(s.value))
	FROM (VALUES ('Panel', @Panel), ('Clinic', @Clinic), ('RefPhy', @RefPhy),
				 ('SalesRep', @SalesRep), ('Collector', @Collector)) f(Dim, Vals)
	CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N'|') s
	WHERE LTRIM(RTRIM(s.value)) <> N'';

	DROP TABLE IF EXISTS #F;
	SELECT YEAR(a.GroupDate) AS Y, MONTH(a.GroupDate) AS M,
		   a.SampleStatus, a.BillCategory, SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.VarX_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate),
			 a.SampleStatus, a.BillCategory;

	-- Status keys ignore spaces and hyphens, so "SystemTest" and "Self-Pay" still match.
	-- Any other status keeps its own name (St = 'OTHER', StName) and gets its own lettered row.
	DROP TABLE IF EXISTS #C;
	SELECT f.Y, f.M, f.Cnt, s.St, s.Bc, s.StName
	INTO #C
	FROM #F f
	CROSS APPLY (SELECT K = REPLACE(REPLACE(f.SampleStatus, N' ', N''), N'-', N'')) k
	CROSS APPLY (SELECT
		St = CASE
				WHEN k.K = N'Billable' THEN 'BILLABLE'
				WHEN k.K IN (N'SystemTest', N'SystemTests') THEN 'SYS'
				ELSE 'OTHER'
			 END,
		Bc = CASE
				WHEN f.BillCategory = N'Billed' THEN 'B'
				WHEN f.BillCategory IN (N'Unbilled', N'Not Billed') THEN 'U'
				ELSE ''
			 END,
		StName = CASE WHEN f.SampleStatus IN (N'', N'-') THEN N'Blank' ELSE f.SampleStatus END) s;

	-- Row definitions. Seq is the display order: group x 1000, Billed x 100.
	-- St / Bc / StName say which samples a row counts (NULL = any).
	DROP TABLE IF EXISTS #D;
	CREATE TABLE #D
	(
		Seq          INT            NOT NULL PRIMARY KEY,
		Code         NVARCHAR(5)    NOT NULL,
		Description  NVARCHAR(300)  NOT NULL,
		RowLevel     INT            NOT NULL,
		Logic        NVARCHAR(1000) NOT NULL,
		IsGrandTotal INT            NOT NULL,
		St           VARCHAR(10)    NULL,
		Bc           CHAR(1)        NULL,
		StName       NVARCHAR(255)  NULL
	);

	INSERT INTO #D (Seq, Code, Description, RowLevel, Logic, IsGrandTotal, St, Bc, StName)
	VALUES
		( 1000, N'A', N'Billable',      0, N'LRN Sample Status = Billable', 0, 'BILLABLE', NULL, NULL),
		( 1100, N'1', N'Billed',        1, N'LRN Sample Status = Billable AND LRN Bill Category = Billed', 0, 'BILLABLE', 'B', NULL),
		( 2000, N'B', N'System Test',   0, N'LRN Sample Status = System Test', 0, 'SYS', NULL, NULL),
		(99999, N'',  N'Total Samples', 0, N'Total Samples', 1, NULL, NULL, NULL);

	-- Not Equal to Billable breakdown: every other status gets the next letter (C, D, ...).
	INSERT INTO #D (Seq, Code, Description, RowLevel, Logic, IsGrandTotal, St, Bc, StName)
	SELECT (2 + x.Rn) * 1000,
		   NCHAR(UNICODE(N'B') + x.Rn),
		   x.StName, 0,
		   N'LRN Sample Status = ' + x.StName,
		   0, 'OTHER', NULL, x.StName
	FROM (SELECT c.StName, ROW_NUMBER() OVER (ORDER BY SUM(c.Cnt) DESC, c.StName) AS Rn
		  FROM #C c
		  WHERE c.St = 'OTHER'
		  GROUP BY c.StName) x;

	-- Month columns, year columns (RowMonth = 0) and the grand total (0, 0).
	DROP TABLE IF EXISTS #P;
	SELECT ISNULL(Y, 0) AS RowYear,
		   CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth
	INTO #P
	FROM #F
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	DROP TABLE IF EXISTS #N;
	SELECT d.Seq,
		   ISNULL(c.Y, 0) AS RowYear,
		   CASE WHEN GROUPING(c.M) = 1 THEN 0 ELSE c.M END AS RowMonth,
		   SUM(c.Cnt) AS Cnt
	INTO #N
	FROM #D d
	JOIN #C c
	  ON d.IsGrandTotal = 1
	  OR (c.St = d.St
		  AND (d.Bc IS NULL OR c.Bc = d.Bc)
		  AND (d.StName IS NULL OR c.StName = d.StName))
	GROUP BY GROUPING SETS ((d.Seq, c.Y, c.M), (d.Seq, c.Y), (d.Seq));

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT d.Seq AS SortOrder, d.Code, d.Description, d.RowLevel, d.Logic, d.IsGrandTotal,
		   p.RowYear, p.RowMonth, ISNULL(n.Cnt, 0) AS SampleCount
	FROM #D d
	CROSS JOIN #P p
	LEFT JOIN #N n ON n.Seq = d.Seq AND n.RowYear = p.RowYear AND n.RowMonth = p.RowMonth
	ORDER BY d.Seq, p.RowYear, p.RowMonth;

	-- Result set 2: KPI cards (Billable billed / unbilled, Self Pay).
	SELECT ISNULL(SUM(Cnt), 0) AS TotalSamples,
		   ISNULL(SUM(CASE WHEN St = 'BILLABLE' AND Bc = 'B' THEN Cnt END), 0) AS BilledCount,
		   ISNULL(SUM(CASE WHEN St = 'BILLABLE' AND Bc = 'U' THEN Cnt END), 0) AS UnbilledCount,
		   ISNULL(SUM(CASE WHEN St = 'OTHER' AND REPLACE(REPLACE(StName, N' ', N''), N'-', N'') = N'SelfPay' THEN Cnt END), 0) AS SelfPayCount
	FROM #C;
END;
GO

EXEC dbo.usp_RefreshVarX_LISSummary;
GO

PRINT '26_VariantX_LISSummary_SP.sql completed.';
GO
