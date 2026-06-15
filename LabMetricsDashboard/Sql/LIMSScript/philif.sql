
SELECT
    YEAR(TRY_CONVERT(date, RequestCollectDate)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, RequestCollectDate)) AS CollectedMonth,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillingStatus))), ''), '') AS BillingStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClaimStatus))), ''), '') AS SampleStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), billedorNot))), ''), '') AS billedorNot,
	   ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), RessultedStatus))), ''), '') AS ResultedStatus,
	   	ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClientStatus))), ''), '') ClientStatus,
			ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), PaymentMethod))), ''), '') PaymentMethod,
					ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SampleSTATUS))), ''), '') SampleStatus,
    COUNT(DISTINCT NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
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
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillingStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClaimStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), billedorNot))), ''), ''),
	ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ClientStatus))), ''), ''),
		   ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), RessultedStatus))), ''), ''),
		   ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), PaymentMethod))), ''), ''),
		   ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SampleSTATUS))), ''), '') 
ORDER BY CollectedYear, CollectedMonth;

--Select * from LIMSMaster

