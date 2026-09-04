-- Seed Collection and LIS "Key Insights & Highlights" templates.
-- Run on CoveLRN AFTER 07_ProductionInsights_Cove.sql (tables must exist).
-- Idempotent: skips a report if its template already has columns.
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.NotesReport', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplate', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NULL
BEGIN
    RAISERROR('Notes Insights tables are missing. Run 01-06, 07_Create_NotesResponsibleParty_Master, 07_ProductionInsights_Cove, then this script.', 16, 1);
    RETURN;
END
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

-- Collection: # of Cases, Total Bill, Case Link, Response By
DECLARE @CollKey INT = (SELECT ReportKeyId FROM dbo.NotesReport WHERE ReportName = N'Collection Report');
DECLARE @CollTpl INT = (SELECT TOP 1 TemplateId FROM dbo.NotesTemplate WHERE ReportKeyId = @CollKey AND TemplateName = N'Key Insights & Highlights');

IF @CollKey IS NOT NULL AND @CollTpl IS NULL
BEGIN
    INSERT INTO dbo.NotesTemplate (ReportKeyId, TemplateName, IsActive, CreatedBy, CreatedDateTime)
    VALUES (@CollKey, N'Key Insights & Highlights', 1, N'system', GETDATE());
    SET @CollTpl = SCOPE_IDENTITY();
END

IF @CollTpl IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.NotesTemplateColumn WHERE TemplateId = @CollTpl AND IsActive = 1)
BEGIN
    INSERT INTO dbo.NotesTemplateColumn (TemplateId, ColumnName, ColumnType, IsRequired, SortOrder, IsActive, FieldKey)
    VALUES
        (@CollTpl, N'Risk',                            N'Dropdown', 1, 1,  1, N'Risk'),
        (@CollTpl, N'Responsible Party',               N'Text',     0, 2,  1, N'ResponsibleParty'),
        (@CollTpl, N'Insights',                        N'Text',     1, 3,  1, N'Insights'),
        (@CollTpl, N'# of Cases',                      N'Text',     0, 4,  1, N'NoOfClaims'),
        (@CollTpl, N'Total Bill',                      N'Text',     0, 5,  1, N'TotalCharge'),
        (@CollTpl, N'Case Link',                       N'Text',     0, 6,  1, N'DataLink'),
        (@CollTpl, N'Action / Solution / Suggestion',  N'Text',     0, 7,  1, N'ActionSolution'),
        (@CollTpl, N'Feedback / Response',             N'Text',     0, 8,  1, N'FeedbackResponse'),
        (@CollTpl, N'Response By',                     N'Text',     0, 9,  1, N'Responsibility'),
        (@CollTpl, N'Discussion Date',                 N'Date',     0, 10, 1, N'DiscussionDate'),
        (@CollTpl, N'ETA',                             N'Date',     0, 11, 1, N'ETA'),
        (@CollTpl, N'Closed Date',                     N'Date',     0, 12, 1, N'ClosedDate'),
        (@CollTpl, N'Status',                          N'Dropdown', 1, 13, 1, N'Status');

    DECLARE @CRisk INT = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @CollTpl AND FieldKey = N'Risk');
    DECLARE @CStat INT = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @CollTpl AND FieldKey = N'Status');
    INSERT INTO dbo.NotesTemplateColumnValue (ColumnId, DropdownValue, SortOrder, IsActive)
    VALUES
        (@CRisk, N'High', 1, 1), (@CRisk, N'Medium', 2, 1), (@CRisk, N'Low', 3, 1),
        (@CStat, N'Yet to Discuss', 1, 1), (@CStat, N'Open', 2, 1),
        (@CStat, N'In Progress', 3, 1), (@CStat, N'Deferred', 4, 1), (@CStat, N'Closed', 5, 1);
END
GO

-- LIS: # of Claims, Expected Reimbursement ($), Data Link, Responsibility
DECLARE @LisKey INT = (SELECT ReportKeyId FROM dbo.NotesReport WHERE ReportName = N'LIS Report');
DECLARE @LisTpl INT = (SELECT TOP 1 TemplateId FROM dbo.NotesTemplate WHERE ReportKeyId = @LisKey AND TemplateName = N'Key Insights & Highlights');

IF @LisKey IS NOT NULL AND @LisTpl IS NULL
BEGIN
    INSERT INTO dbo.NotesTemplate (ReportKeyId, TemplateName, IsActive, CreatedBy, CreatedDateTime)
    VALUES (@LisKey, N'Key Insights & Highlights', 1, N'system', GETDATE());
    SET @LisTpl = SCOPE_IDENTITY();
END

IF @LisTpl IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.NotesTemplateColumn WHERE TemplateId = @LisTpl AND IsActive = 1)
BEGIN
    INSERT INTO dbo.NotesTemplateColumn (TemplateId, ColumnName, ColumnType, IsRequired, SortOrder, IsActive, FieldKey)
    VALUES
        (@LisTpl, N'Risk',                               N'Dropdown', 1, 1,  1, N'Risk'),
        (@LisTpl, N'Responsible Party',                  N'Text',     0, 2,  1, N'ResponsibleParty'),
        (@LisTpl, N'Insights',                           N'Text',     1, 3,  1, N'Insights'),
        (@LisTpl, N'# of Claims',                        N'Text',     0, 4,  1, N'NoOfClaims'),
        (@LisTpl, N'Expected Reimbursement ($)',         N'Text',     0, 5,  1, N'TotalCharge'),
        (@LisTpl, N'Data Link',                          N'Text',     0, 6,  1, N'DataLink'),
        (@LisTpl, N'Action / Solution / Suggestions',    N'Text',     0, 7,  1, N'ActionSolution'),
        (@LisTpl, N'Feedback / Response',                N'Text',     0, 8,  1, N'FeedbackResponse'),
        (@LisTpl, N'Responsibility',                     N'Text',     0, 9,  1, N'Responsibility'),
        (@LisTpl, N'Discussion Date',                    N'Date',     0, 10, 1, N'DiscussionDate'),
        (@LisTpl, N'ETA',                                N'Date',     0, 11, 1, N'ETA'),
        (@LisTpl, N'Closed Date',                        N'Date',     0, 12, 1, N'ClosedDate'),
        (@LisTpl, N'Status',                             N'Dropdown', 1, 13, 1, N'Status');

    DECLARE @LRisk INT = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @LisTpl AND FieldKey = N'Risk');
    DECLARE @LStat INT = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @LisTpl AND FieldKey = N'Status');
    INSERT INTO dbo.NotesTemplateColumnValue (ColumnId, DropdownValue, SortOrder, IsActive)
    VALUES
        (@LRisk, N'High', 1, 1), (@LRisk, N'Medium', 2, 1), (@LRisk, N'Low', 3, 1),
        (@LStat, N'Yet to Discuss', 1, 1), (@LStat, N'Open', 2, 1),
        (@LStat, N'In Progress', 3, 1), (@LStat, N'Deferred', 4, 1), (@LStat, N'Closed', 5, 1);
END
GO

PRINT CASE
    WHEN OBJECT_ID('dbo.NotesInsight', 'U') IS NULL
        THEN '== 09_CollectionLisInsights_Cove.sql STOPPED: run prior NotesInsights scripts first =='
    ELSE '== 09_CollectionLisInsights_Cove.sql complete =='
END;
GO
