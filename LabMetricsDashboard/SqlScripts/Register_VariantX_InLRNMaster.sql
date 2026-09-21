/* ============================================================================
   Register the VariantX lab in LRNMaster.

   >>> RUN AGAINST LRNMaster. <<<

   LRNMaster has THREE separate lab registries, and they are read by different
   parts of the product. A lab missing from any one of them half-works, in a way
   that looks like a data problem rather than a registration problem:

     dbo.Labs           The authoritative active-lab list. LRN.MasterFileProcessor
                        reads it to decide which labs to import at all. Missing =
                        the lab is never imported.

     dbo.LRNMetricsLab  What the Denial Dashboard and Denial Workflow resolve
                        against, and it carries ConnectionKey. Missing = the
                        workflow API cannot open a connection for the LabId, and
                        the Claim Assignment page comes up empty with no error.

     dbo.LabRegistry    Drives CPT Search, including the per-lab column names.
                        Missing = the lab is absent from the CPT Search lab list.

   Two more are handled elsewhere and need nothing here:
     dbo.LabInsuranceMaster  the Master File Processor seeds it from the payer
                             names it finds during the import.
     dbo.LrnFileStatus       only for labs sourced from their own database
                             (Cove); VariantX is SharePoint-sourced.

   User access (dbo.UserLabs) is at the bottom, and is normally done in the UI so
   that nothing has to guess at LabUserID.

   SAFE BY DEFAULT: @Apply = 0 reports what it would write and changes nothing.
   RE-RUNNABLE: every write is guarded, so running it twice is a no-op.
   ============================================================================ */

/* On Azure SQL Database, DELETE this line and connect directly to LRNMaster -
   that engine does not support switching database context. On a box instance or
   a Managed Instance it pins the target regardless of the SSMS dropdown. */
USE LRNMaster;
GO

SET NOCOUNT ON;

/* ── Settings ────────────────────────────────────────────────────────────── */
DECLARE @Apply BIT = 0;      -- 0 = report only, 1 = write

DECLARE @LabId         INT            = 25;
DECLARE @LabName       NVARCHAR(200)  = N'VariantX';          -- MUST match LabConfig.Labs and VariantX.json
DECLARE @DisplayName   NVARCHAR(100)  = N'VariantX';          -- UI label for CPT Search
DECLARE @DbName        NVARCHAR(100)  = N'VariantX_LRN';      -- the lab's own database
DECLARE @ConnectionKey NVARCHAR(200)  = N'VariantXConnection';
DECLARE @SortOrder     INT            = 13;                   -- CPT Search list position

/* ── Guards ──────────────────────────────────────────────────────────────── */
IF @LabId IS NULL OR @LabName IS NULL OR LTRIM(RTRIM(@LabName)) = N''
    THROW 52001, N'@LabId and @LabName are required.', 1;

/* The LabId is written into every claim row this lab loads, so taking one that
   already belongs to another lab silently merges two labs' data. */
DECLARE @IdOwner NVARCHAR(200) =
    (SELECT TOP (1) LabName FROM dbo.Labs WHERE LabId = @LabId AND LabName <> @LabName);

IF @IdOwner IS NOT NULL
BEGIN
    DECLARE @Taken NVARCHAR(400) =
        N'LabId ' + CAST(@LabId AS NVARCHAR(10)) + N' already belongs to "' + @IdOwner
        + N'". Pick a free id and change BOTH this script AND LabConfig.LabsID in all three appsettings files.';
    THROW 52002, @Taken, 1;
END

DECLARE @NameId INT = (SELECT TOP (1) LabId FROM dbo.Labs WHERE LabName = @LabName);

IF @NameId IS NOT NULL AND @NameId <> @LabId
BEGIN
    DECLARE @Mismatch NVARCHAR(400) =
        N'"' + @LabName + N'" is already registered as LabId ' + CAST(@NameId AS NVARCHAR(10))
        + N', not ' + CAST(@LabId AS NVARCHAR(10)) + N'. Use the existing id, or rename the lab.';
    THROW 52003, @Mismatch, 1;
END

PRINT N'LabId        : ' + CAST(@LabId AS NVARCHAR(10));
PRINT N'LabName      : ' + @LabName;
PRINT N'Database     : ' + @DbName;
PRINT N'ConnectionKey: ' + @ConnectionKey;
PRINT N'Apply        : ' + CASE WHEN @Apply = 1 THEN N'YES - writing' ELSE N'no - report only' END;
PRINT N'';

DECLARE @Sql NVARCHAR(MAX);

