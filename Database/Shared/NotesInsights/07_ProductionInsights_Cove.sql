-- ============================================================
-- Production / LIS / Collection Insights (Cove first)
-- Run on the LAB database (CoveLRN), NOT LRNMaster.
-- Prerequisite: 01 through 06, then 07_Create_NotesResponsibleParty_Master.sql
-- (those scripts create NotesInsight / NotesStatus / NotesReport / templates).
-- This file only PATCHes that schema. COL_LENGTH is NULL when a table is
-- missing, so every statement is guarded with OBJECT_ID.
-- Then run 08_NotesInsight_TotalCharge_SPs.sql.
-- Idempotent.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.NotesInsight', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesStatus', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesReport', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplate', 'U') IS NULL
BEGIN
    RAISERROR('Notes Insights tables are not on this database. Run these on CoveLRN in order, then re-run this script:
  01_Create_NotesInsights_Tables.sql
  02_Create_SP_NotesInsights_Read.sql
  03_Create_SP_NotesInsights_Write.sql
  04_Create_SP_NotesInsights_Archive.sql
  05_Create_SP_NotesInsights_Import.sql
  06_Create_SP_NotesTemplateLibrary.sql
  07_Create_NotesResponsibleParty_Master.sql
Confirm SSMS is connected to CoveLRN (not LRNMaster).', 16, 1);
    RETURN;
END
GO

IF OBJECT_ID('dbo.NotesInsight', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.NotesInsight', 'TotalCharge') IS NULL
    ALTER TABLE dbo.NotesInsight ADD TotalCharge DECIMAL(18,2) NULL;
GO

IF OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NOT NULL
   AND COL_LENGTH('dbo.NotesTemplateColumn', 'FieldKey') IS NULL
    ALTER TABLE dbo.NotesTemplateColumn ADD FieldKey NVARCHAR(50) NULL;
GO

IF OBJECT_ID('dbo.NotesStatus', 'U') IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM dbo.NotesStatus WHERE StatusCode = 'Discuss')
    INSERT INTO dbo.NotesStatus (StatusCode, StatusLabel, IsClosedState, SortOrder, IsActive)
    VALUES ('Discuss', 'Yet to Discuss', 0, 0, 1);
GO

IF OBJECT_ID('dbo.NotesReport', 'U') IS NOT NULL
BEGIN
    MERGE dbo.NotesReport AS t
    USING (VALUES
        ('Executive Summary',  'EXEC_SUMMARY'),
        ('Production Report',  'PRODUCTION'),
        ('LIS Report',         'LIS'),
        ('Collection Report',  'COLLECTION')
    ) AS s (ReportName, ReportCode)
    ON t.ReportName = s.ReportName
    WHEN NOT MATCHED THEN
        INSERT (ReportName, ReportCode, IsActive, CreatedDateTime)
        VALUES (s.ReportName, s.ReportCode, 1, GETDATE());
END
GO

IF OBJECT_ID('dbo.NotesReport', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.NotesTemplate', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NOT NULL
BEGIN
    DECLARE @ProdKey INT = (SELECT ReportKeyId FROM dbo.NotesReport WHERE ReportName = 'Production Report');
    DECLARE @TplId INT = (SELECT TOP 1 TemplateId FROM dbo.NotesTemplate WHERE ReportKeyId = @ProdKey AND TemplateName = N'Key Insights & Highlights');

    IF @ProdKey IS NOT NULL AND @TplId IS NULL
    BEGIN
        INSERT INTO dbo.NotesTemplate (ReportKeyId, TemplateName, IsActive, CreatedBy, CreatedDateTime)
        VALUES (@ProdKey, N'Key Insights & Highlights', 1, N'system', GETDATE());
        SET @TplId = SCOPE_IDENTITY();
    END

    IF @TplId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.NotesTemplateColumn WHERE TemplateId = @TplId)
    BEGIN
        INSERT INTO dbo.NotesTemplateColumn (TemplateId, ColumnName, ColumnType, IsRequired, SortOrder, IsActive, FieldKey)
        VALUES
            (@TplId, N'Risk',                             N'Dropdown', 1, 1,  1, N'Risk'),
            (@TplId, N'Responsible Party',                N'Text',     0, 2,  1, N'ResponsibleParty'),
            (@TplId, N'Insights',                         N'Text',     1, 3,  1, N'Insights'),
            (@TplId, N'# of Claims',                      N'Text',     0, 4,  1, N'NoOfClaims'),
            (@TplId, N'Total Charge',                     N'Text',     0, 5,  1, N'TotalCharge'),
            (@TplId, N'Data',                             N'Text',     0, 6,  1, N'DataLink'),
            (@TplId, N'Action / Solution / Suggestions',  N'Text',     0, 7,  1, N'ActionSolution'),
            (@TplId, N'Feedback / Response',              N'Text',     0, 8,  1, N'FeedbackResponse'),
            (@TplId, N'Responsibility',                   N'Text',     0, 9,  1, N'Responsibility'),
            (@TplId, N'Discussion Date',                  N'Date',     0, 10, 1, N'DiscussionDate'),
            (@TplId, N'ETA',                              N'Date',     0, 11, 1, N'ETA'),
            (@TplId, N'Closed Date',                      N'Date',     0, 12, 1, N'ClosedDate'),
            (@TplId, N'Status',                           N'Dropdown', 1, 13, 1, N'Status');

        DECLARE @RiskCol INT = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @TplId AND FieldKey = N'Risk');
        DECLARE @StatCol INT = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @TplId AND FieldKey = N'Status');

        INSERT INTO dbo.NotesTemplateColumnValue (ColumnId, DropdownValue, SortOrder, IsActive)
        VALUES
            (@RiskCol, N'High',   1, 1),
            (@RiskCol, N'Medium', 2, 1),
            (@RiskCol, N'Low',    3, 1),
            (@StatCol, N'Yet to Discuss', 1, 1),
            (@StatCol, N'Open',           2, 1),
            (@StatCol, N'In Progress',    3, 1),
            (@StatCol, N'Deferred',       4, 1),
            (@StatCol, N'Closed',         5, 1);
    END
