/* =====================================================================
   Claim/Line page — COMMON filter-option and count SPs

   Deploy on EVERY lab LRN database, then deploy that lab file:
     Sql/ClaimLineDetails_SPs/{Lab}_Details.sql
   (lab-specific SELECT lists from Sql/Select_Script — add/remove columns there).

   Objects in this file:
     dbo.usp_GetClaimLevelFilterOptions
     dbo.usp_GetClaimLevelDetailsCounts
     dbo.usp_GetLineLevelFilterOptions
     dbo.usp_GetLineLevelDetailsCounts
   ===================================================================== */
SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelFilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT LTRIM(RTRIM(PayerType))
    FROM dbo.ClaimLevelData
    WHERE PayerType IS NOT NULL AND LTRIM(RTRIM(PayerType)) <> ''
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(ClaimStatus))
    FROM dbo.ClaimLevelData
    WHERE ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> ''
      AND TRY_CAST(ClaimStatus AS DATE) IS NULL
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(ClinicName))
    FROM dbo.ClaimLevelData
    WHERE ClinicName IS NOT NULL AND LTRIM(RTRIM(ClinicName)) <> ''
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(PayerName))
    FROM dbo.ClaimLevelData
    WHERE PayerName IS NOT NULL AND LTRIM(RTRIM(PayerName)) <> ''
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(PanelName))
    FROM dbo.ClaimLevelData
    WHERE PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> ''
    ORDER BY 1;

    SELECT DISTINCT
        CASE
            WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
            WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
            WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
            WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
            WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
            ELSE '120+'
        END AS AgingBucket
    FROM dbo.ClaimLevelData
    ORDER BY 1;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelFilterOptions
AS
BEGIN
    SET NOCOUNT ON;

    SELECT DISTINCT LTRIM(RTRIM(PayerType))
    FROM dbo.LineLevelData
    WHERE PayerType IS NOT NULL AND LTRIM(RTRIM(PayerType)) <> ''
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(ClaimStatus))
    FROM dbo.LineLevelData
    WHERE ClaimStatus IS NOT NULL AND LTRIM(RTRIM(ClaimStatus)) <> ''
      AND TRY_CAST(ClaimStatus AS DATE) IS NULL
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(PayStatus))
    FROM dbo.LineLevelData
    WHERE PayStatus IS NOT NULL AND LTRIM(RTRIM(PayStatus)) <> ''
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(ClinicName))
    FROM dbo.LineLevelData
    WHERE ClinicName IS NOT NULL AND LTRIM(RTRIM(ClinicName)) <> ''
    ORDER BY 1;

    SELECT DISTINCT LTRIM(RTRIM(CPTCode))
    FROM dbo.LineLevelData
    WHERE CPTCode IS NOT NULL AND LTRIM(RTRIM(CPTCode)) <> ''
    ORDER BY 1;
