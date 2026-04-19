using ClosedXML.Excel;
using ClosedXML.Excel;
using LabMetricsDashboard.Models;
using LabMetricsDashboard.ViewModels;

namespace LabMetricsDashboard.Services;

public static class DenialDashboardExcelExportBuilder
{
	public static XLWorkbook CreateWorkbook(
		IReadOnlyList<DenialLineItemRecord> lineItems,
		IReadOnlyList<DenialRecord> taskRows,
		BreakdownPivotViewModel? weeklyPivot = null,
		BreakdownPivotViewModel? monthlyPivot = null)
	{
		var workbook = new XLWorkbook();

		var (lineHeaders, lineRows) = BuildLineSheetRows(lineItems);
		var (insightHeaders, insightRows) = BuildInsightSheetRows(lineItems);
		var taskSheetRows = BuildTaskSheetRows(taskRows);

		BuildDenialInsightsSheet(workbook, insightHeaders, insightRows);
		if (weeklyPivot is not null && weeklyPivot.Periods.Count > 0)
		{
			BuildBreakdownPivotSheet(workbook, "Weekly Breakdown", weeklyPivot);
		}

		if (monthlyPivot is not null && monthlyPivot.Periods.Count > 0)
		{
			BuildBreakdownPivotSheet(workbook, "Monthly Breakdown", monthlyPivot);
		}
		BuildTaskBoardSheet(workbook, taskSheetRows);
		BuildDenialDatabaseSheet(workbook, lineHeaders, lineRows);



		return workbook;
	}

