/*
    Cove Executive Summary
    Fix RoleID G: Billed Mismatches - Accessions NA / Other Sample

    Correct formula:
        MAX(PMS F [No. of Billed Claims] - LIS C [Billed], 0)

    The helper is also added to the end of the existing LIS refresh procedure,
    because Cove_ES_LIS must be rebuilt before G is calculated.
*/
SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_Cove_ES_UpdatePmsBilledMismatch
AS
BEGIN
    SET NOCOUNT ON;

    IF OBJECT_ID('dbo.Cove_ES_PMS', 'U') IS NULL
       OR OBJECT_ID('dbo.Cove_ES_LIS', 'U') IS NULL
        RETURN;

    UPDATE g
    SET g.ESMonthClaimCount =
            CASE
                WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0) > 0
                THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0)
                ELSE 0
            END,
        g.RefreshedAt = GETDATE()
    FROM dbo.Cove_ES_PMS AS g
    INNER JOIN dbo.Cove_ES_PMS AS f
        ON  f.ESYear = g.ESYear
        AND f.ESMonth = g.ESMonth
        AND f.RoleID = 'F'
    LEFT JOIN dbo.Cove_ES_LIS AS lis
        ON  lis.ESYear = g.ESYear
        AND lis.ESMonth = g.ESMonth
        AND lis.RoleID = 'C'
    WHERE g.RoleID = 'G';
END;
GO

/*
    Also recalculate at the end of a standalone PMS refresh, using the latest
    available LIS snapshot. The normal capture flow recalculates once more
    after LIS is refreshed.
*/
DECLARE @pmsProcedureId INT =
    OBJECT_ID('dbo.usp_RefreshCove_ExecutiveSummary', 'P');

IF @pmsProcedureId IS NULL
    THROW 51003, 'dbo.usp_RefreshCove_ExecutiveSummary was not found.', 1;

DECLARE @pmsDefinition NVARCHAR(MAX) = OBJECT_DEFINITION(@pmsProcedureId);

IF @pmsDefinition IS NULL
    THROW 51004, 'Unable to read dbo.usp_RefreshCove_ExecutiveSummary definition.', 1;

IF @pmsDefinition NOT LIKE '%EXEC dbo.usp_Cove_ES_UpdatePmsBilledMismatch%'
BEGIN
    DECLARE @pmsProcedureKeyword INT =
        PATINDEX('%PROCEDURE%', UPPER(@pmsDefinition));
    DECLARE @pmsLastEnd INT =
        LEN(@pmsDefinition) - CHARINDEX('DNE', REVERSE(UPPER(@pmsDefinition))) - 1;

    IF @pmsProcedureKeyword = 0
       OR @pmsLastEnd <= 0
       OR LTRIM(RTRIM(REPLACE(REPLACE(
            SUBSTRING(@pmsDefinition, @pmsLastEnd, LEN(@pmsDefinition)),
            CHAR(13), ''), CHAR(10), '')))
            NOT IN ('END', 'END;')
        THROW 51005, 'Unable to safely patch the PMS refresh procedure.', 1;

    SET @pmsDefinition =
        N'ALTER ' + SUBSTRING(
            @pmsDefinition,
            @pmsProcedureKeyword,
            @pmsLastEnd - @pmsProcedureKeyword)
        + N'    EXEC dbo.usp_Cove_ES_UpdatePmsBilledMismatch;'
        + CHAR(13) + CHAR(10)
        + SUBSTRING(@pmsDefinition, @pmsLastEnd, LEN(@pmsDefinition));

    EXEC sys.sp_executesql @pmsDefinition;
END;
GO

/*
    Preserve the currently deployed LIS refresh implementation and append the
    helper call when the server has an older version without that call.
*/
DECLARE @lisProcedureId INT =
    OBJECT_ID('dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt', 'P');

IF @lisProcedureId IS NULL
    THROW 51000, 'dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt was not found.', 1;

DECLARE @definition NVARCHAR(MAX) = OBJECT_DEFINITION(@lisProcedureId);

IF @definition IS NULL
    THROW 51001, 'Unable to read dbo.usp_RefreshCove_ExecutiveSummary_LIS_Alt definition.', 1;

IF @definition NOT LIKE '%EXEC dbo.usp_Cove_ES_UpdatePmsBilledMismatch%'
BEGIN
    DECLARE @procedureKeyword INT = PATINDEX('%PROCEDURE%', UPPER(@definition));
    DECLARE @lastEnd INT =
        LEN(@definition) - CHARINDEX('DNE', REVERSE(UPPER(@definition))) - 1;

    IF @procedureKeyword = 0
       OR @lastEnd <= 0
       OR LTRIM(RTRIM(REPLACE(REPLACE(
            SUBSTRING(@definition, @lastEnd, LEN(@definition)),
            CHAR(13), ''), CHAR(10), '')))
            NOT IN ('END', 'END;')
        THROW 51002, 'Unable to safely patch the LIS refresh procedure.', 1;

    SET @definition =
        N'ALTER ' + SUBSTRING(@definition, @procedureKeyword, @lastEnd - @procedureKeyword)
        + N'    -- Recalculate PMS mismatch after the current LIS snapshot is complete.'
        + CHAR(13) + CHAR(10)
        + N'    EXEC dbo.usp_Cove_ES_UpdatePmsBilledMismatch;'
        + CHAR(13) + CHAR(10)
        + SUBSTRING(@definition, @lastEnd, LEN(@definition));

    EXEC sys.sp_executesql @definition;
END;
GO

-- Repair the current monthly rows and the (0,0) Grand Total immediately.
EXEC dbo.usp_Cove_ES_UpdatePmsBilledMismatch;
GO

-- Verification: Difference must be 0 for every returned row.
SELECT
    g.ESYear,
    g.ESMonth,
    ISNULL(f.ESMonthClaimCount, 0) AS PmsBilledClaims,
    ISNULL(lis.ESMonthClaimCount, 0) AS LisBilled,
    g.ESMonthClaimCount AS StoredMismatch,
    CASE
        WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0) > 0
        THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0)
        ELSE 0
    END AS ExpectedMismatch,
    g.ESMonthClaimCount -
        CASE
            WHEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0) > 0
            THEN ISNULL(f.ESMonthClaimCount, 0) - ISNULL(lis.ESMonthClaimCount, 0)
            ELSE 0
        END AS Difference
FROM dbo.Cove_ES_PMS AS g
INNER JOIN dbo.Cove_ES_PMS AS f
    ON  f.ESYear = g.ESYear
    AND f.ESMonth = g.ESMonth
    AND f.RoleID = 'F'
LEFT JOIN dbo.Cove_ES_LIS AS lis
    ON  lis.ESYear = g.ESYear
    AND lis.ESMonth = g.ESMonth
    AND lis.RoleID = 'C'
WHERE g.RoleID = 'G'
ORDER BY
    CASE WHEN g.ESYear = 0 AND g.ESMonth = 0 THEN 1 ELSE 0 END,
    g.ESYear,
    g.ESMonth;
GO
