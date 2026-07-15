-- ============================================================
-- 04_PredictionAggregateTables.sql
-- PV_* snapshot tables ? one run per lab, refreshed by
-- usp_RefreshAllPredictionAggregates after each ingestion.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.PV_SummaryBuckets', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_SummaryBuckets
    (
        Id                 BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId              NVARCHAR(100)  NOT NULL,
        WeekStartDate      DATE           NULL,
        GroupName          NVARCHAR(100)  NOT NULL,
        BucketName         NVARCHAR(100)  NOT NULL,
        PayStatus          NVARCHAR(100)  NULL,
        IsGroupTotal       BIT            NOT NULL DEFAULT 0,
        SortOrder          INT            NOT NULL,
        LineItemCount      INT            NOT NULL DEFAULT 0,
        PredictedAllowed   DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PredictedInsurance DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualAllowed      DECIMAL(18,4)  NULL,
        ActualInsurance    DECIMAL(18,4)  NULL,
        VarianceAllowed    DECIMAL(18,4)  NULL,
        VariancePaid       DECIMAL(18,4)  NULL,
        RefreshedAt        DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_SummaryBuckets_Run ON dbo.PV_SummaryBuckets (RunId, WeekStartDate);
END
GO

-- Add new columns to existing PV_SummaryBuckets
IF COL_LENGTH('dbo.PV_SummaryBuckets', 'GroupName') IS NULL
    ALTER TABLE dbo.PV_SummaryBuckets ADD GroupName NVARCHAR(100) NOT NULL CONSTRAINT DF_PV_SB_Group DEFAULT '';
IF COL_LENGTH('dbo.PV_SummaryBuckets', 'PayStatus') IS NULL
    ALTER TABLE dbo.PV_SummaryBuckets ADD PayStatus NVARCHAR(100) NULL;
IF COL_LENGTH('dbo.PV_SummaryBuckets', 'IsGroupTotal') IS NULL
    ALTER TABLE dbo.PV_SummaryBuckets ADD IsGroupTotal BIT NOT NULL CONSTRAINT DF_PV_SB_IsGroup DEFAULT 0;
IF COL_LENGTH('dbo.PV_SummaryBuckets', 'VarianceAllowed') IS NULL
    ALTER TABLE dbo.PV_SummaryBuckets ADD VarianceAllowed DECIMAL(18,4) NULL;
IF COL_LENGTH('dbo.PV_SummaryBuckets', 'VariancePaid') IS NULL
    ALTER TABLE dbo.PV_SummaryBuckets ADD VariancePaid DECIMAL(18,4) NULL;
GO

IF OBJECT_ID('dbo.PV_ValidationByPayer', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_ValidationByPayer
    (
        Id                 BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId              NVARCHAR(100)  NOT NULL,
        WeekStartDate      DATE           NULL,
        PayerName          NVARCHAR(255)  NOT NULL,
        PayerType          NVARCHAR(100)  NULL,
        TotalLineItems     INT            NOT NULL DEFAULT 0,
        PredictedAllowed   DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PredictedInsurance DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualAllowed      DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualInsurance    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VarianceAllowed    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VariancePaid       DECIMAL(18,4)  NOT NULL DEFAULT 0,
        RefreshedAt        DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_ValidationByPayer_Run ON dbo.PV_ValidationByPayer (RunId, WeekStartDate);
END
GO

IF COL_LENGTH('dbo.PV_ValidationByPayer', 'VarianceAllowed') IS NULL
    ALTER TABLE dbo.PV_ValidationByPayer ADD VarianceAllowed DECIMAL(18,4) NOT NULL CONSTRAINT DF_PV_VBP_VarAllow DEFAULT 0;
IF COL_LENGTH('dbo.PV_ValidationByPayer', 'VariancePaid') IS NULL
    ALTER TABLE dbo.PV_ValidationByPayer ADD VariancePaid DECIMAL(18,4) NOT NULL CONSTRAINT DF_PV_VBP_VarPaid DEFAULT 0;

-- Legacy pay-status count columns (older PV_ValidationByPayer deployments)
IF COL_LENGTH('dbo.PV_ValidationByPayer', 'PaidCount') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.default_constraints dc
       INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
       WHERE c.object_id = OBJECT_ID('dbo.PV_ValidationByPayer') AND c.name = 'PaidCount')
    ALTER TABLE dbo.PV_ValidationByPayer ADD CONSTRAINT DF_PV_VBP_PaidCount DEFAULT 0 FOR PaidCount;
IF COL_LENGTH('dbo.PV_ValidationByPayer', 'DeniedCount') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.default_constraints dc
       INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
       WHERE c.object_id = OBJECT_ID('dbo.PV_ValidationByPayer') AND c.name = 'DeniedCount')
    ALTER TABLE dbo.PV_ValidationByPayer ADD CONSTRAINT DF_PV_VBP_DeniedCount DEFAULT 0 FOR DeniedCount;
IF COL_LENGTH('dbo.PV_ValidationByPayer', 'NoResponseCount') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.default_constraints dc
       INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
       WHERE c.object_id = OBJECT_ID('dbo.PV_ValidationByPayer') AND c.name = 'NoResponseCount')
    ALTER TABLE dbo.PV_ValidationByPayer ADD CONSTRAINT DF_PV_VBP_NoResponseCount DEFAULT 0 FOR NoResponseCount;
