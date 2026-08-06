using System.Data;
using System.Globalization;
using System.Text.RegularExpressions;
using DenialDatabaseProcessorWorker.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Options;

namespace DenialDatabaseProcessorWorker.Services;

/// <summary>Metadata about one source run found in the lab's PayerValidationReport table.</summary>
public sealed record PayerValidationRun(
	string RunId,
	string WeekFolder,
	string SourceFullPath,
	DateTime? InsertedDateTime,
	int DeniedRowCount,
	int TotalRowCount);

/// <summary>
/// Reads denial rows straight out of each lab database ([dbo].[PayerValidationReport]).
/// This replaces the old "*_Payer_Policy_ValidationReport.xlsx" file read: the upstream
/// process no longer drops the workbook, it writes the same content to the table instead.
/// Rows are returned keyed by the original Excel header names so every downstream builder
/// (DenialDatabaseBuilder / DenialInsightBuilder / TaskBoardBuilder / DenialLineItemTableBuilder)
/// keeps working unchanged.
/// </summary>
public sealed class PayerValidationReportRepository
{
	private static readonly Regex TableNamePattern =
		new(@"^\[?(?<schema>[A-Za-z0-9_]+)\]?\.\[?(?<table>[A-Za-z0-9_]+)\]?$", RegexOptions.Compiled);

	/// <summary>SQL columns that are run metadata / surrogate keys, not denial data.</summary>
	private static readonly HashSet<string> ExcludedColumns = new(StringComparer.OrdinalIgnoreCase)
	{
		"ReportId",
		"FileLogId",
		"WeekFolder",
		"SourceFullPath",
		"InsertedDateTime",
		"LabName2"
	};

