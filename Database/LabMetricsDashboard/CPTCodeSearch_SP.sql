-- ============================================================
-- CPT Code Search  –  Dynamic Cross-Database Stored Procedure
-- Deploy to: LRNMaster  (DefaultConnection database)
--
-- Reads the lab list and column names from dbo.LabRegistry.
-- To add a new lab: INSERT one row into dbo.LabRegistry.
-- No SP changes needed.
--
-- Usage: EXEC dbo.usp_CPTCodeSearch @CPTCode = '87798'
-- ============================================================

CREATE OR ALTER PROCEDURE dbo.usp_CPTCodeSearch
    @CPTCode NVARCHAR(20)
AS
BEGIN
    SET NOCOUNT ON;
    SET @CPTCode = LTRIM(RTRIM(@CPTCode));

    -- ── Result temp tables ─────────────────────────────────────────────────────

    CREATE TABLE #LineSummary (
        LabName       NVARCHAR(100)  NOT NULL,
        LabDisplay    NVARCHAR(100)  NOT NULL,
        PanelName     NVARCHAR(500)  NOT NULL,
        Modifier      NVARCHAR(50)   NOT NULL,
        TotalLines    INT            NOT NULL,
        TotalUnits    DECIMAL(18,2)  NOT NULL,
        DeniedUnits   DECIMAL(18,2)  NOT NULL,
        ClaimedUnits  DECIMAL(18,2)  NOT NULL,
        TotalPayments DECIMAL(18,2)  NOT NULL,
        TotalCharges  DECIMAL(18,2)  NOT NULL,
        LatestDOS     NVARCHAR(50)   NOT NULL,
        EarliestDOS   NVARCHAR(50)   NOT NULL
    );

    CREATE TABLE #DenialSummary (
        LabName       NVARCHAR(100)  NOT NULL,
        LabDisplay    NVARCHAR(100)  NOT NULL,
        DenialCode    NVARCHAR(100)  NOT NULL,
        LineCount     INT            NOT NULL,
        DeniedUnits   DECIMAL(18,2)  NOT NULL,
        Payments      DECIMAL(18,2)  NOT NULL
    );

    CREATE TABLE #TrendSummary (
        LabName       NVARCHAR(100)  NOT NULL,
        LabDisplay    NVARCHAR(100)  NOT NULL,
        MonthYear     NVARCHAR(10)   NOT NULL,
        LineCount     INT            NOT NULL,
        TotalUnits    DECIMAL(18,2)  NOT NULL,
        DeniedUnits   DECIMAL(18,2)  NOT NULL,
        ClaimedUnits  DECIMAL(18,2)  NOT NULL,
        TotalPayments DECIMAL(18,2)  NOT NULL
    );

    CREATE TABLE #ClaimSummary (
        LabName       NVARCHAR(100)  NOT NULL,
        LabDisplay    NVARCHAR(100)  NOT NULL,
        PanelName     NVARCHAR(500)  NOT NULL,
        ClaimStatus   NVARCHAR(100)  NOT NULL,
        DenialCode    NVARCHAR(100)  NOT NULL,
        ClaimCount    INT            NOT NULL,
        TotalPayments DECIMAL(18,2)  NOT NULL,
        TotalCharges  DECIMAL(18,2)  NOT NULL
    );

    CREATE TABLE #PayerSummary (
        LabName       NVARCHAR(100)  NOT NULL,
        LabDisplay    NVARCHAR(100)  NOT NULL,
        PayerName     NVARCHAR(500)  NOT NULL,
        PayerType     NVARCHAR(100)  NOT NULL,
        LineCount     INT            NOT NULL,
        TotalUnits    DECIMAL(18,2)  NOT NULL,
        DeniedUnits   DECIMAL(18,2)  NOT NULL,
        TotalPayments DECIMAL(18,2)  NOT NULL
    );

    -- ── Registry cursor variables ──────────────────────────────────────────────
    DECLARE
        @LabId              INT,
        @LabName            NVARCHAR(100),
        @DisplayName        NVARCHAR(100),
        @DbName             NVARCHAR(100),
        -- LineLevelData columns
        @LineTable          NVARCHAR(100),
        @LineCptCol         NVARCHAR(100),
        @LineUnitsCol       NVARCHAR(100),
        @LineModCol         NVARCHAR(100),
        @LinePanelCol       NVARCHAR(100),
        @LineDenialCol      NVARCHAR(100),
        @LineClaimStatusCol NVARCHAR(100),
        @LinePayerNameCol   NVARCHAR(100),
        @LinePayerTypeCol   NVARCHAR(100),
        @LineDosCol         NVARCHAR(100),
        @LineTotalPayCol    NVARCHAR(100),
        @LineChargeCol      NVARCHAR(100),
        -- ClaimLevelData columns
        @ClaimTable         NVARCHAR(100),
        @ClaimCptCol        NVARCHAR(100),
        @ClaimClaimIdCol    NVARCHAR(100),
        @ClaimPanelCol      NVARCHAR(100),
        @ClaimStatusCol     NVARCHAR(100),
        @ClaimDenialCol     NVARCHAR(100),
        @ClaimTotalPayCol   NVARCHAR(100),
        @ClaimChargeCol     NVARCHAR(100);

    DECLARE @SQL        NVARCHAR(MAX);
    DECLARE @ParamDef   NVARCHAR(500) =
        N'@LabName NVARCHAR(100), @DisplayName NVARCHAR(100), @CPTCode NVARCHAR(20)';

    -- WHILE loop over LabRegistry (avoids cursor overhead)
    DECLARE @CurrentLabId INT = 0;

    WHILE 1 = 1
    BEGIN
        -- Fetch next active lab
        SELECT TOP 1
            @LabId              = LabId,
            @LabName            = LabName,
            @DisplayName        = DisplayName,
            @DbName             = DbName,
            @LineTable          = LineTableName,
            @LineCptCol         = LineCptCodeCol,
            @LineUnitsCol       = LineUnitsCol,
            @LineModCol         = LineModifierCol,
            @LinePanelCol       = LinePanelCol,
            @LineDenialCol      = LineDenialCol,
            @LineClaimStatusCol = LineClaimStatusCol,
            @LinePayerNameCol   = LinePayerNameCol,
            @LinePayerTypeCol   = LinePayerTypeCol,
            @LineDosCol         = LineDosCol,
            @LineTotalPayCol    = LineTotalPayCol,
            @LineChargeCol      = LineChargeCol,
            @ClaimTable         = ClaimTableName,
            @ClaimCptCol        = ClaimCptComboCol,
            @ClaimClaimIdCol    = ClaimClaimIdCol,
            @ClaimPanelCol      = ClaimPanelCol,
            @ClaimStatusCol     = ClaimStatusCol,
            @ClaimDenialCol     = ClaimDenialCol,
            @ClaimTotalPayCol   = ClaimTotalPayCol,
            @ClaimChargeCol     = ClaimChargeCol
        FROM  dbo.LabRegistry
        WHERE IsActive = 1
          AND LabId    > @CurrentLabId
        ORDER BY LabId;

        IF @@ROWCOUNT = 0 BREAK;   -- no more labs

        SET @CurrentLabId = @LabId;

        -- ══════════════════════════════════════════════════════════════
        -- LineLevelData block
        -- Search on exact CPTCode match (primary key column per mappings)
        -- ══════════════════════════════════════════════════════════════
        IF OBJECT_ID(QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@LineTable)) IS NOT NULL
        BEGIN
            BEGIN TRY

                -- ── Panel / Purpose summary ───────────────────────────────────
                SET @SQL = N'
                INSERT INTO #LineSummary
                SELECT
                    @LabName,
                    @DisplayName,
                    ISNULL(LTRIM(RTRIM(' + QUOTENAME(@LinePanelCol) + N')), ''(No Panel)''),
                    ISNULL(CASE WHEN ' + QUOTENAME(@LineModCol) + N' LIKE ''%.00''
                                THEN LEFT(' + QUOTENAME(@LineModCol) + N', LEN(' + QUOTENAME(@LineModCol) + N')-3)
                                ELSE LTRIM(RTRIM(' + QUOTENAME(@LineModCol) + N')) END, ''''),
                    COUNT(*),
                    -- TotalUnits
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)), 0),
                    -- DeniedUnits  (has denial code OR claim status is Denied/Rejected)
                    ISNULL(SUM(CASE
                        WHEN (' + QUOTENAME(@LineDenialCol) + N' IS NOT NULL
                          AND LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')) <> '''')
                          OR  UPPER(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineClaimStatusCol) + N', '''')))) IN (''DENIED'',''REJECTED'')
                        THEN ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)
                        ELSE 0 END), 0),
                    -- ClaimedUnits
                    ISNULL(SUM(CASE
                        WHEN (' + QUOTENAME(@LineDenialCol) + N' IS NULL
                           OR LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')) = '''')
                         AND UPPER(LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineClaimStatusCol) + N', '''')))) NOT IN (''DENIED'',''REJECTED'')
                        THEN ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)
                        ELSE 0 END), 0),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineTotalPayCol) + N' AS DECIMAL(18,2)), 0)), 0),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineChargeCol)   + N' AS DECIMAL(18,2)), 0)), 0),
                    ISNULL(MAX(ISNULL(' + QUOTENAME(@LineDosCol) + N', '''')), ''''),
                    ISNULL(MIN(CASE WHEN ISNULL(' + QUOTENAME(@LineDosCol) + N', '''') <> ''''
                               THEN ' + QUOTENAME(@LineDosCol) + N' END), '''')
                FROM ' + QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@LineTable) + N'
                WHERE LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineCptCol) + N', ''''))) = @CPTCode
                GROUP BY
                    LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LinePanelCol) + N', ''''))),
                    CASE WHEN ' + QUOTENAME(@LineModCol) + N' LIKE ''%.00''
                         THEN LEFT(' + QUOTENAME(@LineModCol) + N', LEN(' + QUOTENAME(@LineModCol) + N')-3)
                         ELSE LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineModCol) + N', ''''))) END
                HAVING COUNT(*) > 0;';

                EXEC sp_executesql @SQL, @ParamDef, @LabName, @DisplayName, @CPTCode;

                -- ── Denial code breakdown ─────────────────────────────────────
                SET @SQL = N'
                INSERT INTO #DenialSummary
                SELECT
                    @LabName, @DisplayName,
                    LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')),
                    COUNT(*),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol)    + N' AS DECIMAL(18,2)), 1)), 0),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineTotalPayCol) + N' AS DECIMAL(18,2)), 0)), 0)
                FROM ' + QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@LineTable) + N'
                WHERE LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineCptCol) + N', ''''))) = @CPTCode
                  AND ' + QUOTENAME(@LineDenialCol) + N' IS NOT NULL
                  AND LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')) <> ''''
                GROUP BY LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N'));';

                EXEC sp_executesql @SQL, @ParamDef, @LabName, @DisplayName, @CPTCode;

                -- ── Monthly trend ─────────────────────────────────────────────
                SET @SQL = N'
                INSERT INTO #TrendSummary
                SELECT
                    @LabName, @DisplayName,
                    ISNULL(FORMAT(TRY_CAST(' + QUOTENAME(@LineDosCol) + N' AS DATE), ''yyyy-MM''), ''Unknown''),
                    COUNT(*),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)), 0),
                    ISNULL(SUM(CASE WHEN ' + QUOTENAME(@LineDenialCol) + N' IS NOT NULL
                                     AND LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')) <> ''''
                               THEN ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)
                               ELSE 0 END), 0),
                    ISNULL(SUM(CASE WHEN ' + QUOTENAME(@LineDenialCol) + N' IS NULL
                                      OR LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')) = ''''
                               THEN ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)
                               ELSE 0 END), 0),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineTotalPayCol) + N' AS DECIMAL(18,2)), 0)), 0)
                FROM ' + QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@LineTable) + N'
                WHERE LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineCptCol) + N', ''''))) = @CPTCode
                GROUP BY ISNULL(FORMAT(TRY_CAST(' + QUOTENAME(@LineDosCol) + N' AS DATE), ''yyyy-MM''), ''Unknown'');';

                EXEC sp_executesql @SQL, @ParamDef, @LabName, @DisplayName, @CPTCode;

                -- ── Payer breakdown (top 20 per lab) ──────────────────────────
                SET @SQL = N'
                INSERT INTO #PayerSummary
                SELECT TOP 20
                    @LabName, @DisplayName,
                    ISNULL(LTRIM(RTRIM(' + QUOTENAME(@LinePayerNameCol) + N')), ''(Unknown)''),
                    ISNULL(LTRIM(RTRIM(' + QUOTENAME(@LinePayerTypeCol) + N')), ''''),
                    COUNT(*),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol)    + N' AS DECIMAL(18,2)), 1)), 0),
                    ISNULL(SUM(CASE WHEN ' + QUOTENAME(@LineDenialCol) + N' IS NOT NULL
                                     AND LTRIM(RTRIM(' + QUOTENAME(@LineDenialCol) + N')) <> ''''
                               THEN ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)
                               ELSE 0 END), 0),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineTotalPayCol) + N' AS DECIMAL(18,2)), 0)), 0)
                FROM ' + QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@LineTable) + N'
                WHERE LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LineCptCol) + N', ''''))) = @CPTCode
                GROUP BY
                    LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LinePayerNameCol) + N', ''''))),
                    LTRIM(RTRIM(ISNULL(' + QUOTENAME(@LinePayerTypeCol) + N', '''')))
                ORDER BY SUM(ISNULL(TRY_CAST(' + QUOTENAME(@LineUnitsCol) + N' AS DECIMAL(18,2)), 1)) DESC;';

                EXEC sp_executesql @SQL, @ParamDef, @LabName, @DisplayName, @CPTCode;

            END TRY
            BEGIN CATCH
                -- Silently skip — DB offline, missing columns, permission issues
                -- Uncomment to surface errors during testing:
                -- PRINT 'LineLevelData error for ' + @DbName + ': ' + ERROR_MESSAGE();
            END CATCH
        END -- LineLevelData block


        -- ══════════════════════════════════════════════════════════════
        -- ClaimLevelData block
        -- Search on CPTCodeXUnitsXModifier LIKE  (combined field)
        -- ══════════════════════════════════════════════════════════════
        IF OBJECT_ID(QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@ClaimTable)) IS NOT NULL
        BEGIN
            BEGIN TRY

                SET @SQL = N'
                INSERT INTO #ClaimSummary
                SELECT
                    @LabName, @DisplayName,
                    ISNULL(LTRIM(RTRIM(' + QUOTENAME(@ClaimPanelCol)  + N')), ''(No Panel)''),
                    ISNULL(LTRIM(RTRIM(' + QUOTENAME(@ClaimStatusCol) + N')), ''''),
                    ISNULL(LTRIM(RTRIM(' + QUOTENAME(@ClaimDenialCol) + N')), ''''),
                    COUNT(DISTINCT ' + QUOTENAME(@ClaimClaimIdCol) + N'),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@ClaimTotalPayCol) + N' AS DECIMAL(18,2)), 0)), 0),
                    ISNULL(SUM(ISNULL(TRY_CAST(' + QUOTENAME(@ClaimChargeCol)   + N' AS DECIMAL(18,2)), 0)), 0)
                FROM ' + QUOTENAME(@DbName) + N'.dbo.' + QUOTENAME(@ClaimTable) + N'
                WHERE ' + QUOTENAME(@ClaimCptCol) + N' LIKE ''%'' + @CPTCode + ''%''
                GROUP BY
                    LTRIM(RTRIM(ISNULL(' + QUOTENAME(@ClaimPanelCol)  + N', ''''))),
                    LTRIM(RTRIM(ISNULL(' + QUOTENAME(@ClaimStatusCol) + N', ''''))),
                    LTRIM(RTRIM(ISNULL(' + QUOTENAME(@ClaimDenialCol) + N', '''')));';

                EXEC sp_executesql @SQL, @ParamDef, @LabName, @DisplayName, @CPTCode;

            END TRY
            BEGIN CATCH
                -- PRINT 'ClaimLevelData error for ' + @DbName + ': ' + ERROR_MESSAGE();
            END CATCH
        END -- ClaimLevelData block

    END -- WHILE loop

    -- ── Final Result Sets ───────────────────────────────────────────────────────

    -- RS 1 : Line-level panel / purpose breakdown per lab
    SELECT LabName, LabDisplay, PanelName, Modifier,
           TotalLines, TotalUnits, DeniedUnits, ClaimedUnits,
           TotalPayments, TotalCharges, LatestDOS, EarliestDOS
    FROM   #LineSummary
    ORDER  BY LabDisplay, TotalUnits DESC;

    -- RS 2 : Denial code breakdown per lab
    SELECT LabName, LabDisplay, DenialCode, LineCount, DeniedUnits, Payments
    FROM   #DenialSummary
    ORDER  BY LabDisplay, LineCount DESC;

    -- RS 3 : Monthly claim/denial trend per lab
    SELECT LabName, LabDisplay, MonthYear, LineCount,
           TotalUnits, DeniedUnits, ClaimedUnits, TotalPayments
    FROM   #TrendSummary
    ORDER  BY LabDisplay, MonthYear;

    -- RS 4 : Claim-level summary per lab
    SELECT LabName, LabDisplay, PanelName, ClaimStatus, DenialCode,
           ClaimCount, TotalPayments, TotalCharges
    FROM   #ClaimSummary
    ORDER  BY LabDisplay, ClaimCount DESC;

    -- RS 5 : Payer breakdown per lab
    SELECT LabName, LabDisplay, PayerName, PayerType,
           LineCount, TotalUnits, DeniedUnits, TotalPayments
    FROM   #PayerSummary
    ORDER  BY LabDisplay, TotalUnits DESC;

END
GO
