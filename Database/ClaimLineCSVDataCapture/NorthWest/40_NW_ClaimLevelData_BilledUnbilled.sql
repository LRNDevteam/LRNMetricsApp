/* =============================================================================
   NorthWest - ClaimLevelData.BilledUnbilled
   File     : 40_NW_ClaimLevelData_BilledUnbilled.sql
   Database : NWL_LRN

   BilledUnbilled (NVARCHAR(250) NULL):
     1. FirstBilledDate is a date                                   -> 'Billed'
     2. FirstBilledDate blank and EmedixSubmissionDate is a date    -> 'Billed'
     3. FirstBilledDate blank and EmedixSubmissionDate blank        -> 'UnBilled'
     ClaimType does not affect the value. Any other value (non-date text) is UnBilled.
     Stored text stays 'UnBilled' so existing filters keep matching.

   DeniedStatus (NVARCHAR(500) NULL), set by the same procedure:
     'Denied' when DenialCodeNormalized has a code AND InsuranceBalance > 0
              AND ClaimStatus IN ('Fully Denied','Partially Denied','Partially Paid' / 'Partial Paid');
     otherwise NULL.

   NWLCollectionPostedDate (NVARCHAR(500) NULL, MM/dd/yyyy like CheckDate):
     1. InsurancePayment > 0 and CheckDate is a date                -> CheckDate
     2. InsurancePayment > 0 and CheckDate blank                    -> ChargeEnteredDate
     otherwise NULL.

   NWLDenialPostedDate (NVARCHAR(500) NULL, MM/dd/yyyy like CheckDate):
     1. CheckDate is a date                                         -> CheckDate (every row)
     2. DenialCode has a code and CheckDate blank                   -> LastActivityDate
     3. DenialCode has a code, CheckDate blank, LastActivityDate blank -> FirstBilledDate
     otherwise NULL. The 12/31/1899 placeholder counts as blank.

   dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled recalculates every row and
   writes only rows whose value changed, so FirstBilledDate / EmedixSubmissionDate
   (and the posted-date sources) updated by a later file are picked up. ClaimLineCSVDataCapture runs it as the
   first step after a new NorthWest RunId. Every run (success or failure) is
   written to dbo.NW_BilledUnbilled_UpdateLog.
   ============================================================================= */

IF DB_NAME() <> N'NWL_LRN'
BEGIN
    RAISERROR(N'40_NW_ClaimLevelData_BilledUnbilled.sql must run on NWL_LRN.', 16, 1);
    SET NOEXEC ON;
END;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'BilledUnbilled') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD BilledUnbilled NVARCHAR(250) NULL;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'DeniedStatus') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD DeniedStatus NVARCHAR(500) NULL;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'NWLCollectionPostedDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD NWLCollectionPostedDate NVARCHAR(500) NULL;
GO

IF COL_LENGTH(N'dbo.ClaimLevelData', N'NWLDenialPostedDate') IS NULL
    ALTER TABLE dbo.ClaimLevelData ADD NWLDenialPostedDate NVARCHAR(500) NULL;
GO

