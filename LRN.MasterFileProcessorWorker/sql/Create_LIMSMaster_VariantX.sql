/* ============================================================================
   dbo.LIMSMaster for VariantX.

   Run against the VariantX lab database.

   Two groups of columns:

     1. The pipeline's own - Accession, RequestCollectDate, ResultStatus,
        SourceFile, RunId, AdditionalFields, CreatedOn and the rest. These are
        the same in every lab's LIMSMaster and the importer and the dashboard
        both expect them by name.

     2. VariantX's file columns, named by VariantX_LIMS_Schema.json's SQLColName
        values. The importer writes a schema column only if a destination column
        of that name already exists, so this script and that JSON have to agree.

   The LRN* columns follow the InHealth naming, because VariantX's file uses the
   same vocabulary: "LRN Result Status", "LRN Sample Status", "LRN Bill Category",
   "LRN Sub Status". That matters beyond tidiness - the LIS Summary resolves
   SampleStatus, BillCategory and SubStatus by those canonical names, so naming
   them anything else would load the data and then show an empty summary.

   RE-RUNNABLE: creates the table when absent, and adds any missing column to an
   existing one.
   ============================================================================ */

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.LIMSMaster
    (
        -- ── Pipeline columns (every lab) ──────────────────────────────────
        Accession            NVARCHAR(50)   NULL,
        PatientName          NVARCHAR(255)  NULL,
        RequestCollectDate   DATE           NULL,
        IncorrectDOS         NVARCHAR(255)  NULL,
        RequestReceivedDate  DATE           NULL,
        BillType             NVARCHAR(255)  NULL,
        ResultStatus         NVARCHAR(255)  NULL,
        BilledTo             NVARCHAR(255)  NULL,
        BillStatus           NVARCHAR(255)  NULL,
        FinalStatus          NVARCHAR(255)  NULL,
        Category             NVARCHAR(255)  NULL,

        -- ── VariantX file columns ─────────────────────────────────────────
        TrueFalse            NVARCHAR(50)   NULL,   -- "T/F"
        OrderStatus          NVARCHAR(255)  NULL,
        PatientLastName      NVARCHAR(255)  NULL,
        PatientFirstName     NVARCHAR(255)  NULL,
        DateOfBirth          DATE           NULL,
        Gender               NVARCHAR(50)   NULL,
        StreetAddress        NVARCHAR(500)  NULL,   -- one free-text line: "ty, Alabama, 9487"
        CollectionWeek       NVARCHAR(100)  NULL,
        TestType             NVARCHAR(255)  NULL,   -- CGX, etc. Doubles as the panel grouping.
        ICD10                NVARCHAR(500)  NULL,
        PhysicianName        NVARCHAR(255)  NULL,
        NPI                  NVARCHAR(50)   NULL,
        FacilityName         NVARCHAR(255)  NULL,
        SaleRepName          NVARCHAR(255)  NULL,
        PrimaryInsurance     NVARCHAR(255)  NULL,
        PolicyNumber         NVARCHAR(100)  NULL,
        Comments             NVARCHAR(MAX)  NULL,
        -- Text, not decimal: the sample file leaves it blank and lab files carry "$", "-" and
        -- commas. A typed column rejects the row; TRY_CONVERT downstream rejects only the value.
        Charges              NVARCHAR(100)  NULL,
        Collected            NVARCHAR(100)  NULL,
        SampleStatus         NVARCHAR(255)  NULL,   -- "LRN Sample Status" - Final Status equivalent
        BillCategory         NVARCHAR(255)  NULL,   -- "LRN Bill Category"  - Billed / Not Billed
        SubStatus            NVARCHAR(255)  NULL,   -- "LRN Sub Status"
        BilledDate           DATE           NULL,

        -- ── Provenance & catch-all ────────────────────────────────────────
        SourceFile           NVARCHAR(260)  NULL,
        RunId                VARCHAR(30)    NULL,
        -- Every file column the schema JSON does not name, as one JSON object per row. Labs add
        -- columns regularly; this is what keeps that from being an ALTER TABLE each time.
        -- Read with JSON_VALUE(AdditionalFields, '$."Some New Column"').
        AdditionalFields     NVARCHAR(MAX)  NULL,
        CreatedOn            DATETIME       NOT NULL
            CONSTRAINT DF_LIMSMaster_CreatedOn DEFAULT (GETDATE())
    );

    PRINT 'Created dbo.LIMSMaster for VariantX.';
END
ELSE
    PRINT 'dbo.LIMSMaster already exists - checking for missing columns.';
GO

/* ── Add anything missing to an existing table ────────────────────────────
   Written one at a time rather than as a single ALTER so the script is safe on
   a table that was created by an earlier version of this file. */
