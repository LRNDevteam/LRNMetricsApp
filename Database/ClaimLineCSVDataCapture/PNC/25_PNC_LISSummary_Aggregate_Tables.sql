/* =============================================================================
   PNC (prefix PNC_) - LIS Summary aggregate tables
   File : 25_PNC_LISSummary_Aggregate_Tables.sql
   DB   : PNC

   Same tables as TexasDiagnostic (25_TexasDiagnostic_LISSummary_Aggregate_Tables.sql).
   Written by SqlLisSummaryRepository.RefreshSummaryAggregateAsync, which
   ClaimLineCSVDataCapture calls whenever a new LIMS file has landed in
   dbo.LIMSMaster (row count / latest CreatedOn / latest RunId changed). The same
   refresh runs dbo.usp_RefreshPNC_LISSummary (26_PNC_LISSummary_SP.sql).

     dbo.PNC_LIS_FieldSets        - distinct combinations of the LIS status fields (JSON)
     dbo.PNC_LIS_SummaryGroups    - template pivot source, one row per
                                    DateType x day x field set x filter values
     dbo.PNC_LIS_KeyMetricsDaily  - Time to Result / Time to Bill sums and counts
                                    per collection day x filter values
     dbo.PNC_LIS_FilterOptions    - Panel / Clinic / RefPhy / SalesRep / Collector dropdown values
     dbo.PNC_LIS_RefreshLog       - one row per successful refresh

   Idempotent: safe to re-run.
   ============================================================================= */
SET NOCOUNT ON;
GO

IF DB_NAME() <> N'PNC'
BEGIN
	RAISERROR('Run 25_PNC_LISSummary_Aggregate_Tables.sql on the PNC database.', 16, 1);
	SET NOEXEC ON;
END
GO

IF OBJECT_ID(N'dbo.PNC_LIS_FieldSets', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PNC_LIS_FieldSets
    (
        FieldSetId   INT            NOT NULL CONSTRAINT PK_PNC_LIS_FieldSets PRIMARY KEY,
        FieldsJson   NVARCHAR(MAX)  NOT NULL
    );
END
GO

IF OBJECT_ID(N'dbo.PNC_LIS_SummaryGroups', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PNC_LIS_SummaryGroups
    (
        DateType     VARCHAR(20)     NOT NULL,   -- Collected / Received / Resulted
        GroupDate    DATE            NOT NULL,
        FieldSetId   INT             NOT NULL,   -- dbo.PNC_LIS_FieldSets
        Panel        NVARCHAR(4000)  NOT NULL,
        Clinic       NVARCHAR(4000)  NOT NULL,
        RefPhy       NVARCHAR(4000)  NOT NULL,
        SalesRep     NVARCHAR(4000)  NOT NULL,
        Collector    NVARCHAR(4000)  NOT NULL,
        TotalClaims  INT             NOT NULL
    );

    CREATE CLUSTERED INDEX CIX_PNC_LIS_SummaryGroups
        ON dbo.PNC_LIS_SummaryGroups (DateType, GroupDate);
END
GO

IF OBJECT_ID(N'dbo.PNC_LIS_KeyMetricsDaily', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PNC_LIS_KeyMetricsDaily
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

    CREATE CLUSTERED INDEX CIX_PNC_LIS_KeyMetricsDaily
        ON dbo.PNC_LIS_KeyMetricsDaily (GroupDate);
END
GO

IF OBJECT_ID(N'dbo.PNC_LIS_FilterOptions', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PNC_LIS_FilterOptions
    (
        FilterName  VARCHAR(20)     NOT NULL,    -- Panel / Clinic / RefPhy / SalesRep / Collector
        SortOrder   INT             NOT NULL,
        Value       NVARCHAR(4000)  NOT NULL,
        CONSTRAINT PK_PNC_LIS_FilterOptions PRIMARY KEY (FilterName, SortOrder)
    );
END
GO

IF OBJECT_ID(N'dbo.PNC_LIS_RefreshLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.PNC_LIS_RefreshLog
    (
        RefreshId         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_PNC_LIS_RefreshLog PRIMARY KEY,
        RefreshedAt       DATETIME2(0)      NOT NULL CONSTRAINT DF_PNC_LIS_RefreshLog_RefreshedAt DEFAULT (SYSDATETIME()),
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

PRINT '25_PNC_LISSummary_Aggregate_Tables.sql completed.';
GO
