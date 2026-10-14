SET NOCOUNT ON;
GO

PRINT 'Dropping stored procedure dbo.usp_BulkInsertLineLevelData if it exists...';
IF OBJECT_ID('dbo.usp_BulkInsertLineLevelData', 'P') IS NOT NULL
BEGIN
	DROP PROCEDURE dbo.usp_BulkInsertLineLevelData;
END
GO

PRINT 'Dropping type dbo.LineLevelDataTVP if it exists...';
IF TYPE_ID('dbo.LineLevelDataTVP') IS NOT NULL
BEGIN
	DROP TYPE dbo.LineLevelDataTVP;
END
GO

PRINT 'Creating type dbo.LineLevelDataTVP (InHealthDTR)...';
-- Column order MUST match the field order in InHealthDTRFieldMappings.json LineLevel > Fields.
-- System columns (FileLogId..RowHash) are always first; then all mapped SQL columns in JSON order.
CREATE TYPE dbo.LineLevelDataTVP AS TABLE
(
	-- System columns (injected by the application)
	FileLogId                        NVARCHAR(500),
	RunId                            NVARCHAR(500),
	WeekFolder                       NVARCHAR(500),
	SourceFullPath                   NVARCHAR(1000),
	FileName                         NVARCHAR(500),
	FileType                         NVARCHAR(100),
	RowHash                          NVARCHAR(64),

	-- CSV-mapped columns (in InHealthDTRFieldMappings.json LineLevel field order)
	LabID                            NVARCHAR(500),
	LabName                          NVARCHAR(500),
	ClaimID                          NVARCHAR(500),
	AccessionNumber                  NVARCHAR(500),
	SourceFileID                     NVARCHAR(1000),
	IngestedOn                       NVARCHAR(500),
	CsvRowHash                       NVARCHAR(500),
	PayerName_Raw                    NVARCHAR(500),
	PayerName                        NVARCHAR(500),
	Payer_Code                       NVARCHAR(500),
	Payer_Common_Code                NVARCHAR(500),
	Payer_Group_Code                 NVARCHAR(500),
	Global_Payer_ID                  NVARCHAR(500),
	PayerType                        NVARCHAR(500),
	BillingProvider                  NVARCHAR(500),
	ReferringProvider                NVARCHAR(500),
	ClinicName                       NVARCHAR(500),
	SalesRepname                     NVARCHAR(500),
	PatientID                        NVARCHAR(500),
	PatientDOB                       NVARCHAR(500),
	DateofService                    NVARCHAR(500),
	ChargeEnteredDate                NVARCHAR(500),
	FirstBilledDate                  NVARCHAR(500),
	Panelname                        NVARCHAR(500),
	CPTCode                          NVARCHAR(500),
	Units                            NVARCHAR(500),
	Modifier                         NVARCHAR(500),
	POS                              NVARCHAR(500),
	TOS                              NVARCHAR(500),
	ChargeAmount                     NVARCHAR(500),
	ChargeAmountPerUnit              NVARCHAR(500),
	AllowedAmount                    NVARCHAR(500),
	AllowedAmountPerUnit             NVARCHAR(500),
	InsurancePayment                 NVARCHAR(500),
	InsurancePaymentPerUnit          NVARCHAR(500),
	PatientPayment                   NVARCHAR(500),
	PatientPaymentPerUnit            NVARCHAR(500),
	TotalPayments                    NVARCHAR(500),
	InsuranceAdjustments             NVARCHAR(500),
	PatientAdjustments               NVARCHAR(500),
	TotalAdjustments                 NVARCHAR(500),
	InsuranceBalance                 NVARCHAR(500),
	PatientBalance                   NVARCHAR(500),
	PatientBalancePerUnit            NVARCHAR(500),
	TotalBalance                     NVARCHAR(500),
	CheckDate                        NVARCHAR(500),
	PaymentPostedDate                NVARCHAR(500),
	ClaimStatus                      NVARCHAR(500),
	PayStatus                        NVARCHAR(500),
	DenialCode                       NVARCHAR(MAX),
	DenialDate                       NVARCHAR(500),
	ICDCode                          NVARCHAR(500),
	DaystoDOS                        NVARCHAR(500),
	RollingDays                      NVARCHAR(500),
	DaystoBill                       NVARCHAR(500),
	DaystoPost                       NVARCHAR(500),
	ICDPointer                       NVARCHAR(500),
	PatientName                      NVARCHAR(1000),
	ResponsibleParty                 NVARCHAR(500),
	SubscriberID                     NVARCHAR(1000),
	EndDOS                           NVARCHAR(500),
	BillOccurance                    NVARCHAR(500),
	EntryUser                        NVARCHAR(500),
	CPTUnits                         NVARCHAR(500),
	CPTMOD                           NVARCHAR(500),
	CPTs                             NVARCHAR(MAX),
	PostedWeek                       NVARCHAR(500)
);
GO

