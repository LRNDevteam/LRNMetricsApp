/*
   LRNLabDemo / LabDemo — Production Summary NW aliases over Cove
   ----------------------------------------------------------------
   WHY (no app code change possible):
     LabProductionSummaryRepositoryMap has no LRNLabDemo entry.
     DashboardController therefore falls back to the NorthWest repo,
     which calls dbo.usp_GetNW_* (not PCR / Cove).

   PCR aliases (script 06) do NOT fix Production Summary for this lab.
   This script creates NW_* synonyms + usp_GetNW_* wrappers → Cove objects.

   Also refreshes Cove monthly/weekly aggregates if refresh SPs exist
   (empty Cove_MonthlyBilledProductionSummary = empty UI message).

   Run on LabDemo. Change USE if needed. Safe to re-run.
*/

USE LabDemo;   -- or: USE LRNLabDemo;
GO

SET NOCOUNT ON;
PRINT '=== Demo Production: NW aliases over Cove on ' + DB_NAME() + ' ===';

/* ---------- 0) Quick data check before aliases ---------- */
IF OBJECT_ID(N'dbo.Cove_MonthlyBilledProductionSummary', N'U') IS NOT NULL
BEGIN
    DECLARE @mc INT = (SELECT COUNT(*) FROM dbo.Cove_MonthlyBilledProductionSummary);
    PRINT 'Cove_MonthlyBilledProductionSummary rows = ' + CAST(@mc AS NVARCHAR(20));
    IF @mc = 0
        PRINT 'WARNING: monthly snapshot is EMPTY — will refresh if SP exists.';
END
ELSE
    PRINT 'ERROR: Cove_MonthlyBilledProductionSummary missing — restore/Cove pack incomplete.';
GO

/* ---------- 1) Table synonyms NW_* → Cove_* ---------- */
DECLARE @Tables TABLE (NwName SYSNAME, CoveName SYSNAME);
INSERT INTO @Tables (NwName, CoveName) VALUES
    (N'NW_MonthlyBilledProductionSummary', N'Cove_MonthlyBilledProductionSummary'),
    (N'NW_WeeklyBilledProductionSummary',  N'Cove_WeeklyBilledProductionSummary'),
    (N'NW_PayerBreakdown',                 N'Cove_PayerBreakdown'),
    (N'NW_PayerByPanel',                   N'Cove_PayerByPanel'),
    (N'NW_CodingPanelSummary',             N'Cove_CodingPanelSummary'),
    (N'NW_CodingCPTDetail',                N'Cove_CodingCPTDetail'),
    (N'NW_UnbilledAging',                  N'Cove_UnbilledAging'),
    (N'NW_CPTBreakdown',                   N'Cove_CPTBreakdown');

DECLARE @Nw SYSNAME, @Cove SYSNAME, @sql NVARCHAR(MAX);
DECLARE tcur CURSOR LOCAL FAST_FORWARD FOR SELECT NwName, CoveName FROM @Tables;
OPEN tcur;
FETCH NEXT FROM tcur INTO @Nw, @Cove;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF OBJECT_ID(N'dbo.' + @Cove, N'U') IS NULL
        PRINT 'SKIP synonym ' + @Nw + ' — missing ' + @Cove;
    ELSE
    BEGIN
        IF OBJECT_ID(N'dbo.' + @Nw, N'U') IS NOT NULL
        BEGIN
            SET @sql = N'DROP TABLE dbo.' + QUOTENAME(@Nw) + N';';
            EXEC sys.sp_executesql @sql;
        END
        IF OBJECT_ID(N'dbo.' + @Nw, N'V') IS NOT NULL
        BEGIN
            SET @sql = N'DROP VIEW dbo.' + QUOTENAME(@Nw) + N';';
            EXEC sys.sp_executesql @sql;
        END
        IF OBJECT_ID(N'dbo.' + @Nw, N'SN') IS NOT NULL
        BEGIN
            SET @sql = N'DROP SYNONYM dbo.' + QUOTENAME(@Nw) + N';';
            EXEC sys.sp_executesql @sql;
        END
        SET @sql = N'CREATE SYNONYM dbo.' + QUOTENAME(@Nw) + N' FOR dbo.' + QUOTENAME(@Cove) + N';';
        EXEC sys.sp_executesql @sql;
        PRINT 'OK synonym ' + @Nw + ' → ' + @Cove;
    END
    FETCH NEXT FROM tcur INTO @Nw, @Cove;
END
CLOSE tcur; DEALLOCATE tcur;
GO

/* ---------- 2) Get SP wrappers (what Production Summary actually calls) ---------- */

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_MonthlyBilledProductionSummary
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_WeeklyBilledProductionSummary
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerBreakdown
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_PayerByPanel
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CodingBreakdown
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetNW_UnbilledAging
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

-- NW CPT tab often uses usp_GetNW_CPTBreakdown; some builds use CountUnits / BySource.
-- Point the core Get at Cove; optional extras only if Cove equivalents exist.
CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdown
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
        @PayerNames=@PayerNames, @PanelNames=@PanelNames,
        @DosFrom=@DosFrom, @DosTo=@DosTo,
        @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
        @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
