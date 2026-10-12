-- ============================================================
-- Script  : 12_NotesInsights_SeedLabDefaults.sql
-- Feature : Key Insights & Highlights (Production / LIS / Collection) and
--           Executive Summary Notes & Insights
-- Purpose : Seed the lookup rows and "Key Insights & Highlights" templates on a
--           lab database that already has the Notes schema (01-11) but no data -
--           without them the panel has no Risk / Status / Responsible Party values
--           and no template to add an insight with.
--             - dbo.NotesRiskLevel, dbo.NotesStatus (incl. 'Yet to Discuss')
--             - dbo.NotesResponsibleParty
--             - dbo.NotesReport (the four reports)
--             - Production / LIS / Collection templates, columns and dropdown values
--               (same columns as CoveLRN; Collection uses 'Total Balance')
-- Run     : On the LAB database (WellHealth, AnalyzePathology, ...), NOT LRNMaster.
-- Idempotent: every block only inserts what is missing; existing rows, templates
--             and insights are left untouched.
-- ============================================================
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID('dbo.NotesInsight', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesRiskLevel', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesStatus', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesResponsibleParty', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesReport', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplate', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NULL
   OR OBJECT_ID('dbo.NotesTemplateColumnValue', 'U') IS NULL
   OR COL_LENGTH('dbo.NotesTemplateColumn', 'FieldKey') IS NULL
BEGIN
    RAISERROR('Notes Insights schema is incomplete on this database. Run NotesInsights scripts 01-11 first.', 16, 1);
    SET NOEXEC ON;
END
GO

-- ── Lookups ─────────────────────────────────────────────────────────────
IF NOT EXISTS (SELECT 1 FROM dbo.NotesRiskLevel)
    INSERT INTO dbo.NotesRiskLevel (RiskCode, RiskLabel, ColorHex, SortOrder)
    VALUES ('Red',    'High Risk',      '#D64545', 1),
           ('Yellow', 'Medium / Watch', '#E0A800', 2),
           ('Green',  'Low / Resolved', '#2E9E5B', 3);

IF NOT EXISTS (SELECT 1 FROM dbo.NotesStatus)
    INSERT INTO dbo.NotesStatus (StatusCode, StatusLabel, IsClosedState, SortOrder)
    VALUES ('Open',     'Open',        0, 1),
           ('WIP',      'In Progress', 0, 2),
           ('Deferred', 'Deferred',    0, 3),
           ('Closed',   'Closed',      1, 4);

IF NOT EXISTS (SELECT 1 FROM dbo.NotesStatus WHERE StatusCode = 'Discuss')
    INSERT INTO dbo.NotesStatus (StatusCode, StatusLabel, IsClosedState, SortOrder, IsActive)
    VALUES ('Discuss', 'Yet to Discuss', 0, 0, 1);

IF NOT EXISTS (SELECT 1 FROM dbo.NotesResponsibleParty)
    INSERT INTO dbo.NotesResponsibleParty (PartyName, SortOrder)
    VALUES ('Billing Team',         1),
           ('AR Manager',           2),
           ('Client Manager',       3),
           ('Payer Follow-up Team', 4),
           ('Operations Team',      5),
           ('Coding Team',          6),
           ('Compliance Team',      7),
           ('Lab Admin',            8);

MERGE dbo.NotesReport AS t
USING (VALUES
    ('Executive Summary', 'EXEC_SUMMARY'),
    ('Production Report', 'PRODUCTION'),
    ('LIS Report',        'LIS'),
    ('Collection Report', 'COLLECTION')
) AS s (ReportName, ReportCode)
ON t.ReportName = s.ReportName
WHEN MATCHED AND t.ReportCode IS NULL THEN
    UPDATE SET ReportCode = s.ReportCode
WHEN NOT MATCHED THEN
    INSERT (ReportName, ReportCode, IsActive, CreatedDateTime)
    VALUES (s.ReportName, s.ReportCode, 1, GETDATE());
GO

-- ── Key Insights & Highlights templates ─────────────────────────────────
-- Columns 4-6 and 9 carry each report's own captions; the rest are shared.
DECLARE @Tpl TABLE (ReportName NVARCHAR(200), CountCaption NVARCHAR(200), AmountCaption NVARCHAR(200),
                    LinkCaption NVARCHAR(200), ActionCaption NVARCHAR(200), RespCaption NVARCHAR(200));
INSERT INTO @Tpl VALUES
    (N'Production Report', N'# of Claims', N'Total Charge',               N'Data',      N'Action / Solution / Suggestions', N'Responsibility'),
    (N'LIS Report',        N'# of Claims', N'Expected Reimbursement ($)', N'Data Link', N'Action / Solution / Suggestions', N'Responsibility'),
    (N'Collection Report', N'# of Cases',  N'Total Balance',              N'Case Link', N'Action / Solution / Suggestion',  N'Response By');

DECLARE @ReportName NVARCHAR(200), @CountCaption NVARCHAR(200), @AmountCaption NVARCHAR(200),
        @LinkCaption NVARCHAR(200), @ActionCaption NVARCHAR(200), @RespCaption NVARCHAR(200);
DECLARE @Key INT, @TplId INT, @RiskCol INT, @StatCol INT;

DECLARE tpl CURSOR LOCAL FAST_FORWARD FOR
    SELECT ReportName, CountCaption, AmountCaption, LinkCaption, ActionCaption, RespCaption FROM @Tpl;
OPEN tpl;
FETCH NEXT FROM tpl INTO @ReportName, @CountCaption, @AmountCaption, @LinkCaption, @ActionCaption, @RespCaption;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @Key   = (SELECT ReportKeyId FROM dbo.NotesReport WHERE ReportName = @ReportName);
    SET @TplId = (SELECT TOP (1) TemplateId FROM dbo.NotesTemplate
                  WHERE ReportKeyId = @Key AND TemplateName = N'Key Insights & Highlights'
                  ORDER BY TemplateId);

    IF @Key IS NOT NULL AND @TplId IS NULL
    BEGIN
        INSERT INTO dbo.NotesTemplate (ReportKeyId, TemplateName, IsActive, CreatedBy, CreatedDateTime)
        VALUES (@Key, N'Key Insights & Highlights', 1, N'system', GETDATE());
        SET @TplId = SCOPE_IDENTITY();
    END

    IF @TplId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.NotesTemplateColumn WHERE TemplateId = @TplId AND IsActive = 1)
    BEGIN
        INSERT INTO dbo.NotesTemplateColumn (TemplateId, ColumnName, ColumnType, IsRequired, SortOrder, IsActive, FieldKey)
        VALUES
            (@TplId, N'Risk',                N'Dropdown', 1, 1,  1, N'Risk'),
            (@TplId, N'Responsible Party',   N'Text',     0, 2,  1, N'ResponsibleParty'),
            (@TplId, N'Insights',            N'Text',     1, 3,  1, N'Insights'),
            (@TplId, @CountCaption,          N'Text',     0, 4,  1, N'NoOfClaims'),
            (@TplId, @AmountCaption,         N'Text',     0, 5,  1, N'TotalCharge'),
            (@TplId, @LinkCaption,           N'Text',     0, 6,  1, N'DataLink'),
            (@TplId, @ActionCaption,         N'Text',     0, 7,  1, N'ActionSolution'),
            (@TplId, N'Feedback / Response', N'Text',     0, 8,  1, N'FeedbackResponse'),
            (@TplId, @RespCaption,           N'Text',     0, 9,  1, N'Responsibility'),
            (@TplId, N'Discussion Date',     N'Date',     0, 10, 1, N'DiscussionDate'),
            (@TplId, N'ETA',                 N'Date',     0, 11, 1, N'ETA'),
            (@TplId, N'Closed Date',         N'Date',     0, 12, 1, N'ClosedDate'),
            (@TplId, N'Status',              N'Dropdown', 1, 13, 1, N'Status');

        SET @RiskCol = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @TplId AND FieldKey = N'Risk');
        SET @StatCol = (SELECT ColumnId FROM dbo.NotesTemplateColumn WHERE TemplateId = @TplId AND FieldKey = N'Status');

        INSERT INTO dbo.NotesTemplateColumnValue (ColumnId, DropdownValue, SortOrder, IsActive)
        VALUES (@RiskCol, N'High', 1, 1), (@RiskCol, N'Medium', 2, 1), (@RiskCol, N'Low', 3, 1),
               (@StatCol, N'Yet to Discuss', 1, 1), (@StatCol, N'Open', 2, 1),
               (@StatCol, N'In Progress', 3, 1), (@StatCol, N'Deferred', 4, 1), (@StatCol, N'Closed', 5, 1);

        PRINT 'Seeded Key Insights & Highlights template for ' + @ReportName + '.';
    END

    FETCH NEXT FROM tpl INTO @ReportName, @CountCaption, @AmountCaption, @LinkCaption, @ActionCaption, @RespCaption;
END
CLOSE tpl;
DEALLOCATE tpl;
GO

SET NOEXEC OFF;
GO

SELECT DB_NAME() AS Db,
       (SELECT COUNT(*) FROM dbo.NotesRiskLevel)        AS RiskLevels,
       (SELECT COUNT(*) FROM dbo.NotesStatus)           AS Statuses,
       (SELECT COUNT(*) FROM dbo.NotesResponsibleParty) AS ResponsibleParties,
       (SELECT COUNT(*) FROM dbo.NotesReport)           AS Reports,
       (SELECT COUNT(*) FROM dbo.NotesTemplate WHERE IsActive = 1) AS Templates;
PRINT '== 12_NotesInsights_SeedLabDefaults.sql complete ==';
GO