CREATE PROCEDURE dbo.usp_BulkInsertLineLevelData
	@Rows                dbo.LineLevelDataTVP READONLY,
	@LabName             NVARCHAR(500),
	@WeekFolder          NVARCHAR(500),
	@SourceFilePath      NVARCHAR(1000),
	@RunId               NVARCHAR(500),
	@FileName            NVARCHAR(500),
	@FileCreatedDateTime DATETIME = NULL,
	@ChunkSize           INT = 5000
AS
BEGIN
	SET NOCOUNT ON;

	IF EXISTS (SELECT 1 FROM dbo.LineClaimFileLogs WHERE RunId = @RunId AND FileType = 'linelevel')
	BEGIN
		SELECT 0 AS InsertedCount;
		RETURN;
	END

	DECLARE @FileLogId INT;

	INSERT INTO dbo.LineClaimFileLogs
		(RunId, WeekFolder, LabName, SourceFullPath, FileName, FileType, FileCreatedDateTime)
	VALUES
		(@RunId, @WeekFolder, @LabName, @SourceFilePath, @FileName, 'linelevel', @FileCreatedDateTime);

	SET @FileLogId = SCOPE_IDENTITY();

	-- Archive existing rows before full replacement
	IF EXISTS (SELECT 1 FROM dbo.LineLevelData)
	BEGIN
		DELETE FROM dbo.LineLevelData;
	END

	DECLARE @InsertOffset INT = 0;
	DECLARE @InsertBatch  INT = 1;

	WHILE @InsertBatch > 0
	BEGIN
		INSERT INTO dbo.LineLevelData
		(
			FileLogId, RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
			LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
			PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
			BillingProvider, ReferringProvider, ClinicName, SalesRepname,
			PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
			Panelname, CPTCode, Units, Modifier, POS, TOS,
			ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
			InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
			TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
			InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
			CheckDate, PaymentPostedDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
			ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
			PatientName, ResponsibleParty, SubscriberID, EndDOS, BillOccurance, EntryUser,
			CPTUnits, CPTMOD, CPTs, PostedWeek
		)
		SELECT
			CAST(@FileLogId AS NVARCHAR(500)), RunId, WeekFolder, SourceFullPath, FileName, FileType, RowHash,
			LabID, LabName, ClaimID, AccessionNumber, SourceFileID, IngestedOn, CsvRowHash,
			PayerName_Raw, PayerName, Payer_Code, Payer_Common_Code, Payer_Group_Code, Global_Payer_ID, PayerType,
			BillingProvider, ReferringProvider, ClinicName, SalesRepname,
			PatientID, PatientDOB, DateofService, ChargeEnteredDate, FirstBilledDate,
			Panelname, CPTCode, Units, Modifier, POS, TOS,
			ChargeAmount, ChargeAmountPerUnit, AllowedAmount, AllowedAmountPerUnit,
			InsurancePayment, InsurancePaymentPerUnit, PatientPayment, PatientPaymentPerUnit,
			TotalPayments, InsuranceAdjustments, PatientAdjustments, TotalAdjustments,
			InsuranceBalance, PatientBalance, PatientBalancePerUnit, TotalBalance,
			CheckDate, PaymentPostedDate, ClaimStatus, PayStatus, DenialCode, DenialDate,
			ICDCode, DaystoDOS, RollingDays, DaystoBill, DaystoPost, ICDPointer,
			PatientName, ResponsibleParty, SubscriberID, EndDOS, BillOccurance, EntryUser,
			CPTUnits, CPTMOD, CPTs, PostedWeek
		FROM @Rows
		ORDER BY (SELECT NULL)
		OFFSET @InsertOffset ROWS FETCH NEXT @ChunkSize ROWS ONLY;

		SET @InsertBatch  = @@ROWCOUNT;
		SET @InsertOffset = @InsertOffset + @ChunkSize;
	END

	SELECT @InsertOffset AS InsertedCount;
END;
GO

PRINT 'InHealthDTR LineLevel TVP/SP recreate script completed.';
