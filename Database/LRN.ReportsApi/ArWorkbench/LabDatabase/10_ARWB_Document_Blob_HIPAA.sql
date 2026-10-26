/* ============================================================================================
   AR Workbench 10 - document access log hardened for Azure Blob storage (HIPAA).
   Run in: each LAB database, after 01. Idempotent: safe to run again.

   1. ARWB_DocumentAccessLog.AccessType also allows 'Blocked' (a refused download: malware scan
      pending / malicious / unavailable, or a SHA-256 integrity failure) and 'Migrate' (moved from
      the API server disk to Blob).
   2. Detail nvarchar(200): the reason for a block. Never PHI - no file or patient names.
   3. The log is append-only (45 CFR 164.312(b)): UPDATE and DELETE raise error 51000.
   4. Indexes for the migration (local rows) and for "who accessed this document".
   ============================================================================================ */

-- 1. Allow 'Blocked' and 'Migrate' access types
IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ARWB_DocumentAccessLog_Type'
           AND parent_object_id = OBJECT_ID(N'dbo.ARWB_DocumentAccessLog') AND definition NOT LIKE N'%Blocked%')
    ALTER TABLE dbo.ARWB_DocumentAccessLog DROP CONSTRAINT CK_ARWB_DocumentAccessLog_Type;
GO
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = N'CK_ARWB_DocumentAccessLog_Type'
               AND parent_object_id = OBJECT_ID(N'dbo.ARWB_DocumentAccessLog'))
    ALTER TABLE dbo.ARWB_DocumentAccessLog WITH CHECK ADD CONSTRAINT CK_ARWB_DocumentAccessLog_Type
        CHECK (AccessType IN ('View', 'Download', 'Upload', 'Delete', 'Blocked', 'Migrate'));
GO

-- 2. Reason for a block (never PHI)
IF COL_LENGTH(N'dbo.ARWB_DocumentAccessLog', N'Detail') IS NULL
    ALTER TABLE dbo.ARWB_DocumentAccessLog ADD Detail nvarchar(200) NULL;
GO

-- 3. Append-only audit log (HIPAA 164.312(b))
IF OBJECT_ID(N'dbo.TR_ARWB_DocumentAccessLog_AppendOnly', N'TR') IS NULL
    EXEC (N'CREATE TRIGGER dbo.TR_ARWB_DocumentAccessLog_AppendOnly ON dbo.ARWB_DocumentAccessLog
INSTEAD OF UPDATE, DELETE AS
BEGIN
    SET NOCOUNT ON;
    THROW 51000, N''ARWB_DocumentAccessLog is append-only (HIPAA 45 CFR 164.312(b)).'', 1;
END;');
GO

-- 4. Indexes (01 already creates IX_ARWB_DocumentAccessLog_Document; the second statement only covers a database without it)
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_Document_Container' AND object_id = OBJECT_ID(N'dbo.ARWB_Document'))
    CREATE INDEX IX_ARWB_Document_Container ON dbo.ARWB_Document (BlobContainer, DocumentId) INCLUDE (BlobPath, ContentSha256);
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = N'IX_ARWB_DocumentAccessLog_Document' AND object_id = OBJECT_ID(N'dbo.ARWB_DocumentAccessLog'))
    CREATE INDEX IX_ARWB_DocumentAccessLog_Document ON dbo.ARWB_DocumentAccessLog (DocumentId, AccessedOn DESC);
GO

-- Optional, for the DBA: DENY UPDATE, DELETE ON dbo.ARWB_DocumentAccessLog TO [<api sql login>];
PRINT 'AR Workbench 10: document access log hardened for Blob storage.';
GO
