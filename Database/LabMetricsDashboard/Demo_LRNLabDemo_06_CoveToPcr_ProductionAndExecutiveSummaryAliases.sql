/*
   LRNLabDemo / LabDemo — Production Summary + Executive Summary
   PCR aliases over Cove objects (SQL-only; no app deploy)
   ----------------------------------------------------------------
   Same pattern as Demo_LRNLabDemo_05_CoveToPcrCollectionSummaryAliases.sql:

     • Synonyms  PCR_* / PCR_ES_*  →  Cove_* / Cove_ES_*
     • Thin Get wrappers           usp_GetPCR_*  →  EXEC usp_GetCove_*
     • Thin Refresh wrappers       usp_RefreshPCR_* → EXEC usp_RefreshCove_*

   Run on the demo database. Change USE if your DB name differs.
   Safe to re-run. Requires the Cove Production / ES objects already present
   (from the Cove restore).
*/

USE LabDemo;   -- or: USE LRNLabDemo;
GO

SET NOCOUNT ON;
PRINT '=== Demo Prod+ES: PCR aliases over Cove on ' + DB_NAME() + ' ===';

/* =====================================================================
   1) Snapshot / aggregate table synonyms
   ===================================================================== */
DECLARE @Tables TABLE (PcrName SYSNAME, CoveName SYSNAME);
INSERT INTO @Tables (PcrName, CoveName) VALUES
    -- Production Summary
    (N'PCR_MonthlyBilledProductionSummary', N'Cove_MonthlyBilledProductionSummary'),
    (N'PCR_WeeklyBilledProductionSummary',  N'Cove_WeeklyBilledProductionSummary'),
    (N'PCR_PayerBreakdown',                 N'Cove_PayerBreakdown'),
    (N'PCR_PayerByPanel',                   N'Cove_PayerByPanel'),
    (N'PCR_CodingPanelSummary',             N'Cove_CodingPanelSummary'),
    (N'PCR_CodingCPTDetail',                N'Cove_CodingCPTDetail'),
    (N'PCR_UnbilledAging',                  N'Cove_UnbilledAging'),
    (N'PCR_CPTBreakdown',                   N'Cove_CPTBreakdown'),
    -- Executive Summary aggregates
    (N'PCR_ES_LIS',                         N'Cove_ES_LIS'),
    (N'PCR_ES_PMS',                         N'Cove_ES_PMS'),
    (N'PCR_ES_Cash',                        N'Cove_ES_Cash'),
    (N'PCR_ES_Avg',                         N'Cove_ES_Avg');

DECLARE @Pcr SYSNAME, @Cove SYSNAME, @sql NVARCHAR(MAX);
DECLARE tcur CURSOR LOCAL FAST_FORWARD FOR SELECT PcrName, CoveName FROM @Tables;
OPEN tcur;
FETCH NEXT FROM tcur INTO @Pcr, @Cove;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'dbo.' + @Cove, N'U') IS NULL
        PRINT 'SKIP synonym ' + @Pcr + ' — missing source ' + @Cove;
    ELSE
    BEGIN
        IF OBJECT_ID(N'dbo.' + @Pcr, N'U') IS NOT NULL
        BEGIN
            SET @sql = N'DROP TABLE dbo.' + QUOTENAME(@Pcr) + N';';
            EXEC sys.sp_executesql @sql;
            PRINT 'Dropped table ' + @Pcr;
        END
        IF OBJECT_ID(N'dbo.' + @Pcr, N'V') IS NOT NULL
        BEGIN
            SET @sql = N'DROP VIEW dbo.' + QUOTENAME(@Pcr) + N';';
            EXEC sys.sp_executesql @sql;
            PRINT 'Dropped view ' + @Pcr;
        END
        IF OBJECT_ID(N'dbo.' + @Pcr, N'SN') IS NOT NULL
        BEGIN
            SET @sql = N'DROP SYNONYM dbo.' + QUOTENAME(@Pcr) + N';';
            EXEC sys.sp_executesql @sql;
        END
        SET @sql = N'CREATE SYNONYM dbo.' + QUOTENAME(@Pcr) + N' FOR dbo.' + QUOTENAME(@Cove) + N';';
        EXEC sys.sp_executesql @sql;
        PRINT 'OK synonym ' + @Pcr + ' → ' + @Cove;
    END
    FETCH NEXT FROM tcur INTO @Pcr, @Cove;
