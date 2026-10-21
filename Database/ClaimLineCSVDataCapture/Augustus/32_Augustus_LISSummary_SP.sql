/* =============================================================================
   Augustus - LIS Summary built entirely in SQL
   Database : Augustus_LRN

   Same design as WellHealth / Analyze Pathology (26_*_LISSummary_SP.sql): rows,
   logic, sort order, month / year / grand totals and the KPI cards all come from
   dbo.usp_GetAug_LISSummary. The dashboard (page, Excel export and the ReportWorker
   LIS workbook) only lays the result out.

   Columns : Date of Service month / year (DateType 'Collected' = RequestCollectDate).
             'Received' (ReqReceivedDate) and 'Resulted' (ResultDate) stay available
             for the page's date-type selector.
   Counting: Count (Accession) - non-blank Accession per LIMSMaster row.
   Filters : Panel = PanelName, Clinic = ClinicName,
             Ref Phy = DoctorLastName + ',' + DoctorFirstName, else DoctorMiddleName
             (same expressions as the page's dropdowns).

   LIMS stores "Insurance Bill" / "Client Bill". The logic sheet says
   "Insurance Bills" / "Client Bills". Matching follows the dashboard
   (NormalizeBillTo, then a compare key that ignores case, spaces and a trailing S),
   so both wordings count the same rows. "Self pay" and "Self Pay" both count as Self pay.

   Rows (client logic sheet):
     A  Insurance Bill                 Bill to = Insurance Bills
     1    Billed                       ... AND Bill status = Billed
     *      Claim Submitted in IRCM    ... AND Final Status = Claim Submitted in IRCM
     *      Claim Submitted in Daqbilling
     *      Claim Submitted in Altumed
     2    Unbilled                     ... AND Bill status = Unbilled
     *      Charges Entered in Altumed ... AND Final Status = Charges Entered in Altumed
     *      Insurance name not listed  ... AND Final Status = Insurance Name Not Listed
     *      Resulted Yet to be Billed  ... AND Final Status = Resulted yet to be billed
     B  Yet to be Validated            Bill to = Yet to be Validated
     1    Billed
     C  Client Bills                   Bill to = Client Bills
     1    Billed
     D  System Test                    Bill to = System Test
     1    Billed
     E  Self pay                       Bill to = Self pay
     1    Billed
        Total Samples                  all samples (returned as the grand-total row)

   Objects:
     dbo.fn_Aug_LisKey             letters-and-digits compare key
     dbo.Aug_LIS_StatusSummary     day x dimension x status aggregate
     dbo.usp_RefreshAug_LISSummary rebuilds the aggregate from dbo.LIMSMaster
     dbo.usp_GetAug_LISSummary     read SP (result set 1 = rows, 2 = KPI cards)
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'Augustus_LRN'
BEGIN
	RAISERROR('Run 32_Augustus_LISSummary_SP.sql on the Augustus_LRN database.', 16, 1);
	SET NOEXEC ON;
END
GO

CREATE OR ALTER FUNCTION dbo.fn_Aug_LisKey (@Value NVARCHAR(400))
RETURNS NVARCHAR(400)
WITH SCHEMABINDING
AS
BEGIN
	DECLARE @s NVARCHAR(400) = UPPER(ISNULL(@Value, N''));
	DECLARE @i INT = PATINDEX(N'%[^A-Z0-9]%', @s);
	WHILE @i > 0
	BEGIN
		SET @s = STUFF(@s, @i, 1, N'');
		SET @i = PATINDEX(N'%[^A-Z0-9]%', @s);
	END
	RETURN @s;
END;
GO

IF OBJECT_ID(N'dbo.Aug_LIS_StatusSummary', N'U') IS NULL
CREATE TABLE dbo.Aug_LIS_StatusSummary
(
	DateType      VARCHAR(10)    NOT NULL,
	GroupDate     DATE           NOT NULL,
	Panel         NVARCHAR(400)  NOT NULL,
	Clinic        NVARCHAR(400)  NOT NULL,
	RefPhy        NVARCHAR(400)  NOT NULL,
	SalesRep      NVARCHAR(400)  NOT NULL,
	Collector     NVARCHAR(400)  NOT NULL,
	BillTo        NVARCHAR(255)  NOT NULL,
	BillingStatus NVARCHAR(255)  NOT NULL,
	FinalStatus   NVARCHAR(255)  NOT NULL,
	SampleCount   INT            NOT NULL,
	RefreshedAt   DATETIME       NOT NULL CONSTRAINT DF_Aug_LIS_StatusSummary_RefreshedAt DEFAULT (GETDATE())
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_Aug_LIS_StatusSummary_Date'
               AND object_id = OBJECT_ID(N'dbo.Aug_LIS_StatusSummary'))
	CREATE CLUSTERED INDEX IX_Aug_LIS_StatusSummary_Date
		ON dbo.Aug_LIS_StatusSummary (DateType, GroupDate);
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshAug_LISSummary
AS
BEGIN
	SET NOCOUNT ON;

	TRUNCATE TABLE dbo.Aug_LIS_StatusSummary;

	INSERT INTO dbo.Aug_LIS_StatusSummary
		(DateType, GroupDate, Panel, Clinic, RefPhy, SalesRep, Collector,
		 BillTo, BillingStatus, FinalStatus, SampleCount, RefreshedAt)
	SELECT d.DateType, d.GroupDate,
		   LEFT(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), l.PanelName))), N''), N''), 400),
		   LEFT(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), l.ClinicName))), N''), N''), 400),
		   LEFT(ISNULL(ISNULL(CONVERT(nvarchar(4000), l.DoctorLastName) + N',' + CONVERT(nvarchar(4000), l.DoctorFirstName),
		                      CONVERT(nvarchar(4000), l.DoctorMiddleName)), N''), 400),
		   N'',
		   N'',
		   LEFT(ISNULL(LTRIM(RTRIM(l.BillTo)), N''), 255),
		   LEFT(ISNULL(LTRIM(RTRIM(l.BillingStatus)), N''), 255),
		   LEFT(ISNULL(LTRIM(RTRIM(l.FinalStatus)), N''), 255),
		   COUNT(NULLIF(LTRIM(RTRIM(l.Accession)), N'')),
		   GETDATE()
	FROM dbo.LIMSMaster l
	CROSS APPLY (VALUES
		('Collected', l.RequestCollectDate),
		('Received',  l.ReqReceivedDate),
		('Resulted',  l.ResultDate)
	) d(DateType, GroupDate)
	WHERE d.GroupDate IS NOT NULL
	  AND YEAR(d.GroupDate) > 1900
	GROUP BY d.DateType, d.GroupDate,
			 LEFT(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), l.PanelName))), N''), N''), 400),
			 LEFT(ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), l.ClinicName))), N''), N''), 400),
			 LEFT(ISNULL(ISNULL(CONVERT(nvarchar(4000), l.DoctorLastName) + N',' + CONVERT(nvarchar(4000), l.DoctorFirstName),
			                  CONVERT(nvarchar(4000), l.DoctorMiddleName)), N''), 400),
			 LEFT(ISNULL(LTRIM(RTRIM(l.BillTo)), N''), 255),
			 LEFT(ISNULL(LTRIM(RTRIM(l.BillingStatus)), N''), 255),
			 LEFT(ISNULL(LTRIM(RTRIM(l.FinalStatus)), N''), 255);

	PRINT 'usp_RefreshAug_LISSummary completed: ' + CONVERT(VARCHAR(20), @@ROWCOUNT) + ' aggregate row(s).';
END;
GO

/* Filters use the page's '|' multi-select separator. */
CREATE OR ALTER PROCEDURE dbo.usp_GetAug_LISSummary
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
	SELECT f.Dim, LEFT(LTRIM(RTRIM(s.value)), 400)
	FROM (VALUES ('Panel', @Panel), ('Clinic', @Clinic), ('RefPhy', @RefPhy),
				 ('SalesRep', @SalesRep), ('Collector', @Collector)) f(Dim, Vals)
	CROSS APPLY STRING_SPLIT(ISNULL(f.Vals, N''), N'|') s
	WHERE LTRIM(RTRIM(s.value)) <> N'';

	DROP TABLE IF EXISTS #F;
	SELECT YEAR(a.GroupDate) AS Y, MONTH(a.GroupDate) AS M,
		   a.BillTo, a.BillingStatus, a.FinalStatus, SUM(a.SampleCount) AS Cnt
	INTO #F
	FROM dbo.Aug_LIS_StatusSummary a
	WHERE a.DateType = @DateType
	  AND (@DateFrom IS NULL OR a.GroupDate >= @DateFrom)
	  AND (@DateTo   IS NULL OR a.GroupDate <= @DateTo)
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Panel')     OR a.Panel     IN (SELECT Val FROM @Filters WHERE Dim = 'Panel'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Clinic')    OR a.Clinic    IN (SELECT Val FROM @Filters WHERE Dim = 'Clinic'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'RefPhy')    OR a.RefPhy    IN (SELECT Val FROM @Filters WHERE Dim = 'RefPhy'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'SalesRep')  OR a.SalesRep  IN (SELECT Val FROM @Filters WHERE Dim = 'SalesRep'))
	  AND (NOT EXISTS (SELECT 1 FROM @Filters WHERE Dim = 'Collector') OR a.Collector IN (SELECT Val FROM @Filters WHERE Dim = 'Collector'))
	GROUP BY YEAR(a.GroupDate), MONTH(a.GroupDate), a.BillTo, a.BillingStatus, a.FinalStatus;

	-- Same buckets as SqlLisSummaryRepository.NormalizeBillTo / NormalizeBillStatus.
	DROP TABLE IF EXISTS #C;
	SELECT f.Y, f.M, f.Cnt,
		   CASE
				WHEN bk.K LIKE N'%INSURANCE%' OR bk.K LIKE N'%INS%' OR bk.K LIKE N'%PAYER%' THEN N'INSURANCE'
				WHEN bk.K LIKE N'%SELFPAY%' OR bk.K LIKE N'%PATIENT%' THEN N'SELFPAY'
				WHEN bk.K LIKE N'%CLIENT%' THEN N'CLIENT'
				WHEN bk.K LIKE N'%VALIDATE%' OR bk.K LIKE N'%UNKNOWN%' THEN N'YTBV'
				WHEN bk.K = N'SYSTEMTEST' THEN N'SYSTEM'
				ELSE N''
		   END AS BillToBucket,
		   CASE
				WHEN sk.K = N'NOBILL' THEN N''
				WHEN sk.K LIKE N'%UNBILL%' OR sk.K LIKE N'%NOTBILL%' OR sk.K LIKE N'%PENDINGBILL%' THEN N'UNBILLED'
				WHEN sk.K LIKE N'%BILLED%' OR sk.K LIKE N'%SUBMITTED%'
				  OR sk.K LIKE N'%CHARGECREATED%' OR sk.K LIKE N'%CLAIMCREATED%' THEN N'BILLED'
				ELSE N''
		   END AS BillStatusBucket,
		   fk.K AS FinalKey
	INTO #C
	FROM #F f
	CROSS APPLY (SELECT K = dbo.fn_Aug_LisKey(f.BillTo)) bk
	CROSS APPLY (SELECT K = dbo.fn_Aug_LisKey(f.BillingStatus)) sk
	CROSS APPLY (SELECT K = dbo.fn_Aug_LisKey(f.FinalStatus)) fk;

	DROP TABLE IF EXISTS #M;
	SELECT
		ISNULL(Y, 0) AS RowYear,
		CASE WHEN GROUPING(M) = 1 THEN 0 ELSE M END AS RowMonth,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' THEN Cnt END), 0) AS InsuranceBills,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'BILLED' THEN Cnt END), 0) AS InsuranceBilled,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'BILLED' AND FinalKey = N'CLAIMSUBMITTEDINIRCM' THEN Cnt END), 0) AS ClaimIrcm,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'BILLED' AND FinalKey = N'CLAIMSUBMITTEDINDAQBILLING' THEN Cnt END), 0) AS ClaimDaq,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'BILLED' AND FinalKey = N'CLAIMSUBMITTEDINALTUMED' THEN Cnt END), 0) AS ClaimAltumed,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'UNBILLED' THEN Cnt END), 0) AS InsuranceUnbilled,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'UNBILLED' AND FinalKey = N'INSURANCENAMENOTLISTED' THEN Cnt END), 0) AS InsuranceNameNotListed,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'UNBILLED' AND FinalKey = N'RESULTEDYETTOBEBILLED' THEN Cnt END), 0) AS ResultedYetToBeBilled,
		ISNULL(SUM(CASE WHEN BillToBucket = N'INSURANCE' AND BillStatusBucket = N'UNBILLED' AND FinalKey = N'CHARGESENTEREDINALTUMED' THEN Cnt END), 0) AS ChargesEnteredAltumed,
		ISNULL(SUM(CASE WHEN BillToBucket = N'YTBV' THEN Cnt END), 0) AS YetToBeValidated,
		ISNULL(SUM(CASE WHEN BillToBucket = N'YTBV' AND BillStatusBucket = N'BILLED' THEN Cnt END), 0) AS YetToBeValidatedBilled,
		ISNULL(SUM(CASE WHEN BillToBucket = N'CLIENT' THEN Cnt END), 0) AS ClientBills,
		ISNULL(SUM(CASE WHEN BillToBucket = N'CLIENT' AND BillStatusBucket = N'BILLED' THEN Cnt END), 0) AS ClientBillsBilled,
		ISNULL(SUM(CASE WHEN BillToBucket = N'SYSTEM' THEN Cnt END), 0) AS SystemTest,
		ISNULL(SUM(CASE WHEN BillToBucket = N'SYSTEM' AND BillStatusBucket = N'BILLED' THEN Cnt END), 0) AS SystemTestBilled,
		ISNULL(SUM(CASE WHEN BillToBucket = N'SELFPAY' THEN Cnt END), 0) AS SelfPay,
		ISNULL(SUM(CASE WHEN BillToBucket = N'SELFPAY' AND BillStatusBucket = N'BILLED' THEN Cnt END), 0) AS SelfPayBilled,
		ISNULL(SUM(Cnt), 0) AS TotalSamples
	INTO #M
	FROM #C
	GROUP BY GROUPING SETS ((Y, M), (Y), ());

	SELECT r.SortOrder, r.Code, r.Description, r.RowLevel, r.Logic, r.IsGrandTotal,
		   m.RowYear, m.RowMonth, r.SampleCount
	FROM #M m
	CROSS APPLY (VALUES
		( 10, N'A',        N'Insurance Bill',                0, N'Bill to = Insurance Bills', 0, m.InsuranceBills),
		( 20, N'1',        N'Billed',                        1, N'Bill to = Insurance Bills AND Bill status = Billed', 0, m.InsuranceBilled),
		( 30, NCHAR(8226), N'Claim Submitted in IRCM',       2, N'Bill to = Insurance Bills AND Bill status = Billed AND Final Status =  Claim Submitted in IRCM', 0, m.ClaimIrcm),
		( 40, NCHAR(8226), N'Claim Submitted in Daqbilling', 2, N'Bill to = Insurance Bills AND Bill status = Billed AND Final Status =  Claim Submitted in Daqbilling', 0, m.ClaimDaq),
		( 50, NCHAR(8226), N'Claim Submitted in Altumed',    2, N'Bill to = Insurance Bills AND Bill status = Billed AND Final Status =  Claim Submitted in Altumed', 0, m.ClaimAltumed),
		( 60, N'2',        N'Unbilled',                      1, N'Bill to = Insurance Bills AND Bill status = Unbilled', 0, m.InsuranceUnbilled),
		( 70, NCHAR(8226), N'Charges Entered in Altumed',    2, N'Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Charges Entered in Altumed', 0, m.ChargesEnteredAltumed),
		( 80, NCHAR(8226), N'Insurance name not listed',     2, N'Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Insurance Name Not Listed', 0, m.InsuranceNameNotListed),
		( 90, NCHAR(8226), N'Resulted Yet to be Billed',     2, N'Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status =  Resulted yet to be billed', 0, m.ResultedYetToBeBilled),
		(100, N'B',        N'Yet to be Validated',           0, N'Bill to = Yet to be Validated', 0, m.YetToBeValidated),
		(110, N'1',        N'Billed',                        1, N'Bill to = Yet to be Validated AND Bill Status = Billed', 0, m.YetToBeValidatedBilled),
		(120, N'C',        N'Client Bills',                  0, N'Bill to = Client Bills', 0, m.ClientBills),
		(130, N'1',        N'Billed',                        1, N'Bill to = Client Bills AND Bill Status = Billed', 0, m.ClientBillsBilled),
		(140, N'D',        N'System Test',                   0, N'Bill to = System Test', 0, m.SystemTest),
		(150, N'1',        N'Billed',                        1, N'Bill to = System Test AND Bill Status = Billed', 0, m.SystemTestBilled),
		(160, N'E',        N'Self pay',                      0, N'Bill to = Self pay', 0, m.SelfPay),
		(170, N'1',        N'Billed',                        1, N'Bill to = Self pay AND Bill Status = Billed', 0, m.SelfPayBilled),
		(999, N'',         N'Total Samples',                 0, N'Count (Accession Number)', 1, m.TotalSamples)
	) r(SortOrder, Code, Description, RowLevel, Logic, IsGrandTotal, SampleCount)
	ORDER BY r.SortOrder, m.RowYear, m.RowMonth;

	SELECT TotalSamples, InsuranceBilled AS BilledCount, InsuranceUnbilled AS UnbilledCount, SelfPay AS SelfPayCount
	FROM #M
	WHERE RowYear = 0 AND RowMonth = 0;
END;
GO

EXEC dbo.usp_RefreshAug_LISSummary;
GO

PRINT '32_Augustus_LISSummary_SP.sql completed.';
GO
