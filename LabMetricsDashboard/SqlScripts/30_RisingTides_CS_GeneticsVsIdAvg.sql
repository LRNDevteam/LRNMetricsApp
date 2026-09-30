-- =====================================================================
-- RisingTides - Collection Summary "Genetics vs ID Avg"
-- Used by LabMetricsDashboard Collection Summary tab + Excel export
-- (web ExportExcel and LRN.ReportWorker CollectionReportGenerator).
--
-- Client pivot (two summaries, same row/column shape):
--   Rows    : Panelname
--   Columns : Count of ClaimID, Sum of InsurancePayment,
--             Average of InsurancePayment (= Sum / Count)
--   1) FullyPaid       : ClaimStatus = 'Fully Paid'
--   2) ExclNoResponse  : ClaimStatus <> 'No Response' (blank status kept,
--                        same as an Excel pivot "(Multiple Items)" filter)
--
-- Source: dbo.ClaimLevelData (live; no snapshot table).
-- Optional filters use the shared Collection Summary parameter set;
-- list parameters use '|' delimiter.
-- =====================================================================

SET NOCOUNT ON;
GO

CREATE OR ALTER PROCEDURE dbo.usp_GetRT_CS_GeneticsVsIdAvg
    @PayerNames      NVARCHAR(MAX) = NULL,
    @PanelNames      NVARCHAR(MAX) = NULL,
    @DosFrom         DATE          = NULL,
    @DosTo           DATE          = NULL,
    @FirstBillFrom   DATE          = NULL,
    @FirstBillTo     DATE          = NULL,
    @CheckDateFrom   DATE          = NULL,
    @CheckDateTo     DATE          = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @PayerList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);
    DECLARE @PanelList TABLE (Value NVARCHAR(500) NOT NULL PRIMARY KEY);

    IF NULLIF(LTRIM(RTRIM(@PayerNames)), '') IS NOT NULL
        INSERT INTO @PayerList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PayerNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    IF NULLIF(LTRIM(RTRIM(@PanelNames)), '') IS NOT NULL
        INSERT INTO @PanelList SELECT DISTINCT LTRIM(RTRIM(value))
        FROM STRING_SPLIT(@PanelNames, '|') WHERE NULLIF(LTRIM(RTRIM(value)), '') IS NOT NULL;

    DECLARE @HasPayerFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PayerList) THEN 1 ELSE 0 END;
    DECLARE @HasPanelFilter BIT = CASE WHEN EXISTS (SELECT 1 FROM @PanelList) THEN 1 ELSE 0 END;

    ;WITH src AS (
        SELECT
            ISNULL(NULLIF(LTRIM(RTRIM(Panelname)), ''), '(blank)')   AS PanelName,
            NULLIF(LTRIM(RTRIM(ClaimID)), '')                        AS ClaimID,
            ISNULL(TRY_CAST(InsurancePayment AS DECIMAL(18,2)), 0)   AS InsPay,
            ISNULL(LTRIM(RTRIM(ClaimStatus)), '')                    AS ClaimStatus
        FROM dbo.ClaimLevelData
        WHERE (@HasPayerFilter = 0 OR LTRIM(RTRIM(ISNULL(PayerName_Raw, 'Unknown'))) IN (SELECT Value FROM @PayerList))
          AND (@HasPanelFilter = 0 OR LTRIM(RTRIM(ISNULL(Panelname,     'Unknown'))) IN (SELECT Value FROM @PanelList))
          AND (@DosFrom       IS NULL OR TRY_CAST(DateOfService   AS DATE) >= @DosFrom)
          AND (@DosTo         IS NULL OR TRY_CAST(DateOfService   AS DATE) <= @DosTo)
          AND (@FirstBillFrom IS NULL OR TRY_CAST(FirstBilledDate AS DATE) >= @FirstBillFrom)
          AND (@FirstBillTo   IS NULL OR TRY_CAST(FirstBilledDate AS DATE) <= @FirstBillTo)
          AND (@CheckDateFrom IS NULL OR TRY_CAST(CheckDate       AS DATE) >= @CheckDateFrom)
          AND (@CheckDateTo   IS NULL OR TRY_CAST(CheckDate       AS DATE) <= @CheckDateTo)
    ),
    tagged AS (
        SELECT CAST('FullyPaid' AS VARCHAR(20)) AS SummaryType, PanelName, ClaimID, InsPay
        FROM src
        WHERE ClaimStatus = 'Fully Paid'
        UNION ALL
        SELECT CAST('ExclNoResponse' AS VARCHAR(20)), PanelName, ClaimID, InsPay
        FROM src
        WHERE ClaimStatus <> 'No Response'
    )
    SELECT
        SummaryType,
        PanelName,
        CAST(COUNT(ClaimID) AS INT)                           AS ClaimCount,
        CAST(SUM(InsPay) AS DECIMAL(18,2))                    AS CarrierPayment,
        CAST(SUM(InsPay) / NULLIF(COUNT(ClaimID), 0) AS DECIMAL(18,2)) AS AveragePayment
    FROM tagged
    GROUP BY SummaryType, PanelName
    ORDER BY SummaryType, CarrierPayment DESC, PanelName;
END
GO

-- Verify (grand totals should match the client pivot Grand Total rows)
-- EXEC dbo.usp_GetRT_CS_GeneticsVsIdAvg;
