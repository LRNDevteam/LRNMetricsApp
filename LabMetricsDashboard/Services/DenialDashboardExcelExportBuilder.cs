using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

public static class DenialDashboardExcelExportBuilder
{
	/// <summary>Workflow columns appended to the Line Item sheet, in sheet order.</summary>
	public const string WorkflowTaskIdHeader = "Workflow Task ID";
	public const string WorkflowAssignedToHeader = "Assigned To";
	public const string WorkflowStatusHeader = "Workflow Status";
	public const string WorkflowNotesHeader = "Denial Notes";

	/// <summary>
	/// One sheet per Denial Dashboard tab that the export covers, in tab order:
	/// Monthly Breakdown, Weekly Breakdown, Denial Insight, Line Item. Every sheet is written
	/// even when its tab has no rows, so the workbook shape never changes between runs.
	///
	/// Filter Panel and SLA Tracker sheets were retired along with their tabs on the page - see
	/// <see cref="DenialDashboardExportData"/> for the task-board-derived fields that fed them,
	/// which BuildExportData still computes (shared with LRN.ReportWorker's queued report) but
	/// which no sheet reads any more.
	/// </summary>
	/// <summary>
	/// Raw-data sheet name — also the sheet LRN.ReportWorker streams in separately. Named
	/// "Denial Masterfile" to match the client's Denial Report workbook
	/// (Template/01. Cove Dx_Denial Report_*.xlsx); it still carries our own DenialLineItem
	/// columns plus the workflow columns, not the source system's column set.
	/// </summary>
	public const string LineItemSheetName = "Denial Masterfile";

	/// <summary>
	/// The single narrative sheet the client template leads with: report header block, the
	/// monthly pivot, the weekly pivot, then Key Observations &amp; Highlights — in that order,
	/// on one sheet, rather than the four separate tabs this export used to produce.
	/// </summary>
	public const string DenialInsightsSheetName = "Denial Insights";

	/// <param name="includeLineItemSheet">
	/// False lets a caller append that sheet itself. LRN.ReportWorker does: ClosedXML holds the
	/// whole sheet in memory while saving and throws "Stream was too long" once the XML passes
	/// 2 GB, which a wide lab with large ICD code lists reaches. The three summary sheets are
	/// small and stay on ClosedXML either way.
	/// </param>
	/// <param name="fileName">
	/// Shown in the report header block's "File Name" row, as the client template does. Optional:
	/// the builder does not name the file, its callers do, and neither is obliged to tell it.
	/// </param>
	public static XLWorkbook CreateWorkbook(DenialDashboardExportData data, bool includeLineItemSheet = true, string? fileName = null)
	{
		var workbook = new XLWorkbook();

		BuildDenialInsightsSheet(workbook, data, fileName);

		if (includeLineItemSheet)
		{
			var (lineHeaders, lineRows) = BuildLineSheetRows(data.LineItems, data.Workflow);
			BuildLineItemSheet(workbook, lineHeaders, lineRows);
		}

		return workbook;
	}

	/// <summary>
	/// Headers plus the rows as flat arrays. <see cref="Rows"/> is lazy and single-pass: the
	/// source line items are already a fully materialised list, so projecting eagerly would
	/// hold a second copy of every value at once — on a lab with large ICD code lists that is
	/// gigabytes. Enumerate it once.
	/// </summary>
	public sealed record LineItemSheetData(string[] Headers, IEnumerable<object?[]> Rows);

	/// <summary>
	/// The Line Item sheet's content as flat rows — the same columns, overflow spilling and
	/// workflow fields <see cref="CreateWorkbook"/> writes, for callers that stream the sheet
	/// instead of building it in memory.
	/// </summary>
	public static LineItemSheetData BuildLineItemSheetData(DenialDashboardExportData data)
	{
		var (lineHeaders, lineRows) = BuildLineSheetRows(data.LineItems, data.Workflow);
		var headers = VisibleLineHeaders(lineHeaders);
		var overflow = MeasureOverflow(headers, lineRows);
		var effective = BuildHeadersWithOverflow(headers, overflow);

		return new LineItemSheetData(effective.ToArray(), Project());

		IEnumerable<object?[]> Project()
		{
			foreach (var row in lineRows)
			{
				var values = new object?[effective.Count];
				var col = 0;
				foreach (var header in headers)
				{
					row.TryGetValue(header, out var val);
					var extras = overflow.GetValueOrDefault(header);
					if (extras == 0)
					{
						values[col++] = val;
						continue;
					}

					foreach (var chunk in ChunksFor(val, extras + 1))
						values[col++] = chunk;
				}
				yield return values;
			}
		}
	}

