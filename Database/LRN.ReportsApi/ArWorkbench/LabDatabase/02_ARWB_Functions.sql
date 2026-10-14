/* ============================================================================================
   AR Workbench - 02 Helper functions
   dbo.ClaimLevelData / dbo.LineLevelData hold every value as nvarchar. These inline table-valued
   functions convert them once, consistently. Inline TVFs (not scalar UDFs) so the optimizer folds
   them into the calling query.
   Usage:  CROSS APPLY dbo.ARWB_tvf_ParseMoney(s.InsuranceBalance) ib        ->  ib.Amount
           CROSS APPLY dbo.ARWB_tvf_ParseDate(s.DateofService)           dos ->  dos.DateValue
           CROSS APPLY dbo.ARWB_tvf_NormalizeDenialCode(N'PR 204')       n   ->  n.DenialCode = '204'
           CROSS APPLY dbo.ARWB_tvf_SplitDenialCodes(N'CO-16, N290')     d   ->  one row per code
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

-- "$1,234.50" -> 1234.50 ; "(12.00)" -> -12.00 ; "" / "NULL" / junk -> NULL
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_ParseMoney (@Value nvarchar(500))
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
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_ParseDate (@Value nvarchar(500))
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
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_CleanText (@Value nvarchar(max))
RETURNS TABLE
AS
RETURN
    SELECT TextValue = NULLIF(NULLIF(LTRIM(RTRIM(@Value)), N''), N'NULL');
GO

-- Typed setting lookup with a fallback, so a missing AppSetting row never breaks a rule.
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_Setting (@SettingKey varchar(100), @Fallback nvarchar(400))
RETURNS TABLE
AS
RETURN
    SELECT SettingValue = COALESCE(
                (SELECT TOP (1) s.SettingValue FROM dbo.ARWB_AppSetting s WHERE s.SettingKey = @SettingKey),
                @Fallback);
GO

/* One denial code -> the normalized form used for every mapping and lookup (handoff 4.2).
     - upper case; spaces, hyphens and colons removed
     - CARC group prefix CO / PR / PI / OA removed:  'PR 204', 'CO-204', 'CO204' -> '204'
     - RARC codes keep their letters:                'N57' -> 'N57', 'MA130' -> 'MA130'
   GroupCode returns the stripped prefix; CodeType is RARC for N.., M.., MA.. codes, else CARC.   */
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_NormalizeDenialCode (@Raw nvarchar(200))
RETURNS TABLE
AS
RETURN
    SELECT
        RawCode    = r.RawCode,
        GroupCode  = CASE WHEN p.HasPrefix = 1 THEN CONVERT(varchar(2), LEFT(u.v, 2)) END,
        DenialCode = CONVERT(nvarchar(50), NULLIF(CASE WHEN p.HasPrefix = 1 THEN SUBSTRING(u.v, 3, 200) ELSE u.v END, N'')),
        CodeType   = CONVERT(varchar(4),
                        CASE WHEN (CASE WHEN p.HasPrefix = 1 THEN SUBSTRING(u.v, 3, 200) ELSE u.v END) LIKE N'N[0-9]%'
                               OR (CASE WHEN p.HasPrefix = 1 THEN SUBSTRING(u.v, 3, 200) ELSE u.v END) LIKE N'M[0-9]%'
                               OR (CASE WHEN p.HasPrefix = 1 THEN SUBSTRING(u.v, 3, 200) ELSE u.v END) LIKE N'MA[0-9]%'
                             THEN 'RARC' ELSE 'CARC' END)
    FROM (SELECT RawCode = NULLIF(NULLIF(LTRIM(RTRIM(@Raw)), N''), N'NULL')) r
    CROSS APPLY (SELECT v = UPPER(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(r.RawCode, N''), N' ', N''), N'-', N''), N':', N''), NCHAR(9), N''))) u
    CROSS APPLY (SELECT HasPrefix = CASE WHEN LEN(u.v) > 2 AND LEFT(u.v, 2) IN (N'CO', N'PR', N'PI', N'OA') THEN 1 ELSE 0 END) p
    WHERE r.RawCode IS NOT NULL;
GO

/* A delimited list of codes -> one row per code, in the order written.
   Delimiters: comma, semicolon, pipe, slash, line breaks. A space is NOT a delimiter ('CO 16' is one
   code). Blank items are skipped. Handles lists up to 4000 characters.                            */
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_SplitDenialCodes (@List nvarchar(4000))
RETURNS TABLE
AS
RETURN
    WITH src AS
    (
        SELECT s = N',' + REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(ISNULL(@List, N''),
                        N';', N','), N'|', N','), N'/', N','), NCHAR(13), N','), NCHAR(10), N','), NCHAR(9), N' ') + N','
    ),
    e1 (n) AS (SELECT 1 FROM (VALUES (1),(1),(1),(1),(1),(1),(1),(1),(1),(1)) v (n)),
    tally (n) AS
    (
        SELECT TOP ((SELECT DATALENGTH(s) / 2 FROM src)) ROW_NUMBER() OVER (ORDER BY (SELECT NULL))
        FROM e1 a CROSS JOIN e1 b CROSS JOIN e1 c CROSS JOIN e1 d
    ),
    items AS
    (
        -- The length is guarded because the optimizer may evaluate it before the WHERE filter.
        SELECT Pos = t.n,
               Item = SUBSTRING(src.s, t.n + 1,
                                CASE WHEN CHARINDEX(N',', src.s, t.n + 1) > t.n THEN CHARINDEX(N',', src.s, t.n + 1) - t.n - 1 ELSE 0 END)
        FROM src
        CROSS JOIN tally t
        WHERE t.n < DATALENGTH(src.s) / 2
          AND SUBSTRING(src.s, t.n, 1) = N','
    )
    SELECT Ordinal    = CONVERT(int, ROW_NUMBER() OVER (ORDER BY i.Pos)),
           RawCode    = CONVERT(nvarchar(100), LEFT(n.RawCode, 100)),
           n.GroupCode,
           n.DenialCode,
           n.CodeType
    FROM items i
    CROSS APPLY dbo.ARWB_tvf_NormalizeDenialCode(i.Item) n
    WHERE n.DenialCode IS NOT NULL;
GO

-- '101,102, 103' -> one row per ClaimKey (bulk actions pass the selected claims this way).
-- Non-numeric items are ignored.
CREATE OR ALTER FUNCTION dbo.ARWB_tvf_ParseKeyList (@List nvarchar(max))
RETURNS TABLE
AS
RETURN
    SELECT DISTINCT ClaimKey = TRY_CONVERT(bigint, LTRIM(RTRIM(k.n.value('.', 'nvarchar(40)'))))
    FROM (SELECT x = CAST(N'<k>' + REPLACE((SELECT ISNULL(@List, N'') FOR XML PATH('')), N',', N'</k><k>') + N'</k>' AS xml)) s
    CROSS APPLY s.x.nodes('/k') k (n)
    WHERE TRY_CONVERT(bigint, LTRIM(RTRIM(k.n.value('.', 'nvarchar(40)')))) IS NOT NULL;
GO

PRINT 'AR Workbench 02: helper functions ready.';
GO