	/// <summary>SQL column -> Excel header used by the rest of the pipeline.</summary>
	private static readonly Dictionary<string, string> SqlToExcelHeader = new(StringComparer.OrdinalIgnoreCase)
	{
		["LabName"] = "Lab Name",
		["AccessionNo"] = "Accession No",
		["VisitNumber"] = "Visit Number",
		["CPTCode"] = "CPTCode",
		["PatientDOB"] = "Patient DOB",
		["PayerCode"] = "Payer Code",
		["PayerName"] = "Payer Name",
		["PayerNameNormalized"] = "PayerName Normalized",
		["PayStatus"] = "Pay Status",
		["HistoricalPayment"] = "Historical Payment",
		["HistoricalPaidLineItemCount"] = "Historical Paid Line-Item Count",
		["HistoricalPaymentConfidenceScore"] = "Historical Payment Confidence Score",
		["TotalLineItemCount"] = "Total Line-Item Count",
		["PaidLineItemCount"] = "Paid Line-Item Count",
		["PctPaidLineItemCount"] = "% Paid Line-Item Count",
		["PayerType"] = "Payer Type",
		["PayerFoundInPolicy"] = "PayerFound in Policy",
		["DateOfService"] = "Date of Service",
		["FirstBilledDate"] = "First Billed Date",
		["PanelName"] = "Panel Name",
		["LISIcd10Codes"] = "LIS ICD 10 Codes",
		["CCWIcd10Code"] = "CCW ICD10Code",
		["Units"] = "Units",
		["Modifier"] = "Modifier",
		["DenialCode"] = "DenialCode",
		["DenialDescription"] = "Denial Description",
		["BilledAmount"] = "Billed Amount",
		["AllowedAmount"] = "Allowed Amount",
		["InsurancePayment"] = "Insurance Payment",
		["InsuranceAdjustment"] = "Insurance Adjustment",
		["PatientPaidAmount"] = "Patient Paid Amount",
		["PatientAdjustment"] = "Patient Adjustment",
		["InsuranceBalance"] = "Insurance Balance",
		["PatientBalance"] = "Patient Balance",
		["TotalBalance"] = "Total Balance",
		["MedicareFee"] = "Medicare Fee",
		["FinalClaimStatus"] = "Final Claim Status",
		["CoveredIcd10CodesBilled"] = "Covered ICD 10 Codes Billed",
		["NonCoveredIcd10CodesBilled"] = "Non Covered ICD 10 Codes Billed",
		["BilledIcdCodesNotAvailableInPolicy"] = "Billed ICD codes not available in Payer Policy",
		["CoverageStatus"] = "Coverage Status",
		["FinalCoverageStatus"] = "Final Coverage Status",
		["CoveredIcd10CodesAsPerPayerPolicy"] = "Covered ICD 10 codes as per Payer Policy",
		["NonCoveredIcd10CodesAsPerPayerPolicy"] = "Non Covered ICD 10 Codes as per Payer Policy",
		["ActionComment"] = "Action Comment",
		["Resolution"] = "Resolution",
		["CodingValidation"] = "Coding Validation",
		["CodingValidationSubStatus"] = "Coding Validation Sub-Status",
		["ICDComplianceStatus"] = "ICD Compliance Status",
		["ICDComplianceSubstatus"] = "ICD Compliance Substatus",
		["ICDPrimaryIndicatorAvailable"] = "ICD Primary Indicator Available",
		["CoveredICDPresence"] = "Covered ICD Presence",
		["ICDValidationConfidence"] = "ICD Validation Confidence",
		["FrequencyConditionMet"] = "Frequency Condition Met",
		["GenderConditionMet"] = "Gender Condition Met",
		["Payability"] = "Payability",
		["ForecastingPayability"] = "Forecasting Payability",
		["PolicyCoverageExpectation"] = "Policy Coverage Expectation",
		["DenialValidity"] = "Denial Validity",
		["CoverageExpectationRemarks"] = "Coverage Expectation Remarks",
		["ExpectedAverageAllowedAmount"] = "Expected Average Allowed Amount",
		["ExpectedAverageInsurancePayment"] = "Expected Average Insurance Payment",
		["ExpectedAllowedAmountSameLab"] = "Expected Allowed Amount - Same Lab",
		["ExpectedInsurancePaymentSameLab"] = "Expected Insurance Payment - Same Lab",
		["ModeAllowedAmountSameLab"] = "Mode Allowed Amount - Same Lab",
		["ModeInsurancePaidSameLab"] = "Mode Insurance Paid - Same Lab",
		["ModeAllowedAmountPeer"] = "Mode Allowed Amount- Peer",
		["ModeInsurancePaidPeer"] = "Mode Insurance Paid - Peer",
		["MedianAllowedAmountSameLab"] = "Median Allowed Amount- Same Lab",
		["MedianInsurancePaidSameLab"] = "Median Insurance Paid - Same Lab",
		["MedianAllowedAmountPeer"] = "Median Allowed Amount- Peer",
		["MedianInsurancePaidPeer"] = "Median Insurance Paid - Peer",
		["ModeAllowedAmountDifference"] = "Mode Allowed Amount Difference",
		["ModeInsurancePaidDifference"] = "Mode Insurance Paid Difference",
		["MedianAllowedAmountDifference"] = "Median Allowed Amount Difference",
		["MedianInsurancePaidDifference"] = "Median Insurance Paid Difference",
		["DenialRate"] = "Denial Rate",
		["AdjustmentRate"] = "Adjustment Rate",
		["PaymentDays"] = "Payment Days",
		["ExpectedPaymentDate"] = "Expected Payment Date",
		["ExpectedPaymentMonth"] = "Expected Payment Month",
		["BillingProvider"] = "BillingProvider",
		["ReferringProvider"] = "ReferringProvider",
		["ClinicName"] = "ClinicName",
		["SalesRepName"] = "SalesRepname",
		["PatientID"] = "PatientID",
		["ChargeEnteredDate"] = "ChargeEnteredDate",
		["POS"] = "POS",
		["TOS"] = "TOS",
		["CheckDate"] = "CheckDate",
		["DaysToDOS"] = "DaystoDOS",
		["RollingDays"] = "RollingDays",
		["DaysToBill"] = "DaystoBill",
		["DaysToPost"] = "DaystoPost",
		["ForecastingPayabilitySubstatus"] = "Forecasting Payability Substatus",
		["Source"] = "Source",
		["PatientName"] = "Pat name",
		["SubscriberID"] = "Subscriber Id",
		["DenialDate"] = "Denial Date"
	};