	private static (List<string> Headers, List<Dictionary<string, string>> Rows) BuildLineSheetRows(
		IReadOnlyList<DenialLineItemRecord> lineItems,
		DenialWorkflowLineItemAnnotator workflow)
	{
		var headers = new List<string>
		{
			"Accession No",
			"Visit Number",
			"CPTCode",
			"Patient DOB",
			"Payer Code",
			"Payer Name",
			"PayerName Normalized",
			"Pay Status",
			"Historical Payment",
			"Historical Paid Line-Item Count",
			"Historical Payment Confidence Score",
			"Total Line-Item Count",
			"Paid Line-Item Count",
			"% Paid Line-Item Count",
			"Payer Type",
			"PayerFound in Policy",
			"Date of Service",
			"First Billed Date",
			"Denial Date",
			"Panel Name",
			"LIS ICD 10 Codes",
			"CCW ICD10Code",
			"Units",
			"Modifier",
			"DenialCode_Original",
			"DenialCode_Normalized",
			"Denial Description",
			"Billed Amount",
			"Allowed Amount",
			"Insurance Payment",
			"Insurance Adjustment",
			"Patient Paid Amount",
			"Patient Adjustment",
			"Insurance Balance",
			"Patient Balance",
			"Total Balance",
			"Medicare Fee",
			"Final Claim Status",
			"Covered ICD 10 Codes Billed",
			"Non Covered ICD 10 Codes Billed",
			"Billed ICD codes not available in Payer Policy",
			"Coverage Status",
			"Final Coverage Status",
			"Covered ICD 10 codes as per Payer Policy",
			"Non Covered ICD 10 Codes as per Payer Policy",
			"Action Comment",
			"Resolution",
			"Lab Name",
			"Coding Validation",
			"Coding Validation Sub-Status",
			"ICD Compliance Status",
			"ICD Compliance Substatus",
			"ICD Primary Indicator Available",
			"Covered ICD Presence",
			"ICD Validation Confidence",
			"Frequency Condition Met",
			"Gender Condition Met",
			"Payability",
			"Forecasting Payability",
			"Policy Coverage Expectation",
			"Denial Validity",
			"Coverage Expectation Remarks",
			"Expected Average Allowed Amount",
			"Expected Average Insurance Payment",
			"Expected Allowed Amount - Same Lab",
			"Expected Insurance Payment - Same Lab",
			"Mode Allowed Amount - Same Lab",
			"Mode Insurance Paid - Same Lab",
			"Mode Allowed Amount- Peer",
			"Mode Insurance Paid- Peer",
			"Median Allowed Amount- Same Lab",
			"Median Insurance Paid - Same Lab",
			"Median Allowed Amount- Peer",
			"Median Insurance Paid - Peer",
			"Mode Allowed Amount Difference",
			"Mode Insurance Paid Difference",
			"Median Allowed Amount Difference",
			"Median Insurance Paid Difference",
			"Denial Rate",
			"Adjustment Rate",
			"Payment Days",
			"Expected Payment Date",
			"Expected Payment Month",
			"BillingProvider",
			"ReferringProvider",
			"ClinicName",
			"SalesRepname",
			"PatientID",
			"ChargeEnteredDate",
			"POS",
			"TOS",
			"CheckDate",
			"DaystoDOS",
			"RollingDays",
			"DaystoBill",
			"DaystoPost",
			"Denial Classification",
			"Denial Type",
			"Action Category",
			"Action Code",
			"Recommended Action",
			"Task Guidance",
			"Task Status",
			"Priority",
			"SLA (Days)",
			"RunId",
			"CreatedOn",
			// Denial Workflow state for this line, matched via DenialTaskBoard.
			WorkflowTaskIdHeader,
			WorkflowAssignedToHeader,
			WorkflowStatusHeader,
			WorkflowNotesHeader
		};

		var rows = lineItems.Select(item =>
		{
			var wf = workflow.Resolve(item);
			return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
		{
			["Accession No"] = item.AccessionNo,
			["Visit Number"] = item.VisitNumber,
			["CPTCode"] = item.CptCode,
			["Patient DOB"] = FormatDate(item.PatientDob),
			["Payer Code"] = item.PayerCode?.ToString() ?? string.Empty,
			["Payer Name"] = item.PayerName,
			["PayerName Normalized"] = item.PayerNameNormalized,
			["Pay Status"] = item.PayStatus,
			["Historical Payment"] = item.HistoricalPayment,
			["Historical Paid Line-Item Count"] = item.HistoricalPaidLineItemCount,
			["Historical Payment Confidence Score"] = item.HistoricalPaymentConfidenceScore,
			["Total Line-Item Count"] = item.TotalLineItemCount?.ToString() ?? string.Empty,
			["Paid Line-Item Count"] = item.PaidLineItemCount?.ToString() ?? string.Empty,
			["% Paid Line-Item Count"] = FormatDecimal(item.PaidLineItemCountPercent),
			["Payer Type"] = item.PayerType,
			["PayerFound in Policy"] = item.PayerFoundInPolicy,
			["Date of Service"] = FormatDate(item.DateOfService),
			["First Billed Date"] = FormatDate(item.FirstBilledDate),
			["Denial Date"] = FormatDate(item.DenialDate),
			["Panel Name"] = item.PanelName,
			["LIS ICD 10 Codes"] = item.LisIcd10Codes,
			["CCW ICD10Code"] = item.CcwIcd10Code,
			["Units"] = item.Units?.ToString() ?? string.Empty,
			["Modifier"] = item.Modifier,
			["DenialCode_Original"] = item.DenialCodeOriginal,
			["DenialCode_Normalized"] = item.DenialCodeNormalized,
			["Denial Description"] = item.DenialDescription,
			["Billed Amount"] = FormatDecimal(item.BilledAmount),
			["Allowed Amount"] = FormatDecimal(item.AllowedAmount),
			["Insurance Payment"] = FormatDecimal(item.InsurancePayment),
			["Insurance Adjustment"] = FormatDecimal(item.InsuranceAdjustment),
			["Patient Paid Amount"] = FormatDecimal(item.PatientPaidAmount),
			["Patient Adjustment"] = FormatDecimal(item.PatientAdjustment),
			["Insurance Balance"] = FormatDecimal(item.InsuranceBalance),
			["Patient Balance"] = FormatDecimal(item.PatientBalance),
			["Total Balance"] = FormatDecimal(item.TotalBalance),
			["Medicare Fee"] = FormatDecimal(item.MedicareFee),
			["Final Claim Status"] = item.FinalClaimStatus,
			["Covered ICD 10 Codes Billed"] = item.CoveredIcd10CodesBilled,
			["Non Covered ICD 10 Codes Billed"] = item.NonCoveredIcd10CodesBilled,
			["Billed ICD codes not available in Payer Policy"] = item.BilledIcdCodesNotAvailableInPayerPolicy,
			["Coverage Status"] = item.CoverageStatus,
			["Final Coverage Status"] = item.FinalCoverageStatus,
			["Covered ICD 10 codes as per Payer Policy"] = item.CoveredIcd10CodesAsPerPayerPolicy,
			["Non Covered ICD 10 Codes as per Payer Policy"] = item.NonCoveredIcd10CodesAsPerPayerPolicy,
			["Action Comment"] = item.ActionComment,
			["Resolution"] = item.Resolution,
			["Lab Name"] = item.LabName,
			["Coding Validation"] = item.CodingValidation,
			["Coding Validation Sub-Status"] = item.CodingValidationSubStatus,
			["ICD Compliance Status"] = item.IcdComplianceStatus,
			["ICD Compliance Substatus"] = item.IcdComplianceSubstatus,
			["ICD Primary Indicator Available"] = item.IcdPrimaryIndicatorAvailable,
			["Covered ICD Presence"] = item.CoveredIcdPresence,
			["ICD Validation Confidence"] = item.IcdValidationConfidence,
			["Frequency Condition Met"] = item.FrequencyConditionMet,
			["Gender Condition Met"] = item.GenderConditionMet,
			["Payability"] = item.Payability,
			["Forecasting Payability"] = item.ForecastingPayability,
			["Policy Coverage Expectation"] = item.PolicyCoverageExpectation,
			["Denial Validity"] = item.DenialValidity,
			["Coverage Expectation Remarks"] = item.CoverageExpectationRemarks,
			["Expected Average Allowed Amount"] = FormatDecimal(item.ExpectedAverageAllowedAmount),
			["Expected Average Insurance Payment"] = FormatDecimal(item.ExpectedAverageInsurancePayment),
			["Expected Allowed Amount - Same Lab"] = FormatDecimal(item.ExpectedAllowedAmountSameLab),
			["Expected Insurance Payment - Same Lab"] = FormatDecimal(item.ExpectedInsurancePaymentSameLab),
			["Mode Allowed Amount - Same Lab"] = FormatDecimal(item.ModeAllowedAmountSameLab),
			["Mode Insurance Paid - Same Lab"] = FormatDecimal(item.ModeInsurancePaidSameLab),
			["Mode Allowed Amount- Peer"] = FormatDecimal(item.ModeAllowedAmountPeer),
			["Mode Insurance Paid- Peer"] = FormatDecimal(item.ModeInsurancePaidPeer),
			["Median Allowed Amount- Same Lab"] = FormatDecimal(item.MedianAllowedAmountSameLab),
			["Median Insurance Paid - Same Lab"] = FormatDecimal(item.MedianInsurancePaidSameLab),
			["Median Allowed Amount- Peer"] = FormatDecimal(item.MedianAllowedAmountPeer),
			["Median Insurance Paid - Peer"] = FormatDecimal(item.MedianInsurancePaidPeer),
			["Mode Allowed Amount Difference"] = FormatDecimal(item.ModeAllowedAmountDifference),
			["Mode Insurance Paid Difference"] = FormatDecimal(item.ModeInsurancePaidDifference),
			["Median Allowed Amount Difference"] = FormatDecimal(item.MedianAllowedAmountDifference),
			["Median Insurance Paid Difference"] = FormatDecimal(item.MedianInsurancePaidDifference),
			["Denial Rate"] = FormatDecimal(item.DenialRate),
			["Adjustment Rate"] = FormatDecimal(item.AdjustmentRate),
			["Payment Days"] = item.PaymentDays?.ToString() ?? string.Empty,
			["Expected Payment Date"] = FormatDate(item.ExpectedPaymentDate),
			["Expected Payment Month"] = item.ExpectedPaymentMonth,
			["BillingProvider"] = item.BillingProvider,
			["ReferringProvider"] = item.ReferringProvider,
			["ClinicName"] = item.ClinicName,
			["SalesRepname"] = item.SalesRepname,
			["PatientID"] = item.PatientId,
			["ChargeEnteredDate"] = FormatDate(item.ChargeEnteredDate),
			["POS"] = item.Pos,
			["TOS"] = item.Tos,
			["CheckDate"] = FormatDate(item.CheckDate),
			["DaystoDOS"] = item.DaystoDos?.ToString() ?? string.Empty,
			["RollingDays"] = item.RollingDays,
			["DaystoBill"] = item.DaystoBill?.ToString() ?? string.Empty,
			["DaystoPost"] = item.DaystoPost?.ToString() ?? string.Empty,
			["Denial Classification"] = item.CleanDenialClassification,
			["Denial Type"] = item.DenialType,
			["Action Category"] = item.CleanActionCategory,
			["Action Code"] = item.ActionCode,
			["Recommended Action"] = item.RecommendedAction,
			["Task Guidance"] = item.TaskGuidance,
			["Task Status"] = item.TaskStatus,
			["Priority"] = item.CleanPriority,
			["SLA (Days)"] = item.SlaDays,
			["RunId"] = item.RunId,
			["CreatedOn"] = FormatDateTime(item.CreatedOn),
			[WorkflowTaskIdHeader] = wf.TaskId,
			[WorkflowAssignedToHeader] = wf.AssignedTo,
			[WorkflowStatusHeader] = wf.Status,
			[WorkflowNotesHeader] = wf.Notes
		};
		}).ToList();

		return (headers, rows);
	}

