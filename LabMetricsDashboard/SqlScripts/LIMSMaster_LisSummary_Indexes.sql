IF OBJECT_ID(N'dbo.LIMSMaster', N'U') IS NOT NULL
BEGIN
    IF COL_LENGTH(N'dbo.LIMSMaster', N'RequestCollectDate') IS NOT NULL
       AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND name = N'IX_LIMSMaster_LisSummary_RequestCollectDate'
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_LIMSMaster_LisSummary_RequestCollectDate
        ON dbo.LIMSMaster (RequestCollectDate)
        INCLUDE (Accession, SourceFile, CreatedOn);
    END;

    IF COL_LENGTH(N'dbo.LIMSMaster', N'ReqReceivedDate') IS NOT NULL
       AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND name = N'IX_LIMSMaster_LisSummary_ReqReceivedDate'
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_LIMSMaster_LisSummary_ReqReceivedDate
        ON dbo.LIMSMaster (ReqReceivedDate)
        INCLUDE (Accession, SourceFile, CreatedOn);
    END;

    IF COL_LENGTH(N'dbo.LIMSMaster', N'ReqReportedDate') IS NOT NULL
       AND NOT EXISTS (
        SELECT 1
        FROM sys.indexes
        WHERE object_id = OBJECT_ID(N'dbo.LIMSMaster')
          AND name = N'IX_LIMSMaster_LisSummary_ReqReportedDate'
    )
    BEGIN
        CREATE NONCLUSTERED INDEX IX_LIMSMaster_LisSummary_ReqReportedDate
        ON dbo.LIMSMaster (ReqReportedDate)
        INCLUDE (Accession, SourceFile, CreatedOn);
    END;
END;
