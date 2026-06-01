-- ============================================================
-- 04_PredictionAggregateTables.sql
-- Snapshot tables for the Prediction Analysis dashboard.
--
-- These tables hold pre-computed aggregate results so the
-- LabMetricsDashboard does not have to scan PayerValidationReport
-- (which can hold 500K+ rows for NorthWest) on every page load.
--
-- They are populated by PredictionAnalysisApp after each successful
-- data ingestion via dbo.usp_RefreshAllPredictionAggregates, which
-- runs the seven usp_GetPrediction* SPs and INSERTs their results
-- here keyed by (RunId, WeekStartDate).
--
-- Mirrors the snapshot pattern already used for Collection Summary
-- in ClaimLineCSVDataCapture.
--
-- Run once against every lab database that holds PayerValidationReport.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

-- ------------------------------------------------------------
-- Table : PV_SummaryBuckets   (mirrors SP 6 result set)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_SummaryBuckets')
BEGIN
    CREATE TABLE dbo.PV_SummaryBuckets
    (
        SnapshotId          BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_SummaryBuckets PRIMARY KEY,
        RunId               NVARCHAR(100)   NOT NULL,
        WeekStartDate       DATE            NULL,
        RefreshedAt         DATETIME2       NOT NULL CONSTRAINT DF_PV_SummaryBuckets_RefreshedAt DEFAULT SYSUTCDATETIME(),
        BucketName          NVARCHAR(100)   NOT NULL,
        SortOrder           INT             NOT NULL,
        LineItemCount       INT             NOT NULL,
        PredictedAllowed    DECIMAL(18,4)   NOT NULL,
        PredictedInsurance  DECIMAL(18,4)   NOT NULL,
        ActualAllowed       DECIMAL(18,4)   NULL,
        ActualInsurance     DECIMAL(18,4)   NULL
    );

    CREATE INDEX IX_PV_SummaryBuckets_Lookup
        ON dbo.PV_SummaryBuckets (RunId, WeekStartDate, SortOrder);
END
GO

-- ------------------------------------------------------------
-- Table : PV_ValidationByPayer   (mirrors SP 7)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_ValidationByPayer')
BEGIN
    CREATE TABLE dbo.PV_ValidationByPayer
    (
        SnapshotId          BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_ValidationByPayer PRIMARY KEY,
        RunId               NVARCHAR(100)   NOT NULL,
        WeekStartDate       DATE            NULL,
        RefreshedAt         DATETIME2       NOT NULL CONSTRAINT DF_PV_ValidationByPayer_RefreshedAt DEFAULT SYSUTCDATETIME(),
        PayerName           NVARCHAR(255)   NOT NULL,
        PayerType           NVARCHAR(100)   NOT NULL,
        TotalLineItems      INT             NOT NULL,
        PaidCount           INT             NOT NULL,
        DeniedCount         INT             NOT NULL,
        NoResponseCount     INT             NOT NULL,
        AdjustedCount       INT             NOT NULL,
        UnpaidCount         INT             NOT NULL,
        PredictedAllowed    DECIMAL(18,4)   NOT NULL,
        PredictedInsurance  DECIMAL(18,4)   NOT NULL,
        ActualAllowed       DECIMAL(18,4)   NOT NULL,
        ActualInsurance     DECIMAL(18,4)   NOT NULL
    );

    CREATE INDEX IX_PV_ValidationByPayer_Lookup
        ON dbo.PV_ValidationByPayer (RunId, WeekStartDate, TotalLineItems DESC);
END
GO

