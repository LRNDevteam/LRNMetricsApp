/* InHealth - LabId 2 */
SELECT
    YEAR(TRY_CONVERT(date, Entry_DateCreated)) AS CollectedYear,
    MONTH(TRY_CONVERT(date, Entry_DateCreated)) AS CollectedMonth,
	 ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), NA))), ''), '') NA,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillCategory))), ''), '') AS BillCategory,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SampleStatus))), ''), '') AS SampleStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SubStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), '') AS ResultStatus,
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), EntryStatus))), ''), '') AS EntryStatus,
    COUNT(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), Accession))), '')) AS TotalSamples,
    (
        SELECT TOP 1 SourceFile
        FROM dbo.LIMSMaster WITH (NOLOCK)
        ORDER BY CreatedOn DESC
    ) AS SourceFile
FROM dbo.LIMSMaster WITH (NOLOCK)
WHERE TRY_CONVERT(date, Entry_DateCreated) IS NOT NULL
  AND YEAR(TRY_CONVERT(date, Entry_DateCreated)) > 1900
GROUP BY
    YEAR(TRY_CONVERT(date, Entry_DateCreated)),
    MONTH(TRY_CONVERT(date, Entry_DateCreated)),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), BillCategory))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SampleStatus))), ''), ''),
    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), ResultStatus))), ''), ''),
	    ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), SubStatus))), ''), ''),
		ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), EntryStatus))), ''), ''),
		 ISNULL(NULLIF(LTRIM(RTRIM(CONVERT(nvarchar(4000), NA))), ''), '')
ORDER BY CollectedYear, CollectedMonth;

--Select * from LIMSMaster

--truncate table LIMSMaster