/* ══ 1. dbo.Labs ═══════════════════════════════════════════════════════════
   Built by hand on some servers and by LabMaster_CreateTable.sql on others, so
   the shape is inspected rather than assumed: IDENTITY_INSERT is toggled only if
   LabId really is an identity column, and the audit columns are written only
   where they exist. A surprising schema then shows up in the output instead of
   failing the script. */
IF OBJECT_ID(N'dbo.Labs', N'U') IS NULL
    THROW 52004, N'dbo.Labs does not exist. Run LabMaster_CreateTable.sql first.', 1;

DECLARE @HasIdentity BIT = CASE WHEN COLUMNPROPERTY(OBJECT_ID(N'dbo.Labs'), 'LabId', 'IsIdentity') = 1 THEN 1 ELSE 0 END;
DECLARE @HasIsActive BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'IsActive')    IS NULL THEN 0 ELSE 1 END;
DECLARE @HasConnKey  BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'ConnectionKey') IS NULL THEN 0 ELSE 1 END;
DECLARE @HasCreatedBy   BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'CreatedBy')   IS NULL THEN 0 ELSE 1 END;
DECLARE @HasCreatedDate BIT = CASE WHEN COL_LENGTH(N'dbo.Labs', 'CreatedDate') IS NULL THEN 0 ELSE 1 END;

PRINT N'dbo.Labs shape: identity=' + CAST(@HasIdentity AS NVARCHAR(1))
    + N' IsActive=' + CAST(@HasIsActive AS NVARCHAR(1))
    + N' ConnectionKey=' + CAST(@HasConnKey AS NVARCHAR(1));

IF EXISTS (SELECT 1 FROM dbo.Labs WHERE LabId = @LabId)
BEGIN
    PRINT N'  dbo.Labs           already has LabId ' + CAST(@LabId AS NVARCHAR(10)) + N' - leaving it alone.';
END
ELSE
BEGIN
    DECLARE @Cols NVARCHAR(MAX) = N'LabId, LabName';
    DECLARE @Vals NVARCHAR(MAX) = N'@Id, @Name';

    IF @HasIsActive    = 1 BEGIN SET @Cols += N', IsActive';      SET @Vals += N', 1'; END
    IF @HasConnKey     = 1 BEGIN SET @Cols += N', ConnectionKey'; SET @Vals += N', @Key'; END
    IF @HasCreatedBy   = 1 BEGIN SET @Cols += N', CreatedBy';     SET @Vals += N', SUSER_SNAME()'; END
    IF @HasCreatedDate = 1 BEGIN SET @Cols += N', CreatedDate';   SET @Vals += N', SYSUTCDATETIME()'; END

    SET @Sql = CASE WHEN @HasIdentity = 1 THEN N'SET IDENTITY_INSERT dbo.Labs ON; ' ELSE N'' END
             + N'INSERT INTO dbo.Labs (' + @Cols + N') VALUES (' + @Vals + N');'
             + CASE WHEN @HasIdentity = 1 THEN N' SET IDENTITY_INSERT dbo.Labs OFF;' ELSE N'' END;

    IF @Apply = 1
    BEGIN
        EXEC sys.sp_executesql @Sql, N'@Id INT, @Name NVARCHAR(200), @Key NVARCHAR(200)',
             @Id = @LabId, @Name = @LabName, @Key = @ConnectionKey;
        PRINT N'  dbo.Labs           INSERTED LabId ' + CAST(@LabId AS NVARCHAR(10));
    END
    ELSE
        PRINT N'  dbo.Labs           WOULD INSERT: ' + @Sql;
END

/* ══ 2. dbo.LRNMetricsLab ══════════════════════════════════════════════════
   The registry the Denial Dashboard and Denial Workflow resolve against. Skip it
   and the workflow API cannot open a connection for this LabId at all - the
   symptom is an empty Claim Assignment page rather than an error, which is why
   it is worth its own step. */
IF OBJECT_ID(N'dbo.LRNMetricsLab', N'U') IS NULL
    PRINT N'  dbo.LRNMetricsLab  DOES NOT EXIST - skipped. The Denial Dashboard will not resolve this lab.';
ELSE IF EXISTS (SELECT 1 FROM dbo.LRNMetricsLab WHERE LabId = @LabId)
    PRINT N'  dbo.LRNMetricsLab  already has LabId ' + CAST(@LabId AS NVARCHAR(10)) + N' - leaving it alone.';