-- ------------------------------------------------------------
-- Table : PV_ValidationByPanel   (mirrors SP 8)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_ValidationByPanel')
BEGIN
    CREATE TABLE dbo.PV_ValidationByPanel
    (
        SnapshotId          BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_ValidationByPanel PRIMARY KEY,
        RunId               NVARCHAR(100)   NOT NULL,
        WeekStartDate       DATE            NULL,
        RefreshedAt         DATETIME2       NOT NULL CONSTRAINT DF_PV_ValidationByPanel_RefreshedAt DEFAULT SYSUTCDATETIME(),
        PanelName           NVARCHAR(255)   NOT NULL,
        TotalLineItems      INT             NOT NULL,
        PaidCount           INT             NOT NULL,
        DeniedCount         INT             NOT NULL,
        NoResponseCount     INT             NOT NULL,
        AdjustedCount       INT             NOT NULL,
        UnpaidCount         INT             NOT NULL,
        PredictedAllowed    DECIMAL(18,4)   NOT NULL,
        PredictedInsurance  DECIMAL(18,4)   NOT NULL,
        ActualAllowed       DECIMAL(18,4)   NOT NULL,
        ActualInsurance     DECIMAL(18,4)   NOT NULL
    );

    CREATE INDEX IX_PV_ValidationByPanel_Lookup
        ON dbo.PV_ValidationByPanel (RunId, WeekStartDate, TotalLineItems DESC);
END
GO

-- ------------------------------------------------------------
-- Table : PV_ValidationByCPT   (mirrors SP 9)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_ValidationByCPT')
BEGIN
    CREATE TABLE dbo.PV_ValidationByCPT
    (
        SnapshotId          BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_ValidationByCPT PRIMARY KEY,
        RunId               NVARCHAR(100)   NOT NULL,
        WeekStartDate       DATE            NULL,
        RefreshedAt         DATETIME2       NOT NULL CONSTRAINT DF_PV_ValidationByCPT_RefreshedAt DEFAULT SYSUTCDATETIME(),
        CPTCode             NVARCHAR(50)    NOT NULL,
        LineItemCount       INT             NOT NULL,
        BilledAmount        DECIMAL(18,4)   NOT NULL,
        PredictedAllowed    DECIMAL(18,4)   NOT NULL,
        PredictedInsurance  DECIMAL(18,4)   NOT NULL
    );

    CREATE INDEX IX_PV_ValidationByCPT_Lookup
        ON dbo.PV_ValidationByCPT (RunId, WeekStartDate, PredictedInsurance DESC);
END
GO

-- ------------------------------------------------------------
-- Table : PV_DenialBreakdown   (mirrors SP 10)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_DenialBreakdown')
BEGIN
    CREATE TABLE dbo.PV_DenialBreakdown
    (
        SnapshotId           BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_DenialBreakdown PRIMARY KEY,
        RunId                NVARCHAR(100)   NOT NULL,
        WeekStartDate        DATE            NULL,
        RefreshedAt          DATETIME2       NOT NULL CONSTRAINT DF_PV_DenialBreakdown_RefreshedAt DEFAULT SYSUTCDATETIME(),
        PayerName            NVARCHAR(255)   NOT NULL,
        DenialCode           NVARCHAR(100)   NOT NULL,
        DenialDescription    NVARCHAR(1000)  NOT NULL,
        ExpectedPaymentMonth NVARCHAR(100)   NOT NULL,
        LineItemCount        INT             NOT NULL,
        PredictedAllowed     DECIMAL(18,4)   NOT NULL,
        PredictedInsurance   DECIMAL(18,4)   NOT NULL
    );

    CREATE INDEX IX_PV_DenialBreakdown_Lookup
        ON dbo.PV_DenialBreakdown (RunId, WeekStartDate, PayerName, DenialCode);
END
GO

-- ------------------------------------------------------------
-- Table : PV_NoResponseBreakdown   (mirrors SP 11)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_NoResponseBreakdown')
BEGIN
    CREATE TABLE dbo.PV_NoResponseBreakdown
    (
        SnapshotId          BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_NoResponseBreakdown PRIMARY KEY,
        RunId               NVARCHAR(100)   NOT NULL,
        WeekStartDate       DATE            NULL,
        RefreshedAt         DATETIME2       NOT NULL CONSTRAINT DF_PV_NoResponseBreakdown_RefreshedAt DEFAULT SYSUTCDATETIME(),
        PayerName           NVARCHAR(255)   NOT NULL,
        AgeBucket           NVARCHAR(50)    NOT NULL,
        LineItemCount       INT             NOT NULL,
        PredictedAllowed    DECIMAL(18,4)   NOT NULL,
        PredictedInsurance  DECIMAL(18,4)   NOT NULL
    );

    CREATE INDEX IX_PV_NoResponseBreakdown_Lookup
        ON dbo.PV_NoResponseBreakdown (RunId, WeekStartDate, PayerName);