	private static void BuildLineItemSheet(XLWorkbook wb, List<string> lineHeaders, List<Dictionary<string, string>> lineRows)
	{
		var hiddenHeaders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
		{
			"Resolution",
			"Payer Policy Validation Required",
			"CPT Validation Required",
			"ICD Validation Required",
			"Frequency Validation Required",
			"Gender Validation Required",
			"MUE Validation Required"
		};

		var baseHeaders = VisibleLineHeaders(lineHeaders);

		// Excel refuses any cell over 32,767 characters — NorthWest's
		// "Covered ICD 10 codes as per Payer Policy" blows past it and used to fail the whole
		// export with "Cells can hold a maximum of 32,767 characters. (Parameter 'text')".
		// Measure the real overflow first, then spill each long value across
		// "{Header} (cont. 1)", "(cont. 2)" … columns. Columns that fit are untouched, so a
		// lab with no oversized values gets exactly the same sheet as before.
		var overflow = MeasureOverflow(baseHeaders, lineRows);
		var effectiveLineHeaders = BuildHeadersWithOverflow(baseHeaders, overflow);

		var ws1 = wb.AddWorksheet(LineItemSheetName);
		ws1.TabColor = ExcelTheme.TabGold;
		ExcelTheme.ApplyDefaults(ws1);

		for (int c = 0; c < effectiveLineHeaders.Count; c++)
		{
			var cell = ws1.Cell(1, c + 1);
			cell.Value = effectiveLineHeaders[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontSize = ExcelTheme.FontSizeHeader;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			cell.Style.Border.OutsideBorderColor = XLColor.White;
		}

		ws1.SheetView.FreezeRows(1);

		for (int r = 0; r < lineRows.Count; r++)
		{
			var row = lineRows[r];
			var col = 1;
			foreach (var header in baseHeaders)
			{
				row.TryGetValue(header, out var val);
				var extras = overflow.GetValueOrDefault(header);

				if (extras == 0)
				{
					ws1.Cell(r + 2, col++).Value = val ?? string.Empty;
					continue;
				}

				// Chunk boundaries prefer a comma, so a code is never cut in half.
				foreach (var chunk in ChunksFor(val, extras + 1))
					ws1.Cell(r + 2, col++).Value = chunk ?? string.Empty;
			}
		}

		if (lineRows.Count > 0)
		{
			// No zebra banding: plain white rows under a green header.
			var dataRange = ws1.Range(2, 1, lineRows.Count + 1, effectiveLineHeaders.Count);
			dataRange.Style.Fill.BackgroundColor = XLColor.White;
			dataRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			dataRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
		}

		string[] wrapColumns =
		{
			"Denial Description", "Coverage Status",
			"Covered ICD 10 codes as per Payer Policy",
			"Non Covered ICD 10 Codes as per Payer Policy",
			"Covered ICD 10 Codes Billed",
			"Non Covered ICD 10 Codes Billed",
			"Billed ICD codes not available in Payer Policy",
			"LIS ICD 10 Codes",
			"CCW ICD10Code",
			"Action Comment", "Coding Validation Sub-Status",
			"Recommended Action", "Notes / Comments", "Task Guidance",
			"Coverage Expectation Remarks",
			WorkflowNotesHeader
		};

		string[] dateColumns =
		{
			"Patient DOB",
			"First Billed Date",
			"Expected Payment Date",
			"Date of Service",
			"Denial Date",
			"ChargeEnteredDate",
			"CheckDate",
			"Claim Received Date",
			"Last Payment Date",
			"CreatedOn"
		};

		string[] moneyColumns =
		{
			"Billed Amount", "Allowed Amount", "Insurance Payment", "Insurance Adjustment",
			"Patient Paid Amount", "Patient Adjustment", "Insurance Balance", "Patient Balance",
			"Total Balance", "Medicare Fee", "Expected Average Allowed Amount",
			"Expected Average Insurance Payment", "Expected Allowed Amount - Same Lab",
			"Expected Insurance Payment - Same Lab", "Mode Allowed Amount - Same Lab",
			"Mode Insurance Paid - Same Lab", "Mode Allowed Amount- Peer",
			"Mode Insurance Paid- Peer", "Median Allowed Amount- Same Lab",
			"Median Insurance Paid - Same Lab", "Median Allowed Amount- Peer",
			"Median Insurance Paid - Peer", "Mode Allowed Amount Difference",
			"Mode Insurance Paid Difference", "Median Allowed Amount Difference",
			"Median Insurance Paid Difference"
		};

		for (int c = 0; c < effectiveLineHeaders.Count; c++)
		{
			var header = effectiveLineHeaders[c];
			var col = ws1.Column(c + 1);

			if (wrapColumns.Contains(header)) col.Style.Alignment.WrapText = true;
			if (dateColumns.Contains(header)) col.Style.NumberFormat.Format = "yyyy-mm-dd";
			if (moneyColumns.Contains(header)) col.Style.NumberFormat.Format = ExcelTheme.AccountingNumberFormat2;
		}

		for (int c = 0; c < effectiveLineHeaders.Count; c++)
		{
			var header = effectiveLineHeaders[c];
			if (hiddenHeaders.Contains(header.Trim())) ws1.Column(c + 1).Hide();
		}

		ws1.Columns().AdjustToContents();
		SetWidth(ws1, effectiveLineHeaders, "Denial Description", 40);
		SetWidth(ws1, effectiveLineHeaders, "Coverage Status", 25);
		SetWidth(ws1, effectiveLineHeaders, "Covered ICD 10 codes as per Payer Policy", 45);
		SetWidth(ws1, effectiveLineHeaders, "Non Covered ICD 10 Codes as per Payer Policy", 45);
		SetWidth(ws1, effectiveLineHeaders, "Covered ICD 10 Codes Billed", 40);
		SetWidth(ws1, effectiveLineHeaders, "Non Covered ICD 10 Codes Billed", 40);
		SetWidth(ws1, effectiveLineHeaders, "Billed ICD codes not available in Payer Policy", 45);
		SetWidth(ws1, effectiveLineHeaders, "LIS ICD 10 Codes", 35);
		SetWidth(ws1, effectiveLineHeaders, "CCW ICD10Code", 35);
		SetWidth(ws1, effectiveLineHeaders, "Action Comment", 40);
		SetWidth(ws1, effectiveLineHeaders, "Recommended Action", 45);
		SetWidth(ws1, effectiveLineHeaders, "Task Guidance", 45);
		SetWidth(ws1, effectiveLineHeaders, "Coverage Expectation Remarks", 45);
		SetWidth(ws1, effectiveLineHeaders, WorkflowNotesHeader, 50);
		SetWidth(ws1, effectiveLineHeaders, WorkflowAssignedToHeader, 22);
		SetWidth(ws1, effectiveLineHeaders, WorkflowStatusHeader, 18);

		if (lineRows.Count > 0 && effectiveLineHeaders.Count > 0)
		{
			// AutoFilter rather than CreateTable(): a ClosedXML table theme repaints the header
			// and forces banded rows, which is exactly what we no longer want. This keeps the
			// filter dropdowns, the green header and plain white rows.
			ws1.Range(1, 1, lineRows.Count + 1, effectiveLineHeaders.Count).SetAutoFilter();
		}

		foreach (var colName in effectiveLineHeaders)
		{
			int colIndex = effectiveLineHeaders.IndexOf(colName);
			if (colIndex < 0) continue;
			if (colName.Contains("Amount", StringComparison.OrdinalIgnoreCase) ||
				colName.Contains("Balance", StringComparison.OrdinalIgnoreCase) ||
				colName.Contains("Payment", StringComparison.OrdinalIgnoreCase) ||
				colName.Contains("Fee", StringComparison.OrdinalIgnoreCase))
			{
				var col = ws1.Column(colIndex + 1);
				col.AddConditionalFormat().WhenLessThan(0).Fill.SetBackgroundColor(XLColor.LightPink);
			}
		}

		int priorityIndex = effectiveLineHeaders.IndexOf("Priority");
		if (priorityIndex >= 0)
		{
			var col = ws1.Column(priorityIndex + 1);
			col.AddConditionalFormat().WhenContains("High").Fill.SetBackgroundColor(ExcelTheme.BadBg);
			col.AddConditionalFormat().WhenContains("Medium").Fill.SetBackgroundColor(ExcelTheme.NeutralBg);
			col.AddConditionalFormat().WhenContains("Low").Fill.SetBackgroundColor(ExcelTheme.GoodBg);
		}
	}

	/// <summary>
	/// The Denial Insight tab: the pre-aggregated dbo.DenialInsight rows for the run
	/// (the same rows and column order the page's insight grid renders).
	/// </summary>
	// ── Client template palette ────────────────────────────────────────────────────────────
	// Sampled from Template/01. Cove Dx_Denial Report_08.26.2026 - 09.01.2026 (1).xlsx. Its fills
	// resolve to the standard Office 2013-2022 scheme, so they are the same Accent 6 family
	// ExcelTheme already carries — but the template assigns the bands differently from how this
	// export used to, and those assignments are what make the workbook recognisable:
	//   header + title bands  Accent 6 Darker 50%  (#385723) — BOTH bands, not Darker 25%
	//   period labels         Accent 6 Lighter 80% (#E2EFDA) with BLACK text
	//   metric + Total rows   Light 2 Darker 10%   (#D0CFCF)
	//   denial child rows     Light 2              (#E7E6E6)
	//   payer group rows      no fill
	private static readonly XLColor TemplateBandBg = ExcelTheme.TitleBg;
	private static readonly XLColor TemplatePeriodBg = ExcelTheme.BandedRowBg;
	private static readonly XLColor TemplateMetricBg = XLColor.FromHtml("#D0CFCF");
	private static readonly XLColor TemplateChildBg = ExcelTheme.SubLabelBg;

	/// <summary>The template's own gold on the "Highest $ Impact" column group.</summary>
	private static readonly XLColor TemplateGoldBg = XLColor.FromHtml("#D09E00");

	/// <summary>The template's own red on Category / Action, and on the sheet tab.</summary>
	private static readonly XLColor TemplateRedBg = XLColor.FromHtml("#C00000");

	// The template writes whole dollars, not cents, in the pivots and the observations table.
	private const string TemplateAccounting = @"_(""$""* #,##0_);_(""$""* \(#,##0\);_(""$""* ""-""??_);_(@_)";
	private const string TemplateCount = @"#,##0;-#,##0;""-""";

	// Column map, matching the template cell-for-cell. Column A is a narrow gutter; the pivot and
	// the observations table both start at B, and both let a long label in C spill across D:F.
	private const int GutterCol = 1;
	private const int IndexCol = 2;   // B
	private const int LabelCol = 3;   // C
	private const int FirstDataCol = 7;   // G — first period column
	private const int ObservationsLastCol = 27;  // AA — Closed Date

	private static int PivotLastColumn(BreakdownPivotViewModel? model) =>
		model is null || model.Periods.Count == 0
			? FirstDataCol + 1
			: FirstDataCol + (model.Periods.Count * 2) + 2 - 1;

	/// <summary>
	/// The client template's lead sheet: report header block, monthly pivot, weekly pivot, then
	/// Key Observations &amp; Highlights — one sheet, in that order. This export previously spread
	/// the same content over three tabs with no header block at all.
	/// </summary>
	private static void BuildDenialInsightsSheet(XLWorkbook wb, DenialDashboardExportData data, string? fileName)
	{
		var ws = wb.AddWorksheet(DenialInsightsSheetName);
		ws.TabColor = TemplateRedBg;
		ExcelTheme.ApplyDefaults(ws);

		var lastColumn = Math.Max(
			Math.Max(PivotLastColumn(data.MonthlyPivot), PivotLastColumn(data.WeeklyPivot)),
			ObservationsLastCol);

		var row = WriteReportHeaderBlock(ws, data, fileName, lastColumn);
		row = WritePivotSection(ws, data.MonthlyPivot, row, "No denial-dated rows for the selected filters.");
		row = WritePivotSection(ws, data.WeeklyPivot, row, "No denial-dated rows in the last four weeks.");
		WriteKeyObservations(ws, data.Insights, row);

		ws.Column(GutterCol).Width = 4.5;
		ws.Column(IndexCol).Width = 4;
		ws.Column(LabelCol).Width = 13;
		for (var c = LabelCol + 1; c <= lastColumn; c++)
			ws.Column(c).Width = 13;
	}

	/// <summary>
	/// Client Name / Report Type / Data Range / Analysis Range / File Name / Source, with the
	/// disclaimer block on the right — the template's rows 2-7. Returns the first free row.
	/// </summary>
	private static int WriteReportHeaderBlock(
		IXLWorksheet ws, DenialDashboardExportData data, string? fileName, int lastColumn)
	{
		var fields = new (string Label, string Value)[]
		{
			("Client Name: ", data.LabName),
			("Report Type: ", "Denial Report"),
			("Data Range:", DescribeRange(data.MonthlyPivot, "Denial Posted Date")),
			("Analysis Range:", DescribeRange(data.WeeklyPivot, "Date Posted")),
			("File Name: ", string.IsNullOrWhiteSpace(fileName) ? "-" : Path.GetFileNameWithoutExtension(fileName)),
			("Source:", string.IsNullOrWhiteSpace(data.RunId) ? "-" : data.RunId)
		};

		var row = 2;
		foreach (var (label, value) in fields)
		{
			ws.Cell(row, LabelCol).Value = label;
			ws.Cell(row, LabelCol).Style.Font.Bold = true;
			ws.Cell(row, LabelCol + 1).Value = string.IsNullOrWhiteSpace(value) ? "-" : value;
			ws.Cell(row, LabelCol + 1).Style.Font.Bold = true;
			row++;
		}

		// Disclaimer, right-aligned with the pivot's last column like the template's AC2:AH7.
		var noticeCol = Math.Max(LabelCol + 3, lastColumn - 5);
		ws.Range(2, noticeCol, 7, noticeCol).Merge();
		ws.Cell(2, noticeCol).Value = "Notice / Disclaimer: ";
		ws.Cell(2, noticeCol).Style.Font.Bold = true;
		ws.Cell(2, noticeCol).Style.Alignment.SetVertical(XLAlignmentVerticalValues.Top).Alignment.SetWrapText();

		ws.Range(2, noticeCol + 1, 7, lastColumn).Merge();
		ws.Cell(2, noticeCol + 1).Value =
			"The following analysis and insights pertain exclusively to the denial data supplied for "
			+ "the stated period. Figures reflect claims denied within that window only and may change "
			+ "as payers reprocess or as later remittance is posted.";
		ws.Cell(2, noticeCol + 1).Style.Alignment.SetVertical(XLAlignmentVerticalValues.Top).Alignment.SetWrapText();

		return row + 2;   // one blank spacer row, as in the template
	}

	/// <summary>Human-readable period span for the header block, e.g. "Denial Posted Date | 01.01.2025 - 09.01.2026".</summary>
	private static string DescribeRange(BreakdownPivotViewModel? model, string basis)
	{
		var periods = model?.Periods.Where(x => !x.IsYearTotal).ToList();
		if (periods is not { Count: > 0 }) return $"{basis} | -";
		return $"{basis} | {periods.Min(x => x.StartDate):MM.dd.yyyy} - {periods.Max(x => x.EndDate):MM.dd.yyyy}";
	}

	/// <summary>
	/// One pivot block - title, header bands, payer/denial rows, Total, footnotes - written at
	/// <paramref name="startRow"/>. Returns the first free row after it.
	///
	/// The band layout follows the client template exactly, and differs from the old per-tab
	/// sheets in three ways that are easy to miss: the monthly block has NO separate section-title
	/// row (the year groups sit on the same row as the "Insurance and Top Denials" corner), a
	/// year-total column's label spans both header rows instead of getting a period label, and the
	/// fill is inverted - payer rows are unfilled and the denial rows beneath them carry the grey.
	/// </summary>
	private static int WritePivotSection(
		IXLWorksheet ws, BreakdownPivotViewModel? model, int startRow, string emptyMessage)
	{
		if (model is null || model.Periods.Count == 0)
		{
			ws.Cell(startRow, IndexCol).Value = emptyMessage;
			ws.Cell(startRow, IndexCol).Style.Font.Italic = true;
			return startRow + 2;
		}

		var lastCol = PivotLastColumn(model);
		var monthly = model.Periods.Any(x => x.IsYearTotal);

		var titleRow = startRow;
		ws.Range(titleRow, IndexCol, titleRow, lastCol).Merge();
		var title = ws.Cell(titleRow, IndexCol);
		title.Value = model.HeaderTitle;
		title.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
		title.Style.Fill.SetBackgroundColor(TemplateBandBg);
		title.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
			.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
		ws.Range(titleRow, IndexCol, titleRow, lastCol).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		var groupRow = titleRow + 1;    // year groups (monthly) or the section title (weekly)
		var periodRow = groupRow + 1;   // month / week labels
		var metricRow = periodRow + 1;  // No. of Claims | Denial Bal

		ws.Range(groupRow, IndexCol, metricRow, LabelCol + 3).Merge();
		var corner = ws.Cell(groupRow, IndexCol);
		corner.Value = "Insurance & Top Denials";
		corner.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
		corner.Style.Fill.SetBackgroundColor(TemplateBandBg);
		corner.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
			.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
		ws.Range(groupRow, IndexCol, metricRow, LabelCol + 3).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		var grandCol = FirstDataCol + (model.Periods.Count * 2);
		ws.Range(groupRow, grandCol, periodRow, lastCol).Merge();
		var grand = ws.Cell(groupRow, grandCol);
		grand.Value = monthly ? model.GrandTotalTitle : "Total";
		grand.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
		grand.Style.Fill.SetBackgroundColor(TemplateBandBg);
		grand.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
			.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
		ws.Range(groupRow, grandCol, periodRow, lastCol).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		if (monthly)
		{
			// Walk the periods and band each run of consecutive months that share a year. A
			// year-total period ends the run: its own header spans the group and period rows
			// instead (written in the period loop below), exactly as the template lays it out.
			var runStartCol = 0;
			var runYear = 0;
			var col = FirstDataCol;
			foreach (var period in model.Periods)
			{
				if (period.IsYearTotal)
				{
					if (runStartCol > 0) WriteYearBand(ws, groupRow, runStartCol, col - 1, runYear);
					runStartCol = 0;
				}
				else if (runStartCol == 0)
				{
					runStartCol = col;
					runYear = period.Year;
				}
				else if (period.Year != runYear)
				{
					WriteYearBand(ws, groupRow, runStartCol, col - 1, runYear);
					runStartCol = col;
					runYear = period.Year;
				}
				col += 2;
			}
			if (runStartCol > 0) WriteYearBand(ws, groupRow, runStartCol, col - 1, runYear);
		}
		else
		{
			ws.Range(groupRow, FirstDataCol, groupRow, grandCol - 1).Merge();
			var band = ws.Cell(groupRow, FirstDataCol);
			band.Value = model.SectionTitle;
			band.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
			band.Style.Fill.SetBackgroundColor(TemplateBandBg);
			band.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
				.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
			ws.Range(groupRow, FirstDataCol, groupRow, grandCol - 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		}

		// A year-total column has no month name of its own, so its label spans the group and
		// period rows instead - "2025 | Total" in the template.
		var periodCol = FirstDataCol;
		foreach (var period in model.Periods)
		{
			if (period.IsYearTotal)
			{
				ws.Range(groupRow, periodCol, periodRow, periodCol + 1).Merge();
				var yearTotal = ws.Cell(groupRow, periodCol);
				yearTotal.Value = period.Label;
				yearTotal.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
				yearTotal.Style.Fill.SetBackgroundColor(TemplateBandBg);
				yearTotal.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
					.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
				ws.Range(groupRow, periodCol, periodRow, periodCol + 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			}
			else
			{
				ws.Range(periodRow, periodCol, periodRow, periodCol + 1).Merge();
				var label = ws.Cell(periodRow, periodCol);
				label.Value = period.Label;
				label.Style.Font.Bold = true;
				label.Style.Fill.SetBackgroundColor(TemplatePeriodBg);
				label.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
					.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
				ws.Range(periodRow, periodCol, periodRow, periodCol + 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			}
			WriteMetricPair(ws, metricRow, periodCol);
			periodCol += 2;
		}
		WriteMetricPair(ws, metricRow, grandCol);

		var dataRow = metricRow + 1;
		var firstDataRow = dataRow;
		foreach (var pivotRow in model.Rows)
		{
			ws.Cell(dataRow, IndexCol).Value = pivotRow.IndexLabel;
			ws.Cell(dataRow, IndexCol).Style.Font.Bold = true;
			ws.Cell(dataRow, IndexCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			ws.Cell(dataRow, LabelCol).Value = pivotRow.Label;
			ws.Cell(dataRow, LabelCol).Style.Font.Bold = pivotRow.IsInsuranceRow;

			var range = ws.Range(dataRow, IndexCol, dataRow, lastCol);
			if (!pivotRow.IsInsuranceRow) range.Style.Fill.SetBackgroundColor(TemplateChildBg);
			range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;

			var cellCol = FirstDataCol;
			for (var i = 0; i < model.Periods.Count; i++)
			{
				var cell = i < pivotRow.Cells.Count ? pivotRow.Cells[i] : new BreakdownPivotCell();
				WriteCountAndBalance(ws, dataRow, cellCol, cell.ClaimCount, cell.DenialBalance);
				cellCol += 2;
			}
			WriteCountAndBalance(ws, dataRow, grandCol, pivotRow.TotalClaimCount, pivotRow.TotalBalance);
			dataRow++;
		}

		ws.Range(dataRow, IndexCol, dataRow, LabelCol + 3).Merge();
		ws.Cell(dataRow, IndexCol).Value = "Total";
		ws.Cell(dataRow, IndexCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Left;
		var totalRange = ws.Range(dataRow, IndexCol, dataRow, lastCol);
		totalRange.Style.Font.Bold = true;
		totalRange.Style.Fill.SetBackgroundColor(TemplateMetricBg);
		totalRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		totalRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;

		var totalCol = FirstDataCol;
		foreach (var total in model.TotalsByPeriod)
		{
			WriteCountAndBalance(ws, dataRow, totalCol, total.ClaimCount, total.DenialBalance);
			totalCol += 2;
		}
		WriteCountAndBalance(ws, dataRow, grandCol, model.GrandTotalClaimCount, model.GrandTotalBalance);

		// Outline the denial rows under their payer, so the (+) control the footnote points at
		// actually exists.
		for (var r = firstDataRow; r < dataRow; r++)
		{
			if (!model.Rows[r - firstDataRow].IsInsuranceRow) ws.Row(r).OutlineLevel = 1;
		}

		var footRow = dataRow + 1;
		ws.Cell(footRow, IndexCol).Value =
			"* The above totals includes only denied claims during the mentioned period of time.";
		ws.Cell(footRow, IndexCol).Style.Font.Italic = true;
		footRow++;
		ws.Cell(footRow, IndexCol).Value =
			"* Use the (+) sign on the left bar to view the top denials per payor.";
		ws.Cell(footRow, IndexCol).Style.Font.Italic = true;

		return footRow + 2;
	}

	/// <summary>One year band over the month columns it covers, excluding that year's total column.</summary>
	private static void WriteYearBand(IXLWorksheet ws, int row, int firstCol, int lastCol, int year)
	{
		if (lastCol < firstCol) return;
		if (lastCol > firstCol) ws.Range(row, firstCol, row, lastCol).Merge();
		var band = ws.Cell(row, firstCol);
		band.Value = year.ToString(System.Globalization.CultureInfo.InvariantCulture);
		band.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
		band.Style.Fill.SetBackgroundColor(TemplateBandBg);
		band.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
			.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
		ws.Range(row, firstCol, row, lastCol).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
	}

	/// <summary>The "No. of Claims" / "Denial Bal" pair under one period column.</summary>
	private static void WriteMetricPair(IXLWorksheet ws, int row, int col)
	{
		ws.Cell(row, col).Value = "No. of Claims";
		ws.Cell(row, col + 1).Value = "Denial Bal";
		var range = ws.Range(row, col, row, col + 1);
		range.Style.Font.Bold = true;
		range.Style.Fill.SetBackgroundColor(TemplateMetricBg);
		range.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
			.Alignment.SetVertical(XLAlignmentVerticalValues.Center).Alignment.SetWrapText();
		range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
	}

	/// <summary>
	/// A claim count and its balance. Both stay numeric - the count format renders zero as a dash
	/// and Accounting does the same for the balance, so the cells are still summable in Excel.
	/// </summary>
	private static void WriteCountAndBalance(IXLWorksheet ws, int row, int col, int count, decimal balance)
	{
		ws.Cell(row, col).Value = count;
		ws.Cell(row, col).Style.NumberFormat.Format = TemplateCount;
		ws.Cell(row, col).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		ws.Cell(row, col + 1).Value = balance;
		ws.Cell(row, col + 1).Style.NumberFormat.Format = TemplateAccounting;
		ws.Cell(row, col + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
	}

	/// <summary>
	/// "Key Observations &amp; Highlights" - the dbo.DenialInsight rows laid out in the client
	/// template's column groups, including its two colour-coded bands: gold over the highest-impact
	/// insurance columns, red over Category / Action.
	///
	/// Observation and Closed Date are written as empty, styled columns. Neither has a source in
	/// dbo.DenialInsight: in the client's workbook the AR analyst types them after the numbers are
	/// produced, and leaving the columns in place keeps this generated file a drop-in replacement
	/// for the hand-built one rather than something that has to be re-shaped before use.
	/// </summary>
	private static int WriteKeyObservations(IXLWorksheet ws, IReadOnlyList<DenialInsightRecord> insights, int startRow)
	{
		var titleRow = startRow;
		ws.Range(titleRow, IndexCol, titleRow, ObservationsLastCol).Merge();
		var title = ws.Cell(titleRow, IndexCol);
		title.Value = "Key Observations & Highlights";
		title.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
		title.Style.Fill.SetBackgroundColor(TemplateBandBg);
		title.Style.Alignment.SetVertical(XLAlignmentVerticalValues.Center);
		ws.Range(titleRow, IndexCol, titleRow, ObservationsLastCol).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		// (first column, last column, heading, fill) - the template's exact column map, B..AA.
		var columns = new (int First, int Last, string Header, XLColor Fill)[]
		{
			(2,  2,  "#",                            TemplateBandBg),
			(3,  3,  "Denial Codes",                 TemplateBandBg),
			(4,  5,  "Descriptions",                 TemplateBandBg),
			(6,  6,  "# of Denial",                  TemplateBandBg),
			(7,  7,  "Total Balance ($)",            TemplateBandBg),
			(8,  10, "Highest $ Impact - Insurance", TemplateGoldBg),
			(11, 11, "Ins. Balance ($)",             TemplateGoldBg),
			(12, 12, "$ Impact (%)",                 TemplateGoldBg),
			(13, 15, "Observation",                  TemplateBandBg),
			(16, 16, "Data",                         TemplateBandBg),
			(17, 17, "Category",                     TemplateRedBg),
			(18, 21, "Action",                       TemplateRedBg),
			(22, 23, "Feedback / Response",          TemplateBandBg),
			(24, 24, "Responsibility",               TemplateBandBg),
			(25, 25, "Discussion Date",              TemplateBandBg),
			(26, 26, "ETA",                          TemplateBandBg),
			(27, 27, "Closed Date",                  TemplateBandBg)
		};

		var headerRow = titleRow + 1;
		foreach (var (first, last, header, fillColor) in columns)
		{
			if (last > first) ws.Range(headerRow, first, headerRow, last).Merge();
			var cell = ws.Cell(headerRow, first);
			cell.Value = header;
			cell.Style.Font.SetBold().Font.SetFontColor(XLColor.White);
			cell.Style.Fill.SetBackgroundColor(fillColor);
			cell.Style.Alignment.SetHorizontal(XLAlignmentHorizontalValues.Center)
				.Alignment.SetVertical(XLAlignmentVerticalValues.Center).Alignment.SetWrapText();
			ws.Range(headerRow, first, headerRow, last).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			ws.Range(headerRow, first, headerRow, last).Style.Border.OutsideBorderColor = XLColor.White;
		}
		ws.Row(headerRow).Height = 28;

		if (insights.Count == 0)
		{
			ws.Cell(headerRow + 1, IndexCol).Value = "No denial insights for the selected filters.";
			ws.Cell(headerRow + 1, IndexCol).Style.Font.Italic = true;
			return headerRow + 3;
		}

		var row = headerRow + 1;
		for (var i = 0; i < insights.Count; i++)
		{
			var item = insights[i];

			// Merge every multi-column group on the data row too, so a long description or action
			// occupies the same block its heading spans instead of spilling under the next group.
			foreach (var (first, last, _, _) in columns.Where(x => x.Last > x.First))
				ws.Range(row, first, row, last).Merge();

			ws.Cell(row, 2).Value = i + 1;
			ws.Cell(row, 2).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			ws.Cell(row, 3).Value = item.DenialCodes;
			ws.Cell(row, 4).Value = item.Descriptions;
			ws.Cell(row, 6).Value = item.NoOfDenialCount;
			ws.Cell(row, 6).Style.NumberFormat.Format = TemplateCount;
			ws.Cell(row, 7).Value = item.TotalBalance;
			ws.Cell(row, 7).Style.NumberFormat.Format = TemplateAccounting;
			ws.Cell(row, 8).Value = item.HighImpactInsurance;
			ws.Cell(row, 11).Value = item.InsuranceBalance;
			ws.Cell(row, 11).Style.NumberFormat.Format = TemplateAccounting;
			ws.Cell(row, 12).Value = item.ImpactPercentage / 100m;
			ws.Cell(row, 12).Style.NumberFormat.Format = "0%";
			// 13-15 Observation: intentionally blank - analyst-authored, see the method remarks.
			ws.Cell(row, 16).Value = "Link";
			ws.Cell(row, 17).Value = item.ActionCategory;
			ws.Cell(row, 18).Value = item.Action;
			ws.Cell(row, 22).Value = item.Feedback;
			ws.Cell(row, 24).Value = string.IsNullOrWhiteSpace(item.Responsibility)
				? item.ResponsibilityReviewer
				: item.Responsibility;
			if (item.DiscussionDate.HasValue)
			{
				ws.Cell(row, 25).Value = item.DiscussionDate.Value;
				ws.Cell(row, 25).Style.NumberFormat.Format = "d-mmm";
			}
			ws.Cell(row, 26).Value = item.ETA;
			// 27 Closed Date: intentionally blank - analyst-authored.

			foreach (var wrapCol in new[] { 4, 13, 18, 22 })
				ws.Cell(row, wrapCol).Style.Alignment.WrapText = true;

			var range = ws.Range(row, IndexCol, row, ObservationsLastCol);
			range.Style.Alignment.Vertical = XLAlignmentVerticalValues.Top;
			range.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			range.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
			range.Style.Border.OutsideBorderColor = ExcelTheme.BorderColor;
			range.Style.Border.InsideBorderColor = ExcelTheme.BorderColor;
			row++;
		}

		return row + 1;
	}
	/// <summary>Suffix for a spill column holding part <paramref name="part"/> of an oversized value.</summary>
	private static string OverflowHeader(string header, int part) => $"{header} (cont. {part})";

	/// <summary>
	/// Ceiling on spill columns per source column — 5 extra columns is ~196K characters, far
	/// past anything readable. Without a cap one pathological row would widen the sheet for
	/// every row and can push the worksheet XML beyond what Excel (or the writer) can hold.
	/// Anything past the cap is truncated with a visible marker rather than dropped silently.
	/// </summary>
	private const int MaxOverflowColumns = 5;

	private static readonly HashSet<string> ExcludedLineHeaders = new(StringComparer.OrdinalIgnoreCase)
	{
		"DenialCode",
		"Denial Code",
		"Status Action Code",
	};

	/// <summary>The Line Item columns actually written, before overflow spilling.</summary>
	private static List<string> VisibleLineHeaders(List<string> headers) => headers
		.Where(h => !string.IsNullOrWhiteSpace(h) && !ExcludedLineHeaders.Contains(h.Trim()))
		.ToList();

	/// <summary>
	/// Exactly <paramref name="slots"/> chunks for one value: the split parts, padded with
	/// nulls, and the final slot marked when the value was longer than the cap allows.
	/// </summary>
	private static string?[] ChunksFor(string? value, int slots)
	{
		var result = new string?[slots];
		if (string.IsNullOrEmpty(value)) return result;

		var chunks = IcdCellSplitter.Split(value);
		for (var i = 0; i < slots && i < chunks.Count; i++)
			result[i] = chunks[i];

		if (chunks.Count > slots)
		{
			var dropped = chunks.Skip(slots).Sum(c => c.Length);
			var marker = $"…[+{dropped:N0} more characters truncated]";
			var last = result[slots - 1] ?? string.Empty;
			var keep = Math.Max(0, IcdCellSplitter.MaxCellLength - marker.Length);
			result[slots - 1] = (last.Length > keep ? last[..keep] : last) + marker;
		}

		return result;
	}

	/// <summary>
	/// How many EXTRA columns each header needs so its longest value fits Excel's
	/// 32,767-character cell limit. Zero for every column that already fits, which is the
	/// normal case — the spill columns only appear for labs that actually overflow.
	/// </summary>
	private static Dictionary<string, int> MeasureOverflow(
		List<string> headers,
		List<Dictionary<string, string>> rows)
	{
		var extras = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
		foreach (var header in headers)
		{
			var maxParts = 1;
			foreach (var row in rows)
			{
				if (!row.TryGetValue(header, out var value)) continue;
				if (value is null || value.Length <= IcdCellSplitter.MaxCellLength) continue;
				var parts = IcdCellSplitter.Split(value).Count;
				if (parts > maxParts) maxParts = parts;
			}
			extras[header] = Math.Min(maxParts - 1, MaxOverflowColumns);
		}
		return extras;
	}

	private static List<string> BuildHeadersWithOverflow(List<string> headers, Dictionary<string, int> extras)
	{
		var result = new List<string>(headers.Count);
		foreach (var header in headers)
		{
			result.Add(header);
			for (var part = 1; part <= extras.GetValueOrDefault(header); part++)
				result.Add(OverflowHeader(header, part));
		}
		return result;
	}

	private static void SetWidth(IXLWorksheet ws, List<string> headers, string header, double width)
	{
		int index = headers.IndexOf(header);
		if (index >= 0) ws.Column(index + 1).Width = width;
	}

	private static string FormatDate(DateTime? value) => value?.ToString("yyyy-MM-dd") ?? string.Empty;
	private static string FormatDateTime(DateTime? value) => value?.ToString("O") ?? string.Empty;
	private static string FormatDecimal(decimal? value) => value?.ToString("0.00") ?? string.Empty;
	private static string FormatDecimal(decimal value) => value.ToString("0.00");
}
