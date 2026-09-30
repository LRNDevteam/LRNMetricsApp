/* ============================================================================================
   AR Workbench - 02 Parsing helpers
   dbo.ClaimLevelData / dbo.LineLevelData hold every value as nvarchar. These inline table-valued
   functions convert them once, consistently. Inline TVFs (not scalar UDFs) so the optimizer folds
   them into the calling query - they cost nothing extra on a 400k-row load.
   Usage:  CROSS APPLY arwb.tvf_ParseMoney(s.InsuranceBalance) ib   ->  ib.Amount
           CROSS APPLY arwb.tvf_ParseDate(s.DateofService)     dos  ->  dos.DateValue
   ============================================================================================ */
-- Required for filtered indexes, persisted computed columns, and captured by every procedure/view at create time.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- "$1,234.50" -> 1234.50 ; "(12.00)" -> -12.00 ; "" / "NULL" / junk -> NULL
CREATE OR ALTER FUNCTION arwb.tvf_ParseMoney (@Value nvarchar(500))
RETURNS TABLE
AS
RETURN
    SELECT Amount =
        CASE
            WHEN c.v IS NULL THEN NULL
            WHEN c.v LIKE N'(%)' THEN -TRY_CONVERT(decimal(18,2), SUBSTRING(c.v, 2, LEN(c.v) - 2))
            ELSE TRY_CONVERT(decimal(18,2), c.v)
        END
    FROM (SELECT v = NULLIF(NULLIF(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Value)), N'$', N''), N',', N''), N' ', N''), N''), N'NULL')) c;
GO

-- Accepts yyyy-mm-dd, yyyy-mm-dd hh:mi:ss, mm/dd/yyyy and anything else SQL Server parses.
CREATE OR ALTER FUNCTION arwb.tvf_ParseDate (@Value nvarchar(500))
RETURNS TABLE
AS
RETURN
    SELECT DateValue = COALESCE(
                TRY_CONVERT(date, c.v, 23),
                TRY_CONVERT(date, c.v, 120),
                TRY_CONVERT(date, c.v, 101),
                TRY_CONVERT(date, c.v, 126),
                TRY_CONVERT(date, c.v))
    FROM (SELECT v = NULLIF(NULLIF(LTRIM(RTRIM(@Value)), N''), N'NULL')) c;
GO

-- Trimmed text, with blank and the literal string "NULL" treated as NULL.
CREATE OR ALTER FUNCTION arwb.tvf_CleanText (@Value nvarchar(max))
RETURNS TABLE
AS
RETURN
    SELECT TextValue = NULLIF(NULLIF(LTRIM(RTRIM(@Value)), N''), N'NULL');
GO

-- Typed setting lookup with a fallback, so a missing AppSetting row never breaks a rule.
CREATE OR ALTER FUNCTION arwb.tvf_Setting (@SettingKey varchar(100), @Fallback nvarchar(400))
RETURNS TABLE
AS
RETURN
    SELECT SettingValue = COALESCE(
                (SELECT TOP (1) s.SettingValue FROM arwb.AppSetting s WHERE s.SettingKey = @SettingKey),
                @Fallback);
GO

PRINT 'AR Workbench 02: parsing helpers ready.';
GO
