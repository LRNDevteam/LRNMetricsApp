/* ============================================================================
   Mask patient and provider identifiers.

   Rewrites, in place:
       * Patient name        (PatientName, PatName, LISPatientName, ...)
       * Patient id          (PatientId, PatientAccountNumber, MRN, ...)
       * Subscriber id       (SubscriberId, MemberId, PolicyNumber, ...)
       * Clinic / facility   (ClinicName, FacilityName, ...)
       * Referring provider  (ReferringProvider, OrderingProvider, ...)

   across DenialLineItem, DenialTaskBoard, LIMSMaster, ClaimLevelData,
   LineLevelData and every other user table in the current database that
   carries a matching column.

   >>> THIS REWRITES DATA. THERE IS NO UNDO. RESTORE FROM BACKUP IS THE ONLY
   >>> WAY BACK. Run it against a clone, not against a client database, unless
   >>> you have deliberately changed @AllowedDbPattern below and know why.

   Companion to Demo_LRNLabDemo_02_Deidentify.sql, which covers patient
   identifiers and DOB only. This one adds clinic/facility and referring
   provider, and applies to whatever database you point it at rather than to
   the demo clone specifically. The two are safe to run in either order.

   HOW IT FINDS COLUMNS
   Schema-driven. It scans INFORMATION_SCHEMA for columns matching the rules in
   #MaskRule, across every base table. A hand-written table list goes stale the
   first time someone adds a column or an archive table - and both exist here:
   ClaimLevelDataArchive and LineLevelDataArchive hold the same patient data as
   their live counterparts and are easy to forget.

   HOW THE REPLACEMENTS BEHAVE
   Every replacement is derived from the original value by a salted one-way
   hash, so:
       * the same patient gets the same fake id in every table - claims, line
         items, tasks, notes and escalations still join up;
       * the same clinic gets the same fake clinic name everywhere, so grouping
         and drill-down on the dashboards still work;
       * no lookup table is written, so nothing is left behind that maps a
         pseudonym back to a real value.
   Values are NOT reproducible between runs unless @Salt is the same. Keep the
   salt if you intend to top up the same clone later; change it if you want a
   fresh, unlinkable set.

   START AT @Apply = 0. It reports exactly which columns it would rewrite, and
   changes nothing.
   ============================================================================ */

/* Several of these tables carry filtered indexes, and an UPDATE against one
   fails outright unless QUOTED_IDENTIFIER and ANSI_NULLS are ON. SSMS sets them
   by default; sqlcmd does NOT, so without this the biggest tables - the ones
   actually holding patient data - land in the !! FAILED list while the small
   ones succeed, and the report looks almost clean while the data is still
   identifiable. If you run this through sqlcmd, pass -I as well. */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* Point this at the database you mean. Left commented so the script cannot
   silently run against whatever was in the connection dropdown - but set it,
   or check the connection, because the guard below only checks the name. */
-- USE LRNLabDemo;
-- GO

SET NOCOUNT ON;

/* ── Settings ─────────────────────────────────────────────────────────────── */
DECLARE @Apply                BIT            = 0;
         /* 0 = report only (default). 1 = rewrite. */

DECLARE @AllowedDbPattern     NVARCHAR(128)  = N'%Demo%';
         /* The guard. The script refuses to run unless DB_NAME() is LIKE this.
            Widen it deliberately and only when you have a reason: masking a
            client database is a one-way operation on production data. */

DECLARE @Salt                 NVARCHAR(64)   = N'';
         /* Strongly recommended for anything that leaves the building. With an
            empty salt the pseudonym is an unsalted hash of the original, and a
            short numeric patient id can be recovered by trying every possible
            id - there are only a few million. A salt you keep private makes
            that attack useless. Use the same salt to top up the same clone. */

DECLARE @TableFilter          NVARCHAR(MAX)  = NULL;
         /* NULL = every base table (recommended - under-masking is the
            dangerous failure). Or restrict, e.g.:
            N'DenialLineItem,DenialTaskBoard,LIMSMaster,ClaimLevelData,LineLevelData' */

DECLARE @MaskBillingProvider  BIT            = 0;
         /* BillingProvider is usually the lab itself, not a referring
            clinician, so it is off by default. Turn on if the clone is going
            outside the company. */