END
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetClaimLevelDetailsCounts
    @PayerName                   NVARCHAR(500) = NULL,
    @PayerTypes                  NVARCHAR(MAX) = NULL,
    @ClaimStatuses               NVARCHAR(MAX) = NULL,
    @ClinicNames                 NVARCHAR(MAX) = NULL,
    @DenialCode                  NVARCHAR(500) = NULL,
    @DenialCodeExcludeBlank      BIT           = 0,
    @PayerNames                  NVARCHAR(MAX) = NULL,
    @PayerExcludeBlank           BIT           = 0,
    @PanelNames                  NVARCHAR(MAX) = NULL,
    @PanelExcludeBlank           BIT           = 0,
    @AgingBuckets                NVARCHAR(MAX) = NULL,
    @FirstBillFrom               DATE          = NULL,
    @FirstBillTo                 DATE          = NULL,
    @FirstBillNull               BIT           = 0,
    @FirstBillExcludeBlank       BIT           = 0,
    @ChargeEnteredFrom           DATE          = NULL,
    @ChargeEnteredTo             DATE          = NULL,
    @ChargeEnteredNull           BIT           = 0,
    @ChargeEnteredExcludeBlank   BIT           = 0,
    @DosFrom                     DATE          = NULL,
    @DosTo                       DATE          = NULL,
    @DosNull                     BIT           = 0,
    @Offset                      INT           = 0,
    @PageSize                    INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerNameLike   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @DenialCodeLike  TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayerTypeList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @ClaimStatusList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @ClinicList      TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayerNameList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PanelList       TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @AgingList       TABLE (Value NVARCHAR(100) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerName)), '') IS NOT NULL
        INSERT INTO @PayerNameLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerName, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@DenialCode)), '') IS NOT NULL
        INSERT INTO @DenialCodeLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@DenialCode, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayerTypes)), '') IS NOT NULL
        INSERT INTO @PayerTypeList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerTypes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClaimStatuses)), '') IS NOT NULL
        INSERT INTO @ClaimStatusList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClaimStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClinicNames)), '') IS NOT NULL
        INSERT INTO @ClinicList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClinicNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerNameList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@AgingBuckets)), '') IS NOT NULL
        INSERT INTO @AgingList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 100)
        FROM STRING_SPLIT(@AgingBuckets, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerNameLike BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerNameLike) THEN 1 ELSE 0 END;
    DECLARE @HasDenialLike    BIT = CASE WHEN EXISTS (SELECT 1 FROM @DenialCodeLike) THEN 1 ELSE 0 END;
    DECLARE @HasPayerType     BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerTypeList) THEN 1 ELSE 0 END;
    DECLARE @HasClaimStatus   BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClaimStatusList) THEN 1 ELSE 0 END;
    DECLARE @HasClinic        BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClinicList) THEN 1 ELSE 0 END;
    DECLARE @HasPayerNames    BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerNameList) THEN 1 ELSE 0 END;
    DECLARE @HasPanel         BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;
    DECLARE @HasAging         BIT = CASE WHEN EXISTS (SELECT 1 FROM @AgingList) THEN 1 ELSE 0 END;

    SELECT
        (SELECT COUNT(*)
         FROM dbo.ClaimLevelData
         WHERE (@HasPayerNameLike = 0 OR EXISTS (SELECT 1 FROM @PayerNameLike p WHERE LTRIM(RTRIM(ClaimLevelData.PayerName)) LIKE N'%' + p.Value + N'%'))
           AND (@HasPayerType = 0 OR LTRIM(RTRIM(PayerType)) IN (SELECT Value FROM @PayerTypeList))
           AND (@HasClaimStatus = 0 OR LTRIM(RTRIM(ClaimStatus)) IN (SELECT Value FROM @ClaimStatusList))
           AND (@HasClinic = 0 OR LTRIM(RTRIM(ClinicName)) IN (SELECT Value FROM @ClinicList))
           AND (@HasDenialLike = 0 OR EXISTS (SELECT 1 FROM @DenialCodeLike d WHERE LTRIM(RTRIM(ClaimLevelData.DenialCode)) LIKE N'%' + d.Value + N'%'))
           AND (@DenialCodeExcludeBlank = 0 OR (DenialCode IS NOT NULL AND LTRIM(RTRIM(DenialCode)) <> ''))
           AND (@HasPayerNames = 0 OR LTRIM(RTRIM(PayerName)) IN (SELECT Value FROM @PayerNameList))
           AND (@PayerExcludeBlank = 0 OR (PayerName IS NOT NULL AND LTRIM(RTRIM(PayerName)) <> ''))
           AND (@HasPanel = 0 OR LTRIM(RTRIM(PanelName)) IN (SELECT Value FROM @PanelList))
           AND (@PanelExcludeBlank = 0 OR (PanelName IS NOT NULL AND LTRIM(RTRIM(PanelName)) <> ''))
           AND (@HasAging = 0 OR CASE
                    WHEN TRY_CAST(DaystoDOS AS INT) IS NULL THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 30    THEN 'Current'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 60    THEN '30+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 90    THEN '60+'
                    WHEN TRY_CAST(DaystoDOS AS INT) < 120   THEN '90+'
                    ELSE '120+'
                END IN (SELECT Value FROM @AgingList))
           AND (@FirstBillExcludeBlank = 0 OR (FirstBilledDate IS NOT NULL AND LTRIM(RTRIM(FirstBilledDate)) <> ''))
           AND (
                (@FirstBillFrom IS NULL AND @FirstBillTo IS NULL AND @FirstBillNull = 0)
                OR (@FirstBillNull = 1 AND (@FirstBillFrom IS NULL AND @FirstBillTo IS NULL)
                    AND (FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = ''))
                OR (@FirstBillNull = 1 AND (@FirstBillFrom IS NOT NULL OR @FirstBillTo IS NOT NULL)
                    AND ((FirstBilledDate IS NULL OR LTRIM(RTRIM(FirstBilledDate)) = '')
                      OR ((@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
                      AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo))))
                OR (@FirstBillNull = 0 AND (
                        (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
                    AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)))
               )
           AND (@ChargeEnteredExcludeBlank = 0 OR (ChargeEnteredDate IS NOT NULL AND LTRIM(RTRIM(ChargeEnteredDate)) <> ''))
           AND (
                (@ChargeEnteredFrom IS NULL AND @ChargeEnteredTo IS NULL AND @ChargeEnteredNull = 0)
                OR (@ChargeEnteredNull = 1 AND (@ChargeEnteredFrom IS NULL AND @ChargeEnteredTo IS NULL)
                    AND (ChargeEnteredDate IS NULL OR LTRIM(RTRIM(ChargeEnteredDate)) = ''))
                OR (@ChargeEnteredNull = 1 AND (@ChargeEnteredFrom IS NOT NULL OR @ChargeEnteredTo IS NOT NULL)
                    AND ((ChargeEnteredDate IS NULL OR LTRIM(RTRIM(ChargeEnteredDate)) = '')
                      OR ((@ChargeEnteredFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @ChargeEnteredFrom)
                      AND (@ChargeEnteredTo   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ChargeEnteredTo))))
                OR (@ChargeEnteredNull = 0 AND (
                        (@ChargeEnteredFrom IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) >= @ChargeEnteredFrom)
                    AND (@ChargeEnteredTo   IS NULL OR TRY_CAST(ChargeEnteredDate AS DATE) <= @ChargeEnteredTo)))
               )
           AND (
                (@DosFrom IS NULL AND @DosTo IS NULL AND @DosNull = 0)
                OR (@DosNull = 1 AND (@DosFrom IS NULL AND @DosTo IS NULL)
                    AND (DateOfService IS NULL OR LTRIM(RTRIM(DateOfService)) = ''))
                OR (@DosNull = 1 AND (@DosFrom IS NOT NULL OR @DosTo IS NOT NULL)
                    AND ((DateOfService IS NULL OR LTRIM(RTRIM(DateOfService)) = '')
                      OR ((@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
                      AND (@DosTo   IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo))))
                OR (@DosNull = 0 AND (
                        (@DosFrom IS NULL OR TRY_CAST(DateOfService AS DATE) >= @DosFrom)
                    AND (@DosTo   IS NULL OR TRY_CAST(DateOfService AS DATE) <= @DosTo)))
               )
        ) AS TotalFiltered,
        (SELECT COUNT(*) FROM dbo.ClaimLevelData) AS TotalAll;
