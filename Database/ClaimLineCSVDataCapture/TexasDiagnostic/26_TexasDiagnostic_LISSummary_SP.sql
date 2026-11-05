/* =============================================================================
   TexasDiagnostic - LIS Summary built entirely in SQL
   Database : TexasDiagnostic

   Same design as CoreBio (26_CoreBio_LISSummary_SP.sql): rows, logic, sort order,
   month / year / grand totals and the KPI cards all come from
   dbo.usp_GetTD_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate,
             the sheet's Collection Date). 'Received' (ReqReceivedDate = Accession Date)
             and 'Resulted' (ResultedDate = Resulted Date) stay available for the
             page's date-type selector.
   Counting: one LIMSMaster row = one sample (Sample IDs is unique per row).
   Filters : Panel = PanelName, Clinic = ClinicName (Client), Ref Phy = DoctorFullName
             (Provider Name), Sales Rep = SalesRepName. Collector is empty on Texas.

   Rows (client logic sheet). Billed / Unbilled come from BillCategory only;
   BillingStatus is not on the Texas file.
     A  Billable                    NewStatus = Billable
     1    Billed                    ... AND BillCategory = Billed
     2    Unbilled                  ... AND BillCategory = Unbilled
     *      Ready to Bill           ... AND SubStatus = Ready to Bill
     *      Missing Insurance Info  ... AND SubStatus = Missing Insurance Info
     B  Client Bill                 NewStatus = Client Bill OR Client Bills
     1    Billed                    ... AND BillCategory = Billed
     C  Rejected                    NewStatus = Rejected
     D  System Test                 NewStatus = System Test
     E  Self Pay                    NewStatus = Self Pay
     1    Billed                    ... AND BillCategory = Billed
     F  Yet to be Validated         NewStatus = Yet to be Validated
     G  CIP/Pending                 NewStatus = CIP/Pending
        Total Samples               all samples (returned as the grand-total row)

   Sort order: A Billable is always first (Billed, Unbilled fixed; Unbilled bullets by total
   descending). The other main rows are by total descending, each with its Billed sub-row,
   and the letters B-G follow that order. Total Samples is last.

   Objects:
     dbo.TD_LIS_StatusSummary      day x dimension x status aggregate
     dbo.usp_RefreshTD_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetTD_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'TexasDiagnostic'
BEGIN
	RAISERROR('Run 26_TexasDiagnostic_LISSummary_SP.sql on the TexasDiagnostic database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.TD_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.TD_LIS_StatusSummary
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
	RefreshedAt   DATETIME       NOT NULL CONSTRAINT DF_TD_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_TD_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.TD_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_TD_LIS_StatusSummary_Date
		ON dbo.TD_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshTD_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.TD_LIS_StatusSummary;

	INSERT INTO dbo.TD_LIS_StatusSummary
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

	PRINT 'usp_RefreshTD_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetTD_LISSummary
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
	FROM dbo.TD_LIS_StatusSummary a
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

	-- Month rows, year rows (RowMonth = 0) and the grand total (0, 0).
	DROP TABLE IF EXISTS #M;
	SELECT
		ISNULL(Y, 0) AS RowYear,
		CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' THEN Cnt END), 0) AS Billable,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Billed = 1 THEN Cnt END), 0) AS BillableBilled,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Unbilled = 1 THEN Cnt END), 0) AS BillableUnbilled,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Unbilled = 1 AND s.Sub = 'READY' THEN Cnt END), 0) AS ReadyToBill,
		ISNULL(SUM(CASE WHEN s.St = 'BILLABLE' AND s.Unbilled = 1 AND s.Sub = 'MISSINS' THEN Cnt END), 0) AS MissingInsurance,
		ISNULL(SUM(CASE WHEN s.St = 'CLIENT' THEN Cnt END), 0) AS ClientBill,
		ISNULL(SUM(CASE WHEN s.St = 'CLIENT' AND s.Billed = 1 THEN Cnt END), 0) AS ClientBillBilled,
		ISNULL(SUM(CASE WHEN s.St = 'REJ' THEN Cnt END), 0) AS Rejected,
		ISNULL(SUM(CASE WHEN s.St = 'YET' THEN Cnt END), 0) AS YetToBeValidated,
		ISNULL(SUM(CASE WHEN s.St = 'SYS' THEN Cnt END), 0) AS SystemTest,
		ISNULL(SUM(CASE WHEN s.St = 'SELFPAY' THEN Cnt END), 0) AS SelfPay,
		ISNULL(SUM(CASE WHEN s.St = 'SELFPAY' AND s.Billed = 1 THEN Cnt END), 0) AS SelfPayBilled,
		ISNULL(SUM(CASE WHEN s.St = 'CIP' THEN Cnt END), 0) AS CipPending,
		ISNULL(SUM(Cnt), 0) AS TotalSamples
	INTO #M
	FROM #F
	CROSS APPLY (SELECT
		St = CASE
				WHEN NewStatus = N'Billable' THEN 'BILLABLE'
				WHEN NewStatus IN (N'Client Bill', N'Client Bills') THEN 'CLIENT'
				WHEN NewStatus = N'Rejected' THEN 'REJ'
				WHEN NewStatus IN (N'Yet to be Validated', N'Yest to be Validated', N'Yet to Be Validate', N'Yet be validated') THEN 'YET'
				WHEN NewStatus = N'System Test' THEN 'SYS'
				WHEN NewStatus IN (N'Self Pay', N'SelfPay', N'Self-Pay') THEN 'SELFPAY'
				WHEN NewStatus IN (N'CIP/Pending', N'CIP / Pending') THEN 'CIP'
				ELSE ''
			 END,
		Billed = CASE WHEN BillCategory = N'Billed' THEN 1 ELSE 0 END,
		Unbilled = CASE WHEN BillCategory IN (N'Unbilled', N'Not Billed') THEN 1 ELSE 0 END,
		Sub = CASE
				WHEN SubStatus = N'Ready to Bill' THEN 'READY'
				WHEN SubStatus = N'Missing Insurance Info' THEN 'MISSINS'
				ELSE ''
			 END) s
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	-- Rows with their place in the hierarchy: Grp = main row (A-G), Sub = its sub-row, Leaf = sub-sub-row.
	DROP TABLE IF EXISTS #R;
	SELECT r.Seq, r.Grp, r.Sub, r.Leaf, r.Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   m.RowYear, m.RowMonth, r.SampleCount
	INTO #R
	FROM #M m
	CROSS APPLY (VALUES
		( 10, 1, 0, 0, N'A',        N'Billable',               0, N'NewStatus = Billable', 0, m.Billable),
		( 20, 1, 1, 0, N'1',        N'Billed',                 1, N'NewStatus = Billable AND BillCategory = Billed', 0, m.BillableBilled),
		( 30, 1, 2, 0, N'2',        N'Unbilled',               1, N'NewStatus = Billable AND BillCategory = Unbilled', 0, m.BillableUnbilled),
		( 40, 1, 2, 1, NCHAR(8226), N'Ready to Bill',          2, N'NewStatus = Billable AND BillCategory = Unbilled AND Sub Status = Ready to Bill', 0, m.ReadyToBill),
		( 50, 1, 2, 2, NCHAR(8226), N'Missing Insurance Info', 2, N'NewStatus = Billable AND BillCategory = Unbilled AND Sub Status = Missing Insurance Info', 0, m.MissingInsurance),
		( 60, 2, 0, 0, N'B',        N'Client Bill',            0, N'NewStatus = Client Bill OR Client Bills', 0, m.ClientBill),
		( 70, 2, 1, 0, N'1',        N'Billed',                 1, N'NewStatus = Client Bill OR Client Bills AND BillCategory = Billed', 0, m.ClientBillBilled),
		( 80, 3, 0, 0, N'C',        N'Rejected',               0, N'NewStatus = Rejected', 0, m.Rejected),
		( 90, 4, 0, 0, N'D',        N'System Test',            0, N'NewStatus = System Test', 0, m.SystemTest),
		(100, 5, 0, 0, N'E',        N'Self Pay',               0, N'NewStatus = Self Pay', 0, m.SelfPay),
		(110, 5, 1, 0, N'1',        N'Billed',                 1, N'NewStatus = Self Pay AND BillCategory = Billed', 0, m.SelfPayBilled),
		(120, 6, 0, 0, N'F',        N'Yet to be Validated',    0, N'NewStatus = Yet to be Validated', 0, m.YetToBeValidated),
		(130, 7, 0, 0, N'G',        N'CIP/Pending',            0, N'NewStatus = CIP/Pending', 0, m.CipPending),
		(999, 0, 0, 0, N'',         N'Total Samples',          0, N'Total Samples', 1, m.TotalSamples)
	) r(Seq, Grp, Sub, Leaf, Code, Description, RowLevel, Logic, IsGrandTotal, SampleCount);

	-- Client ask: Billable (A) is always first and its 1 Billed / 2 Unbilled stay fixed; the bullets under
	-- Unbilled are by TOTAL descending. All other main rows are by TOTAL descending, each keeping its
	-- Billed sub-row, and are re-lettered B, C, ... in that order. Total Samples stays last.
	DROP TABLE IF EXISTS #O;
	WITH t AS (SELECT Seq, Grp, Sub, Leaf, IsGrandTotal, SampleCount FROM #R WHERE RowYear = 0 AND RowMonth = 0),
	g AS (SELECT Grp, GrpRank = ROW_NUMBER() OVER (ORDER BY IIF(Grp = 1, 0, 1), SampleCount DESC, Seq)
		  FROM t WHERE IsGrandTotal = 0 AND Sub = 0 AND Leaf = 0),
	l AS (SELECT Grp, Sub, Leaf, LeafRank = ROW_NUMBER() OVER (PARTITION BY Grp, Sub ORDER BY SampleCount DESC, Seq)
		  FROM t WHERE Leaf > 0)
	SELECT t.Seq,
		   SortOrder = IIF(t.IsGrandTotal = 1, 999, g.GrpRank * 100 + t.Sub * 10 + ISNULL(l.LeafRank, 0)),
		   Code = IIF(t.IsGrandTotal = 0 AND t.Sub = 0 AND t.Leaf = 0, NCHAR(64 + g.GrpRank), NULL)
	INTO #O
	FROM t
	LEFT JOIN g ON g.Grp = t.Grp
	LEFT JOIN l ON l.Grp = t.Grp AND l.Sub = t.Sub AND l.Leaf = t.Leaf;

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT o.SortOrder, ISNULL(o.Code, r.Code) AS Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   r.RowYear, r.RowMonth, r.SampleCount
	FROM #R r
	JOIN #O o ON o.Seq = r.Seq
	ORDER BY o.SortOrder, r.RowYear, r.RowMonth;

	-- Result set 2: KPI cards (Billable billed / unbilled, Self Pay section).
	SELECT TotalSamples,
		   BillableBilled AS BilledCount,
		   BillableUnbilled AS UnbilledCount,
		   SelfPay AS SelfPayCount
	FROM #M
	WHERE RowYear = 0 AND RowMonth = 0;
END;
GO

EXEC dbo.usp_RefreshTD_LISSummary;
GO

PRINT '26_TexasDiagnostic_LISSummary_SP.sql completed.';
GO
