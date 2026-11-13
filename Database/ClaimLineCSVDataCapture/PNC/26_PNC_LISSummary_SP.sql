/* =============================================================================
   PNC - LIS Summary built entirely in SQL
   Database : PNC

   Same design as TexasDiagnostic (26_TexasDiagnostic_LISSummary_SP.sql): rows, logic,
   sort order, month / year / grand totals and the KPI cards all come from
   dbo.usp_GetPNC_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate).
             'Received' (ReqReceivedDate) and 'Resulted' (ResultedDate) stay available
             for the page's date-type selector.
   Counting: one LIMSMaster row = one sample.
   Filters : Panel = PanelName, Clinic = ClinicName, Ref Phy = DoctorFullName,
             Sales Rep = SalesRepName. Collector is empty on PNC.

   Rows (client logic sheet, LISSummary from LIMSMaster):
     A  Billable                            NewStatus = Billable
     1    Billed                            ... AND BillCategory = Billed
     *      Claim Submitted in Historical Lab ... AND SubStatus = Claim Submitted in Historical Lab
     *      Claim Submitted in PNC Lab      ... AND SubStatus = Claim Submitted in PNC Lab
     2    Unbilled                          ... AND BillCategory = Unbilled
     *      Ready to Bill                   ... AND SubStatus = Ready to Bill
     *      No Insurance Info               ... AND SubStatus = No Insurance Info OR Missing Insurance Info
     B  Deleted / Rejected                  NewStatus = Deleted / Rejected
     1    Billed                            ... AND BillCategory = Billed
     C  Client Bill                         NewStatus = Client Bill
     1    Billed                            ... AND BillCategory = Billed
     D  System Test                         NewStatus = System Test
     1    Billed                            ... AND BillCategory = Billed
     E  Self Pay                            NewStatus = Self Pay
     1    Billed                            ... AND BillCategory = Billed
     F  Missing Accession                   NewStatus = Missing Accession
     G  Yet to be Validated                 NewStatus = Yet to be Validated
     1    Billed                            ... AND BillCategory = Billed
     H  Duplicate                           NewStatus = Duplicate (sheet spells it Dublicate)
     1    Billed                            ... AND BillCategory = Billed
        Total Samples                       all samples (returned as the grand-total row)

   Billable > Billed and Billable > Unbilled are a SubStatus breakdown: the named bullets
   above are always shown, and any other SubStatus found under them gets its own bullet
   (by total descending) so the bullets always add up to their parent row.
   Row order is fixed as listed (A-H), Total Samples last.

   Objects:
     dbo.PNC_LIS_StatusSummary      day x dimension x status aggregate
     dbo.usp_RefreshPNC_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetPNC_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
	RAISERROR('Run 26_PNC_LISSummary_SP.sql on the PNC database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.PNC_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.PNC_LIS_StatusSummary
(
	DateType      VARCHAR(10)    NOT NULL,
	GroupDate     DATE           NOT NULL,
	Panel         NVARCHAR(500)  NOT NULL,
	Clinic        NVARCHAR(500)  NOT NULL,
	RefPhy        NVARCHAR(500)  NOT NULL,
	SalesRep      NVARCHAR(500)  NOT NULL,
	Collector     NVARCHAR(150)  NOT NULL,
	NewStatus     NVARCHAR(255)  NOT NULL,
	BillCategory  NVARCHAR(255)  NOT NULL,
	SubStatus     NVARCHAR(255)  NOT NULL,
	SampleCount   INT            NOT NULL,
	RefreshedAt   DATETIME       NOT NULL CONSTRAINT DF_PNC_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_PNC_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.PNC_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_PNC_LIS_StatusSummary_Date
		ON dbo.PNC_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPNC_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.PNC_LIS_StatusSummary;

	INSERT INTO dbo.PNC_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 NewStatus, BillCategory, SubStatus, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   ISNULL(LTRIM(RTRIM(l.PanelName)), N''),
		   ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
		   ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
		   ISNULL(LTRIM(RTRIM(l.SalesRepName)), N''),
		   N'',
		   ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
		   ISNULL(LTRIM(RTRIM(l.SubStatus)), N''),
		   COUNT(*),
		   GETDATE()
	FROM dbo.LIMSMaster l
	CROSS APPLY (VALUES
		('Collected', TRY_CAST(l.RequestCollectDate AS DATE)),
		('Received',  TRY_CAST(l.ReqReceivedDate    AS DATE)),
		('Resulted',  TRY_CAST(l.ResultedDate       AS DATE))
	) d(DateType, GroupDate)
	WHERE d.GroupDate IS NOT NULL
	  AND YEAR(d.GroupDate) > 1900
	GROUP BY d.DateType, d.GroupDate,
			 ISNULL(LTRIM(RTRIM(l.PanelName)), N''),
			 ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
			 ISNULL(LTRIM(RTRIM(l.DoctorFullName)), N''),
			 ISNULL(LTRIM(RTRIM(l.SalesRepName)), N''),
			 ISNULL(LTRIM(RTRIM(l.NewStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillCategory)), N''),
			 ISNULL(LTRIM(RTRIM(l.SubStatus)), N'');

	PRINT 'usp_RefreshPNC_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetPNC_LISSummary
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
		   a.NewStatus, a.BillCategory, a.SubStatus, SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.PNC_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate),
			 a.NewStatus, a.BillCategory, a.SubStatus;

	-- Status keys ignore spaces and hyphens, so "Deleted/Rejected" and "Self-Pay" still match.
	DROP TABLE IF EXISTS #C;
	SELECT f.Y, f.M, f.Cnt, s.St, s.Bc, s.SubName
	INTO #C
	FROM #F f
	CROSS APPLY (SELECT K = REPLACE(REPLACE(f.NewStatus, N' ', N''), N'-', N'')) k
	CROSS APPLY (SELECT
		St = CASE
				WHEN k.K = N'Billable' THEN 'BILLABLE'
				WHEN k.K IN (N'Deleted/Rejected', N'Rejected/Deleted') THEN 'DELREJ'
				WHEN k.K IN (N'ClientBill', N'ClientBills') THEN 'CLIENT'
				WHEN k.K = N'SystemTest' THEN 'SYS'
				WHEN k.K = N'SelfPay' THEN 'SELFPAY'
				WHEN k.K = N'MissingAccession' THEN 'MISSACC'
				WHEN k.K IN (N'YettobeValidated', N'YesttobeValidated', N'YettoBeValidate', N'Yetbevalidated') THEN 'YET'
				WHEN k.K IN (N'Duplicate', N'Dublicate') THEN 'DUP'
				ELSE ''
			 END,
		Bc = CASE
				WHEN f.BillCategory = N'Billed' THEN 'B'
				WHEN f.BillCategory IN (N'Unbilled', N'Not Billed') THEN 'U'
				ELSE ''
			 END,
		SubName = CASE
				WHEN f.SubStatus IN (N'No Insurance Info', N'Missing Insurance Info') THEN N'No Insurance Info'
				WHEN f.SubStatus IN (N'', N'-') THEN N'Blank'
				ELSE f.SubStatus
			 END) s;

	-- Row definitions. Seq is the display order: group x 1000, Billed / Unbilled x 100, bullets + n.
	-- St / Bc / SubName say which samples a row counts (NULL = any).
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
		SubName      NVARCHAR(255)  NULL
	);

	DECLARE @B NCHAR(1) = NCHAR(8226);
	INSERT INTO #D (Seq, Code, Description, RowLevel, Logic, IsGrandTotal, St, Bc, SubName)
	VALUES
		( 1000, N'A', N'Billable',                          0, N'NewStatus = Billable', 0, 'BILLABLE', NULL, NULL),
		( 1100, N'1', N'Billed',                            1, N'NewStatus = Billable AND BillCategory = Billed', 0, 'BILLABLE', 'B', NULL),
		( 1101, @B,   N'Claim Submitted in Historical Lab', 2, N'NewStatus = Billable AND BillCategory = Billed AND SubStatus = Claim Submitted in Historical Lab', 0, 'BILLABLE', 'B', N'Claim Submitted in Historical Lab'),
		( 1102, @B,   N'Claim Submitted in PNC Lab',        2, N'NewStatus = Billable AND BillCategory = Billed AND SubStatus = Claim Submitted in PNC Lab', 0, 'BILLABLE', 'B', N'Claim Submitted in PNC Lab'),
		( 1200, N'2', N'Unbilled',                          1, N'NewStatus = Billable AND BillCategory = Unbilled', 0, 'BILLABLE', 'U', NULL),
		( 1201, @B,   N'Ready to Bill',                     2, N'NewStatus = Billable AND BillCategory = Unbilled AND SubStatus = Ready to Bill', 0, 'BILLABLE', 'U', N'Ready to Bill'),
		( 1202, @B,   N'No Insurance Info',                 2, N'NewStatus = Billable AND BillCategory = Unbilled AND SubStatus = No Insurance Info OR Missing Insurance Info', 0, 'BILLABLE', 'U', N'No Insurance Info'),
		( 2000, N'B', N'Deleted / Rejected',                0, N'NewStatus = Deleted / Rejected', 0, 'DELREJ', NULL, NULL),
		( 2100, N'1', N'Billed',                            1, N'NewStatus = Deleted / Rejected AND BillCategory = Billed', 0, 'DELREJ', 'B', NULL),
		( 3000, N'C', N'Client Bill',                       0, N'NewStatus = Client Bill', 0, 'CLIENT', NULL, NULL),
		( 3100, N'1', N'Billed',                            1, N'NewStatus = Client Bill AND BillCategory = Billed', 0, 'CLIENT', 'B', NULL),
		( 4000, N'D', N'System Test',                       0, N'NewStatus = System Test', 0, 'SYS', NULL, NULL),
		( 4100, N'1', N'Billed',                            1, N'NewStatus = System Test AND BillCategory = Billed', 0, 'SYS', 'B', NULL),
		( 5000, N'E', N'Self Pay',                          0, N'NewStatus = Self Pay', 0, 'SELFPAY', NULL, NULL),
		( 5100, N'1', N'Billed',                            1, N'NewStatus = Self Pay AND BillCategory = Billed', 0, 'SELFPAY', 'B', NULL),
		( 6000, N'F', N'Missing Accession',                 0, N'NewStatus = Missing Accession', 0, 'MISSACC', NULL, NULL),
		( 7000, N'G', N'Yet to be Validated',               0, N'NewStatus = Yet to be Validated', 0, 'YET', NULL, NULL),
		( 7100, N'1', N'Billed',                            1, N'NewStatus = Yet to be Validated AND BillCategory = Billed', 0, 'YET', 'B', NULL),
		( 8000, N'H', N'Duplicate',                         0, N'NewStatus = Duplicate', 0, 'DUP', NULL, NULL),
		( 8100, N'1', N'Billed',                            1, N'NewStatus = Duplicate AND BillCategory = Billed', 0, 'DUP', 'B', NULL),
		(99999, N'',  N'Total Samples',                     0, N'Total Samples', 1, NULL, NULL, NULL);

	-- SubStatus breakdown: any other Sub Status under Billable > Billed / Unbilled gets its own bullet.
	INSERT INTO #D (Seq, Code, Description, RowLevel, Logic, IsGrandTotal, St, Bc, SubName)
	SELECT p.Seq + 2 + ROW_NUMBER() OVER (PARTITION BY x.Bc ORDER BY x.Total DESC, x.SubName),
		   @B, x.SubName, 2,
		   p.Logic + N' AND SubStatus = ' + x.SubName,
		   0, 'BILLABLE', x.Bc, x.SubName
	FROM (SELECT c.Bc, c.SubName, SUM(c.Cnt) AS Total
		  FROM #C c
		  WHERE c.St = 'BILLABLE' AND c.Bc IN ('B', 'U')
		    AND NOT EXISTS (SELECT 1 FROM #D d
							WHERE d.St = 'BILLABLE' AND d.Bc = c.Bc AND d.SubName = c.SubName)
		  GROUP BY c.Bc, c.SubName) x
	JOIN #D p ON p.St = 'BILLABLE' AND p.Bc = x.Bc AND p.SubName IS NULL;

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
		  AND (d.SubName IS NULL OR c.SubName = d.SubName))
	GROUP BY GROUPING SETS ((d.Seq, c.Y, c.M), (d.Seq, c.Y), (d.Seq));

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT d.Seq AS SortOrder, d.Code, d.Description, d.RowLevel, d.Logic, d.IsGrandTotal,
		   p.RowYear, p.RowMonth, ISNULL(n.Cnt, 0) AS SampleCount
	FROM #D d
	CROSS JOIN #P p
	LEFT JOIN #N n ON n.Seq = d.Seq AND n.RowYear = p.RowYear AND n.RowMonth = p.RowMonth
	ORDER BY d.Seq, p.RowYear, p.RowMonth;

	-- Result set 2: KPI cards (Billable billed / unbilled, Self Pay section).
	SELECT ISNULL(SUM(Cnt), 0) AS TotalSamples,
		   ISNULL(SUM(CASE WHEN St = 'BILLABLE' AND Bc = 'B' THEN Cnt END), 0) AS BilledCount,
		   ISNULL(SUM(CASE WHEN St = 'BILLABLE' AND Bc = 'U' THEN Cnt END), 0) AS UnbilledCount,
		   ISNULL(SUM(CASE WHEN St = 'SELFPAY' THEN Cnt END), 0) AS SelfPayCount
	FROM #C;
END;
GO

EXEC dbo.usp_RefreshPNC_LISSummary;
GO

PRINT '26_PNC_LISSummary_SP.sql completed.';
GO