DECLARE @MaskSalesRep         BIT            = 0;
         /* SalesRepname is an internal employee name. Not PHI, but it is a
            real person and it appears on exports. */

DECLARE @LimsJsonAction       VARCHAR(10)    = 'REPORT';
         /* LIMSMaster.AdditionalFields is an NVARCHAR(MAX) JSON blob holding
            every LIMS file column the schema does not name. A column scan
            cannot see inside it, and lab files routinely carry DOB, address,
            phone and MRN there. Options:
              'REPORT' - list the JSON keys found and stop (default)
              'SCRUB'  - overwrite the value of every key matching a mask rule
              'NULL'   - null the whole column
            'REPORT' first, always. Look at what is actually in there. */

/* ── Guard ────────────────────────────────────────────────────────────────── */
IF DB_NAME() NOT LIKE @AllowedDbPattern
BEGIN
    DECLARE @Wrong NVARCHAR(200) = DB_NAME();
    PRINT N'Refusing to run: current database is "' + @Wrong
        + N'", which does not match @AllowedDbPattern (' + @AllowedDbPattern + N').';
    PRINT N'Either switch the connection, or change @AllowedDbPattern deliberately.';
    RAISERROR(N'Masking aborted: database "%s" is outside the allowed pattern.', 16, 1, @Wrong);
    RETURN;
END

IF @Apply = 1 AND @AllowedDbPattern NOT LIKE N'%Demo%'
BEGIN
    PRINT N'';
    PRINT N'*** WARNING: @Apply = 1 and the guard is not restricted to demo databases.';
    PRINT N'*** You are about to permanently rewrite identifiers in ' + DB_NAME() + N'.';
    PRINT N'*** There is no undo. Confirm you have a restorable backup.';
    PRINT N'';
END

/* ── What counts as an identifier ─────────────────────────────────────────
   Patterns are deliberately precise, not Patient%. These tables carry
   PatientPayment, PatientAdjustments, PatientBalance, PatientPaymentPerUnit
   and PatientBalancePerUnit - all money columns. A Patient% wildcard would
   zero out the financials and the report would say it succeeded.          */
CREATE TABLE #MaskRule (Pattern SYSNAME, Category VARCHAR(20), Treatment VARCHAR(20));

INSERT INTO #MaskRule (Pattern, Category, Treatment) VALUES
    -- Patient identifiers: stable pseudonym, keeps rows joinable.
    (N'PatientId',              'PATIENT',    'TOKEN'),
    (N'PatientID',              'PATIENT',    'TOKEN'),
    (N'PatientNumber',          'PATIENT',    'TOKEN'),
    (N'PatientAccount%',        'PATIENT',    'TOKEN'),
    (N'MRN',                    'PATIENT',    'TOKEN'),
    (N'MedicalRecordNumber',    'PATIENT',    'TOKEN'),
    -- Subscriber / insurance identifiers.
    (N'SubscriberId',           'SUBSCRIBER', 'TOKEN'),
    (N'SubscriberID',           'SUBSCRIBER', 'TOKEN'),
    (N'MemberId',               'SUBSCRIBER', 'TOKEN'),
    (N'MemberID',               'SUBSCRIBER', 'TOKEN'),
    (N'PolicyNumber',           'SUBSCRIBER', 'TOKEN'),
    (N'InsuredId',              'SUBSCRIBER', 'TOKEN'),
    -- Patient names: readable placeholder.
    (N'PatientName',            'PATIENT',    'PATNAME'),
    (N'PatName',                'PATIENT',    'PATNAME'),
    (N'LISPatientName',         'PATIENT',    'PATNAME'),
    (N'PatientFirstName',       'PATIENT',    'PATNAME'),
    (N'PatientLastName',        'PATIENT',    'PATNAME'),
    (N'PatientMiddleName',      'PATIENT',    'PATNAME'),
    (N'SubscriberName',         'SUBSCRIBER', 'PATNAME'),
    (N'InsuredName',            'SUBSCRIBER', 'PATNAME'),
    (N'GuarantorName',          'PATIENT',    'PATNAME'),
    -- Clinic / facility.
    (N'ClinicName',             'CLINIC',     'CLINIC'),
    (N'Clinic',                 'CLINIC',     'CLINIC'),
    (N'FacilityName',           'CLINIC',     'CLINIC'),
    (N'Facility',               'CLINIC',     'CLINIC'),
    (N'PracticeName',           'CLINIC',     'CLINIC'),
    (N'AccountName',            'CLINIC',     'CLINIC'),
    -- Referring / ordering clinician.
    (N'ReferringProvider',      'PROVIDER',   'PROVIDER'),
    (N'ReferringProviderName',  'PROVIDER',   'PROVIDER'),
    (N'ReferringPhysician',     'PROVIDER',   'PROVIDER'),
    (N'ReferringDoctor',        'PROVIDER',   'PROVIDER'),
    (N'OrderingProvider',       'PROVIDER',   'PROVIDER'),
    (N'OrderingPhysician',      'PROVIDER',   'PROVIDER');

