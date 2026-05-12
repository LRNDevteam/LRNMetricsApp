/* Run this once in each lab database before enabling LRN.ReportsApi workflow. */
IF OBJECT_ID('dbo.DenialStatusMaster','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialStatusMaster(StatusId int IDENTITY(1,1) PRIMARY KEY, StatusName nvarchar(100) NOT NULL UNIQUE, IsClosedStatus bit NOT NULL DEFAULT(0), IsVerificationStatus bit NOT NULL DEFAULT(0), SortOrder int NOT NULL DEFAULT(100), IsActive bit NOT NULL DEFAULT(1));
END

IF COL_LENGTH('dbo.DenialStatusMaster','IsClosedStatus') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD IsClosedStatus bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsClosedStatus DEFAULT(0);
IF COL_LENGTH('dbo.DenialStatusMaster','IsVerificationStatus') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD IsVerificationStatus bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsVerificationStatus DEFAULT(0);
IF COL_LENGTH('dbo.DenialStatusMaster','SortOrder') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD SortOrder int NOT NULL CONSTRAINT DF_DenialStatusMaster_SortOrder DEFAULT(100);
IF COL_LENGTH('dbo.DenialStatusMaster','IsActive') IS NULL ALTER TABLE dbo.DenialStatusMaster ADD IsActive bit NOT NULL CONSTRAINT DF_DenialStatusMaster_IsActive DEFAULT(1);
MERGE dbo.DenialStatusMaster AS t USING (VALUES
('Closed',1,0,10),('Completed',1,0,20),('Duplicate',0,1,30),('Verification Pending',0,1,40),('Pending Review',0,0,50),('In-Progress',0,0,60),('New',0,0,70)
) AS s(StatusName,IsClosedStatus,IsVerificationStatus,SortOrder) ON t.StatusName=s.StatusName
WHEN MATCHED THEN UPDATE SET IsClosedStatus=s.IsClosedStatus, IsVerificationStatus=s.IsVerificationStatus, SortOrder=s.SortOrder, IsActive=1
WHEN NOT MATCHED THEN INSERT(StatusName,IsClosedStatus,IsVerificationStatus,SortOrder) VALUES(s.StatusName,s.IsClosedStatus,s.IsVerificationStatus,s.SortOrder);

IF OBJECT_ID('dbo.DenialActionCategoryMaster','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialActionCategoryMaster(ActionCategory nvarchar(255) NOT NULL PRIMARY KEY, Scope nvarchar(50) NOT NULL DEFAULT('CPTLevel'), IsActive bit NOT NULL DEFAULT(1), CreatedOn datetime2(0) NOT NULL DEFAULT(SYSDATETIME()));
END
MERGE dbo.DenialActionCategoryMaster AS t USING (VALUES('Rebill','ClaimLevel')) AS s(ActionCategory,Scope) ON t.ActionCategory=s.ActionCategory
WHEN MATCHED THEN UPDATE SET Scope=s.Scope, IsActive=1
WHEN NOT MATCHED THEN INSERT(ActionCategory,Scope) VALUES(s.ActionCategory,s.Scope);

IF OBJECT_ID('dbo.DenialTaskHistory','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialTaskHistory(
 HistoryId bigint IDENTITY(1,1) PRIMARY KEY, TaskID nvarchar(100) NOT NULL, UniqueTrackId nvarchar(150) NOT NULL, LabId int NULL, RunId nvarchar(100) NULL,
 ActionType nvarchar(100) NOT NULL, OldStatus nvarchar(100) NULL, NewStatus nvarchar(100) NULL, OldAssignedTo nvarchar(255) NULL, NewAssignedTo nvarchar(255) NULL,
 Comments nvarchar(max) NULL, ActionBy nvarchar(255) NULL, ActionDate datetime2(0) NOT NULL DEFAULT(SYSDATETIME()), SnapshotJson nvarchar(max) NULL
);
CREATE INDEX IX_DenialTaskHistory_Lab_UID ON dbo.DenialTaskHistory(LabId, UniqueTrackId, HistoryId DESC);
END

IF OBJECT_ID('dbo.DenialVerificationTask','U') IS NULL
BEGIN
CREATE TABLE dbo.DenialVerificationTask(
 VerificationId bigint IDENTITY(1,1) PRIMARY KEY, TaskID nvarchar(100) NOT NULL, UniqueTrackId nvarchar(150) NOT NULL,
 ClaimID nvarchar(100) NULL, PatientId nvarchar(100) NULL, CPTCode nvarchar(50) NULL, DenialCode nvarchar(100) NULL, DenialDescription nvarchar(500) NULL,
 DenialClassification nvarchar(255) NULL, ActionCode nvarchar(100) NULL, RecommendedAction nvarchar(500) NULL, ActionCategory nvarchar(500) NULL, Task nvarchar(500) NULL, Priority nvarchar(100) NULL,
 InsuranceBalance decimal(18,2) NOT NULL DEFAULT(0), Status nvarchar(100) NULL, AssignedTo nvarchar(255) NULL, DateOpened date NULL, DueDate date NULL,
 ReviewerComments nvarchar(max) NULL, LabId int NULL, LabName nvarchar(255) NULL, OriginalRunId nvarchar(100) NULL, MissingDetectedRunId nvarchar(100) NULL, RunId nvarchar(100) NULL,
 VerificationStatus nvarchar(100) NOT NULL DEFAULT('Pending'), VerificationComments nvarchar(max) NULL, MovedOn datetime2(0) NOT NULL DEFAULT(SYSDATETIME()), VerifiedOn datetime2(0) NULL, VerifiedBy nvarchar(255) NULL
);
CREATE INDEX IX_DenialVerificationTask_Lab_Status_Assigned ON dbo.DenialVerificationTask(LabId, VerificationStatus, AssignedTo);
CREATE INDEX IX_DenialVerificationTask_Lab_UID ON dbo.DenialVerificationTask(LabId, UniqueTrackId);
END

IF COL_LENGTH('dbo.DenialTaskBoard','UniqueTrackId') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD UniqueTrackId nvarchar(150) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerComments') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerComments nvarchar(max) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerUpdatedOn') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedOn datetime2(0) NULL;
IF COL_LENGTH('dbo.DenialTaskBoard','ReviewerUpdatedBy') IS NULL ALTER TABLE dbo.DenialTaskBoard ADD ReviewerUpdatedBy nvarchar(255) NULL;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='IX_DenialTaskBoard_Lab_UID' AND object_id=OBJECT_ID('dbo.DenialTaskBoard')) CREATE INDEX IX_DenialTaskBoard_Lab_UID ON dbo.DenialTaskBoard(LabId, UniqueTrackId);
