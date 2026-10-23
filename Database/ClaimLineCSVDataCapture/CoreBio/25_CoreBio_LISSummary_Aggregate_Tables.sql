/* =============================================================================
   CoreBio (prefix CB_) - LIS Summary aggregate tables
   File : 25_CoreBio_LISSummary_Aggregate_Tables.sql
   DB   : CoreBio

   Same tables as Analyze Pathology (25_AnalyzePathology_LISSummary_Aggregate_Tables.sql).
   Written by SqlLisSummaryRepository.RefreshSummaryAggregateAsync, which
   ClaimLineCSVDataCapture calls whenever a new LIMS file has landed in
   dbo.LIMSMaster (row count / latest CreatedOn / latest RunId changed). The same
   refresh runs dbo.usp_RefreshCB_LISSummary (26_CoreBio_LISSummary_SP.sql).

     dbo.CB_LIS_FieldSets        - distinct combinations of the LIS status fields (JSON)
     dbo.CB_LIS_SummaryGroups    - template pivot source, one row per
                                   DateType x day x field set x filter values
     dbo.CB_LIS_KeyMetricsDaily  - Time to Result / Time to Bill sums and counts
                                   per collection day x filter values
     dbo.CB_LIS_FilterOptions    - Panel / Clinic / RefPhy / SalesRep / Collector dropdown values
     dbo.CB_LIS_RefreshLog       - one row per successful refresh

   Idempotent: safe to re-run.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'CoreBio'
BEGIN
	RAISERROR('Run 25_CoreBio_LISSummary_Aggregate_Tables.sql on the CoreBio database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.CB_LIS_FieldSets', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CB_LIS_FieldSets
    (
        FieldSetId   INT            NOT NULL CONSTRAINT PK_CB_LIS_FieldSets PRIMARY KEY,
        FieldsJson   NVARCHAR(MAX)  NOT NULL
    );
END
GO

IF OBJECT_ID(N'dbo.CB_LIS_SummaryGroups', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CB_LIS_SummaryGroups
    (
        DateType     VARCHAR(20)     NOT NULL,   -- Collected / Received / Resulted
        GroupDate    DATE            NOT NULL,
        FieldSetId   INT             NOT NULL,   -- dbo.CB_LIS_FieldSets
        Panel        NVARCHAR(4000)  NOT NULL,
        Clinic       NVARCHAR(4000)  NOT NULL,
        RefPhy       NVARCHAR(4000)  NOT NULL,
        SalesRep     NVARCHAR(4000)  NOT NULL,
        Collector    NVARCHAR(4000)  NOT NULL,
        TotalClaims  INT             NOT NULL
    );

    CREATE CLUSTERED INDEX CIX_CB_LIS_SummaryGroups
        ON dbo.CB_LIS_SummaryGroups (DateType, GroupDate);
END
GO

IF OBJECT_ID(N'dbo.CB_LIS_KeyMetricsDaily', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CB_LIS_KeyMetricsDaily
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

    CREATE CLUSTERED INDEX CIX_CB_LIS_KeyMetricsDaily
        ON dbo.CB_LIS_KeyMetricsDaily (GroupDate);
END
GO

IF OBJECT_ID(N'dbo.CB_LIS_FilterOptions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CB_LIS_FilterOptions
    (
        FilterName  VARCHAR(20)     NOT NULL,    -- Panel / Clinic / RefPhy / SalesRep / Collector
        SortOrder   INT             NOT NULL,
        Value       NVARCHAR(4000)  NOT NULL,
        CONSTRAINT PK_CB_LIS_FilterOptions PRIMARY KEY (FilterName, SortOrder)
    );
END
GO

IF OBJECT_ID(N'dbo.CB_LIS_RefreshLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.CB_LIS_RefreshLog
    (
        RefreshId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_CB_LIS_RefreshLog PRIMARY KEY,
        RefreshedAt       DATETIME2(0)      NOT NULL CONSTRAINT DF_CB_LIS_RefreshLog_RefreshedAt DEFAULT (SYSDATETIME()),
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

PRINT '25_CoreBio_LISSummary_Aggregate_Tables.sql completed.';
GO