END
GO

IF OBJECT_ID('dbo.usp_NotesTemplate_List', 'P') IS NOT NULL DROP PROCEDURE dbo.usp_NotesTemplate_List;
GO
CREATE PROCEDURE dbo.usp_NotesTemplate_List
    @ReportKeyId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SELECT t.TemplateId, t.ReportKeyId, r.ReportName, t.TemplateName, t.IsActive,
           t.CreatedBy, t.CreatedDateTime, t.LastEditedBy, t.LastEditedDateTime
    FROM dbo.NotesTemplate t
    INNER JOIN dbo.NotesReport r ON r.ReportKeyId = t.ReportKeyId
    WHERE t.IsActive = 1
      AND (@ReportKeyId IS NULL OR t.ReportKeyId = @ReportKeyId)
    ORDER BY r.ReportName, t.TemplateName;

    SELECT c.ColumnId, c.TemplateId, c.ColumnName, c.ColumnType, c.IsRequired, c.SortOrder, c.IsActive, c.FieldKey
    FROM dbo.NotesTemplateColumn c
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    WHERE t.IsActive = 1 AND c.IsActive = 1
      AND (@ReportKeyId IS NULL OR t.ReportKeyId = @ReportKeyId)
    ORDER BY c.TemplateId, c.SortOrder;

    SELECT v.ColumnValueId, v.ColumnId, v.DropdownValue, v.SortOrder, v.IsActive
    FROM dbo.NotesTemplateColumnValue v
    INNER JOIN dbo.NotesTemplateColumn c ON c.ColumnId = v.ColumnId
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    WHERE t.IsActive = 1 AND c.IsActive = 1 AND v.IsActive = 1
      AND (@ReportKeyId IS NULL OR t.ReportKeyId = @ReportKeyId)
    ORDER BY v.ColumnId, v.SortOrder;
END
GO

PRINT CASE
    WHEN OBJECT_ID('dbo.NotesInsight', 'U') IS NULL
        THEN '== 07_ProductionInsights_Cove.sql STOPPED: run 01-06 (+ 07_Create_NotesResponsibleParty_Master) on CoveLRN first =='
    ELSE '== 07_ProductionInsights_Cove.sql complete =='
END;
GO
