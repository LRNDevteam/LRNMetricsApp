/* ============================================================================================
   AR Workbench - 09 Legacy CIP conversion (T063). Run in each lab database AFTER scripts 01-07.

   Converts the Denial Workflow's EXTERNAL escalations (dbo.DenialClaimEscalations escalated to a
   Client / Account Manager) and their External Responses / Account Manager notes into AR Workbench
   CIP cases, so the CIP Escalations queue starts with the history the team already has.

     Denial Workflow escalation                          -> ARWB_CipCase
       open (no response yet)                            -> Sent to Client (it already went out)
       responded ('Account Manager Response:', 'Client
         Response:', 'Manager Response:' in Comments,
         or status responded / response submitted)       -> Client Responded (response text extracted)
       resolved / closed / write-off approved|rejected   -> Returned to Agent (closed)
     EscalationReason -> CipCategory, RecommendedNextAction -> RequiredInfo,
     Comments before the response marker -> CipComment, CreatedBy / CreatedOn -> RequestedBy / On.

   Read-only on the Denial Workflow tables. Re-runnable: dbo.ARWB_CipCaseLegacyMap records each
   converted escalation, so a second run only adds new ones. Claims are matched on ClaimID (with or
   without the 'CLM-' prefix); escalations for claims not in the workbench are skipped.

   EXEC dbo.ARWB_usp_ConvertLegacyEscalations @PreviewOnly = 1;   -- counts only
   EXEC dbo.ARWB_usp_ConvertLegacyEscalations @RunBy = N'name';   -- convert
   ============================================================================================ */
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
SET NOCOUNT ON;
GO

IF OBJECT_ID(N'dbo.ARWB_CipCaseLegacyMap', N'U') IS NULL
CREATE TABLE dbo.ARWB_CipCaseLegacyMap
(
    SourceEscalationId      bigint         NOT NULL CONSTRAINT PK_ARWB_CipCaseLegacyMap PRIMARY KEY,   -- dbo.DenialClaimEscalations.EscalationId
    CipCaseId               bigint         NOT NULL CONSTRAINT FK_ARWB_CipCaseLegacyMap_Case REFERENCES dbo.ARWB_CipCase (CipCaseId),
    ConvertedOn             datetime2(0)   NOT NULL CONSTRAINT DF_ARWB_CipCaseLegacyMap_On DEFAULT (SYSUTCDATETIME()),
    ConvertedBy             nvarchar(256)  NOT NULL
);
GO

CREATE OR ALTER PROCEDURE dbo.ARWB_usp_ConvertLegacyEscalations
    @RunBy          nvarchar(256) = N'System',
    @PreviewOnly    bit           = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    IF OBJECT_ID(N'dbo.DenialClaimEscalations', N'U') IS NULL
       OR COL_LENGTH(N'dbo.DenialClaimEscalations', N'EscalatedTo') IS NULL
       OR COL_LENGTH(N'dbo.DenialClaimEscalations', N'EscalatedToRole') IS NULL
    BEGIN
        SELECT Candidates = 0, Converted = 0, SentToClient = 0, ClientResponded = 0, ReturnedToAgent = 0, NoMatchingClaim = 0,
               Note = N'dbo.DenialClaimEscalations (with EscalatedTo / EscalatedToRole) is not in this database - nothing to convert.';
        RETURN;
    END;

    CREATE TABLE #src
    (
        EscalationId bigint NOT NULL PRIMARY KEY, ClaimId nvarchar(150) NOT NULL, Reason nvarchar(300) NULL, NextAction nvarchar(150) NULL,
        Comments nvarchar(max) NULL, Status nvarchar(50) NULL, CreatedBy nvarchar(256) NOT NULL, CreatedOn datetime2(0) NOT NULL
    );

    -- Dynamic: RecommendedNextAction is a later column; older labs do not have it.
    DECLARE @nextAction nvarchar(100) = CASE WHEN COL_LENGTH(N'dbo.DenialClaimEscalations', N'RecommendedNextAction') IS NULL THEN N'NULL' ELSE N'e.RecommendedNextAction' END;
    DECLARE @sql nvarchar(max) = N'