	/// <summary>Extra Excel headers that must carry the same value as another header.</summary>
	private static readonly Dictionary<string, string> HeaderAliases = new(StringComparer.OrdinalIgnoreCase)
	{
		// DenialLineItemTableBuilder maps "Pat name" -> PatName and "Patient Name" -> PatientName.
		["Pat name"] = "Patient Name"
	};

	private readonly ProcessorOptions _options;

	public PayerValidationReportRepository(IOptions<ProcessorOptions> options)
	{
		_options = options.Value;
	}

	private int CommandTimeoutSeconds => _options.SqlCommandTimeoutSeconds;

	/// <summary>
	/// Looks one RunId up in this lab's table and returns its metadata, or null when the lab
	/// has no rows for that run at all. That null is the "is this run in this lab database?"
	/// answer - the RunId comes from LRNMaster and only some labs carry rows for it.
	/// TotalRowCount is every row for the run; DeniedRowCount is the subset that gets imported.
	/// </summary>
	public async Task<PayerValidationRun?> GetRunAsync(LabConfig lab, string runId, CancellationToken ct)
	{
		if (string.IsNullOrWhiteSpace(runId))
			return null;

		// RunId is compared bare so the predicate stays sargable: wrapping the column in
		// LTRIM/RTRIM/ISNULL makes an index on RunId unusable and forces a full scan of a
		// very wide table, which is what times out on the larger labs. SQL Server already
		// ignores trailing blanks in '=', and a NULL RunId can never match a non-empty value,
		// so the bare comparison returns the same rows.
		var sql = $@"
SELECT MAX(ISNULL(WeekFolder, ''))     AS WeekFolder,
       MAX(ISNULL(SourceFullPath, '')) AS SourceFullPath,
       MAX(InsertedDateTime)           AS LastInserted,
       COUNT_BIG(1)                    AS TotalRowCount,
       SUM(CASE WHEN LTRIM(RTRIM(ISNULL(PayStatus, ''))) = @PayStatus THEN 1 ELSE 0 END) AS DeniedRowCount
FROM {QualifiedTableName()}
WHERE RunId = @RunId;";

		await using var conn = new SqlConnection(lab.LabConnectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = CommandTimeoutSeconds };
		cmd.Parameters.Add("@PayStatus", SqlDbType.NVarChar, 100).Value = _options.DeniedPayStatus;
		cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 200).Value = runId.Trim();

		await conn.OpenAsync(ct).ConfigureAwait(false);
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		if (!await reader.ReadAsync(ct).ConfigureAwait(false))
			return null;

		// The aggregate always returns a row; zero rows for the run is the empty case.
		var totalRowCount = reader.IsDBNull(3) ? 0 : Convert.ToInt32(reader.GetInt64(3));

		if (totalRowCount == 0)
			return null;