	private static (List<string> Headers, List<Dictionary<string, string>> Rows) BuildLineSheetRows(IReadOnlyList<DenialLineItemRecord> lineItems)
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
			"CreatedOn"
		};

		var rows = lineItems.Select(item => new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
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
			["CreatedOn"] = FormatDateTime(item.CreatedOn)
		}).ToList();

		return (headers, rows);
	}

	private static (List<string> Headers, List<Dictionary<string, string>> Rows) BuildInsightSheetRows(IReadOnlyList<DenialLineItemRecord> lineItems)
	{
		if (lineItems.Count == 0)
		{
			return (new List<string>
			{
				"Denial Codes",
				"Descriptions",
				"# of Denial",
				"# of Claims",
				"Total Balance ($)",
				"Highest $ Impact - Insurance",
				"Ins. Balance ($)",
				"$ Impact (%)",
				"Observation",
				"Data",
				"Category",
				"Action Code",
				"Action",
				"Task",
				"Feedback / Response",
				"Responsibility",
				"Discussion Date",
				"ETA"
			}, new List<Dictionary<string, string>>());
		}

		var validRows = lineItems
			.Where(r => !string.IsNullOrWhiteSpace(r.DenialCodeNormalized))
			.ToList();

		var defaultHeaders = new List<string>
		{
			"Denial Codes",
			"Descriptions",
			"# of Denial",
			"# of Claims",
			"Total Balance ($)",
			"Highest $ Impact - Insurance",
			"Ins. Balance ($)",
			"$ Impact (%)",
			"Observation",
			"Data",
			"Category",
			"Action Code",
			"Action",
			"Task",
			"Feedback / Response",
			"Responsibility",
			"Discussion Date",
			"ETA"
		};

		if (validRows.Count == 0)
		{
			return (defaultHeaders, new List<Dictionary<string, string>>());
		}

		var groups = validRows.GroupBy(r => new
		{
			Code = r.DenialCodeNormalized ?? string.Empty,
			Desc = r.DenialDescription ?? string.Empty,
			Type = r.DenialType ?? string.Empty,
			ActionCode = r.ActionCode ?? string.Empty,
			Action = r.RecommendedAction ?? string.Empty,
			Task = r.TaskGuidance ?? string.Empty
		});

		var insightRows = new List<Dictionary<string, string>>();

		foreach (var g in groups)
		{
			var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
			{
				["Denial Codes"] = g.Key.Code,
				["Descriptions"] = g.Key.Desc,
				["# of Denial"] = g.Count().ToString(),
				["# of Claims"] = g.Select(r => r.VisitNumber ?? string.Empty).Where(v => !string.IsNullOrWhiteSpace(v)).Distinct(StringComparer.OrdinalIgnoreCase).Count().ToString()
			};

			var totalBalance = g.Sum(r => r.InsuranceBalance);
			row["Total Balance ($)"] = totalBalance.ToString("0.00");

			var highestPayer = g
				.GroupBy(r => !string.IsNullOrWhiteSpace(r.PayerNameNormalized) ? r.PayerNameNormalized : (r.PayerName ?? string.Empty), StringComparer.OrdinalIgnoreCase)
				.Select(x => new { Payer = x.Key, Balance = x.Sum(r => r.InsuranceBalance) })
				.OrderByDescending(x => x.Balance)
				.ThenBy(x => x.Payer)
				.FirstOrDefault();

			row["Highest $ Impact - Insurance"] = highestPayer?.Payer ?? string.Empty;
			var insBalance = highestPayer?.Balance ?? 0m;
			row["Ins. Balance ($)"] = insBalance.ToString("0.00");
			row["$ Impact (%)"] = totalBalance == 0 ? "0%" : ((insBalance / totalBalance) * 100m).ToString("0.00") + "%";
			row["Observation"] = g.GroupBy(r => r.PanelName ?? string.Empty, StringComparer.OrdinalIgnoreCase)
								  .OrderByDescending(x => x.Count())
								  .ThenBy(x => x.Key)
								  .Select(x => string.IsNullOrWhiteSpace(x.Key) ? "General" : x.Key)
								  .FirstOrDefault() ?? "General";
			row["Data"] = "Link";
			row["Category"] = g.Key.Type;
			row["Action Code"] = g.Key.ActionCode;
			row["Action"] = g.Key.Action;
			row["Task"] = g.Key.Task;
			row["Feedback / Response"] = string.Empty;
			row["Responsibility"] = string.Empty;
			row["Discussion Date"] = string.Empty;
			row["ETA"] = string.Empty;

			insightRows.Add(row);
		}

		insightRows = insightRows
			.OrderByDescending(r => ParseDecimal(r, "Total Balance ($)"))
			.ThenByDescending(r => ParseDecimal(r, "Ins. Balance ($)"))
			.ToList();

		return (defaultHeaders, insightRows);
	}

	private static List<Dictionary<string, string>> BuildTaskSheetRows(IReadOnlyList<DenialRecord> taskRows)
	{
		return taskRows.Select(row => new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
		{
			["Task ID"] = row.TaskId,
			["Claim ID"] = row.ClaimId,
			["Patient / Acct #"] = row.PatientAccountNumber,
			["CPT Code"] = row.CptCode,
			["Denial Code"] = row.DenialCode,
			["Denial Description"] = row.DenialDescription,
			["Denial Classification"] = row.DenialClassification,
			["Action Code"] = row.ActionCode,
			["Recommended Action"] = row.RecommendedAction,
			["Task"] = row.Task,
			["Action Category"] = row.EffectiveActionCategory,
			["Priority"] = row.Priority,
			["SLA (Days)"] = row.SlaDays > 0 ? row.SlaDays.ToString() : string.Empty,
			["Insurance Balance"] = row.InsuranceBalance.ToString("0.00"),
			["Assigned To"] = row.AssignedTo,
			["Status"] = row.Status,
			["Date Opened"] = row.DateOpened.ToString("yyyy-MM-dd"),
			["Due Date"] = row.DueDate.ToString("yyyy-MM-dd"),
			["Date Completed"] = FormatDate(row.DateCompleted),
			["Days Remaining"] = row.DaysRemaining?.ToString() ?? string.Empty,
			["SLA Status"] = row.SlaStatus
		}).ToList();
	}

	private static void BuildDenialDatabaseSheet(XLWorkbook wb, List<string> lineHeaders, List<Dictionary<string, string>> lineRows)
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

		var effectiveLineHeaders = lineHeaders
			.Where(h => !string.IsNullOrWhiteSpace(h) && !excludedHeaders.Contains(h.Trim()))
			.ToList();

		var ws1 = wb.AddWorksheet("Denial Database");
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
			for (int c = 0; c < effectiveLineHeaders.Count; c++)
			{
				var key = effectiveLineHeaders[c];
				row.TryGetValue(key, out var val);
				ws1.Cell(r + 2, c + 1).Value = val ?? string.Empty;
			}
		}

		if (lineRows.Count > 0)
		{
			var dataRange = ws1.Range(2, 1, lineRows.Count + 1, effectiveLineHeaders.Count);
			for (int r = 0; r < lineRows.Count; r++)
			{
				bool isEven = ((r + 1) % 2 == 0);
				var rowRange = dataRange.Row(r + 1);
				rowRange.Style.Fill.BackgroundColor = isEven ? ExcelTheme.BandedRowBg : XLColor.White;
			}

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
			"Coverage Expectation Remarks"
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

		if (lineRows.Count > 0 && effectiveLineHeaders.Count > 0)
		{
			var tableRange = ws1.Range(1, 1, lineRows.Count + 1, effectiveLineHeaders.Count);
			var table = tableRange.CreateTable();
			table.Theme = XLTableTheme.TableStyleMedium2;
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

	private static void BuildDenialInsightsSheet(XLWorkbook wb, List<string> insightHeaders, List<Dictionary<string, string>> insightRows)
	{
		var ws2 = wb.AddWorksheet("Denial Insights");
		ExcelTheme.ApplyDefaults(ws2);

		int rowOffset = 3;
		int colOffset = 2;

		var titleCell = ws2.Cell(rowOffset, colOffset);
		titleCell.Value = "Denial Insights Summary";
		ws2.Range(rowOffset, colOffset, rowOffset, colOffset + insightHeaders.Count - 1).Merge();
		titleCell.Style.Font.Bold = true;
		titleCell.Style.Font.FontColor = XLColor.White;
		titleCell.Style.Font.FontSize = ExcelTheme.FontSizeTitle;
		titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		titleCell.Style.Fill.BackgroundColor = ExcelTheme.TitleBg;
		titleCell.Style.Border.BottomBorder = XLBorderStyleValues.Thick;

		int headerRow = rowOffset + 2;

		for (int c = 0; c < insightHeaders.Count; c++)
		{
			var cell = ws2.Cell(headerRow, colOffset + c);
			cell.Value = insightHeaders[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = ExcelTheme.SubHeaderBg;
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
		}

		for (int r = 0; r < insightRows.Count; r++)
		{
			var row = insightRows[r];
			bool isEven = (r % 2 == 0);

			for (int c = 0; c < insightHeaders.Count; c++)
			{
				var key = insightHeaders[c];
				row.TryGetValue(key, out var val);
				var cell = ws2.Cell(headerRow + 1 + r, colOffset + c);
				cell.Style.Fill.BackgroundColor = isEven ? ExcelTheme.GroupRowBg : XLColor.White;

				if (key.Equals("Data", StringComparison.OrdinalIgnoreCase))
				{
					cell.Value = "Link";
					cell.SetHyperlink(new XLHyperlink("'Denial Database'!A1"));
					cell.Style.Font.FontColor = XLColor.Blue;
					cell.Style.Font.Underline = XLFontUnderlineValues.Single;
				}
				else if (key.Contains("Balance", StringComparison.OrdinalIgnoreCase) && decimal.TryParse(val, out var d))
				{
					cell.Value = d;
					cell.Style.NumberFormat.Format = "$#,##0.00";
				}
				else
				{
					cell.Value = val ?? string.Empty;
				}

				if (key is "Descriptions" or "Observation" or "Action" or "Task") cell.Style.Alignment.WrapText = true;
				cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			}
		}

		if (insightHeaders.Count > 0)
		{
			var insightsTableRange = ws2.Range(headerRow, colOffset, headerRow + insightRows.Count, colOffset + insightHeaders.Count - 1);
			var insightsTable = insightsTableRange.CreateTable();
			insightsTable.Theme = XLTableTheme.TableStyleMedium9;
		}

		SetInsightWidth(ws2, insightHeaders, colOffset, "Descriptions", 45);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Observation", 35);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Action Code", 25);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Action", 40);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Task", 30);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Data", 12);
		SetInsightWidth(ws2, insightHeaders, colOffset, "# of Denial", 15);
		SetInsightWidth(ws2, insightHeaders, colOffset, "# of Claims", 15);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Total Balance ($)", 18);
		SetInsightWidth(ws2, insightHeaders, colOffset, "Ins. Balance ($)", 18);
		SetInsightWidth(ws2, insightHeaders, colOffset, "$ Impact (%)", 15);

		ws2.SheetView.FreezeRows(headerRow);
	}

	private static void BuildTaskBoardSheet(XLWorkbook wb, List<Dictionary<string, string>> taskRows)
	{
		var ws3 = wb.AddWorksheet("Task Board");
		ExcelTheme.ApplyDefaults(ws3);

		var taskHeaders = new List<string>
		{
			"Task ID",
			"Claim ID",
			"Patient / Acct #",
			"CPT Code",
			"Denial Code",
			"Denial Description",
			"Denial Classification",
			"Action Code",
			"Recommended Action",
			"Task",
			"Action Category",
			"Priority",
			"SLA (Days)",
			"Insurance Balance",
			"Assigned To",
			"Status",
			"Date Opened",
			"Due Date",
			"Date Completed",
			"Days Remaining",
			"SLA Status"
		};

		for (int c = 0; c < taskHeaders.Count; c++)
		{
			var cell = ws3.Cell(1, c + 1);
			cell.Value = taskHeaders[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = ExcelTheme.HeaderBg;
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			cell.Style.Border.OutsideBorderColor = XLColor.White;
		}

		for (int r = 0; r < taskRows.Count; r++)
		{
			var row = taskRows[r];
			bool isEven = (r % 2 == 0);

			for (int c = 0; c < taskHeaders.Count; c++)
			{
				var key = taskHeaders[c];
				row.TryGetValue(key, out var val);
				var cell = ws3.Cell(r + 2, c + 1);
				cell.Value = val ?? string.Empty;
				cell.Style.Fill.BackgroundColor = isEven ? ExcelTheme.BandedRowBg : XLColor.White;

				if (key is "Recommended Action" or "Task") cell.Style.Alignment.WrapText = true;
				if (key is "Date Opened" or "Due Date" or "Date Completed" or "CreatedOn")
				{
					if (DateTime.TryParse(val, out var dt))
					{
						cell.Value = dt;
						cell.Style.NumberFormat.Format = "yyyy-MM-dd";
					}
				}
				if (key == "Insurance Balance" && decimal.TryParse(val, out var amt))
				{
					cell.Value = amt;
					cell.Style.NumberFormat.Format = "$#,##0.00";
				}
				cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			}
		}

		if (taskRows.Count > 0)
		{
			var taskTableRange = ws3.Range(1, 1, taskRows.Count + 1, taskHeaders.Count);
			var taskTable = taskTableRange.CreateTable();
			taskTable.Theme = XLTableTheme.TableStyleMedium4;
		}

		ws3.SheetView.FreezeRows(1);
		ws3.Columns().AdjustToContents();
	}

	private static void BuildBreakdownPivotSheet(XLWorkbook wb, string sheetName, BreakdownPivotViewModel model)
	{
		var ws = wb.AddWorksheet(sheetName);
		ExcelTheme.ApplyDefaults(ws);
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

	private static decimal ParseDecimal(Dictionary<string, string> row, string key)
		=> row.TryGetValue(key, out var v) && decimal.TryParse(v, out var d) ? d : 0m;

	private static void SetWidth(IXLWorksheet ws, List<string> headers, string header, double width)
	{
		int index = headers.IndexOf(header);
		if (index >= 0) ws.Column(index + 1).Width = width;
	}

	private static void SetInsightWidth(IXLWorksheet ws, List<string> headers, int colOffset, string header, double width)
	{
		int index = headers.IndexOf(header);
		if (index >= 0) ws.Column(colOffset + index).Width = width;
	}

	private static string FormatDate(DateTime? value) => value?.ToString("yyyy-MM-dd") ?? string.Empty;
	private static string FormatDateTime(DateTime? value) => value?.ToString("O") ?? string.Empty;
	private static string FormatDecimal(decimal? value) => value?.ToString("0.00") ?? string.Empty;
	private static string FormatDecimal(decimal value) => value.ToString("0.00");
}