END
GO


CREATE OR ALTER PROCEDURE dbo.usp_GetLineLevelDetailsCounts
    @PayerName       NVARCHAR(500) = NULL,
    @PayerTypes      NVARCHAR(MAX) = NULL,
    @ClaimStatuses   NVARCHAR(MAX) = NULL,
    @PayStatuses     NVARCHAR(MAX) = NULL,
    @CPTCodes        NVARCHAR(MAX) = NULL,
    @ClinicNames     NVARCHAR(MAX) = NULL,
    @DenialCode      NVARCHAR(500) = NULL,
    @Offset          INT           = 0,
    @PageSize        INT           = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerNameLike   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @DenialCodeLike  TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayerTypeList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @ClaimStatusList TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @PayStatusList   TABLE (Value NVARCHAR(500) NOT NULL);
    DECLARE @CptList         TABLE (Value NVARCHAR(100) NOT NULL);
    DECLARE @ClinicList      TABLE (Value NVARCHAR(500) NOT NULL);

    IF NULLIF(LTRIM(RTRIM(@PayerName)), '') IS NOT NULL
        INSERT INTO @PayerNameLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerName, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@DenialCode)), '') IS NOT NULL
        INSERT INTO @DenialCodeLike SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@DenialCode, ',') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayerTypes)), '') IS NOT NULL
        INSERT INTO @PayerTypeList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayerTypes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClaimStatuses)), '') IS NOT NULL
        INSERT INTO @ClaimStatusList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClaimStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@PayStatuses)), '') IS NOT NULL
        INSERT INTO @PayStatusList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@PayStatuses, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@CPTCodes)), '') IS NOT NULL
        INSERT INTO @CptList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 100)
        FROM STRING_SPLIT(@CPTCodes, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;
    IF NULLIF(LTRIM(RTRIM(@ClinicNames)), '') IS NOT NULL
        INSERT INTO @ClinicList SELECT DISTINCT LEFT(LTRIM(RTRIM(value)), 500)
        FROM STRING_SPLIT(@ClinicNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerNameLike BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerNameLike) THEN 1 ELSE 0 END;
    DECLARE @HasDenialLike    BIT = CASE WHEN EXISTS (SELECT 1 FROM @DenialCodeLike) THEN 1 ELSE 0 END;
    DECLARE @HasPayerType     BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerTypeList) THEN 1 ELSE 0 END;
    DECLARE @HasClaimStatus   BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClaimStatusList) THEN 1 ELSE 0 END;
    DECLARE @HasPayStatus     BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayStatusList) THEN 1 ELSE 0 END;
    DECLARE @HasCpt           BIT = CASE WHEN EXISTS (SELECT 1 FROM @CptList) THEN 1 ELSE 0 END;
    DECLARE @HasClinic        BIT = CASE WHEN EXISTS (SELECT 1 FROM @ClinicList) THEN 1 ELSE 0 END;

    SELECT
        (SELECT COUNT(*)
         FROM dbo.LineLevelData
         WHERE (@HasPayerNameLike = 0 OR EXISTS (SELECT 1 FROM @PayerNameLike p WHERE LTRIM(RTRIM(LineLevelData.PayerName)) LIKE N'%' + p.Value + N'%'))
           AND (@HasPayerType = 0 OR LTRIM(RTRIM(PayerType)) IN (SELECT Value FROM @PayerTypeList))
           AND (@HasClaimStatus = 0 OR LTRIM(RTRIM(ClaimStatus)) IN (SELECT Value FROM @ClaimStatusList))
           AND (@HasPayStatus = 0 OR LTRIM(RTRIM(PayStatus)) IN (SELECT Value FROM @PayStatusList))
           AND (@HasCpt = 0 OR LTRIM(RTRIM(CPTCode)) IN (SELECT Value FROM @CptList))
           AND (@HasClinic = 0 OR LTRIM(RTRIM(ClinicName)) IN (SELECT Value FROM @ClinicList))
           AND (@HasDenialLike = 0 OR EXISTS (SELECT 1 FROM @DenialCodeLike d WHERE LTRIM(RTRIM(LineLevelData.DenialCode)) LIKE N'%' + d.Value + N'%'))
        ) AS TotalFiltered,
        (SELECT COUNT(*) FROM dbo.LineLevelData) AS TotalAll;
END
GO

