

/* Elixir - LabId 16 */
SELECT
    YEAR(TRY_CONVERT(date, DateOfCollection)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, DateOfCollection)) AS CollectedMonth,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), InsuranceType))), ''), '') AS InsuranceType,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillCategory))), ''), '') AS BillCategory,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), NewStatus))), ''), '') AS FinalStatus,
    COUNT(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
    (
        SELECT TOP 1 SourceFile
        FROM dbo.LIMSMaster WITH (NOLOCK)
        ORDER BY CreatedOn DESC
    ) AS SourceFile
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE TRY_CONVERT(date, DateOfCollection) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, DateOfCollection)) > 1900
GROUP BY
    YEAR(TRY_CONVERT(date, DateOfCollection)),
    MONTH(TRY_CONVERT(date, DateOfCollection)),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), InsuranceType))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillCategory))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), NewStatus))), ''), '')
ORDER BY CollectedYear, CollectedMonth;

--Select * from LIMSMaster

--Truncate table LIMSMaster