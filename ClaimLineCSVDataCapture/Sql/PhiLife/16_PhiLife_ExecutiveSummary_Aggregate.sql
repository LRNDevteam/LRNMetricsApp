-- ============================================================
-- PhiLife – Executive Summary Aggregate Table + Refresh SP
-- File : 16_PhiLife_ExecutiveSummary_Aggregate.sql
-- DB   : PhiLife_LRN
--
-- Run order: after ingestion of ClaimLevelData.
-- Called by ClaimLineCSVDataCapture via usp_RefreshPhi_ExecutiveSummary.
--
-- Pattern (same as Collection Summary):
--   usp_RefreshPhi_ExecutiveSummary  → populates Phi_ES_Data (full dataset, no filter)
--   usp_GetPhi_ExecutiveSummary      → no filter  → reads Phi_ES_Data (fast)
--                                       with filter → live query on ClaimLevelData
-- ============================================================
SET NOCOUNT ON;
GO

-- ── 1. Aggregate table ────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'Phi_ES_Data')
CREATE TABLE dbo.Phi_ES_Data
(
    Id          INT             NOT NULL IDENTITY(1,1) PRIMARY KEY,
    RowCode     NVARCHAR(10)    NOT NULL,
    Category    NVARCHAR(100)   NOT NULL,
    Description NVARCHAR(300)   NOT NULL,
    BillYear    INT             NOT NULL,
    BillMonth   INT             NOT NULL,
    MetricValue DECIMAL(18,2)   NOT NULL DEFAULT 0,
    RefreshedAt DATETIME        NOT NULL DEFAULT GETDATE()
);
GO

-- Index for fast no-filter reads
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name='IX_Phi_ES_Data_RowYear' AND object_id=OBJECT_ID('dbo.Phi_ES_Data'))
    CREATE NONCLUSTERED INDEX IX_Phi_ES_Data_RowYear
        ON dbo.Phi_ES_Data (BillYear, BillMonth, RowCode);
GO

