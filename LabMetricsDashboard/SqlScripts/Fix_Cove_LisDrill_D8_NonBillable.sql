/* ============================================================================
   Feedback #5 - "Ignored - Client Response Non Billable" reads 0 in the LIS
   Summary; the manual report has 10.

   >>> RUN AGAINST THE COVE LAB DATABASE (where dbo.LisDrillRowDef lives). <<<

   CAUSE
   The row is defined with the misspelling "Non Billiable". The LIS Summary
   compared that against the samples' Sub Status, and a sample recorded with the
   correct spelling never matched - so the row read 0, while the same samples were
   picked up as an "uncovered" sub-status and shown in a separate row instead.

   The application now matches either spelling (SqlLisSummaryRepository,
   FixKnownMisspellings). This script brings the drill-through into line, so that
   clicking the row returns the samples it counted instead of an empty list.

   Re-runnable. Equivalent to re-running LisDrillRowDef.sql, but touches one row.
   ============================================================================ */

SET NOCOUNT ON;

/* ── 1. Which spelling does the data actually use? ─────────────────────────
   Read this before anything else. It is the evidence for the diagnosis: expect
   the correctly-spelled value to carry the samples. If ONLY the misspelling
   appears, the zero has a different cause and this is not the fix for it. */
/* dbo.LIMSMaster is the table Cove's LIS procedures read (19_Cove_ExecutiveSummary_LIS_Alt.sql).
   Dynamic SQL, so the script still parses on a database where the table has a different shape. */
IF OBJECT_ID(N'dbo.LIMSMaster', N'U') IS NOT NULL AND COL_LENGTH(N'dbo.LIMSMaster', N'SubStatus') IS NOT NULL
BEGIN
    EXEC sys.sp_executesql N'
        SELECT SubStatus, COUNT(*) AS Samples
        FROM   dbo.LIMSMaster
        WHERE  SubStatus LIKE N''%Client Response Non Bil%''
        GROUP BY SubStatus;';
END
ELSE
    PRINT N'dbo.LIMSMaster.SubStatus not found - run the spelling check by hand against this lab''s LIS table.';

/* ── 2. Point the drill row at both spellings ─────────────────────────────── */
IF OBJECT_ID(N'dbo.LisDrillRowDef', N'U') IS NULL
    THROW 53001, N'dbo.LisDrillRowDef does not exist here. Run it against the Cove lab database.', 1;

UPDATE dbo.LisDrillRowDef
SET    RowTitle = N'Ignored - Client Response Non Billable',
       Op3      = N'IN',
       Val3     = N'Ignored - Client Response Non Billable,Ignored - Client Response Non Billiable'
WHERE  LabPrefix = N'Cove'
  AND  RowCode   = N'D.8'
  AND  ISNULL(Source, N'LIS') = N'LIS';

PRINT CAST(@@ROWCOUNT AS NVARCHAR(10)) + N' drill row(s) updated.';

SELECT RowCode, RowTitle, Col3, Op3, Val3
FROM   dbo.LisDrillRowDef
WHERE  LabPrefix = N'Cove' AND RowCode = N'D.8';
