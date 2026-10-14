-- Collection Insights template: rename Total Bill / Total Billed -> Total Balance
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.NotesTemplateColumn', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.NotesTemplate', 'U') IS NOT NULL
   AND OBJECT_ID('dbo.NotesReport', 'U') IS NOT NULL
BEGIN
    UPDATE c
    SET c.ColumnName = N'Total Balance'
    FROM dbo.NotesTemplateColumn c
    INNER JOIN dbo.NotesTemplate t ON t.TemplateId = c.TemplateId
    INNER JOIN dbo.NotesReport r ON r.ReportKeyId = t.ReportKeyId
    WHERE r.ReportName = N'Collection Report'
      AND t.TemplateName = N'Key Insights & Highlights'
      AND (
            c.FieldKey = N'TotalCharge'
            OR c.ColumnName IN (N'Total Bill', N'Total Billed')
          );
END
GO