IF @MaskBillingProvider = 1
    INSERT INTO #MaskRule (Pattern, Category, Treatment) VALUES
        (N'BillingProvider',     'PROVIDER',   'PROVIDER'),
        (N'BillingProviderName', 'PROVIDER',   'PROVIDER');

IF @MaskSalesRep = 1
    INSERT INTO #MaskRule (Pattern, Category, Treatment) VALUES
        (N'SalesRepname',        'STAFF',      'PROVIDER'),
        (N'SalesRepName',        'STAFF',      'PROVIDER');

/* Belt and braces. Even with precise patterns, never touch a column whose name
   says it holds money, a count, a date or a code.

   NOTE the [_] escape on the last pattern. Written as '%Id_%' the underscore is
   a LIKE single-character wildcard, so it means "Id followed by any character"
   - which matches Prov-ID-er and silently excluded EVERY ReferringProvider,
   OrderingProvider and BillingProvider column. The run reported success and the
   provider names were left in place. '%Id[_]%' means a literal underscore,
   which is what was intended: keys like Lab_Id_Ref. */
CREATE TABLE #NeverTouch (Pattern SYSNAME);
INSERT INTO #NeverTouch (Pattern) VALUES
    (N'%Payment%'), (N'%Balance%'), (N'%Adjust%'), (N'%Amount%'), (N'%Charge%'),
    (N'%Count%'), (N'%Date%'), (N'%DOB%'), (N'%Npi%'), (N'%Code%'), (N'%Id[_]%');

/* ── Optional table filter ────────────────────────────────────────────────── */
CREATE TABLE #TableScope (TableName SYSNAME);
IF @TableFilter IS NOT NULL
    INSERT INTO #TableScope (TableName)
    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@TableFilter, ',')
    WHERE NULLIF(LTRIM(RTRIM(value)), N'') IS NOT NULL;

/* ── Match the rules against the real schema ──────────────────────────────
   Computed and non-writable columns are excluded or the UPDATE fails.
   Note DenialTaskBoard has computed ClaimIDNormalized and ClaimKeyNormalized;
   they do not match a rule, but the exclusion is here on principle.        */
SELECT
    QUOTENAME(c.TABLE_SCHEMA) + N'.' + QUOTENAME(c.TABLE_NAME) AS FullTable,
    c.TABLE_NAME,
    c.COLUMN_NAME,
    c.DATA_TYPE,
    -- -1 means a MAX type. Used to keep the replacement inside a narrow column:
    -- a varchar(10) clinic code will not hold 'DEMO CLINIC 4821'.
    ISNULL(c.CHARACTER_MAXIMUM_LENGTH, 4000) AS MaxLen,
    r.Category,
    r.Treatment
INTO #Target
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN INFORMATION_SCHEMA.TABLES  t
       ON  t.TABLE_SCHEMA = c.TABLE_SCHEMA
       AND t.TABLE_NAME   = c.TABLE_NAME
       AND t.TABLE_TYPE   = 'BASE TABLE'
JOIN #MaskRule r
       ON c.COLUMN_NAME LIKE r.Pattern
