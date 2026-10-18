-- ============================================================
-- Diagnostic: usp_GetCert_ExecutiveSummary returning all-zero rows
-- Run in Certus_LRN, with the SAME date range shown as zero in the UI
-- (screenshot: DOS From 2026-01-01, DOS To 2026-06-30).
--
-- IMPORTANT: run this against the SAME server the live app actually uses -
-- lrnanalytics-sqlmi.public.4e3a76f4ed99.database.windows.net,3342 / Certus_LRN
-- (the Certus.json DbConnectionString), NOT ASKS\MYDEV. A pass on the wrong
-- server tells you nothing about why the live dashboard is zero.
--
-- Goal: find out WHERE the pipeline goes empty -
--   Step 1: does ClaimLevelData / LIMSMaster actually have rows in this range?
--   Step 2: does the column-detection logic (same candidate lists as the SP)
--           resolve real columns, or does it come back NULL and skip #Lis
--           entirely?
--   Step 3: run the actual SP and see what it returns for this exact range.
-- ============================================================

DECLARE @DosFrom DATE = '2026-01-01';
DECLARE @DosTo   DATE = '2026-06-30';

PRINT '-- STEP 1: raw row counts for this DOS range (sanity check data exists) --';

SELECT COUNT(*) AS ClaimLevelData_RowsInRange
FROM dbo.ClaimLevelData
WHERE TRY_CAST(DateofService AS DATE) BETWEEN @DosFrom AND @DosTo;

SELECT COUNT(*) AS ClaimLevelData_RowsInRange_NoCastFilter
FROM dbo.ClaimLevelData
WHERE DateofService BETWEEN @DosFrom AND @DosTo;

IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
BEGIN
    -- Uses ReqCollectDate directly since that's Certus's priority-0 date column
    SELECT COUNT(*) AS LIMSMaster_RowsInRange_ReqCollectDate
    FROM dbo.LIMSMaster
    WHERE TRY_CAST(ReqCollectDate AS DATE) BETWEEN @DosFrom AND @DosTo;
END
ELSE
    PRINT '*** dbo.LIMSMaster not found in this database. ***';

PRINT '-- STEP 2: which columns does the SP''s candidate-list detection resolve on LIMSMaster? --';

IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
BEGIN
    DECLARE @AccCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('AccessionNumber','Accession','AccessionNo')
        ORDER BY CASE name WHEN 'AccessionNumber' THEN 0 WHEN 'Accession' THEN 1 WHEN 'AccessionNo' THEN 2 ELSE 3 END);

    DECLARE @DateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ReqCollectDate','RequestCollectDate','DateOfCollection','DateofService','CollectionDate','ServiceDate','AccessionDate')
        ORDER BY CASE name
            WHEN 'ReqCollectDate' THEN 0 WHEN 'RequestCollectDate' THEN 1
            WHEN 'DateOfCollection' THEN 2 WHEN 'DateofService' THEN 3
            WHEN 'CollectionDate' THEN 4 WHEN 'ServiceDate' THEN 5 WHEN 'AccessionDate' THEN 6 ELSE 7 END);

    DECLARE @BillToCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillTo','BillCategory','Bill_Category','BillingCategory','BilledorNot','BillStatus')
        ORDER BY CASE name WHEN 'BillTo' THEN 0 WHEN 'BillCategory' THEN 1 WHEN 'Bill_Category' THEN 2 WHEN 'BillingCategory' THEN 3 WHEN 'BilledorNot' THEN 4 WHEN 'BillStatus' THEN 5 ELSE 6 END);

    DECLARE @BillingStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BillingStatus','NewStatus','Status','BillStatus')
        ORDER BY CASE name WHEN 'BillingStatus' THEN 0 WHEN 'NewStatus' THEN 1 WHEN 'Status' THEN 2 WHEN 'BillStatus' THEN 3 ELSE 4 END);

    DECLARE @FinalStatusCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('FinalStatus','SubStatus','Sub_Status','ClientStatus')
        ORDER BY CASE name WHEN 'FinalStatus' THEN 0 WHEN 'SubStatus' THEN 1 WHEN 'Sub_Status' THEN 2 WHEN 'ClientStatus' THEN 3 ELSE 4 END);

    DECLARE @PanelNameCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('PanelName','Panelname','PanelType','PanelCategory','TestPanel','TestPanelName','Panel','PanelDescription','TestName','Test_Panel','TestPanelname')
        ORDER BY CASE name
            WHEN 'PanelName'       THEN 0 WHEN 'Panelname'       THEN 1 WHEN 'PanelType'       THEN 2
            WHEN 'PanelCategory'   THEN 3 WHEN 'TestPanel'        THEN 4 WHEN 'TestPanelName'   THEN 5
            WHEN 'Panel'           THEN 6 WHEN 'PanelDescription' THEN 7 WHEN 'TestName'        THEN 8
            WHEN 'Test_Panel'      THEN 9 WHEN 'TestPanelname'    THEN 10 ELSE 11 END);

    DECLARE @BilledDateCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('BilledDate','FirstBilledDate','BilledOn','BillDate','FirstBillDate')
        ORDER BY CASE name
            WHEN 'BilledDate'    THEN 0 WHEN 'FirstBilledDate' THEN 1
            WHEN 'BilledOn'      THEN 2 WHEN 'BillDate'        THEN 3
            WHEN 'FirstBillDate' THEN 4 ELSE 5 END);

    DECLARE @ClinicCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('ReqLocationName','FacilityName','Facility','ClinicName','Clinic')
        ORDER BY CASE name
            WHEN 'ReqLocationName' THEN 0 WHEN 'FacilityName' THEN 1
            WHEN 'Facility'        THEN 2 WHEN 'ClinicName'   THEN 3 WHEN 'Clinic' THEN 4 ELSE 5 END);

    DECLARE @ProviderCol SYSNAME = (
        SELECT TOP 1 name FROM sys.columns
        WHERE object_id = OBJECT_ID('dbo.LIMSMaster')
          AND name IN ('DoctorFullName','PhysicianName','Physician','ReferringPhysician','ReferringProvider','Provider')
        ORDER BY CASE name
            WHEN 'DoctorFullName'     THEN 0 WHEN 'PhysicianName'      THEN 1
            WHEN 'Physician'          THEN 2 WHEN 'ReferringPhysician' THEN 3
            WHEN 'ReferringProvider'  THEN 4 WHEN 'Provider'           THEN 5 ELSE 6 END);

    SELECT
        ISNULL(@AccCol,'*** NOT FOUND ***')          AS AccessionCol,
        ISNULL(@DateCol,'*** NOT FOUND ***')          AS DateOfServiceCol_ReqCollectDate,
        ISNULL(@BillToCol,'*** NOT FOUND ***')        AS BillToCol,
        ISNULL(@BillingStatusCol,'*** NOT FOUND ***') AS BillingStatusCol,
        ISNULL(@FinalStatusCol,'*** NOT FOUND ***')   AS FinalStatusCol,
        ISNULL(@PanelNameCol,'*** NOT FOUND ***')     AS PanelNameCol,
        ISNULL(@BilledDateCol,'(none - optional)')    AS BilledDateCol,
        ISNULL(@ClinicCol,'(none - optional)')        AS ClinicCol_ReqLocationName,
        ISNULL(@ProviderCol,'(none - optional)')      AS ProviderCol_DoctorFullName;

    -- The SP requires ALL FIVE of these to be non-null or it skips building #Lis
    -- entirely (silently, no error) - that alone would produce all-zero LIS rows.
    IF @AccCol IS NULL OR @DateCol IS NULL OR @BillToCol IS NULL OR @BillingStatusCol IS NULL OR @FinalStatusCol IS NULL
        PRINT '*** ROOT CAUSE CANDIDATE: one or more REQUIRED LIMSMaster columns did not resolve - #Lis build is skipped entirely, every LIS row will show 0. ***';
    ELSE
        PRINT 'All 5 required LIMSMaster columns resolved OK - #Lis build should proceed.';
END

PRINT '-- STEP 3: run the actual SP with the exact filter from the screenshot --';

EXEC dbo.usp_GetCert_ExecutiveSummary
    @DosFrom = '2026-01-01',
    @DosTo   = '2026-06-30';

-- Also add a check for whether dbo.LIMSMaster even exists on THIS server -
-- if this is a separate/newer Azure SQL MI database, the table itself may
-- be missing or empty, which would silently zero out #Lis (row A "Total
-- Samples" included) even with all 5 columns resolving fine on a different
-- server used for schema-detection sanity checks.
PRINT '-- STEP 4: does dbo.LIMSMaster exist here, and does it have ANY rows at all? --';
SELECT OBJECT_ID('dbo.LIMSMaster','U') AS LIMSMaster_ObjectId;
IF OBJECT_ID('dbo.LIMSMaster','U') IS NOT NULL
    SELECT COUNT(*) AS LIMSMaster_TotalRows_NoFilter FROM dbo.LIMSMaster;
