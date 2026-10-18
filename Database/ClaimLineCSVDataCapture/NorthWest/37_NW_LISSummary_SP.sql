/* =============================================================================
   NorthWest - LIS Summary built entirely in SQL
   File     : 37_NW_LISSummary_SP.sql
   Database : NWL_LRN

   Same design as WellHealth / Analyze Pathology (26_*_LISSummary_SP.sql): rows,
   logic, sort order, month / year / grand totals and the KPI cards all come from
   dbo.usp_GetNW_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate,
             the DaqBilling REQ_Collect_Date). 'Received' (RequestReceivedDate) and
             'Resulted' (ResultDate) stay available for the page's date-type selector.
   Scope   : Incorrect DOS = Blank on every row, Total Samples included.
   Counting: Count (Accession) - non-blank Accession per LIMSMaster row.
   Filters : Panel = PanelType, Clinic = ClinicName, Ref Phy = ReferringProvider
             (same values as the page's dropdowns).

   LIMSMaster columns behind the logic sheet:
     Bill To                    = BilledTo
     Bill Status                = BillStatus
     Final Status (section A, E)= FinalStatus  (exact value)
     Final Status (B, C, D, F, G) - the short statuses (Not Resulted, Non Billable, Self Pay,
                                  Do not Bill, Test Samples, Sample Rejected) are in Category;
                                  FinalStatus carries "Non Billable - Excluded ..." and
                                  "Charges Created and Not Submitted".
     Source                     = SourceSystem
     Charges not entered status = ChargesNotEnteredStatus

   Rows (client logic sheet):
     A  Insurance Bill           Billed (5 Final Status rows) / Unbilled (Charge not Created by
                                 Source and Charges not entered status, Non Billable x3,
                                 Charges Created and Not Submitted by Source)
     B  Yet to be validate       Billed / Unbilled (Not Resulted, Non Billable, Charges Created)
     C  Self pay                 Billed / Unbilled (Non Billable, Self Pay, Charges Created)
     D  Client Bills             Billed / Unbilled (Non Billable, Do not Bill, Charges Created)
     E  ADCS Claims              Billed / Unbilled (Non Billable - Excluded Organizations)
     F  System Test              Billed / Unbilled (Non Billable, Test Samples)
     G  Rejections               Billed / Unbilled (Sample Rejected)
        Total Samples            Incorrect DOS = Blank (returned as the grand-total row)

   Objects:
     dbo.NW_LIS_StatusSummary      day x dimension x status aggregate (Incorrect DOS blank only)
     dbo.usp_RefreshNW_LISSummary  rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetNW_LISSummary      read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'NWL_LRN'
BEGIN
	RAISERROR('Run 37_NW_LISSummary_SP.sql on the NWL_LRN database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.NW_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.NW_LIS_StatusSummary
(
	DateType          VARCHAR(10)    NOT NULL,
	GroupDate         DATE           NOT NULL,
	Panel             NVARCHAR(400)  NOT NULL,
	Clinic            NVARCHAR(400)  NOT NULL,
	RefPhy            NVARCHAR(400)  NOT NULL,
	SalesRep          NVARCHAR(400)  NOT NULL,
	Collector         NVARCHAR(400)  NOT NULL,
	BillTo            NVARCHAR(255)  NOT NULL,
	BillStatus        NVARCHAR(255)  NOT NULL,
	FinalStatus       NVARCHAR(255)  NOT NULL,
	Category          NVARCHAR(255)  NOT NULL,
	Source            NVARCHAR(255)  NOT NULL,
	ChargesNotEntered NVARCHAR(255)  NOT NULL,
	SampleCount       INT            NOT NULL,
	RefreshedAt       DATETIME       NOT NULL CONSTRAINT DF_NW_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_NW_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.NW_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_NW_LIS_StatusSummary_Date
		ON dbo.NW_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshNW_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.NW_LIS_StatusSummary;

	INSERT INTO dbo.NW_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 BillTo, BillStatus, FinalStatus, Category, Source, ChargesNotEntered, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   ISNULL(LTRIM(RTRIM(l.PanelType)), N''),
		   ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
		   ISNULL(LTRIM(RTRIM(l.ReferringProvider)), N''),
		   N'',
		   N'',
		   ISNULL(LTRIM(RTRIM(l.BilledTo)), N''),
		   ISNULL(LTRIM(RTRIM(l.BillStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.FinalStatus)), N''),
		   ISNULL(LTRIM(RTRIM(l.Category)), N''),
		   ISNULL(LTRIM(RTRIM(l.SourceSystem)), N''),
		   ISNULL(LTRIM(RTRIM(l.ChargesNotEnteredStatus)), N''),
		   COUNT(NULLIF(LTRIM(RTRIM(l.Accession)), N'')),
		   GETDATE()
	FROM dbo.LIMSMaster l
	CROSS APPLY (VALUES
		('Collected', TRY_CAST(l.RequestCollectDate  AS DATE)),
		('Received',  TRY_CAST(l.RequestReceivedDate AS DATE)),
		('Resulted',  TRY_CAST(l.ResultDate          AS DATE))
	) d(DateType, GroupDate)
	WHERE d.GroupDate IS NOT NULL
	  AND YEAR(d.GroupDate) > 1900
	  AND NULLIF(LTRIM(RTRIM(l.IncorrectDOS)), N'') IS NULL
	GROUP BY d.DateType, d.GroupDate,
			 ISNULL(LTRIM(RTRIM(l.PanelType)), N''),
			 ISNULL(LTRIM(RTRIM(l.ClinicName)), N''),
			 ISNULL(LTRIM(RTRIM(l.ReferringProvider)), N''),
			 ISNULL(LTRIM(RTRIM(l.BilledTo)), N''),
			 ISNULL(LTRIM(RTRIM(l.BillStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.FinalStatus)), N''),
			 ISNULL(LTRIM(RTRIM(l.Category)), N''),
			 ISNULL(LTRIM(RTRIM(l.SourceSystem)), N''),
			 ISNULL(LTRIM(RTRIM(l.ChargesNotEnteredStatus)), N'');

	PRINT 'usp_RefreshNW_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_LISSummary
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
		   a.BillTo, a.BillStatus, a.FinalStatus, a.Category, a.Source, a.ChargesNotEntered,
		   SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.NW_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate),
			 a.BillTo, a.BillStatus, a.FinalStatus, a.Category, a.Source, a.ChargesNotEntered;

	-- BT / BS: Bill To and Bill Status codes. St: the short Final Status used by sections B-G.
	DROP TABLE IF EXISTS #C;
	SELECT f.Y, f.M, f.Cnt, f.FinalStatus, f.Source, f.ChargesNotEntered, c.BT, c.BS, c.St
	INTO #C
	FROM #F f
	CROSS APPLY (SELECT
		BT = CASE
				WHEN f.BillTo IN (N'Insurance Bill', N'Insurance Bills') THEN 'INS'
				WHEN f.BillTo IN (N'Yet to be validate', N'Yet to be validated') THEN 'YTBV'
				WHEN f.BillTo IN (N'Self pay', N'Selfpay') THEN 'SELF'
				WHEN f.BillTo IN (N'Client Bills', N'Client Bill') THEN 'CLIENT'
				WHEN f.BillTo = N'ADCS Claims' THEN 'ADCS'
				WHEN f.BillTo = N'System Test' THEN 'TEST'
				WHEN f.BillTo IN (N'Rejections', N'Rejection') THEN 'REJ'
				ELSE ''
			 END,
		BS = CASE
				WHEN f.BillStatus = N'Billed' THEN 'B'
				WHEN f.BillStatus IN (N'Unbilled', N'Not Billed') THEN 'U'
				ELSE ''
			 END,
		St = CASE
				WHEN f.FinalStatus LIKE N'Non Billable%'
				  OR f.Category IN (N'Nonbillable', N'Non Billable', N'Non-Billable') THEN N'Non Billable'
				WHEN f.FinalStatus = N'Charges Created and Not Submitted' THEN N'Charges Created and Not Submitted'
				ELSE COALESCE(NULLIF(f.Category, N''), f.FinalStatus)
			 END) c;

	-- One row per summary line. NULL match columns mean "any value".
	DROP TABLE IF EXISTS #Rows;
	CREATE TABLE #Rows
	(
		SortOrder         INT            NOT NULL PRIMARY KEY,
		Code              NVARCHAR(5)    COLLATE DATABASE_DEFAULT NOT NULL,
		Description       NVARCHAR(100)  COLLATE DATABASE_DEFAULT NOT NULL,
		RowLevel          INT            NOT NULL,
		Logic             NVARCHAR(400)  COLLATE DATABASE_DEFAULT NOT NULL,
		IsGrandTotal      INT            NOT NULL,
		BT                VARCHAR(10)    COLLATE DATABASE_DEFAULT NULL,
		BS                CHAR(1)        COLLATE DATABASE_DEFAULT NULL,
		FinalStatus       NVARCHAR(255)  COLLATE DATABASE_DEFAULT NULL,
		St                NVARCHAR(255)  COLLATE DATABASE_DEFAULT NULL,
		Source            NVARCHAR(255)  COLLATE DATABASE_DEFAULT NULL,
		ChargesNotEntered NVARCHAR(255)  COLLATE DATABASE_DEFAULT NULL
	);

	DECLARE @b NCHAR(1) = NCHAR(8226);
	INSERT INTO #Rows (SortOrder, Code, Description, RowLevel, Logic, IsGrandTotal, BT, BS, FinalStatus, St, Source, ChargesNotEntered)
	VALUES
	-- A  Insurance Bill
	( 10, N'A', N'Insurance Bill',                         0, N'Bill To = Insurance Bill AND Incorrect DOS = Blank', 0, 'INS', NULL, NULL, NULL, NULL, NULL),
	( 20, N'1', N'Billed',                                 1, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'INS', 'B', NULL, NULL, NULL, NULL),
	( 30, @b,   N'Claim Submitted in Webpm',               2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Billed AND Final Status = Claim Submitted in Webpm', 0, 'INS', 'B', N'Claim Submitted in Webpm', NULL, NULL, NULL),
	( 40, @b,   N'Claim Submitted in Daqbilling',          2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Billed AND Final Status = Claim Submitted in DaqBilling', 0, 'INS', 'B', N'Claim Submitted in DaqBilling', NULL, NULL, NULL),
	( 50, @b,   N'Claim Submitted in Daq & Webpm',         2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Billed AND Final Status = Claim Submitted in Daq & Webpm', 0, 'INS', 'B', N'Claim Submitted in Daq & Webpm', NULL, NULL, NULL),
	( 60, @b,   N'Non Billable - Excluded Organizations',  2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Billed AND Final Status = Non Billable - Excluded Organizations', 0, 'INS', 'B', N'Non Billable - Excluded Organizations', NULL, NULL, NULL),
	( 70, @b,   N'Manually Pushed in Emedix',              2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Billed AND Final Status = Manually Pushed in Emedix', 0, 'INS', 'B', N'Manually Pushed in Emedix', NULL, NULL, NULL),
	( 80, N'2', N'Unbilled',                               1, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'INS', 'U', NULL, NULL, NULL, NULL),
	( 90, @b,   N'Charge not Created',                     2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charge Not Created', 0, 'INS', 'U', N'Charge Not Created', NULL, NULL, NULL),
	(100, @b,   N'Webpm',                                  3, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Webpm', 0, 'INS', 'U', N'Charge Not Created', NULL, N'Webpm', NULL),
	(110, N'*', N'No Charges found in Webpm',              4, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Webpm AND Charges not entered status = No Charges found in Webpm', 0, 'INS', 'U', N'Charge Not Created', NULL, N'Webpm', N'No Charges found in Webpm'),
	(120, N'*', N'Unposted Charges in Webpm',              4, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Webpm AND Charges not entered status = Unposted Charges in Webpm', 0, 'INS', 'U', N'Charge Not Created', NULL, N'Webpm', N'Unposted Charges in Webpm'),
	(130, @b,   N'Daqbilling',                             3, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Source = Daqbilling', 0, 'INS', 'U', N'Charge Not Created', NULL, N'Daqbilling', NULL),
	(140, @b,   N'Non Billable - Excluded PAP Codes',      2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded PAP Codes', 0, 'INS', 'U', N'Non Billable - Excluded PAP Codes', NULL, NULL, NULL),
	(150, @b,   N'Non Billable - Excluded Validity Codes', 2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Validity Codes', 0, 'INS', 'U', N'Non Billable - Excluded Validity Codes', NULL, NULL, NULL),
	(160, @b,   N'Non Billable - Excluded Organizations',  2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Organizations', 0, 'INS', 'U', N'Non Billable - Excluded Organizations', NULL, NULL, NULL),
	(170, @b,   N'Charges Created and Not Submitted',      2, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted', 0, 'INS', 'U', N'Charges Created and Not Submitted', NULL, NULL, NULL),
	(180, @b,   N'Webpm',                                  3, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted AND Source = Webpm', 0, 'INS', 'U', N'Charges Created and Not Submitted', NULL, N'Webpm', NULL),
	(190, @b,   N'Daqbilling',                             3, N'Bill To = Insurance Bill AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted AND Source = Daqbilling', 0, 'INS', 'U', N'Charges Created and Not Submitted', NULL, N'Daqbilling', NULL),
	-- B  Yet to be validate
	(200, N'B', N'Yet to be validate',                     0, N'Bill To = Yet to be validate AND Incorrect DOS = Blank', 0, 'YTBV', NULL, NULL, NULL, NULL, NULL),
	(210, N'1', N'Billed',                                 1, N'Bill To = Yet to be validate AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'YTBV', 'B', NULL, NULL, NULL, NULL),
	(220, N'2', N'Unbilled',                               1, N'Bill To = Yet to be validate AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'YTBV', 'U', NULL, NULL, NULL, NULL),
	(230, @b,   N'Not Resulted',                           2, N'Bill To = Yet to be validate AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Not Resulted', 0, 'YTBV', 'U', NULL, N'Not Resulted', NULL, NULL),
	(240, @b,   N'Non Billable',                           2, N'Bill To = Yet to be validate AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable', 0, 'YTBV', 'U', NULL, N'Non Billable', NULL, NULL),
	(250, @b,   N'Charges Created and Not Submitted',      2, N'Bill To = Yet to be validate AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted', 0, 'YTBV', 'U', NULL, N'Charges Created and Not Submitted', NULL, NULL),
	-- C  Self pay
	(300, N'C', N'Self pay',                               0, N'Bill To = Self pay AND Incorrect DOS = Blank', 0, 'SELF', NULL, NULL, NULL, NULL, NULL),
	(310, N'1', N'Billed',                                 1, N'Bill To = Self pay AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'SELF', 'B', NULL, NULL, NULL, NULL),
	(320, N'2', N'Unbilled',                               1, N'Bill To = Self pay AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'SELF', 'U', NULL, NULL, NULL, NULL),
	(330, @b,   N'Non Billable',                           2, N'Bill To = Self pay AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable', 0, 'SELF', 'U', NULL, N'Non Billable', NULL, NULL),
	(340, @b,   N'Self Pay',                               2, N'Bill To = Self pay AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Self Pay', 0, 'SELF', 'U', NULL, N'Self Pay', NULL, NULL),
	(350, @b,   N'Charges Created and Not Submitted',      2, N'Bill To = Self pay AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted', 0, 'SELF', 'U', NULL, N'Charges Created and Not Submitted', NULL, NULL),
	-- D  Client Bills
	(400, N'D', N'Client Bills',                           0, N'Bill To = Client Bills AND Incorrect DOS = Blank', 0, 'CLIENT', NULL, NULL, NULL, NULL, NULL),
	(410, N'1', N'Billed',                                 1, N'Bill To = Client Bills AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'CLIENT', 'B', NULL, NULL, NULL, NULL),
	(420, N'2', N'Unbilled',                               1, N'Bill To = Client Bills AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'CLIENT', 'U', NULL, NULL, NULL, NULL),
	(430, @b,   N'Non Billable',                           2, N'Bill To = Client Bills AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable', 0, 'CLIENT', 'U', NULL, N'Non Billable', NULL, NULL),
	(440, @b,   N'Do not Bill',                            2, N'Bill To = Client Bills AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Do Not Bill', 0, 'CLIENT', 'U', NULL, N'Do Not Bill', NULL, NULL),
	(450, @b,   N'Charges Created and Not Submitted',      2, N'Bill To = Client Bills AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted', 0, 'CLIENT', 'U', NULL, N'Charges Created and Not Submitted', NULL, NULL),
	-- E  ADCS Claims
	(500, N'E', N'ADCS Claims',                            0, N'Bill To = ADCS Claims AND Incorrect DOS = Blank', 0, 'ADCS', NULL, NULL, NULL, NULL, NULL),
	(510, N'1', N'Billed',                                 1, N'Bill To = ADCS Claims AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'ADCS', 'B', NULL, NULL, NULL, NULL),
	(520, N'2', N'Unbilled',                               1, N'Bill To = ADCS Claims AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'ADCS', 'U', NULL, NULL, NULL, NULL),
	(530, @b,   N'Non Billable - Excluded Organizations',  2, N'Bill To = ADCS Claims AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Organizations', 0, 'ADCS', 'U', N'Non Billable - Excluded Organizations', NULL, NULL, NULL),
	-- F  System Test
	(600, N'F', N'System Test',                            0, N'Bill To = System Test AND Incorrect DOS = Blank', 0, 'TEST', NULL, NULL, NULL, NULL, NULL),
	(610, N'1', N'Billed',                                 1, N'Bill To = System Test AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'TEST', 'B', NULL, NULL, NULL, NULL),
	(620, N'2', N'Unbilled',                               1, N'Bill To = System Test AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'TEST', 'U', NULL, NULL, NULL, NULL),
	(630, @b,   N'Non Billable',                           2, N'Bill To = System Test AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Non Billable', 0, 'TEST', 'U', NULL, N'Non Billable', NULL, NULL),
	(640, @b,   N'Test Samples',                           2, N'Bill To = System Test AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Test Samples', 0, 'TEST', 'U', NULL, N'Test Samples', NULL, NULL),
	-- G  Rejections
	(700, N'G', N'Rejections',                             0, N'Bill To = Rejections AND Incorrect DOS = Blank', 0, 'REJ', NULL, NULL, NULL, NULL, NULL),
	(710, N'1', N'Billed',                                 1, N'Bill To = Rejections AND Incorrect DOS = Blank AND Bill Status = Billed', 0, 'REJ', 'B', NULL, NULL, NULL, NULL),
	(720, N'2', N'Unbilled',                               1, N'Bill To = Rejections AND Incorrect DOS = Blank AND Bill Status = Unbilled', 0, 'REJ', 'U', NULL, NULL, NULL, NULL),
	(730, @b,   N'Sample Rejected',                        2, N'Bill To = Rejections AND Incorrect DOS = Blank AND Bill Status = Unbilled AND Final Status = Sample Rejected', 0, 'REJ', 'U', NULL, N'Sample Rejected', NULL, NULL),
	-- Total Samples (grand total)
	(999, N'',  N'Total Samples',                          0, N'Incorrect DOS = Blank', 1, NULL, NULL, NULL, NULL, NULL, NULL);

	DROP TABLE IF EXISTS #Counts;
	SELECT r.SortOrder,
		   ISNULL(c.Y, 0) AS RowYear,
		   CASE WHEN GROUPING(c.M) = 1 THEN 0 ELSE c.M END AS RowMonth,
		   SUM(c.Cnt) AS Cnt
	INTO #Counts
	FROM #C c
	INNER JOIN #Rows r
		ON  (r.BT                IS NULL OR r.BT                = c.BT)
		AND (r.BS                IS NULL OR r.BS                = c.BS)
		AND (r.FinalStatus       IS NULL OR r.FinalStatus       = c.FinalStatus)
		AND (r.St                IS NULL OR r.St                = c.St)
		AND (r.Source            IS NULL OR r.Source            = c.Source)
		AND (r.ChargesNotEntered IS NULL OR r.ChargesNotEntered = c.ChargesNotEntered)
	GROUP BY GROUPING SETS ((r.SortOrder, c.Y, c.M), (r.SortOrder, c.Y), (r.SortOrder));

	-- Month columns, year columns (RowMonth = 0) and the grand total (0, 0); always at least (0, 0).
	DROP TABLE IF EXISTS #P;
	SELECT ISNULL(Y, 0) AS RowYear,
		   CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth
	INTO #P
	FROM #F
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	-- Result set 1: ordered rows. IsGrandTotal = 1 is the table's closing total row.
	SELECT r.SortOrder, r.Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   p.RowYear, p.RowMonth, ISNULL(k.Cnt, 0) AS SampleCount
	FROM #Rows r
	CROSS JOIN #P p
	LEFT JOIN #Counts k
		ON k.SortOrder = r.SortOrder AND k.RowYear = p.RowYear AND k.RowMonth = p.RowMonth
	ORDER BY r.SortOrder, p.RowYear, p.RowMonth;

	-- Result set 2: KPI cards (Insurance Bill billed / unbilled, Self pay section).
	SELECT ISNULL(MAX(CASE WHEN SortOrder = 999 THEN Cnt END), 0) AS TotalSamples,
		   ISNULL(MAX(CASE WHEN SortOrder =  20 THEN Cnt END), 0) AS BilledCount,
		   ISNULL(MAX(CASE WHEN SortOrder =  80 THEN Cnt END), 0) AS UnbilledCount,
		   ISNULL(MAX(CASE WHEN SortOrder = 300 THEN Cnt END), 0) AS SelfPayCount
	FROM #Counts
	WHERE RowYear = 0 AND RowMonth = 0;
END;
GO

EXEC dbo.usp_RefreshNW_LISSummary;
GO

PRINT '37_NW_LISSummary_SP.sql completed.';
GO
