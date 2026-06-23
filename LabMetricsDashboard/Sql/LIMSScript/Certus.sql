SELECT
    YEAR(TRY_CONVERT(date, ReqCollectDate)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, ReqCollectDate)) AS CollectedMonth,
	IncorrectDOS,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillTo))), ''), '') AS BillTo,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillingStatus))), ''), '') AS BillingStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), FinalStatus))), ''), '') AS FinalStatus,
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
    (
        SELECT TOP 1 SourceFile
        FROM dbo.LIMSMaster WITH (NOLOCK)
        ORDER BY CreatedOn DESC
    ) AS SourceFile
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE TRY_CONVERT(date, ReqCollectDate) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, ReqCollectDate)) > 1900
GROUP BY
    YEAR(TRY_CONVERT(date, ReqCollectDate)),
    MONTH(TRY_CONVERT(date, ReqCollectDate)),
	IncorrectDOS,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillTo))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillingStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), FinalStatus))), ''), '')
ORDER BY CollectedYear, CollectedMonth;