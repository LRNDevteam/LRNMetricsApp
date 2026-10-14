

/* PCRLOA - LabId 13 */
SELECT
    YEAR(TRY_CONVERT(date, RequestCollectDate)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, RequestCollectDate)) AS CollectedMonth,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), InsuranceCategory))), ''), '') AS InsuranceCategory,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BilledorNot))), ''), '') AS BilledorNot,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), RessultedStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClaimStatus))), ''), '') AS ClaimStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClientStatus))), ''), '') AS ClientStatus,
	    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), OrderStatus))), ''), '') OrderStatus,
    COUNT(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
    (
        SELECT TOP 1 SourceFile
        FROM dbo.LIMSMaster WITH (NOLOCK)
        ORDER BY CreatedOn DESC
    ) AS SourceFile
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE TRY_CONVERT(date, RequestCollectDate) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, RequestCollectDate)) > 1900
GROUP BY
    YEAR(TRY_CONVERT(date, RequestCollectDate)),
    MONTH(TRY_CONVERT(date, RequestCollectDate)),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), InsuranceCategory))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BilledorNot))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), RessultedStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClaimStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClientStatus))), ''), ''),
	    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), OrderStatus))), ''), '')
ORDER BY CollectedYear, CollectedMonth;

--Select * from LIMSMaster