		return new PayerValidationRun(
			RunId: runId.Trim(),
			WeekFolder: reader.IsDBNull(0) ? "" : reader.GetString(0).Trim(),
			SourceFullPath: reader.IsDBNull(1) ? "" : reader.GetString(1).Trim(),
			InsertedDateTime: reader.IsDBNull(2) ? null : reader.GetDateTime(2),
			DeniedRowCount: reader.IsDBNull(4) ? 0 : Convert.ToInt32(reader.GetValue(4)),
			TotalRowCount: totalRowCount);
	}

	/// <summary>
	/// Reads every PayStatus = 'Denied' row for the lab, optionally restricted to one RunId.
	/// Values are stringified exactly the way ExcelTableReader used to produce them
	/// (dates as MM/dd/yyyy, numbers without trailing zeros) so the mapping stays identical.
	/// </summary>
	public async Task<List<Dictionary<string, string>>> GetDeniedRowsAsync(
		LabConfig lab,
		string? runId,
		CancellationToken ct)
	{
		// The RunId filter is composed in, not written as "(@RunId IS NULL OR RunId = @RunId)":
		// that OR form has to produce one plan for both cases and gives up the index seek even
		// when a RunId is supplied. PayStatus keeps its trim, evaluated as a residual over the
		// far smaller set the RunId seek returns.
		var filterByRun = !string.IsNullOrWhiteSpace(runId);

		var sql = $@"
SELECT *
FROM {QualifiedTableName()}
WHERE LTRIM(RTRIM(ISNULL(PayStatus, ''))) = @PayStatus{(filterByRun ? "\n  AND RunId = @RunId" : "")};";

		var rows = new List<Dictionary<string, string>>();

		await using var conn = new SqlConnection(lab.LabConnectionString);
		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = CommandTimeoutSeconds };
		cmd.Parameters.Add("@PayStatus", SqlDbType.NVarChar, 100).Value = _options.DeniedPayStatus;

		if (filterByRun)
			cmd.Parameters.Add("@RunId", SqlDbType.NVarChar, 200).Value = runId!.Trim();

		await conn.OpenAsync(ct).ConfigureAwait(false);
		await using var reader = await cmd.ExecuteReaderAsync(ct).ConfigureAwait(false);

		// Resolve the SQL column -> Excel header once, not per row.
		var headers = new string?[reader.FieldCount];
		for (int i = 0; i < reader.FieldCount; i++)
		{
			var sqlColumn = reader.GetName(i);

			if (string.IsNullOrWhiteSpace(sqlColumn) || ExcludedColumns.Contains(sqlColumn))
				continue;

			headers[i] = SqlToExcelHeader.TryGetValue(sqlColumn, out var mapped) ? mapped : sqlColumn;
		}

		while (await reader.ReadAsync(ct).ConfigureAwait(false))
		{
			var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

			for (int i = 0; i < reader.FieldCount; i++)
			{
				var header = headers[i];
				if (header is null)
					continue;

				var value = FormatValue(reader.IsDBNull(i) ? null : reader.GetValue(i));
				row[header] = value;

				if (HeaderAliases.TryGetValue(header, out var alias))
					row[alias] = value;
			}

			rows.Add(row);
		}

		return rows;
	}

	/// <summary>Bracket-quotes the configured table name after validating it is a plain identifier.</summary>
	private string QualifiedTableName()
	{
		var configured = (_options.PayerValidationReportTable ?? "").Trim();

		if (string.IsNullOrWhiteSpace(configured))
			configured = "dbo.PayerValidationReport";

		var match = TableNamePattern.Match(configured);
		if (!match.Success)
		{
			throw new InvalidOperationException(
				$"DenialDatabaseProcessor:PayerValidationReportTable must be 'schema.table'. Value was '{configured}'.");
		}

		return $"[{match.Groups["schema"].Value}].[{match.Groups["table"].Value}]";
	}

	private static string FormatValue(object? value)
	{
		switch (value)
		{
			case null or DBNull:
				return "";

			case DateTime dt:
				return dt.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture);

			case DateTimeOffset dto:
				return dto.ToString("MM/dd/yyyy", CultureInfo.InvariantCulture);

			case decimal m:
				return FormatDecimal(m);

			case double d:
				return double.IsNaN(d) || double.IsInfinity(d) ? "" : FormatDecimal((decimal)d);

			case float f:
				return FormatDecimal((decimal)f);

			case bool b:
				return b ? "True" : "False";

			case int or long or short or byte:
				return Convert.ToString(value, CultureInfo.InvariantCulture) ?? "";

			default:
				return value.ToString()?.Trim() ?? "";
		}
	}

	private static string FormatDecimal(decimal value)
	{
		// Keep whole numbers clean ("12" not "12.0000") the way the Excel reader did.
		return value.ToString("0.############################", CultureInfo.InvariantCulture);
	}
}
