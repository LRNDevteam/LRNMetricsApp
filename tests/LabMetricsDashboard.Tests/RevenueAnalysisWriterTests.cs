using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Text.Json;
using LabMetricsDashboard.Services.RevenueAnalysis;
using Xunit;

namespace LabMetricsDashboard.Tests;

/// <summary>
/// Revenue Analysis: lab claim rows -> the report team's dashboard blobs. The page's script reads the
/// blobs positionally, so these pin the contract it depends on (one entry per claim, dictionary
/// indexes in range, lines grouped by claim) as well as the AR / claim-status derivation.
/// </summary>
public sealed class RevenueAnalysisWriterTests
{
    private static readonly string[] ClaimColumns =
    [
        "ClaimID", "AccessionNumber", "DateofService", "ChargeEnteredDate", "FirstBilledDate", "CheckDate", "Panelname",
        "Payer_Code", "PayerType", "PayerName", "ClinicName", "SalesRepname", "ReferringProvider", "PatientID", "ClaimStatus",
        "DenialCode", "ChargeAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "TotalAdjustments",
        "InsuranceBalance", "PatientBalance"
    ];

    private static readonly string[] LineColumns =
    [
        "ClaimID", "DateofService", "PostingDate", "CPTCode", "Units", "Modifier", "Panelname", "ReferringProvider",
        "ChargeAmount", "InsurancePayment", "PatientPayment", "TotalPayments", "TotalAdjustments", "InsuranceBalance", "PatientBalance"
    ];

    private static object?[] Claim(string id, string dos, string status, string denial, decimal ch, decimal ip, decimal pp, decimal adj,
        decimal ib, decimal pb, string payerType = "Commercial", string payer = "Aetna", string clinic = "Clinic A") =>
    [
        id, "ACC" + id, dos, dos, dos, "2026-03-01", "UTI Panel", "AET", payerType, payer, clinic, "Rep One", "Dr Smith", "P" + id,
        status, denial, ch.ToString(), ip.ToString(), pp.ToString(), (ip + pp).ToString(), adj.ToString(), ib.ToString(), pb.ToString()
    ];

    private static object?[] Line(string id, string cpt, string mods, decimal ch, decimal tp, decimal adj, decimal ib) =>
    [
        id, "2026-01-15", "03/02/2026", cpt, "1", mods, "UTI Panel", "Dr Smith",
        ch.ToString(), tp.ToString(), "0", tp.ToString(), adj.ToString(), ib.ToString(), "0"
    ];

    private static RevenueAnalysisDataset BuildDataset()
    {
        var data = new RevenueAnalysisDataset(new DateOnly(2025, 1, 1), new DateOnly(2026, 12, 31), 1000);
        data.BeginClaims(ClaimColumns);
        data.AddClaim(Claim("C1", "2026-01-15", "Fully Paid", "", 300, 250, 0, 50, 0, 0));
        data.AddClaim(Claim("C2", "01/20/2026", "Partially Paid", "CO-45", 500, 100, 0, 50, 350, 0));
        data.AddClaim(Claim("C3", "2026-02-02", "Denied", "CO-16, N290", 400, 0, 0, 0, 400, 0, clinic: "</script><b>x"));
        data.AddClaim(Claim("C4", "2026-02-10", "No Response", "", 200, 0, 0, 0, 200, 0));
        data.AddClaim(Claim("C5", "2026-02-11", "Patient Responsibility", "", 150, 100, 0, 0, 0, 50, payerType: "Self Pay", payer: "Self Pay"));
        data.AddClaim(Claim("C6", "2026-02-12", "Voided", "", 0, 0, 0, 0, 0, 0));
        data.AddClaim(Claim("C1", "2026-01-15", "Fully Paid", "", 300, 250, 0, 50, 0, 0));      // duplicate ClaimID
        data.AddClaim(Claim("C7", "2023-05-01", "Fully Paid", "", 100, 100, 0, 0, 0, 0));       // outside the DOS window

        data.BeginLines(LineColumns);
        data.AddLine(Line("C2", "87798", "59, 91", 300, 100, 50, 150));
        data.AddLine(Line("C1", "80305", "QW", 300, 250, 50, 0));
        data.AddLine(Line("C2", "87481.00", "", 200, 0, 0, 200));
        data.AddLine(Line("C3", "0240U", "", 400, 0, 0, 400));
        data.AddLine(Line("ZZ", "80305", "", 10, 0, 0, 10));                                   // no such claim
        return data;
    }

