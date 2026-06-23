
/* NWL - LabId 20 */
SELECT
    YEAR(TRY_CONVERT(date, RequestCollectDate)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, RequestCollectDate)) AS CollectedMonth,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BilledTo))), ''), '') AS BillTo,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillStatus))), ''), '') AS BillStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), FinalStatus))), ''), '') AS FinalStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Category))), ''), '') AS Category,
	    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), IncorrectDos))), ''), '') AS IncorrectDos,
		    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SourceSystem))), ''), '') AS SourceSystem,
			    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ChargesNotEnteredStatus))), ''), '') AS ChargeNotEnteredStatus,
    COUNT(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
    (
        SELECT TOP 1 SourceFile
        FROM dbo.LIMSMaster WITH (NOLOCK)
        ORDER BY CreatedOn DESC
    ) AS SourceFile
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE TRY_CONVERT(date, RequestCollectDate) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, RequestCollectDate)) > 1900
  AND ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), IncorrectDOS))), ''), '') = ''
GROUP BY
    YEAR(TRY_CONVERT(date, RequestCollectDate)),
    MONTH(TRY_CONVERT(date, RequestCollectDate)),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BilledTo))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), FinalStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Category))), ''), ''),
	   ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), IncorrectDos))), ''), ''),
	      ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SourceSystem))), ''), ''),
		  ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ChargesNotEnteredStatus))), ''), '')
ORDER BY CollectedYear, CollectedMonth;

--Select * from LIMSMaster

--Truncate table LIMSMaster