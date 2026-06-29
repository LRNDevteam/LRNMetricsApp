/* ============================================================
   Cove Executive Summary — sample SP execution commands
   DB: Cove_LRN
   ------------------------------------------------------------
   usp_GetCove_ExecutiveSummary parameters (all optional):
     @YearFrom   INT  = 0     legacy year/month filters (0 = no filter)
     @YearTo     INT  = 0
     @MonthFrom  INT  = 0
     @MonthTo    INT  = 0
     @DosFrom    DATE = NULL   Date-of-Service range (exact dates)
     @DosTo      DATE = NULL
     @BilledFrom DATE = NULL   First-Billed-Date range
     @BilledTo   DATE = NULL
     @Panels     NVARCHAR(MAX) = NULL  comma-separated list (NULL = all)
     @Clinics    NVARCHAR(MAX) = NULL
     @Providers  NVARCHAR(MAX) = NULL
     @Reps       NVARCHAR(MAX) = NULL

   Any non-default value -> live re-aggregation (filtered) path.
   All defaults -> fast read from the aggregate tables.
   ============================================================ */
USE [CoveLRN];
GO

------------------------------------------------------------------
-- 0) Dropdown values for the filter UI (no parameters)
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary_FilterOptions;
GO

------------------------------------------------------------------
-- 1) No filter — fast path (reads the aggregate tables)
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary;
GO

-- Equivalent explicit no-filter call
EXEC dbo.usp_GetCove_ExecutiveSummary
     @YearFrom = 0, @YearTo = 0, @MonthFrom = 0, @MonthTo = 0,
     @DosFrom = NULL, @DosTo = NULL, @BilledFrom = NULL, @BilledTo = NULL,
     @Panels = NULL, @Clinics = NULL, @Providers = NULL, @Reps = NULL;
GO

------------------------------------------------------------------
-- 2) Date-of-Service range only (matches the screenshot case)
--    LIS is filtered natively on the LIMSMaster date column.
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary
     @DosFrom = '2026-05-01',
     @DosTo   = '2026-06-24';
GO

------------------------------------------------------------------
-- 3) First-Billed-Date range only
--    (LIS uses the ClaimLevelData bridge for this filter)
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary
     @BilledFrom = '2026-06-10',
     @BilledTo   = '2026-06-16';
GO

------------------------------------------------------------------
-- 4) Legacy year / month range
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary
     @YearFrom = 2026, @YearTo = 2026,
     @MonthFrom = 1,   @MonthTo = 6;
GO

------------------------------------------------------------------
-- 5) Single panel
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary
     @Panels = N'UTI,UTI (Specimen Source)';
GO

------------------------------------------------------------------
-- 6) Multiple panels (comma-separated)
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary
     @Panels = N'UTI,UTI (Specimen Source),GI,GI (Specimen Source),STI,STI (Specimen Source)';
GO

------------------------------------------------------------------
-- 7) Clinic / Provider / Rep (each bridges via ClaimLevelData)
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary @Clinics   = N'Main Street Clinic';
GO
EXEC dbo.usp_GetCove_ExecutiveSummary @Providers = N'Dr. Jane Smith,Dr. John Doe';
GO
EXEC dbo.usp_GetCove_ExecutiveSummary @Reps      = N'Alex Rep';
GO

------------------------------------------------------------------
-- 8) All filters together
------------------------------------------------------------------
EXEC dbo.usp_GetCove_ExecutiveSummary
     @YearFrom   = 0,
     @YearTo     = 0,
     @MonthFrom  = 0,
     @MonthTo    = 0,
     @DosFrom    = '2026-05-01',
     @DosTo      = '2026-06-24',
     @BilledFrom = '2026-06-10',
     @BilledTo   = '2026-06-16',
     @Panels     = N'UTI,UTI (Specimen Source),GI,GI (Specimen Source)',
     @Clinics    = N'Main Street Clinic,Downtown Lab',
     @Providers  = N'Dr. Jane Smith',
     @Reps       = N'Alex Rep,Sam Rep';
GO