END
CLOSE tcur; DEALLOCATE tcur;
GO

/* Optional: PCR_ES_LIS_Panel if Cove has a matching table (often absent). */
IF OBJECT_ID(N'dbo.Cove_ES_LIS_Panel', N'U') IS NOT NULL
BEGIN
    IF OBJECT_ID(N'dbo.PCR_ES_LIS_Panel', N'U') IS NOT NULL DROP TABLE dbo.PCR_ES_LIS_Panel;
    IF OBJECT_ID(N'dbo.PCR_ES_LIS_Panel', N'SN') IS NOT NULL DROP SYNONYM dbo.PCR_ES_LIS_Panel;
    CREATE SYNONYM dbo.PCR_ES_LIS_Panel FOR dbo.Cove_ES_LIS_Panel;
    PRINT 'OK synonym PCR_ES_LIS_Panel → Cove_ES_LIS_Panel';
END
ELSE
    PRINT 'SKIP synonym PCR_ES_LIS_Panel — Cove_ES_LIS_Panel not present';
GO

/* =====================================================================
   2) Production Summary — Get SP wrappers
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_MonthlyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_MonthlyBilledProductionSummary
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_WeeklyBilledProductionSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_WeeklyBilledProductionSummary
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_PayerBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_PayerBreakdown
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_PayerByPanel
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_PayerByPanel
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CodingBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CodingBreakdown
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_UnbilledAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_UnbilledAging
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CPTBreakdown
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @FirstBilledFrom DATE          = NULL,
    @FirstBilledTo   DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CPTBreakdown
        @PayerNames      = @PayerNames,
        @PanelNames      = @PanelNames,
        @DosFrom         = @DosFrom,
        @DosTo           = @DosTo,
        @FirstBillFrom   = @FirstBillFrom,
        @FirstBillTo     = @FirstBillTo,
        @FirstBilledFrom = @FirstBilledFrom,
        @FirstBilledTo   = @FirstBilledTo;
END
GO

/* =====================================================================
   3) Executive Summary — Get / Filter / Detail wrappers
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_ExecutiveSummary
(
    @YearFrom     INT           = NULL,
    @YearTo       INT           = NULL,
    @MonthFrom    INT           = NULL,
    @MonthTo      INT           = NULL,
    @DosFrom      DATE          = NULL,
    @DosTo        DATE          = NULL,
    @BilledFrom   DATE          = NULL,
    @BilledTo     DATE          = NULL,
    @Panels       NVARCHAR(MAX) = NULL,
    @Clinics      NVARCHAR(MAX) = NULL,
    @Providers    NVARCHAR(MAX) = NULL,
    @Reps         NVARCHAR(MAX) = NULL
)
AS
BEGIN
    SET NOCOUNT ON;
    -- Cove SP uses INT defaults of 0 (deprecated year/month) + optional @Debug.
    EXEC dbo.usp_GetCove_ExecutiveSummary
        @YearFrom    = @YearFrom,
        @YearTo      = @YearTo,
        @MonthFrom   = @MonthFrom,
        @MonthTo     = @MonthTo,
        @DosFrom     = @DosFrom,
        @DosTo       = @DosTo,
        @BilledFrom  = @BilledFrom,
        @BilledTo    = @BilledTo,
        @Panels      = @Panels,
        @Clinics     = @Clinics,
        @Providers   = @Providers,
        @Reps        = @Reps,
        @Debug       = 0;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_ExecutiveSummary_FilterOptions
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_ExecutiveSummary_FilterOptions;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_ExecutiveSummary_Detail
(
    @Category NVARCHAR(20),
    @RowCode  NVARCHAR(20),
    @Year     INT = 0,
    @Month    INT = 0
)
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_ExecutiveSummary_Detail
        @Category = @Category,
        @RowCode  = @RowCode,
        @Year     = @Year,
        @Month    = @Month;
END
GO

/* =====================================================================
   4) Refresh wrappers (optional; keep PCR refresh names working)
   ===================================================================== */

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_MonthlyBilledProductionSummary
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_MonthlyBilledProductionSummary', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_MonthlyBilledProductionSummary;
    ELSE
        RAISERROR('Missing usp_RefreshCove_MonthlyBilledProductionSummary', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_WeeklyBilledProductionSummary
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_WeeklyBilledProductionSummary', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_WeeklyBilledProductionSummary;
    ELSE
        RAISERROR('Missing usp_RefreshCove_WeeklyBilledProductionSummary', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_PayerBreakdown
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_PayerBreakdown', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_PayerBreakdown;
    ELSE
        RAISERROR('Missing usp_RefreshCove_PayerBreakdown', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_PayerByPanel
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_PayerByPanel', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_PayerByPanel;
    ELSE
        RAISERROR('Missing usp_RefreshCove_PayerByPanel', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CodingBreakdown_Billed
AS BEGIN SET NOCOUNT ON;
    -- Cove uses Unbilled coding refresh; map PCR "Billed" refresh name to it for demo.
    IF OBJECT_ID(N'dbo.usp_RefreshCove_CodingBreakdown_Unbilled', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_CodingBreakdown_Unbilled;
    ELSE IF OBJECT_ID(N'dbo.usp_RefreshCove_CodingBreakdown', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_CodingBreakdown;
    ELSE
        RAISERROR('Missing Cove CodingBreakdown refresh SP', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_UnbilledAging
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_UnbilledAging', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_UnbilledAging;
    ELSE
        RAISERROR('Missing usp_RefreshCove_UnbilledAging', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CPTBreakdown
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_CPTBreakdown', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_CPTBreakdown;
    ELSE
        RAISERROR('Missing usp_RefreshCove_CPTBreakdown', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_ExecutiveSummary
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_ExecutiveSummary', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_ExecutiveSummary;
    ELSE
        RAISERROR('Missing usp_RefreshCove_ExecutiveSummary', 16, 1);
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_ExecutiveSummary_LIS_Alt
AS BEGIN SET NOCOUNT ON;
    IF OBJECT_ID(N'dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt', N'P') IS NOT NULL
        EXEC dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt;
    ELSE
        RAISERROR('Missing usp_RefreshCove_ExecutiveSummary_LIS_Alt', 16, 1);
END
GO

/* =====================================================================
   5) Smoke checks
   ===================================================================== */
PRINT '--- verify Production ---';
SELECT name FROM sys.procedures WHERE name LIKE 'usp_GetPCR_%Billed%' OR name LIKE 'usp_GetPCR_Payer%' OR name LIKE 'usp_GetPCR_Coding%' OR name LIKE 'usp_GetPCR_Unbilled%' OR name LIKE 'usp_GetPCR_CPT%' ORDER BY name;

PRINT '--- verify Executive Summary ---';
SELECT name FROM sys.procedures WHERE name LIKE 'usp_GetPCR_ExecutiveSummary%' ORDER BY name;

IF OBJECT_ID(N'dbo.usp_GetCove_MonthlyBilledProductionSummary', N'P') IS NOT NULL
    EXEC dbo.usp_GetPCR_MonthlyBilledProductionSummary;
ELSE
    PRINT 'SKIP smoke Monthly — Cove Get SP missing';

IF OBJECT_ID(N'dbo.usp_GetCove_ExecutiveSummary', N'P') IS NOT NULL
    EXEC dbo.usp_GetPCR_ExecutiveSummary;
ELSE
    PRINT 'SKIP smoke ES — Cove Get SP missing';
GO

PRINT '=== Demo Prod+ES PCR aliases complete ===';
GO