    private static async Task<string> WriteAsync(RevenueAnalysisDataset data)
    {
        var ctx = new RevenueAnalysisWriteContext
        {
            LabName = "Cove <Lab> & Co",
            SourceLabel = "Live lab database",
            SourceShort = "Live",
            FileTag = "cove",
            GeneratedOn = new DateTime(2026, 11, 24),
            DenialMaster = new Dictionary<string, (string, string)>(StringComparer.OrdinalIgnoreCase)
            {
                ["16"] = ("Claim lacks information", "Claims Edits Related Issues"),
            },
            NonCollectible = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "16" },
            CptDescriptions = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase) { ["87798"] = "Detect agent nos dna amp" },
        };
        using var ms = new MemoryStream();
        await RevenueAnalysisHtmlWriter.WriteAsync(ms, data, ctx, CancellationToken.None);
        var html = Encoding.UTF8.GetString(ms.ToArray());

        // Optional: drop the page somewhere to open it in a browser (used while developing).
        var outPath = Environment.GetEnvironmentVariable("REVENUE_ANALYSIS_TEST_OUT");
        if (!string.IsNullOrWhiteSpace(outPath)) await File.WriteAllTextAsync(outPath, html);
        return html;
    }

    private static string Blob(string html, string id)
    {
        var start = html.IndexOf($"<script id=\"{id}\"", StringComparison.Ordinal);
        Assert.True(start >= 0, $"{id} missing");
        start = html.IndexOf('>', start) + 1;
        var end = html.IndexOf("</script>", start, StringComparison.Ordinal);
        return html[start..end];
    }

    [Fact]
    public void Dataset_skips_duplicates_out_of_window_claims_and_orphan_lines()
    {
        var data = BuildDataset();
        Assert.Equal(6, data.Claims.Count);
        Assert.Equal(1, data.DuplicateClaims);
        Assert.Equal(1, data.ClaimsOutsideWindow);
        Assert.Equal(4, data.Lines.Count);
        Assert.Equal(1, data.UnmatchedLines);
        Assert.Contains(data.Lines, l => l.Cpt == "87481");           // ".00" trimmed
        Assert.Contains(data.Lines, l => l.Mods == "59|91");
    }

    [Fact]
    public async Task Writer_fills_every_placeholder_and_keeps_the_blob_contract()
    {
        var html = await WriteAsync(BuildDataset());
        Assert.DoesNotContain("__LRN_", html);

        using var claims = JsonDocument.Parse(Blob(html, "data-blob"));
        var root = claims.RootElement;
        var n = root.GetProperty("ticket").GetArrayLength();
        Assert.Equal(6, n);
        foreach (var p in root.EnumerateObject())
        {
            if (p.Value.ValueKind == JsonValueKind.Array)
            {
                Assert.Equal(n, p.Value.GetArrayLength());
            }
            else
            {
                var d = p.Value.GetProperty("d").GetArrayLength();
                var i = p.Value.GetProperty("i");
                Assert.Equal(n, i.GetArrayLength());
                Assert.All(i.EnumerateArray(), x => Assert.InRange(x.GetInt32(), 0, d - 1));
            }
        }

        string Cat(string field, int claim)
        {
            var o = root.GetProperty(field);
            return o.GetProperty("d")[o.GetProperty("i")[claim].GetInt32()].GetString()!;
        }

        Assert.Equal(RevenueAnalysisHtmlWriter.ArClosed, Cat("ar", 0));
        Assert.Equal(RevenueAnalysisHtmlWriter.ArPartiallyPaid, Cat("ar", 1));
        Assert.Equal(RevenueAnalysisHtmlWriter.ArDenied, Cat("ar", 2));
        Assert.Equal(RevenueAnalysisHtmlWriter.ArNoResponse, Cat("ar", 3));
        Assert.Equal(RevenueAnalysisHtmlWriter.ArPatient, Cat("ar", 4));
        Assert.Equal(RevenueAnalysisHtmlWriter.ArZero, Cat("ar", 5));
        Assert.Equal(RevenueAnalysisHtmlWriter.CsNonCollectible, Cat("cs", 2));
        Assert.Equal(RevenueAnalysisHtmlWriter.CsCollectible, Cat("cs", 1));
        Assert.Equal("45", Cat("dcode", 1));
        Assert.Equal("16", Cat("dcode", 2));
        Assert.Equal("Claims Edits Related Issues", Cat("dcat", 2));
        Assert.Equal("Uncategorized denial code", Cat("dcat", 1));
        Assert.Equal("Patient Only", Cat("bm", 4));

        using var lines = JsonDocument.Parse(Blob(html, "line-blob"));
        var ci = lines.RootElement.GetProperty("ci").EnumerateArray().Select(x => x.GetInt32()).ToArray();
        Assert.Equal(ci.OrderBy(x => x), ci);                               // grouped by claim
        Assert.Equal(Enumerable.Range(0, 6), ci.Distinct());                // every claim has a line (zero line added)

        var b64 = Blob(html, "lineexport-blob");
        using var gz = new GZipStream(new MemoryStream(Convert.FromBase64String(b64)), CompressionMode.Decompress);
        using var export = await JsonDocument.ParseAsync(gz);
        Assert.Equal(ci.Length, export.RootElement.GetProperty("ci").GetArrayLength());
    }

    [Fact]
    public async Task Values_cannot_break_out_of_the_script_blocks()
    {
        var html = await WriteAsync(BuildDataset());
        Assert.DoesNotContain("</script><b>x", html);
        Assert.Contains("Cove Lab and Co", html);                         // lab name held to inert characters
        Assert.DoesNotContain("Cove <Lab>", html);
    }

    [Theory]
    [InlineData("87798", RevenueAnalysisCptCatalog.IdMolecular)]
    [InlineData("80305", RevenueAnalysisCptCatalog.DrugTesting)]
    [InlineData("G0483", RevenueAnalysisCptCatalog.DrugTesting)]
    [InlineData("0240U", RevenueAnalysisCptCatalog.Pla)]
    [InlineData("81479", RevenueAnalysisCptCatalog.Molecular)]
    [InlineData("80053", RevenueAnalysisCptCatalog.OrganPanels)]
    [InlineData("36415", RevenueAnalysisCptCatalog.Collection)]
    [InlineData("88305", RevenueAnalysisCptCatalog.Surgical)]
    public void Cpt_categories_follow_the_pathology_section_ranges(string code, string expected) =>
        Assert.Equal(expected, RevenueAnalysisCptCatalog.Categorize(code));

    [Theory]
    [InlineData("$1,234.50", 1234.50)]
    [InlineData("(25.00)", -25.00)]
    [InlineData("", 0)]
    [InlineData("abc", 0)]
    public void Money_parsing_is_lenient(string raw, double expected) =>
        Assert.Equal(expected, RaValue.ParseMoney(raw), 2);
}