IF OBJECT_ID(N'dbo.NW_BilledUnbilled_UpdateLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.NW_BilledUnbilled_UpdateLog
    (
        LogId              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NW_BilledUnbilled_UpdateLog PRIMARY KEY,
        RunId              NVARCHAR(500)     NULL,
        TriggeredBy        NVARCHAR(100)     NOT NULL,
        StartedAt          DATETIME2(0)      NOT NULL,
        EndedAt            DATETIME2(0)      NULL,
        DurationMs         INT               NULL,
        Status             VARCHAR(20)       NOT NULL,   -- Running / Success / Failed
        TotalRows          INT               NULL,
        BilledFirstBilled  INT               NULL,       -- condition 1
        BilledEmedix       INT               NULL,       -- condition 2
        UnBilledBlank      INT               NULL,       -- condition 3
        UnBilledOther      INT               NULL,       -- non-date text
        RowsUpdated        INT               NULL,
        ErrorMessage       NVARCHAR(4000)    NULL
    );
END;
GO

IF COL_LENGTH(N'dbo.NW_BilledUnbilled_UpdateLog', N'CollectionPostedCheckDate') IS NULL
    ALTER TABLE dbo.NW_BilledUnbilled_UpdateLog ADD
        CollectionPostedCheckDate     INT NULL,   -- NWLCollectionPostedDate condition 1
        CollectionPostedChargeEntered INT NULL,   -- NWLCollectionPostedDate condition 2
        DenialPostedLastActivity      INT NULL,   -- NWLDenialPostedDate condition 2
        DenialPostedFirstBilled       INT NULL,   -- NWLDenialPostedDate condition 3
        PostedDatesRowsUpdated        INT NULL;
GO

IF COL_LENGTH(N'dbo.NW_BilledUnbilled_UpdateLog', N'DenialPostedCheckDate') IS NULL
    ALTER TABLE dbo.NW_BilledUnbilled_UpdateLog ADD
        DenialPostedCheckDate         INT NULL;   -- NWLDenialPostedDate condition 1
GO

SET ANSI_NULLS ON;
GO
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled
    @RunId       NVARCHAR(500) = NULL,
    @TriggeredBy NVARCHAR(100) = N'Manual'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Started DATETIME2(3) = SYSDATETIME();
    DECLARE @LogId INT;
    DECLARE @Updated INT = 0;
    DECLARE @PostedUpdated INT = 0;

    INSERT INTO dbo.NW_BilledUnbilled_UpdateLog (RunId, TriggeredBy, StartedAt, Status)
    VALUES (@RunId, ISNULL(NULLIF(LTRIM(RTRIM(@TriggeredBy)), N''), N'Manual'), @Started, 'Running');
    SET @LogId = SCOPE_IDENTITY();

    BEGIN TRY
        ;WITH Src AS
        (
            SELECT
                cl.BilledUnbilled,
                NewValue = CASE
                    WHEN d.FirstBilled IS NOT NULL
                        THEN N'Billed'
                    WHEN d.FirstBilled IS NULL AND d.Emedix IS NOT NULL
                        THEN N'Billed'
                    ELSE N'UnBilled'
                END
            FROM dbo.ClaimLevelData cl
            CROSS APPLY (SELECT
                FirstRaw = NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), N''),
                EmedixRaw = NULLIF(LTRIM(RTRIM(cl.EmedixSubmissionDate)), N'')) r
            CROSS APPLY (SELECT
                FirstBilled = TRY_CAST(r.FirstRaw AS DATE),
                Emedix      = TRY_CAST(r.EmedixRaw AS DATE)) d
        )
        UPDATE Src
        SET    BilledUnbilled = NewValue
        WHERE  BilledUnbilled IS NULL OR BilledUnbilled <> NewValue;

        SET @Updated = @@ROWCOUNT;

        ;WITH Den AS
        (
            SELECT
                cl.DeniedStatus,
                NewValue = CASE
                    WHEN NULLIF(LTRIM(RTRIM(cl.DenialCodeNormalized)), N'') IS NOT NULL
                     AND TRY_CAST(cl.InsuranceBalance AS DECIMAL(18,2)) > 0
                     AND LTRIM(RTRIM(cl.ClaimStatus)) IN (N'Fully Denied', N'Partially Denied',
                                                          N'Partially Paid', N'Partial Paid')
                        THEN N'Denied'
                END
            FROM dbo.ClaimLevelData cl
        )
        UPDATE Den
        SET    DeniedStatus = NewValue
        WHERE  ISNULL(DeniedStatus, N'') <> ISNULL(NewValue, N'');

        ;WITH Posted AS
        (
            SELECT
                cl.NWLCollectionPostedDate,
                cl.NWLDenialPostedDate,
                NewCollection = CASE
                    WHEN d.InsPay > 0 AND d.CheckDt IS NOT NULL
                        THEN CONVERT(NVARCHAR(10), d.CheckDt, 101)
                    WHEN d.InsPay > 0 AND r.CheckRaw IS NULL
                        THEN CONVERT(NVARCHAR(10), d.ChargeEnteredDt, 101)
                END,
                NewDenial = CASE
                    WHEN p.CheckDt IS NOT NULL
                        THEN CONVERT(NVARCHAR(10), p.CheckDt, 101)
                    WHEN r.DenialRaw IS NOT NULL AND p.CheckDt IS NULL
                        THEN CONVERT(NVARCHAR(10), COALESCE(p.LastActivityDt, p.FirstBilledDt), 101)
                END
            FROM dbo.ClaimLevelData cl
            CROSS APPLY (SELECT
                CheckRaw  = NULLIF(LTRIM(RTRIM(cl.CheckDate)), N''),
                DenialRaw = NULLIF(LTRIM(RTRIM(cl.DenialCode)), N'')) r
            CROSS APPLY (SELECT
                InsPay          = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.InsurancePayment)), N'') AS DECIMAL(18,2)),
                CheckDt         = TRY_CAST(r.CheckRaw AS DATE),
                ChargeEnteredDt = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.ChargeEnteredDate)), N'') AS DATE),
                LastActivityDt  = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.LastActivityDate)), N'') AS DATE),
                FirstBilledDt   = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), N'') AS DATE)) d
            -- NWLDenialPostedDate sources: 12/31/1899 is the file's blank-date placeholder.
            CROSS APPLY (SELECT
                CheckDt        = CASE WHEN d.CheckDt        >= '19010101' THEN d.CheckDt        END,
                LastActivityDt = CASE WHEN d.LastActivityDt >= '19010101' THEN d.LastActivityDt END,
                FirstBilledDt  = CASE WHEN d.FirstBilledDt  >= '19010101' THEN d.FirstBilledDt  END) p
        )
        UPDATE Posted
        SET    NWLCollectionPostedDate = NewCollection,
               NWLDenialPostedDate     = NewDenial
        WHERE  ISNULL(NWLCollectionPostedDate, N'') <> ISNULL(NewCollection, N'')
            OR ISNULL(NWLDenialPostedDate, N'')     <> ISNULL(NewDenial, N'');

        SET @PostedUpdated = @@ROWCOUNT;

        DECLARE @Total INT, @B1 INT, @B2 INT, @U3 INT, @UX INT;
        DECLARE @C1 INT, @C2 INT, @D0 INT, @D1 INT, @D2 INT;
        SELECT
            @Total = COUNT(*),
            @B1 = SUM(CASE WHEN d.FirstBilled IS NOT NULL THEN 1 ELSE 0 END),
            @B2 = SUM(CASE WHEN d.FirstBilled IS NULL AND d.Emedix IS NOT NULL THEN 1 ELSE 0 END),
            @U3 = SUM(CASE WHEN r.FirstRaw IS NULL AND r.EmedixRaw IS NULL THEN 1 ELSE 0 END),
            @C1 = SUM(CASE WHEN d.InsPay > 0 AND d.CheckDt IS NOT NULL THEN 1 ELSE 0 END),
            @C2 = SUM(CASE WHEN d.InsPay > 0 AND r.CheckRaw IS NULL AND d.ChargeEnteredDt IS NOT NULL THEN 1 ELSE 0 END),
            @D0 = SUM(CASE WHEN p.CheckDt IS NOT NULL THEN 1 ELSE 0 END),
            @D1 = SUM(CASE WHEN r.DenialRaw IS NOT NULL AND p.CheckDt IS NULL AND p.LastActivityDt IS NOT NULL THEN 1 ELSE 0 END),
            @D2 = SUM(CASE WHEN r.DenialRaw IS NOT NULL AND p.CheckDt IS NULL AND p.LastActivityDt IS NULL
                            AND p.FirstBilledDt IS NOT NULL THEN 1 ELSE 0 END)
        FROM dbo.ClaimLevelData cl
        CROSS APPLY (SELECT
            FirstRaw  = NULLIF(LTRIM(RTRIM(cl.FirstBilledDate)), N''),
            EmedixRaw = NULLIF(LTRIM(RTRIM(cl.EmedixSubmissionDate)), N''),
            CheckRaw  = NULLIF(LTRIM(RTRIM(cl.CheckDate)), N''),
            DenialRaw = NULLIF(LTRIM(RTRIM(cl.DenialCode)), N'')) r
        CROSS APPLY (SELECT
            FirstBilled     = TRY_CAST(r.FirstRaw AS DATE),
            Emedix          = TRY_CAST(r.EmedixRaw AS DATE),
            InsPay          = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.InsurancePayment)), N'') AS DECIMAL(18,2)),
            CheckDt         = TRY_CAST(r.CheckRaw AS DATE),
            ChargeEnteredDt = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.ChargeEnteredDate)), N'') AS DATE),
            LastActivityDt  = TRY_CAST(NULLIF(LTRIM(RTRIM(cl.LastActivityDate)), N'') AS DATE),
            FirstBilledDt   = TRY_CAST(r.FirstRaw AS DATE)) d
        CROSS APPLY (SELECT
            CheckDt        = CASE WHEN d.CheckDt        >= '19010101' THEN d.CheckDt        END,
            LastActivityDt = CASE WHEN d.LastActivityDt >= '19010101' THEN d.LastActivityDt END,
            FirstBilledDt  = CASE WHEN d.FirstBilledDt  >= '19010101' THEN d.FirstBilledDt  END) p;
        SET @UX = @Total - ISNULL(@B1, 0) - ISNULL(@B2, 0) - ISNULL(@U3, 0);

        UPDATE dbo.NW_BilledUnbilled_UpdateLog
        SET    EndedAt           = SYSDATETIME(),
               DurationMs        = DATEDIFF(MILLISECOND, @Started, SYSDATETIME()),
               Status            = 'Success',
               TotalRows         = @Total,
               BilledFirstBilled = ISNULL(@B1, 0),
               BilledEmedix      = ISNULL(@B2, 0),
               UnBilledBlank     = ISNULL(@U3, 0),
               UnBilledOther     = @UX,
               RowsUpdated       = @Updated,
               CollectionPostedCheckDate     = ISNULL(@C1, 0),
               CollectionPostedChargeEntered = ISNULL(@C2, 0),
               DenialPostedCheckDate         = ISNULL(@D0, 0),
               DenialPostedLastActivity      = ISNULL(@D1, 0),
               DenialPostedFirstBilled       = ISNULL(@D2, 0),
               PostedDatesRowsUpdated        = @PostedUpdated
        WHERE  LogId = @LogId;

        SELECT LogId = @LogId, TotalRows = @Total, BilledFirstBilled = ISNULL(@B1, 0),
               BilledEmedix = ISNULL(@B2, 0), UnBilledBlank = ISNULL(@U3, 0),
               UnBilledOther = @UX, RowsUpdated = @Updated,
               CollectionPostedCheckDate     = ISNULL(@C1, 0),
               CollectionPostedChargeEntered = ISNULL(@C2, 0),
               DenialPostedCheckDate         = ISNULL(@D0, 0),
               DenialPostedLastActivity      = ISNULL(@D1, 0),
               DenialPostedFirstBilled       = ISNULL(@D2, 0),
               PostedDatesRowsUpdated        = @PostedUpdated,
               DurationMs = DATEDIFF(MILLISECOND, @Started, SYSDATETIME());
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;

        UPDATE dbo.NW_BilledUnbilled_UpdateLog
        SET    EndedAt      = SYSDATETIME(),
               DurationMs   = DATEDIFF(MILLISECOND, @Started, SYSDATETIME()),
               Status       = 'Failed',
               RowsUpdated  = 0,
               ErrorMessage = LEFT(ERROR_MESSAGE(), 4000)
        WHERE  LogId = @LogId;

        THROW;
    END CATCH;
END;
GO

EXEC dbo.usp_UpdateNW_ClaimLevelData_BilledUnbilled @TriggeredBy = N'40_NW_ClaimLevelData_BilledUnbilled.sql';
GO

PRINT '40_NW_ClaimLevelData_BilledUnbilled.sql completed.';
GO
