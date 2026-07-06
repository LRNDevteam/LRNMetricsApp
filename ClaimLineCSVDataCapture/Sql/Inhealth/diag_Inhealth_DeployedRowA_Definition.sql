-- ============================================================
-- Diagnostic: what does the ACTUALLY DEPLOYED
-- usp_RefreshInh_ExecutiveSummary_LIS_Alt look like right now in the
-- database, specifically around Row A ("Total Samples")?
--
-- Purpose: confirm whether the live stored procedure matches the
-- "NA is not blank" formula currently in
-- ClaimLineCSVDataCapture\Sql\Inhealth\26_Inhealth_ExecutiveSummary_LIS_Alt.sql,
-- or whether it's an older/different version (e.g. plain COUNT with no
-- NA condition) that was never redeployed.
--
-- Run in: Inhealth_LRN
-- Read-only — does not modify anything.
-- ============================================================

PRINT '=== Does usp_RefreshInh_ExecutiveSummary_LIS_Alt exist? ===';
IF OBJECT_ID('dbo.usp_RefreshInh_ExecutiveSummary_LIS_Alt', 'P') IS NOT NULL
    PRINT '  YES — exists.';
ELSE
    PRINT '  NO — does not exist (unexpected).';

PRINT '';
PRINT '=== Last modified date (sys.objects) ===';
SELECT
    name,
    create_date,
    modify_date
FROM sys.objects
WHERE object_id = OBJECT_ID('dbo.usp_RefreshInh_ExecutiveSummary_LIS_Alt');

PRINT '';
PRINT '=== Does the deployed definition contain the Row A / "NA is not blank" text? ===';
DECLARE @def NVARCHAR(MAX) = OBJECT_DEFINITION(OBJECT_ID('dbo.usp_RefreshInh_ExecutiveSummary_LIS_Alt'));
PRINT '  Contains ''NULLIF(l.NAFlag'''''''' ''            = ' + CASE WHEN @def LIKE '%NULLIF(l.NAFlag%' THEN 'YES (matches repo file 26)' ELSE 'NO (does NOT match repo file 26)' END;
PRINT '  Contains ''Total Samples''                        = ' + CASE WHEN @def LIKE '%Total Samples%' THEN 'YES' ELSE 'NO' END;
PRINT '  Definition length (chars)                          = ' + CAST(LEN(ISNULL(@def,'')) AS VARCHAR(20));

-- Print the deployed Row A block for direct comparison, if found.
IF @def LIKE '%Total Samples%'
BEGIN
    DECLARE @pos INT = CHARINDEX('Total Samples', @def);
    PRINT '';
    PRINT '=== Deployed text around ''Total Samples'' (200 chars before/after) ===';
    PRINT SUBSTRING(@def, IIF(@pos > 200, @pos - 200, 1), 500);
END