END
GO

-- ------------------------------------------------------------
-- Table : PV_SummaryMetrics   (mirrors SP 12 – single row per snapshot)
-- ------------------------------------------------------------
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'PV_SummaryMetrics')
BEGIN
    CREATE TABLE dbo.PV_SummaryMetrics
    (
        SnapshotId                    BIGINT          IDENTITY(1,1) NOT NULL CONSTRAINT PK_PV_SummaryMetrics PRIMARY KEY,
        RunId                         NVARCHAR(100)   NOT NULL,
        WeekStartDate                 DATE            NULL,
        RefreshedAt                   DATETIME2       NOT NULL CONSTRAINT DF_PV_SummaryMetrics_RefreshedAt DEFAULT SYSUTCDATETIME(),

        -- Section 1: raw bucket values
        ToPay_LineItems               INT             NOT NULL,
        ToPay_ModeAllowed             DECIMAL(18,4)   NOT NULL,
        ToPay_ModeIns                 DECIMAL(18,4)   NOT NULL,
        Paid_LineItems                INT             NOT NULL,
        Paid_ModeAllowed              DECIMAL(18,4)   NOT NULL,
        Paid_ModeIns                  DECIMAL(18,4)   NOT NULL,
        Paid_ActAllowed               DECIMAL(18,4)   NOT NULL,
        Paid_ActIns                   DECIMAL(18,4)   NOT NULL,
        Unpaid_LineItems              INT             NOT NULL,
        Unpaid_ModeAllowed            DECIMAL(18,4)   NOT NULL,
        Unpaid_ModeIns                DECIMAL(18,4)   NOT NULL,
        Denied_LineItems              INT             NOT NULL,
        Denied_ModeAllowed            DECIMAL(18,4)   NOT NULL,
        Denied_ModeIns                DECIMAL(18,4)   NOT NULL,
        NoResp_LineItems              INT             NOT NULL,
        NoResp_ModeAllowed            DECIMAL(18,4)   NOT NULL,
        NoResp_ModeIns                DECIMAL(18,4)   NOT NULL,
        Adj_LineItems                 INT             NOT NULL,
        Adj_ModeAllowed               DECIMAL(18,4)   NOT NULL,
        Adj_ModeIns                   DECIMAL(18,4)   NOT NULL,

        -- Section 2: Ratios
        PaymentRatio_Claim            DECIMAL(10,2)   NULL,
        PaymentRatio_Allowed          DECIMAL(10,2)   NULL,
        PaymentRatio_Insurance        DECIMAL(10,2)   NULL,
        NonPaymentRate_Claim          DECIMAL(10,2)   NULL,
        NonPaymentRate_Allowed        DECIMAL(10,2)   NULL,
        NonPaymentRate_Insurance      DECIMAL(10,2)   NULL,
        DeniedPct_Claim               DECIMAL(10,2)   NULL,
        DeniedPct_Allowed             DECIMAL(10,2)   NULL,
        DeniedPct_Insurance           DECIMAL(10,2)   NULL,
        NoResponsePct_Claim           DECIMAL(10,2)   NULL,
        NoResponsePct_Allowed         DECIMAL(10,2)   NULL,
        NoResponsePct_Insurance       DECIMAL(10,2)   NULL,
        AdjustedPct_Claim             DECIMAL(10,2)   NULL,
        AdjustedPct_Allowed           DECIMAL(10,2)   NULL,
        AdjustedPct_Insurance         DECIMAL(10,2)   NULL,

        -- Section 3: Prediction Accuracy
        PredAccuracy_Claim            DECIMAL(10,2)   NULL,
        PredAccuracy_AllowedAmount    DECIMAL(10,2)   NULL,
        PredAccuracy_InsurancePayment DECIMAL(10,2)   NULL
    );

    CREATE UNIQUE INDEX IX_PV_SummaryMetrics_Lookup
        ON dbo.PV_SummaryMetrics (RunId, WeekStartDate);
END
GO
