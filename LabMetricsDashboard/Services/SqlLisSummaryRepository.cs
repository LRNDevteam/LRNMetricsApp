using System.Data;
using LabMetricsDashboard.Models;
using Microsoft.Data.SqlClient;

namespace LabMetricsDashboard.Services;

public sealed class SqlLisSummaryRepository : ILisSummaryRepository
{
	private sealed record RawLisGroup(
		string ResultedStatus,
		string ClaimStatus,
		string BilledOrNot,
		string ClientStatus,
		string SampleStatus,
		string PaymentMethod,
		string BillingStatus,
		string OrderStatus,
		int CollectedYear,
		int CollectedMonth,
		int TotalClaims);

	private sealed record LisRule(string Code, string Description, string Logic, int Level, Func<RawLisGroup, bool> Match);

	public async Task<LisSummaryResult> GetLisSummaryAsync(
		string connectionString,
		string labName,
		int? labId = null,
		DateOnly? collectedFrom = null,
		DateOnly? collectedTo = null,
		CancellationToken ct = default)
	{
		ArgumentException.ThrowIfNullOrWhiteSpace(connectionString);

		var logicSheet = ResolveLogicSheet(labName, labId);
		var rules = GetRules(logicSheet);
		var collectedDateColumn = ResolveCollectedDateColumn(logicSheet);

		var where = new List<string>
		{
			$"{collectedDateColumn} IS NOT NULL",
			$"YEAR({collectedDateColumn}) > 1900"
		};

		var parameters = new List<SqlParameter>();

		if (collectedFrom.HasValue)
		{
			where.Add($"{collectedDateColumn} >= @fromDate");
			parameters.Add(new SqlParameter("@fromDate", SqlDbType.Date)
			{
				Value = collectedFrom.Value.ToDateTime(TimeOnly.MinValue)
			});
		}

		if (collectedTo.HasValue)
		{
			where.Add($"{collectedDateColumn} <= @toDate");
			parameters.Add(new SqlParameter("@toDate", SqlDbType.Date)
			{
				Value = collectedTo.Value.ToDateTime(TimeOnly.MinValue)
			});
		}

		/*
         * PCR Labs of America has a different LIMSMaster schema.
         * It does NOT contain SampleStatus, PaymentMethod, BillingStatus, OrderStatus, OrderID in that lab DB.
         * For PCRLOA, use the exact grouping requested:
         * RessultedStatus, ClaimStatus, BilledorNot, ClientStatus, InsuranceCategory, Collected Month/Year, Count(*)
         *
         * InsuranceCategory is mapped into RawLisGroup.PaymentMethod so the existing PCRLOA rules that check
         * Payment/PaymentAny continue to work without changing the rule engine.
         */
		var sql = logicSheet switch
		{
			"PCRLOA" => BuildPcrLoaSql(where),
			"NWL" => BuildNorthWestSql(where),
			"Augustus" => BuildAugustusSql(where),
			"Certus" => BuildCertusSql(where),
			"Cove" => BuildCoveElixirSql(where, collectedDateColumn),
			"Elixir" => BuildCoveElixirSql(where, collectedDateColumn),
			"InHealth" => BuildInHealthSql(where, collectedDateColumn),
			"PCRDx-AL" => BuildPcrDxAlSql(where, collectedDateColumn),
			"PCRDx-CO" => BuildPcrDxCoSql(where, collectedDateColumn),
			_ => BuildDefaultSql(logicSheet, where)
		};

		var raw = new List<RawLisGroup>();

		await using var conn = new SqlConnection(connectionString);
		await conn.OpenAsync(ct);

		await using var cmd = new SqlCommand(sql, conn) { CommandTimeout = 180 };
		foreach (var p in parameters)
		{
			cmd.Parameters.Add(p);
		}

		await using var rdr = await cmd.ExecuteReaderAsync(ct);
		while (await rdr.ReadAsync(ct))
		{
			raw.Add(new RawLisGroup(
				rdr.GetString(0),
				rdr.GetString(1),
				rdr.GetString(2),
				rdr.GetString(3),
				rdr.GetString(4),
				rdr.GetString(5),
				rdr.GetString(6),
				rdr.GetString(7),
				rdr.GetInt32(8),
				rdr.GetInt32(9),
				rdr.GetInt32(10)));
		}

		var months = raw
			.Select(x => $"{x.CollectedYear:D4}-{x.CollectedMonth:D2}")
			.Distinct()
			.OrderBy(x => x)
			.ToList();

		var years = months
			.Select(x => int.Parse(x[..4]))
			.Distinct()
			.OrderBy(x => x)
			.ToList();

		var resultRows = new List<LisSummaryRow>();

		foreach (var rule in rules)
		{
			var matched = raw.Where(rule.Match).ToList();

			var byMonth = matched
				.GroupBy(x => $"{x.CollectedYear:D4}-{x.CollectedMonth:D2}")
				.ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));

