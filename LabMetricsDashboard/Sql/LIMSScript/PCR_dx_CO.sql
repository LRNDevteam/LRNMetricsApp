/* PCRDx-CO - LabId 8 */
SELECT
    YEAR(TRY_CONVERT(date, CollectionDate)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, CollectionDate)) AS CollectedMonth,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNBillCategory))), ''), '') AS BillCategory,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNSampleStatus))), ''), '') AS SampleStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNSubStatus))), ''), '') AS SubStatus,
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
    (
        SELECT TOP 1 SourceFile
        FROM dbo.LIMSMaster WITH (NOLOCK)
        ORDER BY CreatedOn DESC
    ) AS SourceFile
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE  TRY_CONVERT(date, CollectionDate) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, CollectionDate)) > 1900
GROUP BY
    YEAR(TRY_CONVERT(date, CollectionDate)),
    MONTH(TRY_CONVERT(date, CollectionDate)),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNBillCategory))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNSampleStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNSubStatus))), ''), '')
ORDER BY CollectedYear, CollectedMonth;

--Select * from LIMSMaster