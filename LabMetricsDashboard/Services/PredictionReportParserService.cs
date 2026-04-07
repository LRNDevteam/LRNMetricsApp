using System.Globalization;
using System.Text.RegularExpressions;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Spreadsheet;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Reads the "output" sheet from a Payer Policy Validation Report XLSX file
/// using OpenXml SAX streaming — the worksheet XML is parsed as a forward-only
/// stream so the entire object tree is never loaded into RAM at once.
/// <para>Register as <b>Scoped</b> so the service is disposed after every request.</para>
/// </summary>
public sealed class PredictionReportParserService
{
    private const string SheetName = "output";

    private static readonly Regex WhitespaceRun =
        new(@"\s+", RegexOptions.Compiled);

    private static readonly Regex DashSpacing =
        new(@"\s*-\s*", RegexOptions.Compiled);

    private static readonly HashSet<string> ForecastPayableValues =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "Payable",
            "Potentially Payable",
            "Payable - Need Action"
        };

    private readonly ILogger<PredictionReportParserService> _logger;

    public PredictionReportParserService(ILogger<PredictionReportParserService> logger)
    {
        _logger = logger;
    }

    // ?? Public API ????????????????????????????????????????????????????????????

    /// <summary>Parses every data row. For the Diagnostics endpoint only.</summary>
    public List<PredictionRecord> Parse(string filePath) =>
        ParseCore(filePath, weekStartCutoff: null);

    /// <summary>
    /// Streams and parses only rows that pass the global bucket filter:
    /// ForecastingPayability IN (Payable / Potentially Payable / Payable - Need Action)
    /// AND ExpectedPaymentDate &lt; <paramref name="weekStartCutoff"/>.
    /// Non-qualifying rows are skipped before a PredictionRecord is ever allocated.
    /// </summary>
    public List<PredictionRecord> ParseFiltered(string filePath, DateOnly weekStartCutoff) =>
        ParseCore(filePath, weekStartCutoff);

    /// <summary>
    /// Applies the same global filters used by <see cref="ParseFiltered"/> to an
    /// already-loaded list of records (e.g. from the database).
    /// Keeps only rows where:
    ///   ForecastingPayability IN (Payable / Potentially Payable / Payable – Need Action)
    ///   AND ExpectedPaymentDate &lt; <paramref name="weekStartCutoff"/>.
    /// </summary>
    public static List<PredictionRecord> ApplyGlobalFilter(
        IEnumerable<PredictionRecord> records,
        DateOnly weekStartCutoff)
    {
        var result = new List<PredictionRecord>();
        foreach (var r in records)
        {
            if (!ForecastPayableValues.Contains(r.ForecastingPayability))
                continue;

            if (!TryParseDate(r.ExpectedPaymentDate, out var pmtDate))
                continue;

            if (pmtDate >= weekStartCutoff)
                continue;

            result.Add(r);
        }
        return result;
    }

    /// <summary>
    /// Filters records by ForecastingPayability and an inclusive date range
    /// on ExpectedPaymentDate. Used for the last-4-weeks weekly summaries.
    /// </summary>
    public static List<PredictionRecord> ApplyForecastDateRangeFilter(
        IEnumerable<PredictionRecord> records,
        DateOnly rangeStart,
        DateOnly rangeEndExclusive)
    {
        var result = new List<PredictionRecord>();
        foreach (var r in records)
        {
            if (!ForecastPayableValues.Contains(r.ForecastingPayability))
                continue;

            if (!TryParseDate(r.ExpectedPaymentDate, out var pmtDate))
                continue;

            if (pmtDate < rangeStart || pmtDate >= rangeEndExclusive)
                continue;

            result.Add(r);
        }
        return result;
    }

    // ?? Core SAX implementation ???????????????????????????????????????????????

    private List<PredictionRecord> ParseCore(string filePath, DateOnly? weekStartCutoff)
    {
        if (!File.Exists(filePath))
        {
            _logger.LogWarning("Prediction report file not found: {FilePath}", filePath);
            return [];
        }

        try
        {
            // Open read-only — minimum lock and memory footprint
            using var doc = SpreadsheetDocument.Open(filePath, isEditable: false);

            var wbPart = doc.WorkbookPart
                ?? throw new InvalidOperationException("Workbook has no WorkbookPart.");

            // Locate the target sheet by name
            var sheet = wbPart.Workbook.Descendants<Sheet>()
                .FirstOrDefault(s => string.Equals(
                    s.Name?.Value, SheetName, StringComparison.OrdinalIgnoreCase));

            if (sheet?.Id?.Value is not string sheetRelId)
            {
                _logger.LogWarning(
                    "Sheet '{Sheet}' not found in '{FilePath}'. Available: {Sheets}",
                    SheetName, filePath,
                    string.Join(", ", wbPart.Workbook.Descendants<Sheet>()
                        .Select(s => s.Name?.Value ?? "(unnamed)")));
                return [];
            }

            var wsPart = (WorksheetPart)wbPart.GetPartById(sheetRelId);

            // Build shared strings lookup once — O(1) per cell resolution
            var sstArray = BuildSharedStrings(
                wbPart.SharedStringTablePart?.SharedStringTable);

            var records = new List<PredictionRecord>();

            // Forward-only SAX reader — O(1) peak memory regardless of file size
            using var reader = OpenXmlReader.Create(wsPart);

            Dictionary<string, int>? headerMap = null;
            int forecastCol = -1;   // 0-based index into currentRowCells
            int dateCol     = -1;

            // Re-used cell buffer; grows on demand but never shrinks
            string?[] currentRowCells = new string?[100];
            int currentRowIndex = 0;
            bool inRow = false;

            while (reader.Read())
            {
                // ?? Row start ????????????????????????????????????????????????
                if (reader.ElementType == typeof(Row) && reader.IsStartElement)
                {
                    currentRowIndex++;
                    Array.Clear(currentRowCells, 0, currentRowCells.Length);
                    inRow = true;
                    continue;
                }

                // ?? Row end ??????????????????????????????????????????????????
                if (reader.ElementType == typeof(Row) && !reader.IsStartElement)
                {
                    inRow = false;

                    if (currentRowIndex == 1)
                    {
                        // First row = header — build the column-name ? 1-based-col map
                        headerMap = BuildHeaderMap(currentRowCells);

                        // Resolve the two gate-column 0-based indices up front
                        forecastCol = ColIndex(headerMap, "Forecasting Payability");
                        dateCol     = ColIndex(headerMap, "Expected Payment Date");

                        _logger.LogDebug(
                            "Header map: {Count} cols. ForecastCol={FC} DateCol={DC}",
                            headerMap.Count, forecastCol, dateCol);
                        continue;
                    }

                    if (headerMap is null) continue;

                    // Apply global filter before allocating a record object
                    if (weekStartCutoff.HasValue)
                    {
                        if (forecastCol >= 0 && forecastCol < currentRowCells.Length)
                        {
                            var fv = Normalise(currentRowCells[forecastCol] ?? "");
                            if (!ForecastPayableValues.Contains(fv)) continue;
                        }
                        if (dateCol >= 0 && dateCol < currentRowCells.Length)
                        {
                            var dv = OADateOrRaw(currentRowCells[dateCol] ?? "");
                            if (!TryParseDate(dv, out var d) || d >= weekStartCutoff.Value)
                                continue;
                        }
                    }

                    var record = MapRow(currentRowCells, headerMap);
                    if (record is not null) records.Add(record);
                    continue;
                }

                // ?? Cell ?????????????????????????????????????????????????????
                if (!inRow || reader.ElementType != typeof(Cell) || !reader.IsStartElement)
                    continue;

                var cellRef  = reader.Attributes.FirstOrDefault(a => a.LocalName == "r").Value ?? "";
                var cellType = reader.Attributes.FirstOrDefault(a => a.LocalName == "t").Value ?? "";
                int colIndex = ColLetterToIndex(cellRef);

                // Read the inner <v> element
                string? rawValue = null;
                while (reader.Read())
                {
                    if (reader.ElementType == typeof(CellValue) && reader.IsStartElement)
                    {
                        rawValue = reader.GetText();
                        break;
                    }
                    // Stop at the </Cell> closing tag
                    if (reader.ElementType == typeof(Cell) && !reader.IsStartElement)
                        break;
                }

                if (rawValue is not null && colIndex >= 0)
                {
                    // Grow buffer if this sheet has more columns than expected
                    if (colIndex >= currentRowCells.Length)
                        Array.Resize(ref currentRowCells, colIndex + 20);

                    currentRowCells[colIndex] = cellType == "s"
                        ? ResolveSharedString(sstArray, rawValue)
                        : rawValue;
                }
            }

            _logger.LogInformation(
                "SAX parse (filtered={F}): {Count} records from '{File}'.",
                weekStartCutoff.HasValue, records.Count, filePath);

            return records;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to parse prediction report: {FilePath}", filePath);
            return [];
        }
    }

    // ?? Header map ????????????????????????????????????????????????????????????

    /// <summary>Builds column-name ? 1-based column number from the header row buffer.</summary>
    private static Dictionary<string, int> BuildHeaderMap(string?[] cells)
    {
        var map = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < cells.Length; i++)
        {
            if (string.IsNullOrWhiteSpace(cells[i])) continue;
            map.TryAdd(Normalise(cells[i]!), i + 1); // store 1-based
        }
        return map;
    }

    /// <summary>Returns 0-based array index for a named column, or -1 if not found.</summary>
    private static int ColIndex(Dictionary<string, int> map, string header) =>
        map.TryGetValue(Normalise(header), out var col) ? col - 1 : -1;

    // ?? Row mapper ????????????????????????????????????????????????????????????

    private static PredictionRecord? MapRow(string?[] cells, IReadOnlyDictionary<string, int> map)
    {
        // Skip rows where both primary key fields are empty
        if (string.IsNullOrWhiteSpace(Str(cells, map, "Visit Number")) &&
            string.IsNullOrWhiteSpace(Str(cells, map, "CPTCode")))
            return null;

        return new PredictionRecord
        {
            AccessionNo                             = Str(cells, map, "Accession No"),
            VisitNumber                             = Str(cells, map, "Visit Number"),
            CPTCode                                 = Str(cells, map, "CPTCode"),
            PatientDOB                              = Str(cells, map, "Patient DOB"),
            PayerCode                               = Str(cells, map, "Payer Code"),
            PayerName                               = Str(cells, map, "Payer Name"),
            PayerNameNormalized                     = Str(cells, map, "PayerName Normalized"),
            PayStatus                               = Str(cells, map, "Pay Status"),
            HistoricalPayment                       = Str(cells, map, "Historical Payment"),
            HistoricalPaidLineItemCount             = Str(cells, map, "Historical Paid Line-Item Count"),
            HistoricalPaymentConfidenceScore        = Str(cells, map, "Historical Payment Confidence Score"),
            TotalLineItemCount                      = Int(cells, map, "Total Line-Item Count"),
            PaidLineItemCount                       = Int(cells, map, "Paid Line-Item Count"),
            PctPaidLineItemCount                    = Str(cells, map, "% Paid Line-Item Count"),
            PayerType                               = Str(cells, map, "Payer Type"),
            PayerFoundInPolicy                      = Str(cells, map, "PayerFound in Policy"),
            DateOfService                           = Str(cells, map, "Date of Service"),
            FirstBilledDate                         = Str(cells, map, "First Billed Date"),
            PanelName                               = Str(cells, map, "Panel Name"),
            LISIcd10Codes                           = Str(cells, map, "LIS ICD 10 Codes"),
            CCWIcd10Code                            = Str(cells, map, "CCW ICD10Code"),
            Units                                   = Str(cells, map, "Units"),
            Modifier                                = Str(cells, map, "Modifier"),
            DenialCode                              = Str(cells, map, "DenialCode"),
            DenialDescription                       = Str(cells, map, "Denial Description"),
            BilledAmount                            = Dec(cells, map, "Billed Amount"),
            AllowedAmount                           = Dec(cells, map, "Allowed Amount"),
            InsurancePayment                        = Dec(cells, map, "Insurance Payment"),
            InsuranceAdjustment                     = Dec(cells, map, "Insurance Adjustment"),
            PatientPaidAmount                       = Dec(cells, map, "Patient Paid Amount"),
            PatientAdjustment                       = Dec(cells, map, "Patient Adjustment"),
            InsuranceBalance                        = Dec(cells, map, "Insurance Balance"),
            PatientBalance                          = Dec(cells, map, "Patient Balance"),
            TotalBalance                            = Dec(cells, map, "Total Balance"),
            MedicareFee                             = Dec(cells, map, "Medicare Fee"),
            FinalClaimStatus                        = Str(cells, map, "Final Claim Status"),
            CoveredIcd10CodesBilled                 = Str(cells, map, "Covered ICD 10 Codes Billed"),
            NonCoveredIcd10CodesBilled              = Str(cells, map, "Non Covered ICD 10 Codes Billed"),
            BilledIcdCodesNotAvailableInPayerPolicy = Str(cells, map, "Billed ICD codes not available in Payer Policy"),
            CoverageStatus                          = Str(cells, map, "Coverage Status"),
            FinalCoverageStatus                     = Str(cells, map, "Final Coverage Status"),
            CoveredIcd10CodesAsPerPayerPolicy       = Str(cells, map, "Covered ICD 10 codes as per Payer Policy"),
            NonCoveredIcd10CodesAsPerPayerPolicy    = Str(cells, map, "Non Covered ICD 10 Codes as per Payer Policy"),
            ActionComment                           = Str(cells, map, "Action Comment"),
            Resolution                              = Str(cells, map, "Resolution"),
            LabName                                 = Str(cells, map, "Lab Name"),
            CodingValidation                        = Str(cells, map, "Coding Validation"),
            CodingValidationSubStatus               = Str(cells, map, "Coding Validation Sub-Status"),
            ICDComplianceStatus                     = Str(cells, map, "ICD Compliance Status"),
            ICDComplianceSubstatus                  = Str(cells, map, "ICD Compliance Substatus"),
            ICDPrimaryIndicatorAvailable            = Str(cells, map, "ICD Primary Indicator Available"),
            CoveredICDPresence                      = Str(cells, map, "Covered ICD Presence"),
            ICDValidationConfidence                 = Str(cells, map, "ICD Validation Confidence"),
            FrequencyConditionMet                   = Str(cells, map, "Frequency Condition Met"),
            GenderConditionMet                      = Str(cells, map, "Gender Condition Met"),
            Payability                              = Str(cells, map, "Payability"),
            ForecastingPayability                   = Str(cells, map, "Forecasting Payability"),
            PolicyCoverageExpectation               = Str(cells, map, "Policy Coverage Expectation"),
            DenialValidity                          = Str(cells, map, "Denial Validity"),
            CoverageExpectationRemarks              = Str(cells, map, "Coverage Expectation Remarks"),
            ExpectedAverageAllowedAmount            = Dec(cells, map, "Expected Average Allowed Amount"),
            ExpectedAverageInsurancePayment         = Dec(cells, map, "Expected Average Insurance Payment"),
            ExpectedAllowedAmountSameLab            = Dec(cells, map, "Expected Allowed Amount - Same Lab"),
            ExpectedInsurancePaymentSameLab         = Dec(cells, map, "Expected Insurance Payment - Same Lab"),
            ModeAllowedAmountSameLab                = Dec(cells, map, "Mode Allowed Amount - Same Lab"),
            ModeInsurancePaidSameLab                = Dec(cells, map, "Mode Insurance Paid - Same Lab"),
            ModeAllowedAmountPeer                   = Dec(cells, map, "Mode Allowed Amount - Peer"),
            ModeInsurancePaidPeer                   = Dec(cells, map, "Mode Insurance Paid - Peer"),
            MedianAllowedAmountSameLab              = Dec(cells, map, "Median Allowed Amount - Same Lab"),
            MedianInsurancePaidSameLab              = Dec(cells, map, "Median Insurance Paid - Same Lab"),
            MedianAllowedAmountPeer                 = Dec(cells, map, "Median Allowed Amount - Peer"),
            MedianInsurancePaidPeer                 = Dec(cells, map, "Median Insurance Paid - Peer"),
            ModeAllowedAmountDifference             = Dec(cells, map, "Mode Allowed Amount Difference"),
            ModeInsurancePaidDifference             = Dec(cells, map, "Mode Insurance Paid Difference"),
            MedianAllowedAmountDifference           = Dec(cells, map, "Median Allowed Amount Difference"),
            MedianInsurancePaidDifference           = Dec(cells, map, "Median Insurance Paid Difference"),
            DenialRate                              = Str(cells, map, "Denial Rate"),
            AdjustmentRate                          = Str(cells, map, "Adjustment Rate"),
            PaymentDays                             = Str(cells, map, "Payment Days"),
            ExpectedPaymentDate                     = OADateOrText(cells, map, "Expected Payment Date"),
            ExpectedPaymentMonth                    = Str(cells, map, "Expected Payment Month"),
        };
    }

    // ?? Cell value helpers ????????????????????????????????????????????????????

    private static string Str(string?[] cells, IReadOnlyDictionary<string, int> map, string header)
    {
        if (!map.TryGetValue(Normalise(header), out var col)) return string.Empty;
        int idx = col - 1;
        if (idx < 0 || idx >= cells.Length) return string.Empty;
        return cells[idx]?.Trim() ?? string.Empty;
    }

    private static int Int(string?[] cells, IReadOnlyDictionary<string, int> map, string header)
    {
        var raw = Str(cells, map, header);
        return int.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : 0;
    }

    private static decimal Dec(string?[] cells, IReadOnlyDictionary<string, int> map, string header)
    {
        var raw = Str(cells, map, header)
            .TrimStart('$').Replace(",", "").TrimEnd('%');
        return decimal.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var v) ? v : 0m;
    }

    /// <summary>
    /// Reads a date cell that may be stored as an OA-date serial number (e.g. "46477")
    /// or as a text string, and returns a canonical MM/dd/yyyy string.
    /// </summary>
    private static string OADateOrText(
        string?[] cells, IReadOnlyDictionary<string, int> map, string header) =>
        OADateOrRaw(Str(cells, map, header));

    /// <summary>Converts a raw OA-date serial or date string to MM/dd/yyyy.</summary>
    private static string OADateOrRaw(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return string.Empty;

        // Excel stores dates as numeric OA-date serials
        if (double.TryParse(raw, NumberStyles.Any, CultureInfo.InvariantCulture, out var serial)
            && serial > 1 && serial < 2958466)
        {
            try
            {
                return DateTime.FromOADate(serial)
                               .ToString("MM/dd/yyyy", CultureInfo.InvariantCulture);
            }
            catch { /* fall through */ }
        }

        if (DateTime.TryParse(raw, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
            return dt.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture);

        return raw;
    }

    // ?? Shared string resolution ??????????????????????????????????????????????

    /// <summary>Builds a flat array from the SharedStringTable once for O(1) lookups.</summary>
    private static string[] BuildSharedStrings(SharedStringTable? sst)
    {
        if (sst is null) return [];
        return sst.Elements<SharedStringItem>()
                  .Select(item => item.InnerText?.Trim() ?? string.Empty)
                  .ToArray();
    }

    private static string ResolveSharedString(string[] sstArray, string indexStr)
    {
        if (!int.TryParse(indexStr, out var idx)) return indexStr;
        if (idx < 0 || idx >= sstArray.Length) return indexStr;
        return sstArray[idx];
    }

    // ?? Column reference helpers ??????????????????????????????????????????????

    /// <summary>Converts a cell reference like "AB7" to a 0-based column index (27).</summary>
    private static int ColLetterToIndex(string cellRef)
    {
        if (string.IsNullOrEmpty(cellRef)) return -1;
        int i = 0;
        while (i < cellRef.Length && char.IsLetter(cellRef[i])) i++;
        if (i == 0) return -1;

        int col = 0;
        for (int k = 0; k < i; k++)
            col = col * 26 + (char.ToUpperInvariant(cellRef[k]) - 'A' + 1);

        return col - 1; // 0-based
    }

    // ?? Normalisation & date parsing ??????????????????????????????????????????

    internal static string Normalise(string s)
    {
        if (string.IsNullOrEmpty(s)) return s;
        var collapsed = WhitespaceRun.Replace(s.Trim(), " ");
        return DashSpacing.Replace(collapsed, " - ");
    }

    internal static bool TryParseDate(string value, out DateOnly date)
    {
        date = default;
        if (string.IsNullOrWhiteSpace(value)) return false;
        if (DateOnly.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out date))
            return true;
        if (DateTime.TryParse(value, CultureInfo.InvariantCulture, DateTimeStyles.None, out var dt))
        {
            date = DateOnly.FromDateTime(dt);
            return true;
        }
        return false;
    }
}