INSERT INTO #src (EscalationId, ClaimId, Reason, NextAction, Comments, Status, CreatedBy, CreatedOn)
SELECT e.EscalationId, LTRIM(RTRIM(e.ClaimId)), e.EscalationReason, ' + @nextAction + N', e.Comments, e.Status, e.CreatedBy, e.CreatedOn
FROM dbo.DenialClaimEscalations e
WHERE e.IsDeleted = 0
  AND (LOWER(ISNULL(e.EscalatedToRole, N'''')) LIKE N''%clientmanager%'' OR LOWER(ISNULL(e.EscalatedToRole, N'''')) LIKE N''%accountmanager%''
       OR LOWER(ISNULL(e.EscalatedTo, N'''')) LIKE N''%client manager%'' OR LOWER(ISNULL(e.EscalatedTo, N'''')) LIKE N''%account manager%'')
  AND NOT EXISTS (SELECT 1 FROM dbo.ARWB_CipCaseLegacyMap m WHERE m.SourceEscalationId = e.EscalationId);';
    EXEC sys.sp_executesql @sql;

    CREATE TABLE #conv
    (
        EscalationId bigint NOT NULL PRIMARY KEY, ClaimKey bigint NULL, AgentUser nvarchar(256) NULL, ClinicName nvarchar(500) NULL,
        CaseStatus varchar(30) NOT NULL, Category nvarchar(200) NOT NULL, RequiredInfo nvarchar(400) NOT NULL, CipComment nvarchar(4000) NOT NULL,
        ResponseText nvarchar(4000) NULL, CreatedBy nvarchar(256) NOT NULL, CreatedOn datetime2(0) NOT NULL
    );

    INSERT INTO #conv (EscalationId, ClaimKey, AgentUser, ClinicName, CaseStatus, Category, RequiredInfo, CipComment, ResponseText, CreatedBy, CreatedOn)
    SELECT s.EscalationId, w.ClaimKey, w.AssignedAgentUser, w.ClinicName,
           CASE WHEN st.IsClosed = 1 THEN 'Returned to Agent'
                WHEN mk.Pos > 0 OR st.IsResponded = 1 THEN 'Client Responded'
                ELSE 'Sent to Client' END,
           LEFT(ISNULL(NULLIF(LTRIM(RTRIM(s.Reason)), N''), N'Legacy External Escalation'), 200),
           LEFT(ISNULL(NULLIF(LTRIM(RTRIM(s.NextAction)), N''), N'See the escalation note'), 400),
           LEFT(ISNULL(NULLIF(LTRIM(RTRIM(CASE WHEN mk.Pos > 0 THEN LEFT(s.Comments, mk.Pos - 1) ELSE s.Comments END)), N''), N'(No note on the original escalation.)'), 4000),
           CASE WHEN mk.Pos > 0 THEN LEFT(LTRIM(RTRIM(SUBSTRING(s.Comments, mk.Pos + mk.Len, 4000))), 4000) END,
           s.CreatedBy, s.CreatedOn
    FROM #src s
    -- Claim match: same id, or the Denial Workflow's 'CLM-' form
    OUTER APPLY (SELECT TOP (1) c.ClaimKey, c.AssignedAgentUser, c.ClinicName
                 FROM dbo.ARWB_Claim c
                 WHERE c.ClaimID = s.ClaimId OR c.ClaimID = REPLACE(s.ClaimId, N'CLM-', N'') OR N'CLM-' + c.ClaimID = s.ClaimId) w
    -- The earliest response marker in the comments, if any
    OUTER APPLY (SELECT TOP (1) Pos = x.Pos, Len = x.Len
                 FROM (VALUES (CHARINDEX(N'Account Manager Response:', ISNULL(s.Comments, N'')), 25),
                              (CHARINDEX(N'Client Response:', ISNULL(s.Comments, N'')), 16),
                              (CHARINDEX(N'Manager Response:', ISNULL(s.Comments, N'')), 17)) x (Pos, Len)
                 WHERE x.Pos > 0 ORDER BY x.Pos) mk0
    CROSS APPLY (SELECT Pos = ISNULL(mk0.Pos, 0), Len = ISNULL(mk0.Len, 0)) mk
    CROSS APPLY (SELECT IsClosed = CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(s.Status, N'')))) IN (N'resolved', N'closed', N'writeoffapproved', N'writeoffrejected') THEN 1 ELSE 0 END,
                        IsResponded = CASE WHEN LOWER(LTRIM(RTRIM(ISNULL(s.Status, N'')))) IN (N'responded', N'response submitted', N'manager response', N'in review') THEN 1 ELSE 0 END) st;

    IF @PreviewOnly = 1
    BEGIN
        SELECT Candidates = COUNT(*),
               Converted = 0,
               SentToClient = SUM(CASE WHEN ClaimKey IS NOT NULL AND CaseStatus = 'Sent to Client' THEN 1 ELSE 0 END),
               ClientResponded = SUM(CASE WHEN ClaimKey IS NOT NULL AND CaseStatus = 'Client Responded' THEN 1 ELSE 0 END),
               ReturnedToAgent = SUM(CASE WHEN ClaimKey IS NOT NULL AND CaseStatus = 'Returned to Agent' THEN 1 ELSE 0 END),
               NoMatchingClaim = SUM(CASE WHEN ClaimKey IS NULL THEN 1 ELSE 0 END),
               Note = CAST(NULL AS nvarchar(400))
        FROM #conv;
        RETURN;
    END;

    DECLARE @Now datetime2(0) = SYSUTCDATETIME();
    DECLARE @made TABLE (CipCaseId bigint NOT NULL, EscalationId bigint NOT NULL);

    BEGIN TRANSACTION;

    -- MERGE so the new case id comes back paired with its source escalation.
    MERGE dbo.ARWB_CipCase AS t
    USING (SELECT * FROM #conv WHERE ClaimKey IS NOT NULL) AS s ON 1 = 0
    WHEN NOT MATCHED THEN
        INSERT (ClaimKey, CipCategory, RequiredInfo, CipComment, CaseStatus, RoundNumber, OriginalAgentUser, ClinicName,
                RequestedBy, RequestedByRole, RequestedOn, FollowUpDate, ClientResponseText, ClientRespondedBy, ClientRespondedByRole, ClientRespondedOn, ClosedOn,
                LastReviewDecision, LastReviewNote, LastReviewedBy, LastReviewedOn)
        VALUES (s.ClaimKey, s.Category, s.RequiredInfo, s.CipComment, s.CaseStatus, 1, ISNULL(s.AgentUser, s.CreatedBy), s.ClinicName,
                s.CreatedBy, 'legacy', s.CreatedOn, CONVERT(date, s.CreatedOn),
                s.ResponseText, CASE WHEN s.ResponseText IS NOT NULL THEN N'Account / Client Manager' END,
                CASE WHEN s.ResponseText IS NOT NULL THEN 'viewer' END,
                CASE WHEN s.ResponseText IS NOT NULL THEN s.CreatedOn END,
                CASE WHEN s.CaseStatus = 'Returned to Agent' THEN @Now END,
                CASE WHEN s.CaseStatus = 'Returned to Agent' THEN 'approved' END,
                CASE WHEN s.CaseStatus = 'Returned to Agent' THEN N'Closed in the Denial Workflow before conversion.' END,
                CASE WHEN s.CaseStatus = 'Returned to Agent' THEN @RunBy END,
                CASE WHEN s.CaseStatus = 'Returned to Agent' THEN @Now END)
    OUTPUT inserted.CipCaseId, s.EscalationId INTO @made (CipCaseId, EscalationId);

    INSERT INTO dbo.ARWB_CipCaseLegacyMap (SourceEscalationId, CipCaseId, ConvertedBy)
    SELECT m.EscalationId, m.CipCaseId, @RunBy FROM @made m;

    INSERT INTO dbo.ARWB_CipCaseHistory (CipCaseId, RoundNumber, ActionOn, Actor, ActorRole, ActionName, Note)
    SELECT m.CipCaseId, 1, c.CreatedOn, c.CreatedBy, 'legacy', N'Converted from Denial Workflow External Escalation',
           N'Denial Workflow escalation #' + CONVERT(nvarchar(20), c.EscalationId) + N' converted by ' + @RunBy + N'.'
    FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId;

    INSERT INTO dbo.ARWB_CipCaseHistory (CipCaseId, RoundNumber, ActionOn, Actor, ActorRole, ActionName, Note)
    SELECT m.CipCaseId, 1, c.CreatedOn, N'Account / Client Manager', 'viewer', N'Client Responded', LEFT(c.ResponseText, 4000)
    FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId
    WHERE c.ResponseText IS NOT NULL;

    INSERT INTO dbo.ARWB_ClaimActivity (ClaimKey, ActivityOn, ActionType, Detail, NewValue, UserName, RoleCode, IsSystem, RelatedEntityType, RelatedEntityId)
    SELECT c.ClaimKey, @Now, N'CIP Case Converted',
           N'Denial Workflow external escalation #' + CONVERT(nvarchar(20), c.EscalationId) + N' brought into CIP Escalations as ' + c.CaseStatus + N'.',
           c.CaseStatus, @RunBy, 'admin', 1, 'CipCase', m.CipCaseId
    FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId;

    COMMIT TRANSACTION;

    DECLARE @List nvarchar(max) = STUFF((SELECT DISTINCT N',' + CONVERT(nvarchar(20), c.ClaimKey)
                                        FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId
                                        FOR XML PATH(''), TYPE).value('.', 'nvarchar(max)'), 1, 1, N'');
    IF @List IS NOT NULL
    BEGIN
        CREATE TABLE #recalc (UpdatedClaims int);
        INSERT INTO #recalc EXEC dbo.ARWB_usp_RecalculateClaimState @ClaimKeyList = @List;
    END;

    SELECT Candidates = (SELECT COUNT(*) FROM #conv),
           Converted = (SELECT COUNT(*) FROM @made),
           SentToClient = (SELECT COUNT(*) FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId WHERE c.CaseStatus = 'Sent to Client'),
           ClientResponded = (SELECT COUNT(*) FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId WHERE c.CaseStatus = 'Client Responded'),
           ReturnedToAgent = (SELECT COUNT(*) FROM @made m INNER JOIN #conv c ON c.EscalationId = m.EscalationId WHERE c.CaseStatus = 'Returned to Agent'),
           NoMatchingClaim = (SELECT COUNT(*) FROM #conv WHERE ClaimKey IS NULL),
           Note = CAST(NULL AS nvarchar(400));
END;
GO

PRINT 'AR Workbench 09: dbo.ARWB_usp_ConvertLegacyEscalations ready.';
GO