ELSE
BEGIN
    IF @Apply = 1
    BEGIN
        INSERT INTO dbo.LRNMetricsLab (LabId, LabName, ConnectionKey, IsActive)
        VALUES (@LabId, @LabName, @ConnectionKey, 1);
        PRINT N'  dbo.LRNMetricsLab  INSERTED LabId ' + CAST(@LabId AS NVARCHAR(10));
    END
    ELSE
        PRINT N'  dbo.LRNMetricsLab  WOULD INSERT (' + CAST(@LabId AS NVARCHAR(10)) + N', '
            + @LabName + N', ' + @ConnectionKey + N', 1)';
END

/* ══ 3. dbo.LabRegistry ════════════════════════════════════════════════════
   CPT Search. Every column-name column has a default that matches the standard
   field mappings, so only the identity columns are supplied here - VariantX uses
   the standard names (CPTCode, Units, Modifier, Panelname, ClaimID,
   CPTCodeXUnitsXModifier), which VariantXFieldMappings.Json confirms.

   Its LabId is its OWN identity and has nothing to do with dbo.Labs.LabId -
   do not try to force them to match. */
IF OBJECT_ID(N'dbo.LabRegistry', N'U') IS NULL
    PRINT N'  dbo.LabRegistry    DOES NOT EXIST - skipped. Run LabRegistry_CreateAndSeed.sql if CPT Search is wanted.';
ELSE IF EXISTS (SELECT 1 FROM dbo.LabRegistry WHERE LabName = @DbName OR LabName = @LabName)
    PRINT N'  dbo.LabRegistry    already has this lab - leaving it alone.';
ELSE
BEGIN
    IF @Apply = 1
    BEGIN
        INSERT INTO dbo.LabRegistry (LabName, DisplayName, DbName, SortOrder, IsActive)
        VALUES (@DbName, @DisplayName, @DbName, @SortOrder, 1);
        PRINT N'  dbo.LabRegistry    INSERTED ' + @DbName;
    END
    ELSE
        PRINT N'  dbo.LabRegistry    WOULD INSERT (' + @DbName + N', ' + @DisplayName + N', '
            + @DbName + N', ' + CAST(@SortOrder AS NVARCHAR(10)) + N', 1)';
END

PRINT N'';

/* ══ 4. Verify ═════════════════════════════════════════════════════════════ */
IF @Apply = 1
BEGIN
    PRINT N'Registered rows:';

    SELECT N'dbo.Labs' AS [Registry], LabId, LabName FROM dbo.Labs WHERE LabId = @LabId
    UNION ALL
    SELECT N'dbo.LRNMetricsLab', LabId, LabName
    FROM   dbo.LRNMetricsLab WHERE LabId = @LabId AND OBJECT_ID(N'dbo.LRNMetricsLab', N'U') IS NOT NULL;

    PRINT N'';
    PRINT N'Still to do:';
    PRINT N'  * Add VariantX to LabConfig.Labs and LabConfig.LabsID (id ' + CAST(@LabId AS NVARCHAR(10)) + N')';
    PRINT N'    in LabMetricsDashboard, LRN.ReportsApi and LRN.ReportWorker appsettings.json, then restart them.';
    PRINT N'  * Place VariantX.json in the lab config folder (DbConnectionString -> ' + @DbName + N').';
    PRINT N'  * Run LRN.MasterFileProcessorWorker/sql/VariantX/01_CreateTables.sql against ' + @DbName + N'.';
    PRINT N'  * Assign users: Admin > Assign User Labs (see the optional block below).';
END
ELSE
    PRINT N'@Apply = 0 - nothing was written. Review the output above, then set @Apply = 1.';
GO


/* ============================================================================
   OPTIONAL - assign a user to VariantX.

   Normally done in Admin > Assign User Labs, which is the safer route because it
   resolves the LabUserID for you. This is here for a scripted environment build.
   Set @UserName and run it on its own.
   ============================================================================ */
/*
DECLARE @UserName NVARCHAR(200) = N'first.last';
DECLARE @LabId    INT           = 25;

DECLARE @LabUserId INT = (SELECT TOP (1) LabUserID FROM dbo.LabUsers WHERE UserName = @UserName);

IF @LabUserId IS NULL
    PRINT N'No user "' + @UserName + N'" in dbo.LabUsers - create them in Admin > Manage Users first.';
ELSE IF EXISTS (SELECT 1 FROM dbo.UserLabs WHERE LabUserID = @LabUserId AND LabId = @LabId)
    PRINT N'Already assigned.';
ELSE
BEGIN
    INSERT INTO dbo.UserLabs (LabUserID, LabId) VALUES (@LabUserId, @LabId);
    PRINT N'Assigned "' + @UserName + N'" to LabId ' + CAST(@LabId AS NVARCHAR(10)) + N'.';
END
*/
