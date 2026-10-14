/*
   LRNLabDemo / LabDemo — Collection Summary PCR aliases over Cove objects
   -----------------------------------------------------------------------
   LabDemo DB was restored from Cove, so aggregates are Cove_CS_* /
   usp_GetCove_CS_*. The dashboard maps LRNLabDemo → prefix "PCR" and looks
   for PCR_CS_* / usp_GetPCR_CS_*.

   This script:
     1) Creates synonyms PCR_CS_* → Cove_CS_* (snapshot tables)
     2) Creates thin usp_GetPCR_CS_* wrappers that EXEC the Cove Get SPs
     3) Creates thin usp_RefreshPCR_CS_* wrappers that EXEC Cove Refresh SPs

   Run on the demo database (change USE below if your DB name differs).
   Safe to re-run.
*/

USE LabDemo;   -- or: USE LRNLabDemo;
GO

SET NOCOUNT ON;
PRINT '=== Demo CS: create PCR aliases over Cove objects on ' + DB_NAME() + ' ===';

/* ---------- Snapshot table synonyms ---------- */
DECLARE @Tables TABLE (PcrName SYSNAME, CoveName SYSNAME);
INSERT INTO @Tables (PcrName, CoveName) VALUES
    (N'PCR_CS_Top5ReimbursementPct',  N'Cove_CS_Top5ReimbursementPct'),
    (N'PCR_CS_Top5ReimbursementPay',  N'Cove_CS_Top5ReimbursementPay'),
    (N'PCR_CS_MonthlyClaimVolume',    N'Cove_CS_MonthlyClaimVolume'),
    (N'PCR_CS_WeeklyClaimVolume',     N'Cove_CS_WeeklyClaimVolume'),
    (N'PCR_CS_PanelAverages',         N'Cove_CS_PanelAverages'),
    (N'PCR_CS_AvgPayments',           N'Cove_CS_AvgPayments'),
    (N'PCR_CS_InsuranceVsAging',      N'Cove_CS_InsuranceVsAging'),
    (N'PCR_CS_PanelVsPayment',        N'Cove_CS_PanelVsPayment'),
    (N'PCR_CS_RepVsPayment',          N'Cove_CS_RepVsPayment'),
    (N'PCR_CS_InsuranceVsPaymentPct', N'Cove_CS_InsuranceVsPaymentPct'),
    (N'PCR_CS_CptVsPaymentPct',       N'Cove_CS_CptVsPaymentPct'),
    (N'PCR_CS_StatusSummary',         N'Cove_CS_StatusSummary'),
    (N'PCR_CS_ProviderSummary',       N'Cove_CS_ProviderSummary'),
    (N'PCR_CS_InsuranceVsPayment',    N'Cove_CS_InsuranceVsPayment');

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

/* ---------- Get SP wrappers (same params as Cove Get SPs) ---------- */

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_Top5ReimbursementPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_Top5ReimbursementPct
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_Top5ReimbursementPay
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_Top5ReimbursementPay
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_MonthlyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_MonthlyClaimVolume
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_WeeklyClaimVolume
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_WeeklyClaimVolume
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_PanelAverages
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_PanelAverages
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_AvgPayments
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_AvgPayments
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_InsuranceVsAging
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_InsuranceVsAging
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_PanelVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_PanelVsPayment
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_RepVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_RepVsPayment
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_InsuranceVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_InsuranceVsPaymentPct
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_CptVsPaymentPct
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_CptVsPaymentPct
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_StatusSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_StatusSummary
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_ProviderSummary
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_ProviderSummary
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetPCR_CS_InsuranceVsPayment
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;
    EXEC dbo.usp_GetCove_CS_InsuranceVsPayment
        @PayerNames    = @PayerNames,
        @PanelNames    = @PanelNames,
        @DosFrom       = @DosFrom,
        @DosTo         = @DosTo,
        @FirstBillFrom = @FirstBillFrom,
        @FirstBillTo   = @FirstBillTo,
        @CheckDateFrom = @CheckDateFrom,
        @CheckDateTo   = @CheckDateTo;
END
GO

/* ---------- Refresh wrappers (optional; keep PCR refresh names working) ---------- */

CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_Top5ReimbursementPct
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_Top5ReimbursementPct; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_Top5ReimbursementPay
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_Top5ReimbursementPay; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_MonthlyClaimVolume
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_MonthlyClaimVolume; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_WeeklyClaimVolume
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_WeeklyClaimVolume; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_PanelAverages
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_PanelAverages; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_AvgPayments
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_AvgPayments; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_InsuranceVsAging
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_InsuranceVsAging; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_PanelVsPayment
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_PanelVsPayment; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_RepVsPayment
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_RepVsPayment; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_InsuranceVsPaymentPct
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_InsuranceVsPaymentPct; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_CptVsPaymentPct
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_CptVsPaymentPct; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_StatusSummary
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_StatusSummary; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_ProviderSummary
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_ProviderSummary; END
GO
CREATE OR ALTER PROCEDURE dbo.usp_RefreshPCR_CS_InsuranceVsPayment
AS BEGIN SET NOCOUNT ON; EXEC dbo.usp_RefreshCove_CS_InsuranceVsPayment; END
GO

/* ---------- Smoke check ---------- */
PRINT '--- verify ---';
SELECT name AS [TableOrSynonym]
FROM sys.synonyms
WHERE name LIKE 'PCR_CS_%'
ORDER BY name;

SELECT name AS [GetProc]
FROM sys.procedures
WHERE name LIKE 'usp_GetPCR_CS_%'
ORDER BY name;

EXEC dbo.usp_GetPCR_CS_Top5ReimbursementPct;
GO

PRINT '=== Demo CS PCR aliases complete ===';
GO