END
GO

IF OBJECT_ID(N'dbo.usp_GetCove_CPTBreakdown_CountCpt', N'P') IS NOT NULL
BEGIN
    EXEC(N'
    CREATE OR ALTER PROCEDURE dbo.usp_GetNW_CPTBreakdown_CountUnits
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
        EXEC dbo.usp_GetCove_CPTBreakdown_CountCpt
            @PayerNames=@PayerNames, @PanelNames=@PanelNames,
            @DosFrom=@DosFrom, @DosTo=@DosTo,
            @FirstBillFrom=@FirstBillFrom, @FirstBillTo=@FirstBillTo,
            @FirstBilledFrom=@FirstBilledFrom, @FirstBilledTo=@FirstBilledTo;
    END
    ');
    PRINT 'OK usp_GetNW_CPTBreakdown_CountUnits → Cove CountCpt';
END
GO

/* ---------- 3) Refresh Cove aggregates if empty / stale ---------- */
IF OBJECT_ID(N'dbo.usp_RefreshCove_MonthlyBilledProductionSummary', N'P') IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC dbo.usp_RefreshCove_MonthlyBilledProductionSummary;
        PRINT 'OK refresh Monthly';
    END TRY
    BEGIN CATCH
        PRINT 'FAIL refresh Monthly: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
    PRINT 'SKIP refresh Monthly — SP missing';

IF OBJECT_ID(N'dbo.usp_RefreshCove_WeeklyBilledProductionSummary', N'P') IS NOT NULL
BEGIN
    BEGIN TRY
        EXEC dbo.usp_RefreshCove_WeeklyBilledProductionSummary;
        PRINT 'OK refresh Weekly';
    END TRY
    BEGIN CATCH
        PRINT 'FAIL refresh Weekly: ' + ERROR_MESSAGE();
    END CATCH
END
ELSE
    PRINT 'SKIP refresh Weekly — SP missing';

IF OBJECT_ID(N'dbo.usp_RefreshCove_PayerBreakdown', N'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshCove_PayerBreakdown; PRINT 'OK refresh PayerBreakdown'; END TRY
BEGIN CATCH PRINT 'FAIL PayerBreakdown: ' + ERROR_MESSAGE(); END CATCH

IF OBJECT_ID(N'dbo.usp_RefreshCove_PayerByPanel', N'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshCove_PayerByPanel; PRINT 'OK refresh PayerByPanel'; END TRY
BEGIN CATCH PRINT 'FAIL PayerByPanel: ' + ERROR_MESSAGE(); END CATCH

IF OBJECT_ID(N'dbo.usp_RefreshCove_CodingBreakdown_Unbilled', N'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshCove_CodingBreakdown_Unbilled; PRINT 'OK refresh Coding'; END TRY
BEGIN CATCH PRINT 'FAIL Coding: ' + ERROR_MESSAGE(); END CATCH

IF OBJECT_ID(N'dbo.usp_RefreshCove_UnbilledAging', N'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshCove_UnbilledAging; PRINT 'OK refresh UnbilledAging'; END TRY
BEGIN CATCH PRINT 'FAIL UnbilledAging: ' + ERROR_MESSAGE(); END CATCH

IF OBJECT_ID(N'dbo.usp_RefreshCove_CPTBreakdown', N'P') IS NOT NULL
BEGIN TRY EXEC dbo.usp_RefreshCove_CPTBreakdown; PRINT 'OK refresh CPT'; END TRY
BEGIN CATCH PRINT 'FAIL CPT: ' + ERROR_MESSAGE(); END CATCH
GO

/* ---------- 4) Smoke ---------- */
PRINT '--- row counts ---';
IF OBJECT_ID(N'dbo.Cove_MonthlyBilledProductionSummary', N'U') IS NOT NULL
    SELECT 'Cove_Monthly' AS Src, COUNT(*) AS Rows FROM dbo.Cove_MonthlyBilledProductionSummary;
IF OBJECT_ID(N'dbo.NW_MonthlyBilledProductionSummary', N'SN') IS NOT NULL
    OR OBJECT_ID(N'dbo.NW_MonthlyBilledProductionSummary', N'U') IS NOT NULL
    SELECT 'NW_Monthly (alias)' AS Src, COUNT(*) AS Rows FROM dbo.NW_MonthlyBilledProductionSummary;

PRINT '--- EXEC usp_GetNW_MonthlyBilledProductionSummary (top 20) ---';
IF OBJECT_ID(N'dbo.usp_GetNW_MonthlyBilledProductionSummary', N'P') IS NOT NULL
BEGIN
    EXEC dbo.usp_GetNW_MonthlyBilledProductionSummary;
END
GO

PRINT '=== Done. Hard-refresh Production Summary (Ctrl+F5). ===';
PRINT 'If monthly still empty: ClaimLevelData may lack ChargeEnteredDate / FirstBilledDate rows.';
GO
