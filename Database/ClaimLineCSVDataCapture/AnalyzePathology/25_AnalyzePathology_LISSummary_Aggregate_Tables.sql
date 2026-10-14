/* =============================================================================
   Analyze Pathology (prefix AnP_) - LIS Summary aggregate tables
   File : 25_AnalyzePathology_LISSummary_Aggregate_Tables.sql
   DB   : AnalyzePathology

   Written by SqlLisSummaryRepository.RefreshSummaryAggregateAsync, which
   ClaimLineCSVDataCapture calls whenever a new LIMS file has landed in
   dbo.LIMSMaster (row count / latest CreatedOn / latest RunId changed).
   The refresh reuses the LIS Summary page's own grouping logic (logic sheet,
   date columns, field columns, filter columns), so these tables hold exactly
   what the page would compute live - pre-grouped by day.

   Read by the LIS Summary page and LRN.ReportWorker (same repository):
     dbo.AnP_LIS_FieldSets        - distinct combinations of the LIS status fields
                                    (JSON), referenced by FieldSetId
     dbo.AnP_LIS_SummaryGroups    - template pivot source, one row per
                                    DateType x day x field set x filter values
     dbo.AnP_LIS_KeyMetricsDaily  - Time to Result / Time to Bill sums and
                                    counts per collection day x filter values
     dbo.AnP_LIS_FilterOptions    - Panel / Clinic / RefPhy / SalesRep /
                                    Collector dropdown values
     dbo.AnP_LIS_RefreshLog       - one row per successful refresh; the page
                                    reads the aggregate only when a row exists

   The line-data tab is not aggregated - it pages raw dbo.LIMSMaster rows.
   Idempotent: safe to re-run.
   ============================================================================= */

-- First version stored the field JSON on every row; it is derived data, so rebuild.
IF COL_LENGTH(N'dbo.AnP_LIS_SummaryGroups', N'FieldsJson') IS NOT NULL
BEGIN
    DROP TABLE dbo.AnP_LIS_SummaryGroups;
    IF OBJECT_ID(N'dbo.AnP_LIS_RefreshLog', N'U') IS NOT NULL
        DELETE FROM dbo.AnP_LIS_RefreshLog;   -- page falls back to live until the next refresh
END
GO

IF OBJECT_ID(N'dbo.AnP_LIS_FieldSets', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AnP_LIS_FieldSets
    (
        FieldSetId   INT            NOT NULL CONSTRAINT PK_AnP_LIS_FieldSets PRIMARY KEY,
        FieldsJson   NVARCHAR(MAX)  NOT NULL     -- {"<LIS field>":"<raw value>", ...}
    );
END
GO

IF OBJECT_ID(N'dbo.AnP_LIS_SummaryGroups', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AnP_LIS_SummaryGroups
    (
        DateType     VARCHAR(20)     NOT NULL,   -- Collected / Received / Resulted
        GroupDate    DATE            NOT NULL,
        FieldSetId   INT             NOT NULL,   -- dbo.AnP_LIS_FieldSets
        Panel        NVARCHAR(4000)  NOT NULL,
        Clinic       NVARCHAR(4000)  NOT NULL,
        RefPhy       NVARCHAR(4000)  NOT NULL,
        SalesRep     NVARCHAR(4000)  NOT NULL,
        Collector    NVARCHAR(4000)  NOT NULL,
        TotalClaims  INT             NOT NULL
    );

    CREATE CLUSTERED INDEX CIX_AnP_LIS_SummaryGroups
        ON dbo.AnP_LIS_SummaryGroups (DateType, GroupDate);
END
GO

IF OBJECT_ID(N'dbo.AnP_LIS_KeyMetricsDaily', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AnP_LIS_KeyMetricsDaily
    (
        GroupDate     DATE            NOT NULL,  -- collection date
        Panel         NVARCHAR(4000)  NOT NULL,
        Clinic        NVARCHAR(4000)  NOT NULL,
        RefPhy        NVARCHAR(4000)  NOT NULL,
        SalesRep      NVARCHAR(4000)  NOT NULL,
        Collector     NVARCHAR(4000)  NOT NULL,
        ResultSum     FLOAT           NULL,
        ResultCount   INT             NOT NULL,
        BillSum       FLOAT           NULL,
        BillCount     INT             NOT NULL
    );

    CREATE CLUSTERED INDEX CIX_AnP_LIS_KeyMetricsDaily
        ON dbo.AnP_LIS_KeyMetricsDaily (GroupDate);
END
GO

IF OBJECT_ID(N'dbo.AnP_LIS_FilterOptions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AnP_LIS_FilterOptions
    (
        FilterName  VARCHAR(20)     NOT NULL,    -- Panel / Clinic / RefPhy / SalesRep / Collector
        SortOrder   INT             NOT NULL,
        Value       NVARCHAR(4000)  NOT NULL,
        CONSTRAINT PK_AnP_LIS_FilterOptions PRIMARY KEY (FilterName, SortOrder)
    );
END
GO

IF OBJECT_ID(N'dbo.AnP_LIS_RefreshLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.AnP_LIS_RefreshLog
    (
        RefreshId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_AnP_LIS_RefreshLog PRIMARY KEY,
        RefreshedAt       DATETIME2(0)      NOT NULL CONSTRAINT DF_AnP_LIS_RefreshLog_RefreshedAt DEFAULT (SYSDATETIME()),
        LogicSheet        NVARCHAR(50)      NOT NULL,
        SourceFileName    NVARCHAR(500)     NOT NULL,
        LimsSignature     NVARCHAR(400)     NOT NULL,   -- rowcount|max CreatedOn|latest RunId
        DateTypes         VARCHAR(100)      NOT NULL,   -- date types that resolved a date column
        SummaryRows       INT               NOT NULL,
        KeyMetricRows     INT               NOT NULL,
        FilterOptionRows  INT               NOT NULL,
        DurationMs        INT               NOT NULL
    );
END
GO