IF COL_LENGTH('dbo.PV_ValidationByPayer', 'AdjustedCount') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.default_constraints dc
       INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
       WHERE c.object_id = OBJECT_ID('dbo.PV_ValidationByPayer') AND c.name = 'AdjustedCount')
    ALTER TABLE dbo.PV_ValidationByPayer ADD CONSTRAINT DF_PV_VBP_AdjustedCount DEFAULT 0 FOR AdjustedCount;
IF COL_LENGTH('dbo.PV_ValidationByPayer', 'UnpaidCount') IS NOT NULL
   AND NOT EXISTS (
       SELECT 1 FROM sys.default_constraints dc
       INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
       WHERE c.object_id = OBJECT_ID('dbo.PV_ValidationByPayer') AND c.name = 'UnpaidCount')
    ALTER TABLE dbo.PV_ValidationByPayer ADD CONSTRAINT DF_PV_VBP_UnpaidCount DEFAULT 0 FOR UnpaidCount;
GO

IF OBJECT_ID('dbo.PV_PayerPayStatusBreakdown', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_PayerPayStatusBreakdown
    (
        Id                 BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId              NVARCHAR(100)  NOT NULL,
        WeekStartDate      DATE           NULL,
        PayerName          NVARCHAR(255)  NOT NULL,
        PayStatus          NVARCHAR(100)  NOT NULL,
        LineItemCount      INT            NOT NULL DEFAULT 0,
        PredictedAllowed   DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PredictedInsurance DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualAllowed      DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualInsurance    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VarianceAllowed    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VariancePaid       DECIMAL(18,4)  NOT NULL DEFAULT 0,
        RefreshedAt        DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_PayerPayStatus_Run ON dbo.PV_PayerPayStatusBreakdown (RunId, WeekStartDate);
END
GO

IF OBJECT_ID('dbo.PV_DenialBreakdown', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_DenialBreakdown
    (
        Id                 BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId              NVARCHAR(100)  NOT NULL,
        WeekStartDate      DATE           NULL,
        PayerName          NVARCHAR(255)  NOT NULL,
        DenialCode         NVARCHAR(100)  NULL,
        DenialDescription  NVARCHAR(1000) NULL,
        LineItemCount      INT            NOT NULL DEFAULT 0,
        PredictedAllowed   DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PredictedInsurance DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualAllowed      DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualInsurance    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VarianceAllowed    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VariancePaid       DECIMAL(18,4)  NOT NULL DEFAULT 0,
        RefreshedAt        DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_DenialBreakdown_Run ON dbo.PV_DenialBreakdown (RunId, WeekStartDate);
END
GO

IF COL_LENGTH('dbo.PV_DenialBreakdown', 'ActualAllowed') IS NULL
    ALTER TABLE dbo.PV_DenialBreakdown ADD ActualAllowed DECIMAL(18,4) NOT NULL CONSTRAINT DF_PV_DB_ActAllow DEFAULT 0;
IF COL_LENGTH('dbo.PV_DenialBreakdown', 'ActualInsurance') IS NULL
    ALTER TABLE dbo.PV_DenialBreakdown ADD ActualInsurance DECIMAL(18,4) NOT NULL CONSTRAINT DF_PV_DB_ActIns DEFAULT 0;
IF COL_LENGTH('dbo.PV_DenialBreakdown', 'VarianceAllowed') IS NULL
    ALTER TABLE dbo.PV_DenialBreakdown ADD VarianceAllowed DECIMAL(18,4) NOT NULL CONSTRAINT DF_PV_DB_VarAllow DEFAULT 0;
IF COL_LENGTH('dbo.PV_DenialBreakdown', 'VariancePaid') IS NULL
    ALTER TABLE dbo.PV_DenialBreakdown ADD VariancePaid DECIMAL(18,4) NOT NULL CONSTRAINT DF_PV_DB_VarPaid DEFAULT 0;

-- Legacy versions stored ExpectedPaymentMonth as NOT NULL. The current
-- denial snapshot is grouped by payer/code and no longer persists a month,
-- so inserts must be allowed to omit this legacy column.
IF COL_LENGTH('dbo.PV_DenialBreakdown', 'ExpectedPaymentMonth') IS NOT NULL
    ALTER TABLE dbo.PV_DenialBreakdown ALTER COLUMN ExpectedPaymentMonth NVARCHAR(100) NULL;
GO

IF OBJECT_ID('dbo.PV_NoResponseBreakdown', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_NoResponseBreakdown
    (
        Id                 BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId              NVARCHAR(100)  NOT NULL,
        WeekStartDate      DATE           NULL,
        PayerName          NVARCHAR(255)  NOT NULL,
        AgeBucket          NVARCHAR(50)   NOT NULL,
        LineItemCount      INT            NOT NULL DEFAULT 0,
        VarianceAllowed    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VariancePaid       DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PctVarianceAllowed DECIMAL(10,2)  NULL,
        PctVariancePaid    DECIMAL(10,2)  NULL,
        RefreshedAt        DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_NoResponseBreakdown_Run ON dbo.PV_NoResponseBreakdown (RunId, WeekStartDate);
END
GO

-- Migrate existing PV_NoResponseBreakdown (older schema used PredictedAllowed/PredictedInsurance)
IF OBJECT_ID('dbo.PV_NoResponseBreakdown', 'U') IS NOT NULL
BEGIN
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'VarianceAllowed') IS NULL
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD VarianceAllowed DECIMAL(18,4) NOT NULL
            CONSTRAINT DF_PV_NR_VarAllow DEFAULT 0;
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'VariancePaid') IS NULL
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD VariancePaid DECIMAL(18,4) NOT NULL
            CONSTRAINT DF_PV_NR_VarPaid DEFAULT 0;
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PctVarianceAllowed') IS NULL
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD PctVarianceAllowed DECIMAL(10,2) NULL;
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PctVariancePaid') IS NULL
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD PctVariancePaid DECIMAL(10,2) NULL;

    -- Legacy amount columns: ensure DEFAULT 0 so inserts that omit them do not fail
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PredictedAllowed') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM sys.default_constraints dc
           INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
           WHERE c.object_id = OBJECT_ID('dbo.PV_NoResponseBreakdown') AND c.name = 'PredictedAllowed')
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD CONSTRAINT DF_PV_NR_PredAllow DEFAULT 0 FOR PredictedAllowed;
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'PredictedInsurance') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM sys.default_constraints dc
           INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
           WHERE c.object_id = OBJECT_ID('dbo.PV_NoResponseBreakdown') AND c.name = 'PredictedInsurance')
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD CONSTRAINT DF_PV_NR_PredIns DEFAULT 0 FOR PredictedInsurance;
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'ActualAllowed') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM sys.default_constraints dc
           INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
           WHERE c.object_id = OBJECT_ID('dbo.PV_NoResponseBreakdown') AND c.name = 'ActualAllowed')
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD CONSTRAINT DF_PV_NR_ActAllow DEFAULT 0 FOR ActualAllowed;
    IF COL_LENGTH('dbo.PV_NoResponseBreakdown', 'ActualInsurance') IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM sys.default_constraints dc
           INNER JOIN sys.columns c ON c.default_object_id = dc.object_id
           WHERE c.object_id = OBJECT_ID('dbo.PV_NoResponseBreakdown') AND c.name = 'ActualInsurance')
        ALTER TABLE dbo.PV_NoResponseBreakdown ADD CONSTRAINT DF_PV_NR_ActIns DEFAULT 0 FOR ActualInsurance;