WHERE COLUMNPROPERTY(OBJECT_ID(QUOTENAME(c.TABLE_SCHEMA) + '.' + QUOTENAME(c.TABLE_NAME)),
                     c.COLUMN_NAME, 'IsComputed') = 0
  AND c.DATA_TYPE IN ('char', 'nchar', 'varchar', 'nvarchar')
  AND NOT EXISTS (SELECT 1 FROM #NeverTouch n WHERE c.COLUMN_NAME LIKE n.Pattern)
  AND (@TableFilter IS NULL OR EXISTS (SELECT 1 FROM #TableScope s WHERE s.TableName = c.TABLE_NAME));

/* A column can match more than one pattern. Keep one row each. */
;WITH Deduped AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY FullTable, COLUMN_NAME
                                 ORDER BY Treatment, Category) AS rn
    FROM #Target
)
DELETE FROM Deduped WHERE rn > 1;

PRINT N'Columns matched in ' + DB_NAME() + N':';
SELECT FullTable, COLUMN_NAME, DATA_TYPE, MaxLen, Category, Treatment
FROM #Target
ORDER BY FullTable, Category, COLUMN_NAME;

/* PRINT takes a scalar expression only - a subquery inside it is a parse
   error, not a runtime one, so the whole batch fails to compile. Count into
   variables first. */
DECLARE @ScopeTables INT, @ScopeColumns INT;
SELECT @ScopeTables  = COUNT(DISTINCT FullTable),
       @ScopeColumns = COUNT(*)
FROM #Target;

PRINT N'';
PRINT N'Tables in scope: '  + CAST(ISNULL(@ScopeTables, 0)  AS NVARCHAR(10))
    + N'   Columns to rewrite: ' + CAST(ISNULL(@ScopeColumns, 0) AS NVARCHAR(10));

/* ── Tables named in the request that were NOT matched ────────────────────
   If one of these is missing, either it does not exist in this database or it
   holds none of the target columns. Either way you want to know, rather than
   assume it was covered.                                                    */
PRINT N'';
PRINT N'Requested tables not matched (check these by hand):';
SELECT x.Expected
FROM (VALUES (N'DenialLineItem'), (N'DenialTaskBoard'), (N'LIMSMaster'),
             (N'ClaimLevelData'), (N'ClaimLevelDataArchive'),
             (N'LineLevelData'),  (N'LineLevelDataArchive'),
             (N'PayerPolicyData')) x(Expected)
WHERE NOT EXISTS (SELECT 1 FROM #Target t WHERE t.TABLE_NAME = x.Expected);

/* ── LIMSMaster.AdditionalFields: what is actually inside the JSON ────────── */
IF OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields') IS NOT NULL
BEGIN
    PRINT N'';
    PRINT N'LIMSMaster.AdditionalFields - distinct JSON keys, flagged against the mask rules.';
    PRINT N'A column scan cannot see inside this blob. Review every key marked ** REVIEW **.';

    /* OPENJSON returns [key] as Latin1_General_BIN2, which collides with the
       database collation the moment it meets #MaskRule.Pattern in a LIKE.
       COLLATE DATABASE_DEFAULT fixes the conflict - and it matters for more
       than the error: BIN2 is case AND accent sensitive, so under it
       '%DOB%' would not match a key named "Dob" or "patient_dob". Left as
       BIN2 this block would run clean and quietly miss identifier keys. */
    ;WITH JsonKeys AS (
        SELECT j.[key] COLLATE DATABASE_DEFAULT AS JsonKey
        FROM dbo.LIMSMaster m
        CROSS APPLY OPENJSON(m.AdditionalFields) j
        WHERE ISJSON(m.AdditionalFields) = 1
    )
    SELECT TOP (500)
           k.JsonKey,
           COUNT_BIG(*) AS Rows_,
           CASE WHEN EXISTS (SELECT 1 FROM #MaskRule r WHERE k.JsonKey LIKE r.Pattern)
                THEN N'** REVIEW ** matches a mask rule'
                WHEN k.JsonKey LIKE N'%DOB%'     OR k.JsonKey LIKE N'%Birth%'
                  OR k.JsonKey LIKE N'%Address%' OR k.JsonKey LIKE N'%Phone%'
                  OR k.JsonKey LIKE N'%Email%'   OR k.JsonKey LIKE N'%SSN%'
                  OR k.JsonKey LIKE N'%Zip%'     OR k.JsonKey LIKE N'%Postal%'
                  OR k.JsonKey LIKE N'%Name%'    OR k.JsonKey LIKE N'%MRN%'
                THEN N'** REVIEW ** identifier-shaped'
                ELSE N'' END AS Flag
    FROM JsonKeys k
    GROUP BY k.JsonKey
    ORDER BY Rows_ DESC;
END

/* ── Report-only exit ─────────────────────────────────────────────────────── */
IF @Apply = 0
BEGIN
    PRINT N'';
    PRINT N'REPORT ONLY - nothing was changed.';
    PRINT N'Review the lists above, take a backup, then set @Apply = 1 and run again.';
    DROP TABLE #Target; DROP TABLE #MaskRule; DROP TABLE #NeverTouch; DROP TABLE #TableScope;
    RETURN;
END

/* ── Rewrite ─────────────────────────────────────────────────────────────
   One UPDATE per column.

   The token is a salted SHA-256 of the ORIGINAL value, rendered as hex and cut
   to 10 characters - about a trillion values, so distinct patients keep
   distinct ids. The readable placeholders use a 7-digit number instead: two
   clinics can in principle land on the same fake name, which is cosmetic only,
   because every join in the schema runs on the id columns, not the names.

   Inputs are trimmed and upper-cased before hashing, so 'Smith Clinic',
   'SMITH CLINIC' and 'Smith Clinic ' collapse to one pseudonym. Clinic and
   provider names arrive from lab files with inconsistent casing and padding;
   without this the same clinic would get several different fake names and the
   dashboard grouping would fragment.

   NULL and blank stay NULL and blank. Inventing a fake clinic for a row that
   never had one would change what the reports say.                          */
DECLARE @FullTable NVARCHAR(300), @Column SYSNAME, @Treatment VARCHAR(20), @MaxLen INT;
DECLARE @Fit INT, @sql NVARCHAR(MAX);
DECLARE @Changed INT = 0, @Failed INT = 0, @TotalRows BIGINT = 0, @Rows BIGINT = 0;

DECLARE @Norm NVARCHAR(MAX) =
    N'UPPER(LTRIM(RTRIM(CONVERT(NVARCHAR(400), {COL}))))';
DECLARE @Hash NVARCHAR(MAX), @Num NVARCHAR(MAX), @Tok NVARCHAR(MAX);

DECLARE TargetCursor CURSOR LOCAL FAST_FORWARD FOR
    SELECT FullTable, COLUMN_NAME, Treatment, MaxLen
    FROM #Target ORDER BY FullTable, COLUMN_NAME;

OPEN TargetCursor;
FETCH NEXT FROM TargetCursor INTO @FullTable, @Column, @Treatment, @MaxLen;

WHILE @@FETCH_STATUS = 0
BEGIN
    /* Wrap every replacement in LEFT(...) so a narrow column truncates instead
       of failing the UPDATE outright. -1 is a MAX type: nothing overflows. */
    SET @Fit = CASE WHEN @MaxLen = -1 OR @MaxLen > 4000 THEN 4000 ELSE @MaxLen END;

    SET @Hash =
        N'HASHBYTES(''SHA2_256'', @Salt + N''|'' + '
        + REPLACE(@Norm, N'{COL}', QUOTENAME(@Column)) + N')';

    /* 6 bytes -> BIGINT is always positive (< 2^48), so no ABS needed and no
       risk of the ABS(-2147483648) overflow that bites CHECKSUM-based code. */
    SET @Num =
        N'CAST(CONVERT(BIGINT, SUBSTRING(' + @Hash + N', 1, 6)) % 10000000 AS NVARCHAR(10))';

    SET @Tok =
        N'LEFT(CONVERT(VARCHAR(64), ' + @Hash + N', 2), 10)';

    SET @sql =
        N'UPDATE ' + @FullTable + N' SET ' + QUOTENAME(@Column) + N' = LEFT('
        + CASE @Treatment
            WHEN 'TOKEN'    THEN N'''DP'' + '            + @Tok
            WHEN 'PATNAME'  THEN N'''Demo Patient '' + ' + @Num
            WHEN 'CLINIC'   THEN N'''DEMO CLINIC '' + '  + @Num
            WHEN 'PROVIDER' THEN N'''DEMO PROVIDER '' + '+ @Num
          END
        + N', @Fit) WHERE NULLIF(LTRIM(RTRIM(CONVERT(NVARCHAR(400), '
        + QUOTENAME(@Column) + N'))), '''') IS NOT NULL;';

    BEGIN TRY
        EXEC sp_executesql @sql, N'@Salt NVARCHAR(64), @Fit INT', @Salt = @Salt, @Fit = @Fit;
        /* @@ROWCOUNT must be captured on the very next statement. Incrementing
           @Changed first would reset it to 1, and the run would report one row
           per column instead of the rows actually rewritten. */
        SET @Rows      = @@ROWCOUNT;
        SET @Changed   = @Changed + 1;
        SET @TotalRows = @TotalRows + @Rows;
        PRINT N'  masked ' + @FullTable + N'.' + @Column
            + N' (' + @Treatment + N') - ' + CAST(@Rows AS NVARCHAR(20)) + N' rows';
    END TRY
    BEGIN CATCH
        /* Keep going. One awkward column - a unique index the pseudonym
           collides with, a column used in an indexed view - must not leave the
           rest identifiable. Every failure is printed; deal with those by hand
           and re-run, or the data is only partly masked. */
        SET @Failed = @Failed + 1;
        PRINT N'  !! FAILED ' + @FullTable + N'.' + @Column + N' : ' + ERROR_MESSAGE();
    END CATCH

    FETCH NEXT FROM TargetCursor INTO @FullTable, @Column, @Treatment, @MaxLen;
END

CLOSE TargetCursor;
DEALLOCATE TargetCursor;

/* ── LIMSMaster.AdditionalFields ──────────────────────────────────────────── */
IF @LimsJsonAction <> 'REPORT'
   AND OBJECT_ID('dbo.LIMSMaster', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.LIMSMaster', 'AdditionalFields') IS NOT NULL
BEGIN
    IF @LimsJsonAction = 'NULL'
    BEGIN
        UPDATE dbo.LIMSMaster SET AdditionalFields = NULL WHERE AdditionalFields IS NOT NULL;
        PRINT N'  nulled dbo.LIMSMaster.AdditionalFields (' + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' rows)';
    END
    ELSE IF @LimsJsonAction = 'SCRUB'
    BEGIN
        /* Same COLLATE DATABASE_DEFAULT as the report block above, and for the
           same two reasons: the collation conflict, and BIN2's case
           sensitivity silently skipping keys whose casing differs. */
        DECLARE @JsonKey NVARCHAR(400);
        DECLARE KeyCursor CURSOR LOCAL FAST_FORWARD FOR
            SELECT DISTINCT k.JsonKey
            FROM (
                SELECT j.[key] COLLATE DATABASE_DEFAULT AS JsonKey
                FROM dbo.LIMSMaster m
                CROSS APPLY OPENJSON(m.AdditionalFields) j
                WHERE ISJSON(m.AdditionalFields) = 1
            ) k
            WHERE EXISTS (SELECT 1 FROM #MaskRule r WHERE k.JsonKey LIKE r.Pattern)
               OR k.JsonKey LIKE N'%DOB%'     OR k.JsonKey LIKE N'%Birth%'
               OR k.JsonKey LIKE N'%Address%' OR k.JsonKey LIKE N'%Phone%'
               OR k.JsonKey LIKE N'%Email%'   OR k.JsonKey LIKE N'%SSN%'
               OR k.JsonKey LIKE N'%Name%'    OR k.JsonKey LIKE N'%MRN%';

        OPEN KeyCursor;
        FETCH NEXT FROM KeyCursor INTO @JsonKey;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            /* JSON_MODIFY needs a literal path, so it is built per key. The key
               name comes from the data, so it is escaped for the quote that
               would otherwise break the path expression. */
            SET @sql = N'UPDATE dbo.LIMSMaster
                         SET AdditionalFields = JSON_MODIFY(AdditionalFields,
                             ''$."' + REPLACE(@JsonKey, N'"', N'') + N'"'', ''MASKED'')
                         WHERE ISJSON(AdditionalFields) = 1
                           AND JSON_VALUE(AdditionalFields, ''$."'
                             + REPLACE(@JsonKey, N'"', N'') + N'"'') IS NOT NULL;';
            BEGIN TRY
                EXEC sp_executesql @sql;
                PRINT N'  scrubbed JSON key "' + @JsonKey + N'" ('
                    + CAST(@@ROWCOUNT AS NVARCHAR(20)) + N' rows)';
            END TRY
            BEGIN CATCH
                SET @Failed = @Failed + 1;
                PRINT N'  !! FAILED JSON key "' + @JsonKey + N'" : ' + ERROR_MESSAGE();
            END CATCH
            FETCH NEXT FROM KeyCursor INTO @JsonKey;
        END
        CLOSE KeyCursor; DEALLOCATE KeyCursor;
    END
END

DROP TABLE #Target; DROP TABLE #MaskRule; DROP TABLE #NeverTouch; DROP TABLE #TableScope;

PRINT N'';
PRINT N'Masking finished: ' + CAST(@Changed AS NVARCHAR(10)) + N' column(s) rewritten, '
    + CAST(@TotalRows AS NVARCHAR(20)) + N' row update(s), '
    + CAST(@Failed AS NVARCHAR(10)) + N' failure(s).';
PRINT N'';
PRINT N'STILL TO DO BY HAND:';
PRINT N'  1. Free-text fields are NOT masked - DenialClaimNotes.NoteText,';
PRINT N'     DenialClaimEscalations.Comments, DenialTaskHistory.Comments and';
PRINT N'     DenialTaskBoard.ReviewerComments all accept anything a user typed,';
PRINT N'     including patient names. Spot-check them.';
PRINT N'  2. ClaimLevelData.RowHash and LineLevelData.RowHash are now stale -';
PRINT N'     they were computed over the unmasked values. Incremental loads use';
PRINT N'     them for change detection, so recompute or clear them before the';
PRINT N'     next import, or rows will be re-detected as changed.';
PRINT N'  3. Dates of service, billing and posting are untouched by design.';
PRINT N'     This is a masking pass, not a Safe Harbor de-identification.';
GO


/* ============================================================================
   VERIFICATION - run after @Apply = 1.
   Every count below should be 0. Anything above 0 is a column the mask missed.
   ============================================================================ */
SET NOCOUNT ON;

SELECT
    QUOTENAME(c.TABLE_SCHEMA) + N'.' + QUOTENAME(c.TABLE_NAME) AS FullTable,
    c.COLUMN_NAME,
    N'SELECT ''' + c.TABLE_NAME + N'.' + c.COLUMN_NAME
      + N''' AS Col, COUNT_BIG(*) AS Unmasked FROM '
      + QUOTENAME(c.TABLE_SCHEMA) + N'.' + QUOTENAME(c.TABLE_NAME)
      + N' WHERE NULLIF(LTRIM(RTRIM(' + QUOTENAME(c.COLUMN_NAME) + N')), '''') IS NOT NULL'
      + N'   AND ' + QUOTENAME(c.COLUMN_NAME) + N' NOT LIKE ''DP%'''
      + N'   AND ' + QUOTENAME(c.COLUMN_NAME) + N' NOT LIKE ''Demo Patient %'''
      + N'   AND ' + QUOTENAME(c.COLUMN_NAME) + N' NOT LIKE ''DEMO CLINIC %'''
      + N'   AND ' + QUOTENAME(c.COLUMN_NAME) + N' NOT LIKE ''DEMO PROVIDER %'';'
        AS CheckSql
FROM INFORMATION_SCHEMA.COLUMNS c
JOIN INFORMATION_SCHEMA.TABLES t
       ON  t.TABLE_SCHEMA = c.TABLE_SCHEMA
       AND t.TABLE_NAME   = c.TABLE_NAME
       AND t.TABLE_TYPE   = 'BASE TABLE'
WHERE c.DATA_TYPE IN ('char', 'nchar', 'varchar', 'nvarchar')
  AND c.COLUMN_NAME IN (N'PatientName', N'PatName', N'LISPatientName', N'PatientId',
                        N'PatientID', N'SubscriberId', N'ClinicName', N'ReferringProvider')
ORDER BY FullTable, c.COLUMN_NAME;
/* Copy the CheckSql column out and run it. Or wrap it in a cursor if you prefer;
   it is left as generated text so you can see exactly what is being asserted
   before you run it against a database you care about. */
GO