-- ── 2. Refresh SP ─────────────────────────────────────────────────────────────
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPhi_ExecutiveSummary
AS
BEGIN
    SET NOCOUNT ON;

    -- ── Build full working set (no date filter) ──────────────────────────────
    DROP TABLE IF EXISTS #Base;

    SELECT
        AccessionNumber,
        YEAR (TRY_CAST(DateofService AS DATE))  AS BillYear,
        MONTH(TRY_CAST(DateofService AS DATE))  AS BillMonth,
        ISNULL(BilledUnbilled, '')              AS BilledUnbilled,
        ISNULL(LTRIM(RTRIM(ClaimStatus)), '')   AS ClaimStatus,
        ISNULL(Panelname,  '')                  AS Panelname,
        ISNULL(PayerType,  '')                  AS PayerType,
        ISNULL(TRY_CAST(ChargeAmount          AS DECIMAL(18,2)), 0) AS ChargeAmount,
        ISNULL(TRY_CAST(InsurancePayment      AS DECIMAL(18,2)), 0) AS InsurancePayment,
        ISNULL(TRY_CAST(PatientPayment        AS DECIMAL(18,2)), 0) AS PatientPayment,
        ISNULL(TRY_CAST(PatientBalance        AS DECIMAL(18,2)), 0) AS PatientBalance,
        ISNULL(TRY_CAST(InsuranceBalance      AS DECIMAL(18,2)), 0) AS InsuranceBalance,
        ISNULL(TRY_CAST(InsuranceAdjustments  AS DECIMAL(18,2)), 0) AS InsuranceAdjustments,
        ISNULL(TRY_CAST(PatientAdjustments    AS DECIMAL(18,2)), 0) AS PatientAdjustments,
        CASE
            WHEN FirstBilledDate IS NOT NULL THEN 1
            WHEN ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> '' THEN 1
            ELSE 0
        END AS IsResulted
    INTO #Base
    FROM dbo.ClaimLevelData
    WHERE TRY_CAST(DateofService AS DATE) IS NOT NULL;

    -- ── Periods = all distinct Year/Month + grand-total sentinel (0,0) ───────
    DROP TABLE IF EXISTS #Periods;
    SELECT DISTINCT BillYear, BillMonth INTO #Periods FROM #Base
    UNION ALL SELECT 0, 0;

    -- ── Compute all metrics into staging ─────────────────────────────────────
    DROP TABLE IF EXISTS #Out;

    SELECT RowCode, Category, Description, BillYear, BillMonth,
           CAST(MetricValue AS DECIMAL(18,2)) AS MetricValue
    INTO #Out
    FROM
    (
        SELECT p.BillYear,p.BillMonth,'A' AS RowCode,'LIS' AS Category,'Total Samples' AS Description,CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'B','LIS','Billable Samples - Resulted',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 GROUP BY p.BillYear,p.BillMonth
-- ── B sub-panels: dynamic – one row per distinct Panelname ─────────────
        -- RowCode = 'B.' + Panelname so rows sort between 'B' and 'C'
        UNION ALL
        SELECT
            p.BillYear, p.BillMonth,
            'B.' + LTRIM(RTRIM(b.Panelname))  AS RowCode,
            'LIS'                              AS Category,
            '  ' + LTRIM(RTRIM(b.Panelname))  AS Description,
            CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) AS MetricValue
        FROM #Periods p
        LEFT JOIN #Base b
             ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth))
             AND b.IsResulted=1
             AND b.Panelname <> ''
        GROUP BY p.BillYear, p.BillMonth, LTRIM(RTRIM(b.Panelname))
        UNION ALL SELECT p.BillYear,p.BillMonth,'C','LIS','Billed to Insurance',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Billed' AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'D','LIS','Not Entered in AMD (Insurance Unbilled)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Not Entered in AMD' AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'D-Recv','LIS','  Received',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD') GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'D-BRR','LIS','  Billing Review Required',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' AND b.ClaimStatus='Billing Review Required' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'D-Coll','LIS','  Collected',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.PayerType='Insurance' AND b.ClaimStatus='Collected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'E','LIS','Unbilled Not Released to Payer (EDI Hold)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.BilledUnbilled='Unbilled' AND b.ClaimStatus='Entered' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'F','LIS','Client Bill',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Client Bill' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'F-AMD','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Client Bill' AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'F-Bill','LIS','  Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Client Bill' AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'G','LIS','Self Pay',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Self Pay' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'G-Bill','LIS','  Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Self Pay' AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'G-AMD','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='Self Pay' AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'H','LIS','Test Entries',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType<>'No Bill' AND b.ClaimStatus='Test Entries' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'H-AMD','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType<>'No Bill' AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'H-Bill','LIS','  Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType<>'No Bill' AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'I','LIS','Rejected Sample',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Rejected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'I-AMD','LIS','  Not Entered in AMD',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Not Entered in AMD' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'I-Bill','LIS','  Billed (Rejected)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.ClaimStatus='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'J','LIS','Payment Method No Bill',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=1 AND b.PayerType='No Bill' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'K','LIS','Not Resulted',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'L','LIS','Not Entered in AMD (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.ClaimStatus='Not Entered in AMD' AND b.PayerType='Insurance' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'L-Recv','LIS','  Received',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus IN ('Received','Not Entered in AMD') GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'L-Coll','LIS','  Collected',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus='Collected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'M','LIS','Client Bill (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Client Bill' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'N','LIS','Test Entries (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus='Test Entries' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'O','LIS','Rejected Sample (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='Insurance' AND b.ClaimStatus='Rejected' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'P','LIS','Payment Method No Bill (Not Resulted)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.IsResulted=0 AND b.PayerType='No Bill' GROUP BY p.BillYear,p.BillMonth
        -- PMS
        UNION ALL SELECT p.BillYear,p.BillMonth,'Q','PMS','Billed',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'S','PMS','Unbilled',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Unbilled' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'T','PMS','Fully Paid',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Fully Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'U','PMS','Fully Adjusted (Complete W/O)',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Complete W/O' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'V','PMS','Patient Responsibility',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Patient Responsibility' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'W','PMS','Partially Paid',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Partially Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'X','PMS','Patient Payment',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Patient Payment' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y1','PMS','Insurance Balance - No Response',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='No Response' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y2','PMS','Insurance Balance - Fully Denied',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Fully Denied' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'Y3','PMS','Insurance Balance - Partially Denied',CAST(COUNT(DISTINCT b.AccessionNumber) AS DECIMAL(18,2)) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Partially Denied' GROUP BY p.BillYear,p.BillMonth
        -- Cash
        UNION ALL SELECT p.BillYear,p.BillMonth,'Z','Cash','Total Billed ($)',ISNULL(SUM(b.ChargeAmount),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Billed' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AA','Cash','Unbilled ($)',ISNULL(SUM(b.ChargeAmount),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.BilledUnbilled='Unbilled' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AB','Cash','Insurance Payment - Fully Paid ($)',ISNULL(SUM(b.InsurancePayment),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Fully Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AC','Cash','Partially Paid ($)',ISNULL(SUM(b.InsurancePayment),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Partially Paid' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AD','Cash','Patient Payment ($)',ISNULL(SUM(b.PatientPayment),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.PatientPayment>0 GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AE','Cash','Fully Adjusted - Complete W/O ($)',ISNULL(SUM(b.InsuranceAdjustments),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Complete W/O' GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AG','Cash','Patient Balance ($)',ISNULL(SUM(b.PatientBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.PatientBalance>0 GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AH','Cash','Patient WO ($)',ISNULL(SUM(b.PatientAdjustments),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.PatientAdjustments>0 GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AI1','Cash','Insurance Balance - Fully Denied ($)',ISNULL(SUM(b.InsuranceBalance),0) FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) AND b.ClaimStatus='Fully Denied' GROUP BY p.BillYear,p.BillMonth
        -- Averages
        UNION ALL SELECT p.BillYear,p.BillMonth,'AJ','Avg','Avg Payment ($) Total Pay / Billed Claims',
            ISNULL(ROUND(SUM(CASE WHEN b.BilledUnbilled='Billed' THEN b.InsurancePayment ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN b.BilledUnbilled='Billed' THEN b.AccessionNumber END),0),2),0)
            FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AK','Avg','Avg Payment ($) Total Pay / Paid Claims',
            ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.InsurancePayment ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid') THEN b.AccessionNumber END),0),2),0)
            FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
        UNION ALL SELECT p.BillYear,p.BillMonth,'AL','Avg','Avg Payment ($) Total Pay / Adjudicated Claims',
            ISNULL(ROUND(SUM(CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted','Fully Denied','Denied','Partially Denied','Patient Responsibility') THEN b.InsurancePayment ELSE 0 END)/NULLIF(COUNT(DISTINCT CASE WHEN b.ClaimStatus IN ('Fully Paid','Partially Paid','Complete W/O','Fully Adjusted','Fully Denied','Denied','Partially Denied','Patient Responsibility') THEN b.AccessionNumber END),0),2),0)
            FROM #Periods p LEFT JOIN #Base b ON (p.BillYear=0 OR (b.BillYear=p.BillYear AND b.BillMonth=p.BillMonth)) GROUP BY p.BillYear,p.BillMonth
    ) x;

    -- ── Swap into aggregate table atomically ─────────────────────────────────
    TRUNCATE TABLE dbo.Phi_ES_Data;

    INSERT INTO dbo.Phi_ES_Data (RowCode, Category, Description, BillYear, BillMonth, MetricValue, RefreshedAt)
    SELECT RowCode, Category, Description, BillYear, BillMonth, MetricValue, GETDATE()
    FROM #Out
    ORDER BY BillYear, BillMonth, RowCode;

    DROP TABLE IF EXISTS #Base;
    DROP TABLE IF EXISTS #Periods;
    DROP TABLE IF EXISTS #Out;

    PRINT 'usp_RefreshPhi_ExecutiveSummary completed — ' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + ' rows.';
END;
GO

PRINT '16_PhiLife_ExecutiveSummary_Aggregate.sql completed.';
GO