IF COL_LENGTH('dbo.LIMSMaster', 'TrueFalse')           IS NULL ALTER TABLE dbo.LIMSMaster ADD TrueFalse           NVARCHAR(50)   NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'OrderStatus')         IS NULL ALTER TABLE dbo.LIMSMaster ADD OrderStatus         NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientLastName')     IS NULL ALTER TABLE dbo.LIMSMaster ADD PatientLastName     NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PatientFirstName')    IS NULL ALTER TABLE dbo.LIMSMaster ADD PatientFirstName    NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'DateOfBirth')         IS NULL ALTER TABLE dbo.LIMSMaster ADD DateOfBirth         DATE           NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Gender')              IS NULL ALTER TABLE dbo.LIMSMaster ADD Gender              NVARCHAR(50)   NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'StreetAddress')       IS NULL ALTER TABLE dbo.LIMSMaster ADD StreetAddress       NVARCHAR(500)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'CollectionWeek')      IS NULL ALTER TABLE dbo.LIMSMaster ADD CollectionWeek      NVARCHAR(100)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'TestType')            IS NULL ALTER TABLE dbo.LIMSMaster ADD TestType            NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ICD10')               IS NULL ALTER TABLE dbo.LIMSMaster ADD ICD10               NVARCHAR(500)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PhysicianName')       IS NULL ALTER TABLE dbo.LIMSMaster ADD PhysicianName       NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'NPI')                 IS NULL ALTER TABLE dbo.LIMSMaster ADD NPI                 NVARCHAR(50)   NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'FacilityName')        IS NULL ALTER TABLE dbo.LIMSMaster ADD FacilityName        NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SaleRepName')         IS NULL ALTER TABLE dbo.LIMSMaster ADD SaleRepName         NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PrimaryInsurance')    IS NULL ALTER TABLE dbo.LIMSMaster ADD PrimaryInsurance    NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'PolicyNumber')        IS NULL ALTER TABLE dbo.LIMSMaster ADD PolicyNumber        NVARCHAR(100)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Comments')            IS NULL ALTER TABLE dbo.LIMSMaster ADD Comments            NVARCHAR(MAX)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Charges')             IS NULL ALTER TABLE dbo.LIMSMaster ADD Charges             NVARCHAR(100)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'Collected')           IS NULL ALTER TABLE dbo.LIMSMaster ADD Collected           NVARCHAR(100)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SampleStatus')        IS NULL ALTER TABLE dbo.LIMSMaster ADD SampleStatus        NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BillCategory')        IS NULL ALTER TABLE dbo.LIMSMaster ADD BillCategory        NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SubStatus')           IS NULL ALTER TABLE dbo.LIMSMaster ADD SubStatus           NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'BilledDate')          IS NULL ALTER TABLE dbo.LIMSMaster ADD BilledDate          DATE           NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RequestReceivedDate') IS NULL ALTER TABLE dbo.LIMSMaster ADD RequestReceivedDate DATE           NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RequestCollectDate')  IS NULL ALTER TABLE dbo.LIMSMaster ADD RequestCollectDate  DATE           NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'ResultStatus')        IS NULL ALTER TABLE dbo.LIMSMaster ADD ResultStatus        NVARCHAR(255)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'SourceFile')          IS NULL ALTER TABLE dbo.LIMSMaster ADD SourceFile          NVARCHAR(260)  NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'RunId')               IS NULL ALTER TABLE dbo.LIMSMaster ADD RunId               VARCHAR(30)    NULL;
IF COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields')    IS NULL ALTER TABLE dbo.LIMSMaster ADD AdditionalFields    NVARCHAR(MAX)  NULL;
GO

/* ── Indexes ──────────────────────────────────────────────────────────────
   RunId is how a week's load is found and re-run; RequestCollectDate is what
   every LIS Summary column groups by. */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LIMSMaster_RunId' AND object_id = OBJECT_ID('dbo.LIMSMaster'))
    CREATE INDEX IX_LIMSMaster_RunId ON dbo.LIMSMaster (RunId);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LIMSMaster_CollectDate' AND object_id = OBJECT_ID('dbo.LIMSMaster'))
    CREATE INDEX IX_LIMSMaster_CollectDate ON dbo.LIMSMaster (RequestCollectDate);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_LIMSMaster_Accession' AND object_id = OBJECT_ID('dbo.LIMSMaster'))
    CREATE INDEX IX_LIMSMaster_Accession ON dbo.LIMSMaster (Accession);
GO

SELECT c.name AS ColumnName, t.name AS DataType, c.max_length, c.is_nullable
FROM   sys.columns AS c
JOIN   sys.types   AS t ON t.user_type_id = c.user_type_id
WHERE  c.object_id = OBJECT_ID('dbo.LIMSMaster')
ORDER  BY c.column_id;
GO
