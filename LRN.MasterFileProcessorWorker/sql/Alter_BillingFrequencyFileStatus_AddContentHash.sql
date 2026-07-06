-- Adds the ContentHash column used to detect files whose SharePoint eTag /
-- modified date changed without any real content change (e.g. a user opened
-- and closed the file). Safe to run multiple times.

IF COL_LENGTH('dbo.BillingFrequencyFileStatus', 'ContentHash') IS NULL
BEGIN
    ALTER TABLE dbo.BillingFrequencyFileStatus
        ADD ContentHash nvarchar(200) NULL;
END
GO

IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE name = 'IX_BFFS_ContentHash'
      AND object_id = OBJECT_ID('dbo.BillingFrequencyFileStatus'))
BEGIN
    CREATE INDEX IX_BFFS_ContentHash ON dbo.BillingFrequencyFileStatus(LabId, ContentHash);
END
GO