END
GO

IF OBJECT_ID('dbo.PV_AdjustedByPayer', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_AdjustedByPayer
    (
        Id                 BIGINT         IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId              NVARCHAR(100)  NOT NULL,
        WeekStartDate      DATE           NULL,
        PayerName          NVARCHAR(255)  NOT NULL,
        LineItemCount      INT            NOT NULL DEFAULT 0,
        PredictedAllowed   DECIMAL(18,4)  NOT NULL DEFAULT 0,
        PredictedInsurance DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualAllowed      DECIMAL(18,4)  NOT NULL DEFAULT 0,
        ActualInsurance    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VarianceAllowed    DECIMAL(18,4)  NOT NULL DEFAULT 0,
        VariancePaid       DECIMAL(18,4)  NOT NULL DEFAULT 0,
        RefreshedAt        DATETIME2      NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_AdjustedByPayer_Run ON dbo.PV_AdjustedByPayer (RunId, WeekStartDate);
END
GO

IF OBJECT_ID('dbo.PV_SummaryMetrics', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.PV_SummaryMetrics
    (
        Id                            BIGINT        IDENTITY(1,1) NOT NULL PRIMARY KEY,
        RunId                         NVARCHAR(100) NOT NULL,
        WeekStartDate                 DATE          NULL,
        ToPay_LineItems               INT           NOT NULL DEFAULT 0,
        ToPay_ModeAllowed             DECIMAL(18,4) NOT NULL DEFAULT 0,
        ToPay_ModeIns                 DECIMAL(18,4) NOT NULL DEFAULT 0,
        Paid_LineItems                INT           NOT NULL DEFAULT 0,
        Paid_ModeAllowed              DECIMAL(18,4) NOT NULL DEFAULT 0,
        Paid_ModeIns                  DECIMAL(18,4) NOT NULL DEFAULT 0,
        Paid_ActAllowed               DECIMAL(18,4) NOT NULL DEFAULT 0,
        Paid_ActIns                   DECIMAL(18,4) NOT NULL DEFAULT 0,
        Unpaid_LineItems              INT           NOT NULL DEFAULT 0,
        Unpaid_ModeAllowed            DECIMAL(18,4) NOT NULL DEFAULT 0,
        Unpaid_ModeIns                DECIMAL(18,4) NOT NULL DEFAULT 0,
        Denied_LineItems              INT           NOT NULL DEFAULT 0,
        Denied_ModeAllowed            DECIMAL(18,4) NOT NULL DEFAULT 0,
        Denied_ModeIns                DECIMAL(18,4) NOT NULL DEFAULT 0,
        NoResp_LineItems              INT           NOT NULL DEFAULT 0,
        NoResp_ModeAllowed            DECIMAL(18,4) NOT NULL DEFAULT 0,
        NoResp_ModeIns                DECIMAL(18,4) NOT NULL DEFAULT 0,
        Adj_LineItems                 INT           NOT NULL DEFAULT 0,
        Adj_ModeAllowed               DECIMAL(18,4) NOT NULL DEFAULT 0,
        Adj_ModeIns                   DECIMAL(18,4) NOT NULL DEFAULT 0,
        PaymentRatio_Claim            DECIMAL(10,2) NULL,
        PaymentRatio_Allowed          DECIMAL(10,2) NULL,
        PaymentRatio_Insurance        DECIMAL(10,2) NULL,
        NonPaymentRate_Claim            DECIMAL(10,2) NULL,
        NonPaymentRate_Allowed          DECIMAL(10,2) NULL,
        NonPaymentRate_Insurance        DECIMAL(10,2) NULL,
        DeniedPct_Claim               DECIMAL(10,2) NULL,
        DeniedPct_Allowed             DECIMAL(10,2) NULL,
        DeniedPct_Insurance           DECIMAL(10,2) NULL,
        NoResponsePct_Claim           DECIMAL(10,2) NULL,
        NoResponsePct_Allowed         DECIMAL(10,2) NULL,
        NoResponsePct_Insurance       DECIMAL(10,2) NULL,
        AdjustedPct_Claim             DECIMAL(10,2) NULL,
        AdjustedPct_Allowed           DECIMAL(10,2) NULL,
        AdjustedPct_Insurance         DECIMAL(10,2) NULL,
        PredAccuracy_Claim            DECIMAL(10,2) NULL,
        PredAccuracy_AllowedAmount      DECIMAL(10,2) NULL,
        PredAccuracy_InsurancePayment   DECIMAL(10,2) NULL,
        RefreshedAt                   DATETIME2     NOT NULL DEFAULT SYSUTCDATETIME()
    );
    CREATE INDEX IX_PV_SummaryMetrics_Run ON dbo.PV_SummaryMetrics (RunId, WeekStartDate);
END
GO
