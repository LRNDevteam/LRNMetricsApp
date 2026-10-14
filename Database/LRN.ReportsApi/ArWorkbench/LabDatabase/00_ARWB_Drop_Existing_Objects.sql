/* ============================================================================================
   AR Workbench - 00 DROP every existing AR Workbench object in this LAB database

   Removes:
     1. The legacy [arwb] schema and everything in it (arwb.Claim, arwb.ClaimLine, arwb.CipCase, ...,
        the arwb.usp_* procedures, arwb.vw_* views and arwb.tvf_* functions), then the schema itself.
     2. Any dbo.ARWB_* object from an earlier run of these scripts, so 01-07 rebuild from clean.

   THIS DELETES ALL AR WORKBENCH DATA IN THE LAB: assignments, follow-ups, QA reviews, CIP cases,
   batches, saved views and the activity log. Source tables (dbo.ClaimLevelData, dbo.LineLevelData)
   and the Denial Workflow tables (dbo.Denial*) are NOT touched. Neither is the optional source
   index from script 08 (IX_LineLevelData_ClaimID_ArWorkbench), because it lives on a dbo source table.

   Run it on purpose, in the lab database, before 01. It is not part of the merged setup file.
   Safe to re-run: it only drops what exists.
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

-- Objects in scope: everything in schema arwb, and dbo objects named ARWB_%.
-- dbo.ARWB_UserScope is an LRNMaster table; it is excluded in case both live in one database.
DECLARE @Targets TABLE (ObjectId int NOT NULL PRIMARY KEY, SchemaName sysname NOT NULL, ObjectName sysname NOT NULL, TypeCode char(2) NOT NULL);
INSERT INTO @Targets (ObjectId, SchemaName, ObjectName, TypeCode)
SELECT o.object_id, s.name, o.name, o.type
FROM sys.objects o
INNER JOIN sys.schemas s ON s.schema_id = o.schema_id
WHERE o.is_ms_shipped = 0
  AND o.parent_object_id = 0
  AND o.type IN ('U', 'V', 'P', 'IF', 'TF', 'FN')
  AND (   s.name = N'arwb'
       OR (s.name = N'dbo' AND o.name LIKE N'ARWB[_]%' AND o.name <> N'ARWB_UserScope'));

-- Foreign keys first (on, or pointing at, a target table), then views, procedures, functions, tables.
DECLARE @Statements TABLE (Seq int IDENTITY(1,1) PRIMARY KEY, Stmt nvarchar(1000) NOT NULL);

INSERT INTO @Statements (Stmt)
SELECT N'ALTER TABLE ' + QUOTENAME(ps.name) + N'.' + QUOTENAME(pt.name) + N' DROP CONSTRAINT ' + QUOTENAME(fk.name) + N';'
FROM sys.foreign_keys fk
INNER JOIN sys.tables  pt ON pt.object_id = fk.parent_object_id
INNER JOIN sys.schemas ps ON ps.schema_id = pt.schema_id
WHERE fk.parent_object_id     IN (SELECT ObjectId FROM @Targets)
   OR fk.referenced_object_id IN (SELECT ObjectId FROM @Targets)
ORDER BY fk.name;

INSERT INTO @Statements (Stmt)
SELECT CASE t.TypeCode WHEN 'V' THEN N'DROP VIEW ' WHEN 'P' THEN N'DROP PROCEDURE ' WHEN 'U' THEN N'DROP TABLE ' ELSE N'DROP FUNCTION ' END
       + QUOTENAME(t.SchemaName) + N'.' + QUOTENAME(t.ObjectName) + N';'
FROM @Targets t
ORDER BY CASE t.TypeCode WHEN 'V' THEN 1 WHEN 'P' THEN 2 WHEN 'U' THEN 4 ELSE 3 END, t.ObjectName;

DECLARE @Stmt nvarchar(1000), @Dropped int = 0;
DECLARE drop_cursor CURSOR LOCAL FAST_FORWARD FOR SELECT Stmt FROM @Statements ORDER BY Seq;
OPEN drop_cursor;
FETCH NEXT FROM drop_cursor INTO @Stmt;
WHILE @@FETCH_STATUS = 0
BEGIN
    PRINT @Stmt;
    EXEC sys.sp_executesql @Stmt;
    IF @Stmt LIKE N'DROP %' SET @Dropped += 1;
    FETCH NEXT FROM drop_cursor INTO @Stmt;
END;
CLOSE drop_cursor;
DEALLOCATE drop_cursor;

-- The legacy schema itself, once empty.
IF SCHEMA_ID(N'arwb') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM sys.objects WHERE schema_id = SCHEMA_ID(N'arwb'))
   AND NOT EXISTS (SELECT 1 FROM sys.types   WHERE schema_id = SCHEMA_ID(N'arwb'))
BEGIN
    EXEC (N'DROP SCHEMA arwb;');
    PRINT 'DROP SCHEMA arwb;';
END;

PRINT CONCAT('AR Workbench 00: dropped ', @Dropped, ' object(s).');
GO
