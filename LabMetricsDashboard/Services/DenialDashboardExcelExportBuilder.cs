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
	/// Monthly Breakdown, Weekly Breakdown, Filter Panel, SLA Tracker, Denial Insight,
	/// Line Item. Every sheet is written even when its tab has no rows, so the workbook
	/// shape never changes between runs.
	/// </summary>
	public static XLWorkbook CreateWorkbook(DenialDashboardExportData data)
	{
		var workbook = new XLWorkbook();

		BuildBreakdownPivotSheet(workbook, "Monthly Breakdown", data.MonthlyPivot);
		BuildBreakdownPivotSheet(workbook, "Weekly Breakdown", data.WeeklyPivot);
		BuildFilterPanelSheet(workbook, data);
		BuildSlaTrackerSheet(workbook, data.TaskRecords);
		BuildDenialInsightSheet(workbook, data.Insights);

		var (lineHeaders, lineRows) = BuildLineSheetRows(data.LineItems, data.Workflow);
		BuildLineItemSheet(workbook, lineHeaders, lineRows);

		return workbook;
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
		var excludedHeaders = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
		{
			"DenialCode",
			"Denial Code",
			"Status Action Code"
		};

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

		var baseHeaders = lineHeaders
			.Where(h => !string.IsNullOrWhiteSpace(h) && !excludedHeaders.Contains(h.Trim()))
			.ToList();

		// Excel refuses any cell over 32,767 characters — NorthWest's
		// "Covered ICD 10 codes as per Payer Policy" blows past it and used to fail the whole
		// export with "Cells can hold a maximum of 32,767 characters. (Parameter 'text')".
		// Measure the real overflow first, then spill each long value across
		// "{Header} (cont. 1)", "(cont. 2)" … columns. Columns that fit are untouched, so a
		// lab with no oversized values gets exactly the same sheet as before.
		var overflow = MeasureOverflow(baseHeaders, lineRows);
		var effectiveLineHeaders = BuildHeadersWithOverflow(baseHeaders, overflow);

		var ws1 = wb.AddWorksheet("Line Item");
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
				var chunks = IcdCellSplitter.Split(val ?? string.Empty);
				for (var part = 0; part <= extras; part++)
					ws1.Cell(r + 2, col++).Value = part < chunks.Count ? chunks[part] : string.Empty;
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
			if (moneyColumns.Contains(header)) col.Style.NumberFormat.Format = "$#,##0.00";
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
	/// The Filter Panel tab: the five mini-panels (Task Status, Priority, Action Category,
	/// Classification, Deadline) stacked on one sheet, each with the tab's own
	/// Label / Claims / Balance / Rate columns over the CURRENTLY FILTERED task rows.
	/// </summary>
	private static void BuildFilterPanelSheet(XLWorkbook wb, DenialDashboardExportData data)
	{
		var ws = wb.AddWorksheet("Filter Panel");
		ExcelTheme.ApplyDefaults(ws);

		var row = 1;
		ws.Cell(row, 1).Value = $"Filter Panel — {data.LabName}";
		ws.Range(row, 1, row, 4).Merge();
		var title = ws.Range(row, 1, row, 4);
		title.Style.Font.Bold = true;
		title.Style.Font.FontSize = ExcelTheme.FontSizeTitle;
		title.Style.Font.FontColor = XLColor.White;
		title.Style.Fill.BackgroundColor = ExcelTheme.TitleBg;
		title.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		row++;

		ws.Cell(row, 1).Value = "Run Id";
		ws.Cell(row, 2).Value = string.IsNullOrWhiteSpace(data.RunId) ? "-" : data.RunId;
		ws.Cell(row, 1).Style.Font.Bold = true;
		row++;
		ws.Cell(row, 1).Value = "Tasks (filtered)";
		ws.Cell(row, 2).Value = data.TaskRecords.Count;
		ws.Cell(row, 1).Style.Font.Bold = true;
		row += 2;

		// Active filters, so a downloaded workbook always says what it was filtered by.
		if (data.ActiveFilters.Count > 0)
		{
			ws.Cell(row, 1).Value = "Active Filters";
			ws.Range(row, 1, row, 4).Merge();
			ws.Cell(row, 1).Style.Font.Bold = true;
			ws.Cell(row, 1).Style.Font.FontColor = XLColor.White;
			ws.Cell(row, 1).Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
			row++;
			foreach (var (label, value) in data.ActiveFilters)
			{
				ws.Cell(row, 1).Value = label;
				ws.Cell(row, 2).Value = value ?? string.Empty;
				ws.Range(row, 2, row, 4).Merge();
				ws.Cell(row, 1).Style.Font.Bold = true;
				row++;
			}
			row++;
		}

		row = WriteBreakdownBlock(ws, row, "Task Status", data.StatusBreakdown);
		row = WriteBreakdownBlock(ws, row, "Priority", data.PriorityBreakdown);
		row = WriteBreakdownBlock(ws, row, "Action Category", data.ActionCategoryBreakdown);
		row = WriteBreakdownBlock(ws, row, "Classification", data.ClassificationBreakdown);
		_ = WriteBreakdownBlock(ws, row, "Deadline", data.DeadlineBreakdown);

		ws.Column(1).Width = 42;
		ws.Column(2).Width = 14;
		ws.Column(3).Width = 18;
		ws.Column(4).Width = 12;
	}

	/// <summary>Writes one mini-panel and returns the next free row (blank row included).</summary>
	private static int WriteBreakdownBlock(IXLWorksheet ws, int startRow, string title, IReadOnlyList<BreakdownItem> items)
	{
		var row = startRow;
		ws.Cell(row, 1).Value = title;
		ws.Range(row, 1, row, 4).Merge();
		var header = ws.Range(row, 1, row, 4);
		header.Style.Font.Bold = true;
		header.Style.Font.FontColor = XLColor.White;
		header.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
		header.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		row++;

		var columnRow = row;
		ws.Cell(row, 1).Value = "Label";
		ws.Cell(row, 2).Value = "Claims";
		ws.Cell(row, 3).Value = "Balance";
		ws.Cell(row, 4).Value = "Rate";
		var columns = ws.Range(row, 1, row, 4);
		columns.Style.Font.Bold = true;
		columns.Style.Fill.BackgroundColor = ExcelTheme.GroupRowBg;
		columns.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		columns.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
		row++;

		if (items.Count == 0)
		{
			ws.Cell(row, 1).Value = "No rows for the selected filters.";
			ws.Range(row, 1, row, 4).Merge();
			return row + 2;
		}

		foreach (var item in items)
		{
			ws.Cell(row, 1).Value = item.Label;
			ws.Cell(row, 2).Value = item.Count;
			ws.Cell(row, 3).Value = item.InsuranceBalanceSum;
			ws.Cell(row, 3).Style.NumberFormat.Format = "$#,##0.00";
			ws.Cell(row, 4).Value = item.Percentage / 100m;
			ws.Cell(row, 4).Style.NumberFormat.Format = "0.0%";
			row++;
		}

		var body = ws.Range(columnRow, 1, row - 1, 4);
		body.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		body.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
		return row + 1;
	}

	/// <summary>The SLA Tracker tab: the deadline monitor, same columns and order as the page.</summary>
	private static void BuildSlaTrackerSheet(XLWorkbook wb, IReadOnlyList<DenialRecord> records)
	{
		var ws = wb.AddWorksheet("SLA Tracker");
		ExcelTheme.ApplyDefaults(ws);

		var headers = new List<string>
		{
			"Task ID", "Claim ID", "Patient / Acct #", "CPT", "Task", "Priority",
			"Insurance Balance", "Status", "SLA Days", "Due Date", "Days Remaining",
			"Escalation Flag", "SLA Status", "Assigned To", "Date Opened", "Date Completed"
		};

		for (var c = 0; c < headers.Count; c++)
		{
			var cell = ws.Cell(1, c + 1);
			cell.Value = headers[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			cell.Style.Border.OutsideBorderColor = XLColor.White;
		}

		for (var r = 0; r < records.Count; r++)
		{
			var item = records[r];
			var excelRow = r + 2;

			ws.Cell(excelRow, 1).Value = item.TaskId;
			ws.Cell(excelRow, 2).Value = item.ClaimId;
			ws.Cell(excelRow, 3).Value = item.PatientAccountNumber;
			ws.Cell(excelRow, 4).Value = item.CptCode;
			ws.Cell(excelRow, 5).Value = item.Task;
			ws.Cell(excelRow, 6).Value = item.Priority;
			ws.Cell(excelRow, 7).Value = item.InsuranceBalance;
			ws.Cell(excelRow, 7).Style.NumberFormat.Format = "$#,##0.00";
			ws.Cell(excelRow, 8).Value = item.Status;
			ws.Cell(excelRow, 9).Value = item.SlaDays;
			ws.Cell(excelRow, 10).Value = item.DueDate;
			ws.Cell(excelRow, 10).Style.NumberFormat.Format = "yyyy-mm-dd";
			// "Done" mirrors the page, which shows that instead of a number once the task closes.
			ws.Cell(excelRow, 11).Value = item.DaysRemaining?.ToString() ?? "Done";
			ws.Cell(excelRow, 12).Value = item.EscalationFlag;
			ws.Cell(excelRow, 13).Value = item.SlaStatus;
			ws.Cell(excelRow, 14).Value = item.AssignedTo;
			ws.Cell(excelRow, 15).Value = item.DateOpened;
			ws.Cell(excelRow, 15).Style.NumberFormat.Format = "yyyy-mm-dd";
			if (item.DateCompleted.HasValue)
			{
				ws.Cell(excelRow, 16).Value = item.DateCompleted.Value;
				ws.Cell(excelRow, 16).Style.NumberFormat.Format = "yyyy-mm-dd";
			}

			ws.Cell(excelRow, 5).Style.Alignment.WrapText = true;
			ws.Range(excelRow, 1, excelRow, headers.Count).Style.Fill.BackgroundColor = XLColor.White;
		}

		if (records.Count > 0)
		{
			ws.Range(1, 1, records.Count + 1, headers.Count).SetAutoFilter();

			var priorityColumn = ws.Column(6);
			priorityColumn.AddConditionalFormat().WhenContains("High").Fill.SetBackgroundColor(ExcelTheme.BadBg);
			priorityColumn.AddConditionalFormat().WhenContains("Medium").Fill.SetBackgroundColor(ExcelTheme.NeutralBg);
			priorityColumn.AddConditionalFormat().WhenContains("Low").Fill.SetBackgroundColor(ExcelTheme.GoodBg);
			ws.Column(12).AddConditionalFormat().WhenContains("Escalate").Fill.SetBackgroundColor(ExcelTheme.BadBg);
		}
		else
		{
			ws.Cell(2, 1).Value = "No tasks matched the selected filters.";
		}

		ws.SheetView.FreezeRows(1);
		ws.Columns().AdjustToContents();
		SetWidth(ws, headers, "Task", 45);
	}

	/// <summary>
	/// The Denial Insight tab: the pre-aggregated dbo.DenialInsight rows for the run
	/// (the same rows and column order the page's insight grid renders).
	/// </summary>
	private static void BuildDenialInsightSheet(XLWorkbook wb, IReadOnlyList<DenialInsightRecord> insights)
	{
		var ws = wb.AddWorksheet("Denial Insight");
		ExcelTheme.ApplyDefaults(ws);

		var headers = new List<string>
		{
			"Denial Codes", "Description", "# of Denial", "# of Claims", "Total Balance",
			"High Impact Insurance", "Insurance Balance", "$ Impact (%)", "Action Category",
			"Action Code", "Action", "Task", "Feedback", "Responsibility",
			"Responsibility Reviewer", "Discussion Date", "ETA"
		};

		for (var c = 0; c < headers.Count; c++)
		{
			var cell = ws.Cell(1, c + 1);
			cell.Value = headers[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			cell.Style.Border.OutsideBorderColor = XLColor.White;
		}

		for (var r = 0; r < insights.Count; r++)
		{
			var item = insights[r];
			var excelRow = r + 2;

			ws.Cell(excelRow, 1).Value = item.DenialCodes;
			ws.Cell(excelRow, 2).Value = item.Descriptions;
			ws.Cell(excelRow, 3).Value = item.NoOfDenialCount;
			ws.Cell(excelRow, 4).Value = item.NoOfClaimsCount;
			ws.Cell(excelRow, 5).Value = item.TotalBalance;
			ws.Cell(excelRow, 5).Style.NumberFormat.Format = "$#,##0.00";
			ws.Cell(excelRow, 6).Value = item.HighImpactInsurance;
			ws.Cell(excelRow, 7).Value = item.InsuranceBalance;
			ws.Cell(excelRow, 7).Style.NumberFormat.Format = "$#,##0.00";
			ws.Cell(excelRow, 8).Value = item.ImpactPercentage / 100m;
			ws.Cell(excelRow, 8).Style.NumberFormat.Format = "0.00%";
			ws.Cell(excelRow, 9).Value = item.ActionCategory;
			ws.Cell(excelRow, 10).Value = item.ActionCode;
			ws.Cell(excelRow, 11).Value = item.Action;
			ws.Cell(excelRow, 12).Value = item.Task;
			ws.Cell(excelRow, 13).Value = item.Feedback;
			ws.Cell(excelRow, 14).Value = item.Responsibility;
			ws.Cell(excelRow, 15).Value = item.ResponsibilityReviewer;
			if (item.DiscussionDate.HasValue)
			{
				ws.Cell(excelRow, 16).Value = item.DiscussionDate.Value;
				ws.Cell(excelRow, 16).Style.NumberFormat.Format = "yyyy-mm-dd";
			}
			ws.Cell(excelRow, 17).Value = item.ETA;

			foreach (var wrapColumn in new[] { 2, 11, 12, 13 })
				ws.Cell(excelRow, wrapColumn).Style.Alignment.WrapText = true;

			ws.Range(excelRow, 1, excelRow, headers.Count).Style.Fill.BackgroundColor = XLColor.White;
		}

		if (insights.Count > 0)
		{
			ws.Range(1, 1, insights.Count + 1, headers.Count).SetAutoFilter();
		}
		else
		{
			ws.Cell(2, 1).Value = "No denial insights for the selected filters.";
		}

		ws.SheetView.FreezeRows(1);
		ws.Columns().AdjustToContents();
		SetWidth(ws, headers, "Description", 45);
		SetWidth(ws, headers, "Action", 40);
		SetWidth(ws, headers, "Task", 30);
		SetWidth(ws, headers, "Feedback", 35);
	}

	private static void BuildBreakdownPivotSheet(XLWorkbook wb, string sheetName, BreakdownPivotViewModel? model)
	{
		var ws = wb.AddWorksheet(sheetName);
		ExcelTheme.ApplyDefaults(ws);

		// The tab renders an empty pivot as "no data"; the sheet must still exist so the
		// workbook always has the same six tabs.
		if (model is null || model.Periods.Count == 0)
		{
			ws.Cell(1, 1).Value = sheetName;
			ws.Cell(1, 1).Style.Font.Bold = true;
			ws.Cell(1, 1).Style.Font.FontSize = ExcelTheme.FontSizeTitle;
			ws.Cell(2, 1).Value = "No denial-dated rows for the selected filters.";
			ws.Column(1).Width = 52;
			return;
		}

		BuildBreakdownPivotSheetCore(ws, model);
	}

	private static void BuildBreakdownPivotSheetCore(IXLWorksheet ws, BreakdownPivotViewModel model)
	{
		var totalColumns = 2 + (model.Periods.Count * 2) + 2;
		var monthly = model.Periods.Any(x => x.IsYearTotal);

		ws.Cell(1, 1).Value = model.HeaderTitle;
		ws.Range(1, 1, 1, totalColumns).Merge();
		var titleRange = ws.Range(1, 1, 1, totalColumns);
		titleRange.Style.Font.Bold = true;
		titleRange.Style.Font.FontColor = XLColor.White;
		titleRange.Style.Font.FontSize = ExcelTheme.FontSizeTitle;
		titleRange.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		titleRange.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
		titleRange.Style.Fill.BackgroundColor = ExcelTheme.TitleBg;
		titleRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		var leftEndRow = monthly ? 4 : 3;
		ws.Cell(2, 1).Value = "Insurance & Top Denials";
		ws.Range(2, 1, leftEndRow, 2).Merge();
		var leftHeader = ws.Range(2, 1, leftEndRow, 2);
		leftHeader.Style.Font.Bold = true;
		leftHeader.Style.Font.FontColor = XLColor.White;
		leftHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		leftHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
		leftHeader.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
		leftHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		if (model.Periods.Count > 0)
		{
			ws.Cell(2, 3).Value = model.SectionTitle;
			ws.Range(2, 3, 2, 2 + (model.Periods.Count * 2)).Merge();
			var sectionHeader = ws.Range(2, 3, 2, 2 + (model.Periods.Count * 2));
			sectionHeader.Style.Font.Bold = true;
			sectionHeader.Style.Font.FontColor = XLColor.White;
			sectionHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			sectionHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
			sectionHeader.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
			sectionHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		}

		var grandHeaderStart = 3 + (model.Periods.Count * 2);
		ws.Cell(2, grandHeaderStart).Value = monthly ? model.GrandTotalTitle : "Total";
		ws.Range(2, grandHeaderStart, monthly ? 4 : 3, totalColumns).Merge();
		var totalHeader = ws.Range(2, grandHeaderStart, monthly ? 4 : 3, totalColumns);
		totalHeader.Style.Font.Bold = true;
		totalHeader.Style.Font.FontColor = XLColor.White;
		totalHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		totalHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
		totalHeader.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
		totalHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

		var metricsRow = monthly ? 5 : 4;
		var periodHeaderRow = monthly ? 4 : 3;
		if (monthly)
		{
			var col = 3;
			foreach (var group in model.ColumnGroups.Where(x => !string.Equals(x.Label, model.GrandTotalTitle, StringComparison.OrdinalIgnoreCase)))
			{
				ws.Cell(3, col).Value = group.Label;
				ws.Range(3, col, 3, col + group.ColumnSpan - 1).Merge();
				var yearHeader = ws.Range(3, col, 3, col + group.ColumnSpan - 1);
				yearHeader.Style.Font.Bold = true;
				yearHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
				yearHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
				yearHeader.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
				yearHeader.Style.Font.FontColor = XLColor.White;
				yearHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
				col += group.ColumnSpan;
			}
		}

		var periodCol = 3;
		foreach (var period in model.Periods)
		{
			ws.Cell(periodHeaderRow, periodCol).Value = period.Label;
			ws.Range(periodHeaderRow, periodCol, periodHeaderRow, periodCol + 1).Merge();
			var periodHeader = ws.Range(periodHeaderRow, periodCol, periodHeaderRow, periodCol + 1);
			periodHeader.Style.Font.Bold = true;
			periodHeader.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			periodHeader.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
			periodHeader.Style.Fill.BackgroundColor = ExcelTheme.GroupRowBg;
			periodHeader.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;

			ws.Cell(metricsRow, periodCol).Value = "No. of Claims";
			ws.Cell(metricsRow, periodCol + 1).Value = "Insurance Balance";
			ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Font.Bold = true;
			ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Fill.BackgroundColor = ExcelTheme.SubLabelBg;
			ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Border.InsideBorder = XLBorderStyleValues.Thin;
			periodCol += 2;
		}

		ws.Cell(metricsRow, periodCol).Value = "No. of Claims";
		ws.Cell(metricsRow, periodCol + 1).Value = "Insurance Balance";
		ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Font.Bold = true;
		ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Fill.BackgroundColor = ExcelTheme.SubLabelBg;
		ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		ws.Range(metricsRow, periodCol, metricsRow, periodCol + 1).Style.Border.InsideBorder = XLBorderStyleValues.Thin;

		var dataRow = metricsRow + 1;
		foreach (var row in model.Rows)
		{
			ws.Cell(dataRow, 1).Value = row.IndexLabel;
			ws.Cell(dataRow, 2).Value = row.Label;

			var rowRange = ws.Range(dataRow, 1, dataRow, totalColumns);
			rowRange.Style.Fill.BackgroundColor = row.IsInsuranceRow ? ExcelTheme.GroupRowBg : XLColor.White;
			rowRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			rowRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;

			ws.Cell(dataRow, 1).Style.Font.Bold = true;
			ws.Cell(dataRow, 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			ws.Cell(dataRow, 2).Style.Alignment.WrapText = true;
			ws.Cell(dataRow, 2).Style.Font.Bold = row.IsInsuranceRow;

			var cellCol = 3;
			for (var i = 0; i < model.Periods.Count; i++)
			{
				var cell = i < row.Cells.Count ? row.Cells[i] : new BreakdownPivotCell();
				ws.Cell(dataRow, cellCol).Value = cell.ClaimCount == 0 ? "-" : cell.ClaimCount;
				if (cell.DenialBalance == 0)
				{
					ws.Cell(dataRow, cellCol + 1).Value = "$ -";
				}
				else
				{
					ws.Cell(dataRow, cellCol + 1).Value = cell.DenialBalance;
					ws.Cell(dataRow, cellCol + 1).Style.NumberFormat.Format = "$#,##0.00";
				}
				ws.Cell(dataRow, cellCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
				ws.Cell(dataRow, cellCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
				cellCol += 2;
			}

			ws.Cell(dataRow, cellCol).Value = row.TotalClaimCount == 0 ? "-" : row.TotalClaimCount;
			if (row.TotalBalance == 0)
			{
				ws.Cell(dataRow, cellCol + 1).Value = "$ -";
			}
			else
			{
				ws.Cell(dataRow, cellCol + 1).Value = row.TotalBalance;
				ws.Cell(dataRow, cellCol + 1).Style.NumberFormat.Format = "$#,##0.00";
			}
			ws.Cell(dataRow, cellCol).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			ws.Cell(dataRow, cellCol + 1).Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Right;
			dataRow++;
		}

		ws.Cell(dataRow, 1).Value = "";
		ws.Cell(dataRow, 2).Value = "Total";
		ws.Range(dataRow, 1, dataRow, totalColumns).Style.Font.Bold = true;
		ws.Range(dataRow, 1, dataRow, totalColumns).Style.Fill.BackgroundColor = ExcelTheme.TotalRowBg;
		ws.Range(dataRow, 1, dataRow, totalColumns).Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		ws.Range(dataRow, 1, dataRow, totalColumns).Style.Border.InsideBorder = XLBorderStyleValues.Thin;

		var totalCol = 3;
		for (var i = 0; i < model.TotalsByPeriod.Count; i++)
		{
			var total = model.TotalsByPeriod[i];
			ws.Cell(dataRow, totalCol).Value = total.ClaimCount == 0 ? "-" : total.ClaimCount;
			if (total.DenialBalance == 0)
			{
				ws.Cell(dataRow, totalCol + 1).Value = "$ -";
			}
			else
			{
				ws.Cell(dataRow, totalCol + 1).Value = total.DenialBalance;
				ws.Cell(dataRow, totalCol + 1).Style.NumberFormat.Format = "$#,##0.00";
			}
			totalCol += 2;
		}

		ws.Cell(dataRow, totalCol).Value = model.GrandTotalClaimCount == 0 ? "-" : model.GrandTotalClaimCount;
		if (model.GrandTotalBalance == 0)
		{
			ws.Cell(dataRow, totalCol + 1).Value = "$ -";
		}
		else
		{
			ws.Cell(dataRow, totalCol + 1).Value = model.GrandTotalBalance;
			ws.Cell(dataRow, totalCol + 1).Style.NumberFormat.Format = "$#,##0.00";
		}

		ws.SheetView.FreezeRows(metricsRow);
		ws.SheetView.FreezeColumns(2);
		ws.Column(1).Width = 6;
		ws.Column(2).Width = 56;
		for (var c = 3; c <= totalColumns; c++)
		{
			ws.Column(c).Width = 16;
		}
	}

	/// <summary>Suffix for a spill column holding part <paramref name="part"/> of an oversized value.</summary>
	private static string OverflowHeader(string header, int part) => $"{header} (cont. {part})";

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
			extras[header] = maxParts - 1;
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