			var byYear = matched
				.GroupBy(x => x.CollectedYear)
				.ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));

			resultRows.Add(new LisSummaryRow
			{
				Code = rule.Code,
				Description = rule.Description,
				Logic = rule.Logic,
				Level = rule.Level,
				ByMonth = byMonth,
				ByYear = byYear,
				Total = byMonth.Values.Sum()
			});
		}

		var grandByMonth = raw
			.GroupBy(x => $"{x.CollectedYear:D4}-{x.CollectedMonth:D2}")
			.ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));

		var grandByYear = raw
			.GroupBy(x => x.CollectedYear)
			.ToDictionary(g => g.Key, g => g.Sum(x => x.TotalClaims));

		return new LisSummaryResult(
			logicSheet,
			months,
			years,
			resultRows,
			grandByMonth,
			grandByYear,
			grandByMonth.Values.Sum());
	}

	private static string BuildDefaultSql(string logicSheet, List<string> where)
	{
		var uniqueColumn = logicSheet.Equals("Beech Tree", StringComparison.OrdinalIgnoreCase)
			? "OrderID"
			: "Accession";

		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(RessultedStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(ClaimStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(BilledorNot)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(ClientStatus)), '') AS ClientStatus,
                ISNULL(LTRIM(RTRIM(SampleStatus)), '') AS SampleStatus,
                ISNULL(LTRIM(RTRIM(PaymentMethod)), '') AS PaymentMethod,
                ISNULL(LTRIM(RTRIM(BillingStatus)), '') AS BillingStatus,
                ISNULL(LTRIM(RTRIM(OrderStatus)), '') AS OrderStatus,
                YEAR(RequestCollectDate) AS CollectedYear,
                MONTH(RequestCollectDate) AS CollectedMonth,
                COUNT(DISTINCT NULLIF(LTRIM(RTRIM({uniqueColumn})), '')) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(RessultedStatus)), ''),
                ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
                ISNULL(LTRIM(RTRIM(BilledorNot)), ''),
                ISNULL(LTRIM(RTRIM(ClientStatus)), ''),
                ISNULL(LTRIM(RTRIM(SampleStatus)), ''),
                ISNULL(LTRIM(RTRIM(PaymentMethod)), ''),
                ISNULL(LTRIM(RTRIM(BillingStatus)), ''),
                ISNULL(LTRIM(RTRIM(OrderStatus)), ''),
                YEAR(RequestCollectDate),
                MONTH(RequestCollectDate)
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildPcrLoaSql(List<string> where)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(RessultedStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(ClaimStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(BilledorNot)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(ClientStatus)), '') AS ClientStatus,
                CAST('' AS nvarchar(100)) AS SampleStatus,
                ISNULL(LTRIM(RTRIM(InsuranceCategory)), '') AS PaymentMethod,
                CAST('' AS nvarchar(100)) AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR(RequestCollectDate) AS CollectedYear,
                MONTH(RequestCollectDate) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(RessultedStatus)), ''),
                ISNULL(LTRIM(RTRIM(ClaimStatus)), ''),
                ISNULL(LTRIM(RTRIM(BilledorNot)), ''),
                ISNULL(LTRIM(RTRIM(ClientStatus)), ''),
                ISNULL(LTRIM(RTRIM(InsuranceCategory)), ''),
                YEAR(RequestCollectDate),
                MONTH(RequestCollectDate)
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}


	private static string BuildNorthWestSql(List<string> where)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(ResultStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(BillStatus)), '') AS ClaimStatus,
                CAST('' AS nvarchar(100)) AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(FinalStatus)), '') AS ClientStatus,
                ISNULL(LTRIM(RTRIM(Category)), '') AS SampleStatus,
                ISNULL(LTRIM(RTRIM(BilledTo)), '') AS PaymentMethod,
                CAST('' AS nvarchar(100)) AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR(RequestCollectDate) AS CollectedYear,
                MONTH(RequestCollectDate) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(ResultStatus)), ''),
                ISNULL(LTRIM(RTRIM(BillStatus)), ''),
                ISNULL(LTRIM(RTRIM(BilledTo)), ''),
                ISNULL(LTRIM(RTRIM(FinalStatus)), ''),
                ISNULL(LTRIM(RTRIM(Category)), ''),
                YEAR(RequestCollectDate),
                MONTH(RequestCollectDate)
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildAugustusSql(List<string> where)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(ResultStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(FinalStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(BillingStatus)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(FinalStatus)), '') AS ClientStatus,
                CAST('' AS nvarchar(100)) AS SampleStatus,
                ISNULL(LTRIM(RTRIM(BillTo)), '') AS PaymentMethod,
                ISNULL(LTRIM(RTRIM(BillingStatus)), '') AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR(ReqCollectDate) AS CollectedYear,
                MONTH(ReqCollectDate) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(ResultStatus)), ''),
                ISNULL(LTRIM(RTRIM(FinalStatus)), ''),
                ISNULL(LTRIM(RTRIM(BillingStatus)), ''),
                ISNULL(LTRIM(RTRIM(BillTo)), ''),
                YEAR(ReqCollectDate),
                MONTH(ReqCollectDate)
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildCertusSql(List<string> where)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(ResultStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(FinalStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(BillingStatus)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(FinalStatus)), '') AS ClientStatus,
                CAST('' AS nvarchar(100)) AS SampleStatus,
                ISNULL(LTRIM(RTRIM(BillTo)), '') AS PaymentMethod,
                ISNULL(LTRIM(RTRIM(BillingStatus)), '') AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR(ReqCollectDate) AS CollectedYear,
                MONTH(ReqCollectDate) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(ResultStatus)), ''),
                ISNULL(LTRIM(RTRIM(BillingStatus)), ''),
                ISNULL(LTRIM(RTRIM(BillTo)), ''),
                ISNULL(LTRIM(RTRIM(FinalStatus)), ''),
                YEAR(ReqCollectDate),
                MONTH(ReqCollectDate)
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildCoveElixirSql(List<string> where, string dateColumn)
	{
		return $"""
            SELECT
                CAST('' AS nvarchar(100)) AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(NewStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(BillCategory)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(NewStatus)), '') AS ClientStatus,
                CAST('' AS nvarchar(100)) AS SampleStatus,
                ISNULL(LTRIM(RTRIM(InsuranceType)), '') AS PaymentMethod,
                CAST('' AS nvarchar(100)) AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR({dateColumn}) AS CollectedYear,
                MONTH({dateColumn}) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(BillCategory)), ''),
                ISNULL(LTRIM(RTRIM(NewStatus)), ''),
                ISNULL(LTRIM(RTRIM(InsuranceType)), ''),
                YEAR({dateColumn}),
                MONTH({dateColumn})
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildInHealthSql(List<string> where, string dateColumn)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(ResultStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(SampleStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(BillCategory)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(SubStatus)), '') AS ClientStatus,
                ISNULL(LTRIM(RTRIM(SampleStatus)), '') AS SampleStatus,
                CAST('' AS nvarchar(100)) AS PaymentMethod,
                CAST('' AS nvarchar(100)) AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR({dateColumn}) AS CollectedYear,
                MONTH({dateColumn}) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(ResultStatus)), ''),
                ISNULL(LTRIM(RTRIM(BillCategory)), ''),
                ISNULL(LTRIM(RTRIM(SampleStatus)), ''),
                ISNULL(LTRIM(RTRIM(SubStatus)), ''),
                YEAR({dateColumn}),
                MONTH({dateColumn})
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildPcrDxAlSql(List<string> where, string dateColumn)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(LRNResultStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(LRNBillCategory)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), '') AS ClientStatus,
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), '') AS SampleStatus,
                CAST('' AS nvarchar(100)) AS PaymentMethod,
                CAST('' AS nvarchar(100)) AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR({dateColumn}) AS CollectedYear,
                MONTH({dateColumn}) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(LRNResultStatus)), ''),
                ISNULL(LTRIM(RTRIM(LRNBillCategory)), ''),
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), ''),
                YEAR({dateColumn}),
                MONTH({dateColumn})
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string BuildPcrDxCoSql(List<string> where, string dateColumn)
	{
		return $"""
            SELECT
                ISNULL(LTRIM(RTRIM(ResultStatus)), '') AS ResultedStatus,
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), '') AS ClaimStatus,
                ISNULL(LTRIM(RTRIM(LRNBillCategory)), '') AS BilledOrNot,
                ISNULL(LTRIM(RTRIM(LRNSubStatus)), '') AS ClientStatus,
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), '') AS SampleStatus,
                CAST('' AS nvarchar(100)) AS PaymentMethod,
                CAST('' AS nvarchar(100)) AS BillingStatus,
                CAST('' AS nvarchar(100)) AS OrderStatus,
                YEAR({dateColumn}) AS CollectedYear,
                MONTH({dateColumn}) AS CollectedMonth,
                COUNT(*) AS TotalClaims
            FROM dbo.LIMSMaster WITH (NOLOCK)
            WHERE {string.Join(" AND ", where)}
            GROUP BY
                ISNULL(LTRIM(RTRIM(ResultStatus)), ''),
                ISNULL(LTRIM(RTRIM(LRNBillCategory)), ''),
                ISNULL(LTRIM(RTRIM(LRNSampleStatus)), ''),
                ISNULL(LTRIM(RTRIM(LRNSubStatus)), ''),
                YEAR({dateColumn}),
                MONTH({dateColumn})
            ORDER BY CollectedYear, CollectedMonth;
            """;
	}

	private static string ResolveCollectedDateColumn(string logicSheet) => logicSheet switch
	{
		"Augustus" => "ReqCollectDate",
		"Certus" => "ReqCollectDate",
		"Cove" => "DateOfCollection",
		"Elixir" => "DateOfCollection",
		"InHealth" => "Entry_DateCreated",
		"PCRDx-AL" => "ReceivedDate",
		"PCRDx-CO" => "CollectionDate",
		_ => "RequestCollectDate"
	};

	private static string ResolveLogicSheet(string labName, int? labId)
	{
		if (labId.HasValue)
		{
			return labId.Value switch
			{
				2 => "InHealth",
				4 => "Cove",
				7 => "PCRDx-AL",
				8 => "PCRDx-CO",
				13 => "PCRLOA",
				16 => "Elixir",
				18 => "Certus",
				19 => "Augustus",
				20 => "NWL",
				_ => ResolveLogicSheetByName(labName)
			};
		}

		return ResolveLogicSheetByName(labName);
	}

	private static string ResolveLogicSheetByName(string labName)
	{
		var n = Normalize(labName);
		if (n.Contains("BEECH")) return "Beech Tree";
		if (n.Contains("NORTHWEST") || n.Contains("NORTH WEST") || n.Contains("NWL")) return "NWL";
		if (n.Contains("AUGUSTUS")) return "Augustus";
		if (n.Contains("CERTUS")) return "Certus";
		if (n.Contains("COVE")) return "Cove";
		if (n.Contains("ELIXIR")) return "Elixir";
		if (n.Contains("INHEALTH") || n.Contains("IN HEALTH")) return "InHealth";
		if ((n.Contains("PCRDX") || n.Contains("PCR DX")) && (n.Contains("AL") || n.Contains("ALABAMA"))) return "PCRDx-AL";
		if ((n.Contains("PCRDX") || n.Contains("PCR DX")) && (n.Contains("CO") || n.Contains("COLORADO"))) return "PCRDx-CO";
		if (n.Contains("PCRLOA") || n.Contains("PCR LABS") || n.Contains("PCR LAB")) return "PCRLOA";
		if (n.Contains("PHILIFE") || n.Contains("PHI LIFE")) return "PhiLife";
		if (n.Contains("RISING")) return "Rising Tides";
		return "Common";
	}

	private static List<LisRule> GetRules(string sheet) => sheet switch
	{
		"PCRLOA" => PcrloaRules(),
		"NWL" => NorthWestRules(),
		"Augustus" => AugustusRules(),
		"Certus" => CertusRules(),
		"PhiLife" => PhiLifeRules(),
		"Rising Tides" => RisingTidesRules(),
		"Beech Tree" => BeechTreeRules(),
		_ => CommonRules()
	};

	private static List<LisRule> CommonRules() =>
	[
		R("", "Total Samples", "Count all LIMSMaster rows for the selected collected date range", 0, x => true),
		R("A", "Resulted Samples", "ResultedStatus = Resulted", 0, x => Resulted(x)),
		R("B", "Not Resulted Samples", "ResultedStatus = Not Resulted", 0, x => NotResulted(x)),
		R("1", "Billed", "BilledOrNot / BillCategory / BillingStatus = Billed", 1, x => BilledAny(x, "Billed", "Billable", "Yes")),
		R("2", "Unbilled", "BilledOrNot / BillCategory / BillingStatus = Unbilled", 1, x => BilledAny(x, "UnBilled", "Unbilled", "Not Billed", "No")),
		R("3", "Client Bill", "BillTo / InsuranceType / SubStatus = Client Bill", 1, x => PaymentAny(x, "Client Bill", "Client Bills") || ClientAny(x, "Client Bill", "Client Bills")),
		R("4", "Self Pay", "BillTo / InsuranceType / SubStatus = Self Pay", 1, x => PaymentAny(x, "Self Pay", "Self pay") || ClientAny(x, "Self Pay", "Self pay")),
		R("5", "Rejected / Non Billable", "FinalStatus / SampleStatus / SubStatus contains rejection or non-billable statuses", 1, x => ClientAny(x, "Rejected", "Rejected Sample", "Sample Rejected", "Non Billable") || SampleAny(x, "Rejected", "Rejected Sample", "Sample Rejected", "Non Billable"))
	];

	private static List<LisRule> BeechTreeRules() =>
	[
		R("", "Total Samples", "Count [Unique Order ID]", 0, x => true),
		R("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]", 0, x => Resulted(x)),
		R("1", "Billed to Insurance", "Resulted, Claim Status Billed, Billed, Client Status Blank", 1, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && BlankClient(x)),
		R("•", "Billed In AMD", "Same as Billed to Insurance", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && BlankClient(x)),
		R("2", "Not Entered in AMD", "Resulted, Not Entered in AMD, UnBilled, Client Blank/Billing Review Required", 1, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && ClientAny(x,"","Billing Review Required")),
		R("•", "Received", "Not Entered in AMD - Received", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Sample(x,"Received") && ClientAny(x,"","Billing Review Required")),
		R("•", "Billing Review Required", "Not Entered in AMD - Billing Review Required", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Sample(x,"Received") && Client(x,"Billing Review Required")),
		R("•", "In Transit", "Not Entered in AMD - In Transit", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Sample(x,"In Transit") && ClientAny(x,"","Billing Review Required")),
		R("•", "Transferred", "Not Entered in AMD - Transferred", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Sample(x,"Transferred") && ClientAny(x,"","Billing Review Required")),
		R("•", "Collected", "Not Entered in AMD - Collected", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Sample(x,"Collected") && ClientAny(x,"","Billing Review Required")),
		R("3", "Unbilled", "Resulted, Entered, UnBilled, Client Blank", 1, x => Resulted(x) && Claim(x,"Entered") && Billed(x,"UnBilled") && BlankClient(x)),
		R("4", "Client Bill", "Resulted, Client Bill", 1, x => Resulted(x) && Client(x,"Client Bill")),
		R("•", "Not Entered in AMD", "Client Bill - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Client Bill")),
		R("•", "Billed", "Client Bill - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Client(x,"Client Bill")),
		R("5", "Self Pay", "Resulted, Self Pay", 1, x => Resulted(x) && Client(x,"Self Pay")),
		R("•", "Not Entered in AMD", "Self Pay - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Self Pay")),
		R("•", "Billed", "Self Pay - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Self Pay")),
		R("•", "Entered", "Self Pay - Entered", 2, x => Resulted(x) && Claim(x,"Entered") && Billed(x,"UnBilled") && Client(x,"Self Pay")),
		R("6", "Test Entries", "Resulted, Test Entries", 1, x => Resulted(x) && Client(x,"Test Entries")),
		R("•", "Not Entered in AMD", "Test Entries - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Test Entries")),
		R("•", "Billed", "Test Entries - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Test Entries")),
		R("7", "Rejected Sample", "Resulted, Rejected Sample", 1, x => Resulted(x) && Client(x,"Rejected Sample")),
		R("•", "Not Entered in AMD", "Rejected Sample - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Rejected Sample")),
		R("•", "Billed", "Rejected Sample - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Rejected Sample")),
		R("8", "Payment Method No Bill", "Resulted, Payment Method No Bill", 1, x => Resulted(x) && Payment(x,"No Bill")),
		R("B", "Not Resulted", "Resulted / Not = [Not Resulted]", 0, x => NotResulted(x)),
		R("1", "No Result date on LIS but Billed", "Not Resulted, Billed, Client Blank", 1, x => NotResulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && BlankClient(x)),
		R("2", "Not Entered in AMD", "Not Resulted, Not Entered in AMD, UnBilled, Client Blank", 1, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x)),
		R("•", "Received", "Not Resulted - Received", 2, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"Received")),
		R("•", "In Transit", "Not Resulted - In Transit", 2, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"In Transit")),
		R("•", "Collected", "Not Resulted - Collected", 2, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"Collected")),
		R("•", "Transferred", "Not Resulted - Transferred", 2, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"Transferred")),
		R("3", "Client Bill", "Not Resulted, Client Bill", 1, x => NotResulted(x) && Client(x,"Client Bill")),
		R("4", "Self Pay", "Not Resulted, Self Pay", 1, x => NotResulted(x) && Client(x,"Self Pay")),
		R("•", "Not Entered in AMD", "Self Pay - Not Entered", 2, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Self Pay")),
		R("•", "Billed", "Self Pay - Billed", 2, x => NotResulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Self Pay")),
		R("5", "Test Entries", "Not Resulted, Test Entries", 1, x => NotResulted(x) && Client(x,"Test Entries")),
		R("6", "Rejected Sample", "Not Resulted, Rejected Sample", 1, x => NotResulted(x) && Client(x,"Rejected Sample"))
	];

	private static List<LisRule> PcrloaRules() =>
	[
		R("", "Total Samples", "Count all LIMSMaster rows", 0, x => true),
		R("A", "Resulted", "Resulted / Not = [Resulted]", 0, x => Resulted(x)),
		R("1", "Billed to Insurance", "Resulted, Claim Status Billed", 1, x => Resulted(x) && Claim(x,"Billed")),
		R("◦", "Claims Billed to Payor via AMD", "Resulted, Claim Status Billed, Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed")),
		R("2", "Not Entered in AMD", "Resulted, UnBilled, Not Entered in AMD, InsuranceCategory Insurance/Missing Insurance/PAID", 1, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && PaymentAny(x,"Insurance","Missing Insurance","PAID")),
		R("•", "Billing Review Required", "Not Entered - Billing Review Required", 2, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Billing Review Required")),
		R("•", "Rejected", "Not Entered - Rejected", 2, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Rejected Sample")),
		R("3", "Client Bill", "Resulted, Client Bill", 1, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Client Bill")),
		R("4", "Unbilled", "Resulted, Entered, UnBilled", 1, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Entered")),
		R("◦", "Charges Entered in AMD - Not Released to Payor (EDI Hold)", "Same as Unbilled", 2, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Entered")),
		R("5", "Test Entries", "Resulted, Test Entries", 1, x => Resulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Test Entries")),
		R("B", "Not Resulted", "Resulted / Not = [Not Resulted]", 0, x => NotResulted(x)),
		R("1", "Not Entered in AMD", "Not Resulted, Not Entered, Rejected/Blank", 1, x => NotResulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && ClientAny(x,"Rejected Sample","")),
		R("•", "Rejected", "Not Resulted - Rejected", 2, x => NotResulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Rejected Sample")),
		R("2", "Client Bill", "Not Resulted, Client Bill", 1, x => NotResulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Client Bill")),
		R("3", "Test Entries", "Not Resulted, Test Entries", 1, x => NotResulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Test Entries")),
		R("4", "Self Pay", "Not Resulted, Self Pay", 1, x => NotResulted(x) && Billed(x,"UnBilled") && Claim(x,"Not Entered in AMD") && Client(x,"Self Pay"))
	];

	private static List<LisRule> AugustusRules() =>
	[
		R("A", "Insurance Bills", "Bill to = Insurance Bills", 0, x => Payment(x, "Insurance Bills")),
		R("1", "Billed", "Bill to = Insurance Bills AND Bill status = Billed", 1, x => Payment(x, "Insurance Bills") && Billing(x, "Billed")),
		R("•", "Claim Submitted in IRCM", "Bill to = Insurance Bills AND Bill status = Billed AND Final Status = Claim Submitted in IRCM", 2, x => Payment(x, "Insurance Bills") && Billing(x, "Billed") && Client(x, "Claim Submitted in IRCM")),
		R("•", "Claim Submitted in Daqbilling", "Bill to = Insurance Bills AND Bill status = Billed AND Final Status = Claim Submitted in Daqbilling", 2, x => Payment(x, "Insurance Bills") && Billing(x, "Billed") && Client(x, "Claim Submitted in Daqbilling")),
		R("2", "Unbilled", "Bill to = Insurance Bills AND Bill status = Unbilled", 1, x => Payment(x, "Insurance Bills") && Billing(x, "Unbilled")),
		R("•", "Resulted yet to be billed", "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status = Resulted yet to be billed", 2, x => Payment(x, "Insurance Bills") && Billing(x, "Unbilled") && Client(x, "Resulted yet to be billed")),
		R("*", "Ready to bill", "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status = Resulted yet to be billed AND Client Status 2 = Ready to bill", 3, x => Payment(x, "Insurance Bills") && Billing(x, "Unbilled") && Client(x, "Resulted yet to be billed") && Order(x, "Ready to bill")),
		R("•", "Insurance name not listed", "Bill to = Insurance Bills AND Bill status = Unbilled AND Final Status = Insurance Name Not Listed", 2, x => Payment(x, "Insurance Bills") && Billing(x, "Unbilled") && Client(x, "Insurance Name Not Listed")),

		R("B", "Yet to be Validated", "Bill to = Yet to be Validated", 0, x => Payment(x, "Yet to be Validated")),
		R("1", "Billed", "Bill to = Yet to be Validated AND Bill Status = Billed", 1, x => Payment(x, "Yet to be Validated") && Billing(x, "Billed")),

		R("C", "Client Bills", "Bill to = Client Bills", 0, x => Payment(x, "Client Bills")),
		R("1", "Billed", "Bill to = Client Bills AND Bill Status = Billed", 1, x => Payment(x, "Client Bills") && Billing(x, "Billed")),

		R("D", "System Test", "Bill to = System Test", 0, x => Payment(x, "System Test")),
		R("1", "Billed", "Bill to = System Test AND Bill Status = Billed", 1, x => Payment(x, "System Test") && Billing(x, "Billed")),

		R("E", "Self pay", "Bill to = Self pay", 0, x => PaymentAny(x, "Self pay", "Self Pay", "Selfpay")),
		R("1", "Billed", "Bill to = Self pay AND Bill Status = Billed", 1, x => PaymentAny(x, "Self pay", "Self Pay", "Selfpay") && Billing(x, "Billed"))
	];

	private static List<LisRule> CertusRules() =>
	[
		R("A", "Insurance Bill", "Bill to = Insurance Bill", 0, x => Payment(x, "Insurance Bill")),
		R("1", "Billed", "Bill to = Insurance Bill AND Billing status = Billed", 1, x => Payment(x, "Insurance Bill") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = Insurance Bill AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => Payment(x, "Insurance Bill") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling")),
		R("2", "Not Billed", "Bill to = Insurance Bill AND Billing status = Not Billed", 1, x => Payment(x, "Insurance Bill") && Billing(x, "Not Billed")),
		R("•", "Claim Entered in Daqbilling", "Bill to = Insurance Bill AND Billing status = Billed AND Final Status = Claim Entered in Daqbilling", 2, x => Payment(x, "Insurance Bill") && Billing(x, "Billed") && Client(x, "Claim Entered in Daqbilling")),
		R("•", "Resulted yet to be billed", "Bill to = Insurance Bill AND Billing status = Billed AND Final Status = Resulted yet to be billed", 2, x => Payment(x, "Insurance Bill") && Billing(x, "Billed") && Client(x, "Resulted yet to be billed")),
		R("•", "D/L Isomer", "Bill to = Insurance Bill AND Billing status = Billed AND Final Status = D/L Isomer", 2, x => Payment(x, "Insurance Bill") && Billing(x, "Billed") && Client(x, "D/L Isomer")),

		R("B", "Duplicate", "Bill to = Duplicate", 0, x => PaymentAny(x, "Duplicate", "Duplicate Bill")),
		R("1", "Billed", "Bill to = Duplicate Bill AND Billing status = Billed", 1, x => PaymentAny(x, "Duplicate", "Duplicate Bill") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = Duplicate Bill AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => PaymentAny(x, "Duplicate", "Duplicate Bill") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling")),

		R("C", "Client Bill", "Bill to = Client Bill", 0, x => Payment(x, "Client Bill")),
		R("1", "Billed", "Bill to = Client Bill AND Billing status = Billed", 1, x => Payment(x, "Client Bill") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = Client Bill AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => Payment(x, "Client Bill") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling")),

		R("D", "Yet to be Validated", "Bill to = Yet to be Validated", 0, x => Payment(x, "Yet to be Validated")),
		R("1", "Billed", "Bill to = Yet to be Validated AND Billing status = Billed", 1, x => Payment(x, "Yet to be Validated") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = Yet to be Validated AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => Payment(x, "Yet to be Validated") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling")),

		R("E", "Selfpay", "Bill to = Selfpay", 0, x => PaymentAny(x, "Selfpay", "Self pay", "Self Pay")),
		R("1", "Billed", "Bill to = Selfpay AND Billing status = Billed", 1, x => PaymentAny(x, "Selfpay", "Self pay", "Self Pay") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = Selfpay AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => PaymentAny(x, "Selfpay", "Self pay", "Self Pay") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling")),

		R("F", "Rejection", "Bill to = Rejection", 0, x => Payment(x, "Rejection")),
		R("1", "Billed", "Bill to = Rejection AND Billing status = Billed", 1, x => Payment(x, "Rejection") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = Rejection AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => Payment(x, "Rejection") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling")),

		R("G", "System Test", "Bill to = System Test", 0, x => Payment(x, "System Test")),
		R("1", "Billed", "Bill to = System Test AND Billing status = Billed", 1, x => Payment(x, "System Test") && Billing(x, "Billed")),
		R("•", "Claim submitted in Daqbilling", "Bill to = System Test AND Billing status = Billed AND Final Status = Claim submitted in Daqbilling", 2, x => Payment(x, "System Test") && Billing(x, "Billed") && Client(x, "Claim submitted in Daqbilling"))
	];

	private static List<LisRule> PhiLifeRules() =>
	[
		R("", "Total Samples", "Count [Unique Accession]", 0, x => true),
		R("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]", 0, x => Resulted(x)),
		R("1", "Billed to Insurance", "Resulted, Billed, Client Blank/Billing Review Required", 1, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && ClientAny(x,"","Billing Review Required")),
		R("•", "Billed In AMD", "Same as Billed to Insurance", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && ClientAny(x,"","Billing Review Required")),
		R("2", "Not Entered in AMD", "Resulted, Insurance, Not Entered", 1, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && ClientAny(x,"","Billing Review Required") && Payment(x,"Insurance")),
		R("•", "Received", "Not Entered - Received", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && ClientAny(x,"","Billing Review Required") && Payment(x,"Insurance") && Sample(x,"Received")),
		R("•", "Billing Review Required", "Not Entered - Billing Review Required", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Payment(x,"Insurance") && Sample(x,"Received") && Client(x,"Billing Review Required")),
		R("•", "Collected", "Not Entered - Collected", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && ClientAny(x,"","Billing Review Required") && Payment(x,"Insurance") && Sample(x,"Collected")),
		R("3", "Rejected Samples", "Resulted, Rejected Sample", 1, x => Resulted(x) && Client(x,"Rejected Sample")),
		R("•", "Billed In AMD", "Rejected - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Rejected Sample")),
		R("•", "Not Entered in AMD", "Rejected - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Rejected Sample")),
		R("4", "Client Bill", "Resulted, Client Bill", 1, x => Resulted(x) && Client(x,"Client Bill")),
		R("•", "Billed In AMD", "Client Bill - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Client Bill")),
		R("•", "Not Entered in AMD", "Client Bill - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Client Bill")),
		R("5", "Test Entries", "Resulted, Test Entries", 1, x => Resulted(x) && Client(x,"Test Entries")),
		R("•", "Billed In AMD", "Test Entries - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Test Entries")),
		R("•", "Not Entered in AMD", "Test Entries - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Test Entries")),
		R("6", "Unbilled", "Resulted, Entered, UnBilled", 1, x => Resulted(x) && Claim(x,"Entered") && Billed(x,"UnBilled")),
		R("7", "Self Pay", "Resulted, Self Pay", 1, x => Resulted(x) && Client(x,"Self Pay")),
		R("•", "Billed In AMD", "Self Pay - Billed", 2, x => Resulted(x) && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Self Pay")),
		R("•", "Not Entered in AMD", "Self Pay - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Self Pay")),
		R("8", "Payment Method No Bill", "Resulted, Payment Method No Bill", 1, x => Resulted(x) && Payment(x,"No Bill")),
		R("•", "Billed In AMD", "No Bill - Billed", 2, x => Resulted(x) && Payment(x,"No Bill") && ClaimAny(x,"Billed in AMD","Billed")),
		R("•", "Not Entered in AMD", "No Bill - Not Entered", 2, x => Resulted(x) && Payment(x,"No Bill") && Claim(x,"Not Entered in AMD")),
		R("B", "Not Resulted", "Resulted / Not = [Not Resulted]", 0, x => NotResulted(x)),
		R("1", "Not Entered in AMD", "Not Resulted, Insurance, Not Entered, Blank", 1, x => NotResulted(x) && Payment(x,"Insurance") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x)),
		R("•", "Received", "Not Resulted - Received", 2, x => NotResulted(x) && Payment(x,"Insurance") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"Received")),
		R("•", "Collected", "Not Resulted - Collected", 2, x => NotResulted(x) && Payment(x,"Insurance") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"Collected")),
		R("•", "Transferred", "Not Resulted - Transferred", 2, x => NotResulted(x) && Payment(x,"Insurance") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && BlankClient(x) && Sample(x,"Transferred")),
		R("3", "Rejected Samples", "Not Resulted, Rejected", 1, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && ClientAny(x,"Rejected","Rejected Sample")),
		R("2", "Client Bill", "Not Resulted, Client Bill", 1, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Client Bill")),
		R("3", "No Result date on LIS but Billed", "Not Resulted but Billed", 1, x => NotResulted(x) && Claim(x,"Billed") && Billed(x,"Billed")),
		R("4", "Test Entries", "Not Resulted, Test Entries", 1, x => NotResulted(x) && Payment(x,"Insurance") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Test Entries")),
		R("5", "Payment Method No Bill", "Not Resulted, No Bill", 1, x => NotResulted(x) && Payment(x,"No Bill"))
	];

	private static List<LisRule> RisingTidesRules() =>
	[
		R("", "Total Samples", "Count [Unique Accession]", 0, x => true),
		R("A", "Billable Samples - Resulted", "Resulted / Not = [Resulted]", 0, x => Resulted(x)),
		R("1", "Billed to Insurance", "Resulted, Insurance, Billed", 1, x => Resulted(x) && Payment(x,"Insurance") && Claim(x,"Billed")),
		R("•", "Billed In AMD", "Resulted, Insurance, Billed", 2, x => Resulted(x) && Payment(x,"Insurance") && Claim(x,"Billed") && Billed(x,"Billed")),
		R("2", "Not Entered in AMD", "Resulted, Insurance, Billing Review Required", 1, x => Resulted(x) && Payment(x,"Insurance") && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Billing Review Required") && BillingAny(x,"Billed","Not Ready To Bill","Ready To Bill")),
		R("•", "Received", "Billing Review Required - Received", 2, x => Resulted(x) && Payment(x,"Insurance") && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Billing Review Required") && BillingAny(x,"Billed","Not Ready To Bill","Ready To Bill") && Sample(x,"Received")),
		R("•", "Billing Review Required", "Billing Review Required - Received", 2, x => Resulted(x) && Payment(x,"Insurance") && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Billing Review Required") && BillingAny(x,"Billed","Not Ready To Bill","Ready To Bill") && Sample(x,"Received")),
		R("3", "Unbilled", "Resulted, Insurance, Entered, UnBilled", 1, x => Resulted(x) && Payment(x,"Insurance") && Claim(x,"Entered") && Billed(x,"UnBilled")),
		R("4", "Client Bill", "Resulted, Client Bill, Billed", 1, x => Resulted(x) && Payment(x,"Client Bill") && ClaimAny(x,"Billed","Not Entered in AMD") && BilledAny(x,"Billed","UnBilled") && Client(x,"Client Bill") && Billing(x,"Billed")),
		R("•", "Not Entered in AMD", "Client Bill - Not Entered", 2, x => Resulted(x) && Payment(x,"Client Bill") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Client Bill") && Billing(x,"Billed")),
		R("•", "Billed", "Client Bill - Billed", 2, x => Resulted(x) && Payment(x,"Client Bill") && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Client Bill") && Billing(x,"Billed")),
		R("5", "Self Pay", "Resulted, Self Pay", 1, x => Resulted(x) && Payment(x,"Self Pay") && Client(x,"Self Pay") && BillingAny(x,"Billed","Not Ready To Bill")),
		R("•", "Billed", "Self Pay - Billed", 2, x => Resulted(x) && Payment(x,"Self Pay") && Claim(x,"Billed") && Billed(x,"Billed") && Client(x,"Self Pay") && BillingAny(x,"Billed","Not Ready To Bill")),
		R("•", "Not Entered in AMD", "Self Pay - Not Entered", 2, x => Resulted(x) && Payment(x,"Self Pay") && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Self Pay") && Billing(x,"Billed")),
		R("•", "Entered", "Self Pay - Entered", 2, x => Resulted(x) && Payment(x,"Self Pay") && Claim(x,"Entered") && Billed(x,"UnBilled") && Client(x,"Self Pay") && Billing(x,"Billed")),
		R("6", "Test Entries", "Resulted, Test Entries", 1, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Test Entries") && Billing(x,"Billed")),
		R("•", "Not Entered in AMD", "Test Entries - Not Entered", 2, x => Resulted(x) && Claim(x,"Not Entered in AMD") && Billed(x,"UnBilled") && Client(x,"Test Entries") && Billing(x,"Billed")),
		R("7", "Billing Status - No Bill", "Resulted, Billing Status No Bill", 1, x => Resulted(x) && Billing(x,"No Bill")),
		R("•", "Rejected", "No Bill - Rejected", 2, x => Resulted(x) && Billing(x,"No Bill") && Order(x,"Rejected")),
		R("•", "Completed", "No Bill - Completed", 2, x => Resulted(x) && Billing(x,"No Bill") && Order(x,"Completed")),
		R("•", "Recollect Required", "No Bill - Recollect Required", 2, x => Resulted(x) && Billing(x,"No Bill") && Order(x,"Recollect Required")),
		R("B", "Not Resulted", "Resulted / Not = [Not Resulted]", 0, x => NotResulted(x)),
		R("1", "Not Entered in AMD", "Not Resulted, Not Entered", 1, x => NotResulted(x) && Claim(x,"Not Entered in AMD")),
		R("•", "Collected", "Not Resulted - Collected", 2, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && Sample(x,"Collected")),
		R("2", "Rejected Sample", "Not Resulted - Rejected", 1, x => NotResulted(x) && Claim(x,"Not Entered in AMD") && SampleAny(x,"Rejected","Rejected Sample"))
	];


	private static List<LisRule> NorthWestRules() =>
	[
		R("", "Total Samples", "Count all LIS records by collected date", 0, x => true),

		R("A", "Insurance Bill", "Bill To = Insurance Bill", 0, x => Payment(x, "Insurance Bill")),
		R("1", "Billed", "Bill To = Insurance Bill AND Bill Status = Billed", 1, x => Payment(x, "Insurance Bill") && Claim(x, "Billed")),
		R("•", "Claim Submitted in Webpm", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Claim Submitted in Webpm", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Billed") && Client(x, "Claim Submitted in Webpm")),
		R("•", "Claim Submitted in Daqbilling", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Claim Submitted in DaqBilling", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Billed") && Client(x, "Claim Submitted in DaqBilling")),
		R("•", "Claim Submitted in Daq & Webpm", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Claim Submitted in Daq & Webpm", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Billed") && Client(x, "Claim Submitted in Daq & Webpm")),
		R("•", "Non Billable - Excluded Organizations", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Non Billable - Excluded Organizations", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Billed") && Client(x, "Non Billable - Excluded Organizations")),
		R("•", "Manually Pushed in Emedix", "Bill To = Insurance Bill AND Bill Status = Billed AND Final Status = Manually Pushed in Emedix", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Billed") && Client(x, "Manually Pushed in Emedix")),

		R("2", "Unbilled", "Bill To = Insurance Bill AND Bill Status = Unbilled", 1, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled")),
		R("•", "Charge Not Created", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charge Not Created")),
		R("•", "Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Category = Webpm", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charge Not Created") && Sample(x, "Webpm")),
		R("*", "No Charges found in Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Category = No Charges found in Webpm", 3, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charge Not Created") && Sample(x, "No Charges found in Webpm")),
		R("*", "Unposted Charges in Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Category = Unposted Charges in Webpm", 3, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charge Not Created") && Sample(x, "Unposted Charges in Webpm")),
		R("•", "Daqbilling", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charge Not Created AND Category = Daqbilling", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charge Not Created") && Sample(x, "Daqbilling")),
		R("•", "Non Billable - Excluded Validity Codes", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Validity Codes", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Non Billable - Excluded Validity Codes")),
		R("•", "Non Billable - Excluded PAP Codes", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded PAP Codes", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Non Billable - Excluded PAP Codes")),
		R("•", "Non Billable - Excluded Organizations", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Non Billable - Excluded Organizations", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Non Billable - Excluded Organizations")),
		R("•", "Charges Created and Not Submitted", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charges Created and Not Submitted")),
		R("•", "Webpm", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted AND Category = Webpm", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charges Created and Not Submitted") && Sample(x, "Webpm")),
		R("•", "Daqbilling", "Bill To = Insurance Bill AND Bill Status = Unbilled AND Final Status = Charges Created and Not Submitted AND Category = Daqbilling", 2, x => Payment(x, "Insurance Bill") && Claim(x, "Unbilled") && Client(x, "Charges Created and Not Submitted") && Sample(x, "Daqbilling")),

		R("B", "Yet to be validate", "Bill To = Yet to be validate", 0, x => Payment(x, "Yet to be validate")),
		R("1", "Billed", "Bill To = Yet to be validate AND Bill Status = Billed", 1, x => Payment(x, "Yet to be validate") && Claim(x, "Billed")),
		R("2", "Unbilled", "Bill To = Yet to be validate AND Bill Status = Unbilled", 1, x => Payment(x, "Yet to be validate") && Claim(x, "Unbilled")),
		R("•", "Not Resulted", "Bill To = Yet to be validate AND Bill Status = Unbilled AND Category = Not Resulted", 2, x => Payment(x, "Yet to be validate") && Claim(x, "Unbilled") && Sample(x, "Not Resulted")),
		R("•", "Non Billable", "Bill To = Yet to be validate AND Bill Status = Unbilled AND Category = Non Billable", 2, x => Payment(x, "Yet to be validate") && Claim(x, "Unbilled") && Sample(x, "Non Billable")),
		R("•", "Charges Created and Not Submitted", "Bill To = Yet to be validate AND Bill Status = Unbilled AND Category = Charges Created and Not Submitted", 2, x => Payment(x, "Yet to be validate") && Claim(x, "Unbilled") && Sample(x, "Charges Created and Not Submitted")),

		R("C", "Self pay", "Bill To = Self pay", 0, x => Payment(x, "Self pay")),
		R("1", "Billed", "Bill To = Self pay AND Bill Status = Billed", 1, x => Payment(x, "Self pay") && Claim(x, "Billed")),
		R("2", "Unbilled", "Bill To = Self pay AND Bill Status = Unbilled", 1, x => Payment(x, "Self pay") && Claim(x, "Unbilled")),
		R("•", "Non Billable", "Bill To = Self pay AND Bill Status = Unbilled AND Category = Non Billable", 2, x => Payment(x, "Self pay") && Claim(x, "Unbilled") && Sample(x, "Non Billable")),
		R("•", "Self Pay", "Bill To = Self pay AND Bill Status = Unbilled AND Category = Self Pay", 2, x => Payment(x, "Self pay") && Claim(x, "Unbilled") && Sample(x, "Self Pay")),
		R("•", "Charges Created and Not Submitted", "Bill To = Self pay AND Bill Status = Unbilled AND Category = Charges Created and Not Submitted", 2, x => Payment(x, "Self pay") && Claim(x, "Unbilled") && Sample(x, "Charges Created and Not Submitted")),

		R("D", "ADCS Claims", "Bill To = ADCS Claims", 0, x => Payment(x, "ADCS Claims")),
		R("1", "Billed", "Bill To = ADCS Claims AND Bill Status = Billed", 1, x => Payment(x, "ADCS Claims") && Claim(x, "Billed")),
		R("2", "Unbilled", "Bill To = ADCS Claims AND Bill Status = Unbilled", 1, x => Payment(x, "ADCS Claims") && Claim(x, "Unbilled")),
		R("•", "Non Billable", "Bill To = ADCS Claims AND Bill Status = Unbilled AND Category = Non Billable", 2, x => Payment(x, "ADCS Claims") && Claim(x, "Unbilled") && Sample(x, "Non Billable")),

		R("E", "Client Bills", "Bill To = Client Bills", 0, x => Payment(x, "Client Bills")),
		R("1", "Billed", "Bill To = Client Bills AND Bill Status = Billed", 1, x => Payment(x, "Client Bills") && Claim(x, "Billed")),
		R("2", "Unbilled", "Bill To = Client Bills AND Bill Status = Unbilled", 1, x => Payment(x, "Client Bills") && Claim(x, "Unbilled")),
		R("•", "Non Billable", "Bill To = Client Bills AND Bill Status = Unbilled AND Category = Non Billable", 2, x => Payment(x, "Client Bills") && Claim(x, "Unbilled") && Sample(x, "Non Billable")),
		R("•", "Do Not Bill", "Bill To = Client Bills AND Bill Status = Unbilled AND Category = Do Not Bill", 2, x => Payment(x, "Client Bills") && Claim(x, "Unbilled") && Sample(x, "Do Not Bill")),
		R("•", "Charges Created and Not Submitted", "Bill To = Client Bills AND Bill Status = Unbilled AND Category = Charges Created and Not Submitted", 2, x => Payment(x, "Client Bills") && Claim(x, "Unbilled") && Sample(x, "Charges Created and Not Submitted")),

		R("F", "System Test", "Bill To = System Test", 0, x => Payment(x, "System Test")),
		R("1", "Billed", "Bill To = System Test AND Bill Status = Billed", 1, x => Payment(x, "System Test") && Claim(x, "Billed")),
		R("2", "Unbilled", "Bill To = System Test AND Bill Status = Unbilled", 1, x => Payment(x, "System Test") && Claim(x, "Unbilled")),
		R("•", "Non Billable", "Bill To = System Test AND Bill Status = Unbilled AND Category = Non Billable", 2, x => Payment(x, "System Test") && Claim(x, "Unbilled") && Sample(x, "Non Billable")),
		R("•", "Test Samples", "Bill To = System Test AND Bill Status = Unbilled AND Category = Test Samples", 2, x => Payment(x, "System Test") && Claim(x, "Unbilled") && Sample(x, "Test Samples")),

		R("G", "Rejections", "Bill To = Rejections", 0, x => Payment(x, "Rejections")),
		R("1", "Billed", "Bill To = Rejections AND Bill Status = Billed", 1, x => Payment(x, "Rejections") && Claim(x, "Billed")),
		R("2", "Unbilled", "Bill To = Rejections AND Bill Status = Unbilled", 1, x => Payment(x, "Rejections") && Claim(x, "Unbilled")),
		R("•", "Sample Rejected", "Bill To = Rejections AND Bill Status = Unbilled AND Category = Sample Rejected", 2, x => Payment(x, "Rejections") && Claim(x, "Unbilled") && Sample(x, "Sample Rejected"))
	];

	private static LisRule R(string code, string desc, string logic, int level, Func<RawLisGroup, bool> match)
		=> new(code, desc, logic, level, match);

	private static string Normalize(string? value)
		=> (value ?? string.Empty).Trim().ToUpperInvariant();

	private static bool Eq(string? actual, string expected)
		=> Normalize(actual) == Normalize(expected);

	private static bool Any(string? actual, params string[] values)
		=> values.Any(v => Eq(actual, v));

	private static bool Resulted(RawLisGroup x) => Eq(x.ResultedStatus, "Resulted");
	private static bool NotResulted(RawLisGroup x) => Eq(x.ResultedStatus, "Not Resulted");
	private static bool Claim(RawLisGroup x, string v) => Eq(x.ClaimStatus, v);
	private static bool ClaimAny(RawLisGroup x, params string[] v) => Any(x.ClaimStatus, v);
	private static bool Billed(RawLisGroup x, string v) => Eq(x.BilledOrNot, v);
	private static bool BilledAny(RawLisGroup x, params string[] v) => Any(x.BilledOrNot, v);
	private static bool Client(RawLisGroup x, string v) => Eq(x.ClientStatus, v);
	private static bool ClientAny(RawLisGroup x, params string[] v) => Any(x.ClientStatus, v);
	private static bool BlankClient(RawLisGroup x) => string.IsNullOrWhiteSpace(x.ClientStatus);
	private static bool Sample(RawLisGroup x, string v) => Eq(x.SampleStatus, v);
	private static bool SampleAny(RawLisGroup x, params string[] v) => Any(x.SampleStatus, v);
	private static bool Payment(RawLisGroup x, string v) => Eq(x.PaymentMethod, v);
	private static bool PaymentAny(RawLisGroup x, params string[] v) => Any(x.PaymentMethod, v);
	private static bool Billing(RawLisGroup x, string v) => Eq(x.BillingStatus, v);
	private static bool BillingAny(RawLisGroup x, params string[] v) => Any(x.BillingStatus, v);
	private static bool Order(RawLisGroup x, string v) => Eq(x.OrderStatus, v);
}
