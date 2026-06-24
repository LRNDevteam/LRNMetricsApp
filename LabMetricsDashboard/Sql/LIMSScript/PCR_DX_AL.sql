/* PCRDx-AL - LabId 7 */
SELECT
    YEAR(TRY_CONVERT(date, ReceivedDate)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, ReceivedDate)) AS CollectedMonth,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNResultStatus))), ''), '') AS ResultStatus,
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
WHERE TRY_CONVERT(date, ReceivedDate) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, ReceivedDate)) > 1900
GROUP BY
    YEAR(TRY_CONVERT(date, ReceivedDate)),
    MONTH(TRY_CONVERT(date, ReceivedDate)),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNResultStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNBillCategory))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNSampleStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), LRNSubStatus))), ''), '')
ORDER BY CollectedYear, CollectedMonth;