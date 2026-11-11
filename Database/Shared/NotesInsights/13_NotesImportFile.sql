-- ============================================================
-- Script  : 13_NotesImportFile.sql
-- Feature : Key Insights & Highlights import (LIS / Production / Collection)
-- Purpose : Keeps every imported Key Insights workbook, as uploaded, so it can be
--           downloaded again from the report's Import dialog (Imported files).
-- Note    : LabMetricsDashboard creates the same table on first use
--           (SqlNotesImportFileRepository); this script is for running it ahead of time.
-- Run     : On each lab database, after 01-12.
-- ============================================================
SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

IF OBJECT_ID('dbo.NotesImportFile', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.NotesImportFile
    (
        ImportFileId     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NotesImportFile PRIMARY KEY,
        ReportName       NVARCHAR(200)  NOT NULL,
        FileName         NVARCHAR(260)  NOT NULL,
        ContentType      NVARCHAR(150)  NULL,
        FileSize         BIGINT         NOT NULL,
        FileContent      VARBINARY(MAX) NOT NULL,
        WeekRangeText    NVARCHAR(100)  NULL,
        WeekRangeStart   DATE           NULL,
        ReportRunId      NVARCHAR(100)  NULL,
        ImportMode       NVARCHAR(20)   NOT NULL CONSTRAINT DF_NotesImportFile_Mode DEFAULT 'Append',
        RowsImported     INT            NOT NULL CONSTRAINT DF_NotesImportFile_Rows DEFAULT 0,
        RowsReplaced     INT            NOT NULL CONSTRAINT DF_NotesImportFile_Replaced DEFAULT 0,
        ImportedBy       NVARCHAR(256)  NOT NULL,
        ImportedDateTime DATETIME2(0)   NOT NULL CONSTRAINT DF_NotesImportFile_At DEFAULT GETDATE()
    );
    CREATE INDEX IX_NotesImportFile_Report_At ON dbo.NotesImportFile (ReportName, ImportedDateTime DESC);
END
GO

PRINT '== 13_NotesImportFile.sql complete ==';
GO
