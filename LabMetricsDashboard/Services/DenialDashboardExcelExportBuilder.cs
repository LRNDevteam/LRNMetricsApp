using ClosedXML.Excel;
using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

public static class DenialDashboardExcelExportBuilder
{
	public static XLWorkbook CreateWorkbook(
		IReadOnlyList<DenialLineItemRecord> lineItems,
		IReadOnlyList<DenialRecord> taskRows)
	{
		var workbook = new XLWorkbook();

		var (lineHeaders, lineRows) = BuildLineSheetRows(lineItems);
		var (insightHeaders, insightRows) = BuildInsightSheetRows(lineItems);
		var taskSheetRows = BuildTaskSheetRows(taskRows);

		BuildDenialDatabaseSheet(workbook, lineHeaders, lineRows);
		BuildDenialInsightsSheet(workbook, insightHeaders, insightRows);
		BuildTaskBoardSheet(workbook, taskSheetRows);

		return workbook;
	}

	private static (List<string> Headers, List<Dictionary<string, string>> Rows) BuildLineSheetRows(IReadOnlyList<DenialLineItemRecord> lineItems)
	{
		var headers = new List<string>
		{
			"Accession No",
			"Visit Number",
			"CPTCode",
			"Date of Service",
			"First Billed Date",
			"Panel Name",
			"Payer Name",
			"PayerName Normalized",
			"Payer Type",
			"ReferringProvider",
			"ClinicName",
			"SalesRepname",
			"DenialCode_Original",
			"DenialCode_Normalized",
			"Denial Description",
			"Billed Amount",
			"Allowed Amount",
			"Insurance Payment",
			"Insurance Adjustment",
			"Insurance Balance",
			"Patient Balance",
			"Total Balance",
			"Coverage Status",
			"Final Coverage Status",
			"Action Comment",
			"Resolution",
			"LabName",
			"Denial Classification",
			"Denial Type",
			"Action Category",
			"Action Code",
			"Recommended Action",
			"Task Guidance",
			"Task Status",
			"Priority",
			"SLA (Days)",
			"PatientID",
			"RunId",
			"CreatedOn"
		};

		var rows = lineItems.Select(item => new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
		{
			["Accession No"] = item.AccessionNo,
			["Visit Number"] = item.VisitNumber,
			["CPTCode"] = item.CptCode,
			["Date of Service"] = FormatDate(item.DateOfService),
			["First Billed Date"] = FormatDate(item.FirstBilledDate),
			["Panel Name"] = item.PanelName,
			["Payer Name"] = item.PayerName,
			["PayerName Normalized"] = item.PayerNameNormalized,
			["Payer Type"] = item.PayerType,
			["ReferringProvider"] = item.ReferringProvider,
			["ClinicName"] = item.ClinicName,
			["SalesRepname"] = item.SalesRepname,
			["DenialCode_Original"] = item.DenialCodeOriginal,
			["DenialCode_Normalized"] = item.DenialCodeNormalized,
			["Denial Description"] = item.DenialDescription,
			["Billed Amount"] = item.BilledAmount.ToString("0.00"),
			["Allowed Amount"] = item.AllowedAmount.ToString("0.00"),
			["Insurance Payment"] = item.InsurancePayment.ToString("0.00"),
			["Insurance Adjustment"] = item.InsuranceAdjustment.ToString("0.00"),
			["Insurance Balance"] = item.InsuranceBalance.ToString("0.00"),
			["Patient Balance"] = item.PatientBalance.ToString("0.00"),
			["Total Balance"] = item.TotalBalance.ToString("0.00"),
			["Coverage Status"] = item.CoverageStatus,
			["Final Coverage Status"] = item.FinalCoverageStatus,
			["Action Comment"] = item.ActionComment,
			["Resolution"] = item.Resolution,
			["LabName"] = item.LabName,
			["Denial Classification"] = item.CleanDenialClassification,
			["Denial Type"] = item.DenialType,
			["Action Category"] = item.CleanActionCategory,
			["Action Code"] = item.ActionCode,
			["Recommended Action"] = item.RecommendedAction,
			["Task Guidance"] = item.TaskGuidance,
			["Task Status"] = item.TaskStatus,
			["Priority"] = item.CleanPriority,
			["SLA (Days)"] = item.SlaDays,
			["PatientID"] = item.PatientId,
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

		for (int c = 0; c < effectiveLineHeaders.Count; c++)
		{
			var cell = ws1.Cell(1, c + 1);
			cell.Value = effectiveLineHeaders[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#1F4E78");
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Alignment.Vertical = XLAlignmentVerticalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
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
				rowRange.Style.Fill.BackgroundColor = isEven ? XLColor.FromHtml("#D9E1F2") : XLColor.White;
			}

			dataRange.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
			dataRange.Style.Border.InsideBorder = XLBorderStyleValues.Thin;
		}

		string[] wrapColumns =
		{
			"Denial Description", "Coverage Status",
			"Covered ICD 10 codes as per Payer Policy",
			"Non Covered ICD 10 Codes as per Payer Policy",
			"Action Comment", "Coding Validation Sub-Status",
			"Recommended Action", "Notes / Comments", "Task Guidance"
		};

		string[] dateColumns =
		{
			"First Billed Date",
			"Expected Payment Date",
			"Date of Service",
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
			"Median, Insurance Paid - Peer", "Mode Allowed Amount Difference",
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
		SetWidth(ws1, effectiveLineHeaders, "Action Comment", 40);
		SetWidth(ws1, effectiveLineHeaders, "Recommended Action", 45);
		SetWidth(ws1, effectiveLineHeaders, "Task Guidance", 45);

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
			col.AddConditionalFormat().WhenContains("High").Fill.SetBackgroundColor(XLColor.FromHtml("#FF9999"));
			col.AddConditionalFormat().WhenContains("Medium").Fill.SetBackgroundColor(XLColor.FromHtml("#FFD580"));
			col.AddConditionalFormat().WhenContains("Low").Fill.SetBackgroundColor(XLColor.FromHtml("#C6EFCE"));
		}
	}

	private static void BuildDenialInsightsSheet(XLWorkbook wb, List<string> insightHeaders, List<Dictionary<string, string>> insightRows)
	{
		var ws2 = wb.AddWorksheet("Denial Insights");

		int rowOffset = 3;
		int colOffset = 2;

		var titleCell = ws2.Cell(rowOffset, colOffset);
		titleCell.Value = "Denial Insights Summary";
		ws2.Range(rowOffset, colOffset, rowOffset, colOffset + insightHeaders.Count - 1).Merge();
		titleCell.Style.Font.Bold = true;
		titleCell.Style.Font.FontColor = XLColor.White;
		titleCell.Style.Font.FontSize = 18;
		titleCell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
		titleCell.Style.Fill.BackgroundColor = XLColor.FromHtml("#1E3D2F");
		titleCell.Style.Border.BottomBorder = XLBorderStyleValues.Thick;

		int headerRow = rowOffset + 2;

		for (int c = 0; c < insightHeaders.Count; c++)
		{
			var cell = ws2.Cell(headerRow, colOffset + c);
			cell.Value = insightHeaders[c];
			cell.Style.Font.Bold = true;
			cell.Style.Font.FontColor = XLColor.White;
			cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#6B8E23");
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
				cell.Style.Fill.BackgroundColor = isEven ? XLColor.FromHtml("#E8F5E9") : XLColor.White;

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
			cell.Style.Fill.BackgroundColor = XLColor.FromHtml("#34495E");
			cell.Style.Alignment.Horizontal = XLAlignmentHorizontalValues.Center;
			cell.Style.Border.OutsideBorder = XLBorderStyleValues.Thin;
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
				cell.Style.Fill.BackgroundColor = isEven ? XLColor.FromHtml("#ECF0F1") : XLColor.White;

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
}
