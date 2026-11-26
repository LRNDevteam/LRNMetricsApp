using System.Globalization;
using System.IO.Compression;
using System.Reflection;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;

namespace LabMetricsDashboard.Services.RevenueAnalysis;

/// <summary>Lookups the writer needs beyond the claim and line rows.</summary>
internal sealed class RevenueAnalysisWriteContext
{
    public required string LabName { get; init; }
    public required string SourceLabel { get; init; }
    public required string SourceShort { get; init; }
    public required string FileTag { get; init; }

    /// <summary>"Today" for the dashboard: aging, the as-of date and the future-date cut-off.</summary>
    public required DateTime GeneratedOn { get; init; }

    /// <summary>Normalized denial code (DenialCodeKey) -> description and category.</summary>
    public IReadOnlyDictionary<string, (string Description, string Category)> DenialMaster { get; init; } =
        new Dictionary<string, (string, string)>();

    /// <summary>Normalized denial codes of LRNMaster.dbo.NonCollectibleDenialMaster.</summary>
    public IReadOnlySet<string> NonCollectible { get; init; } = new HashSet<string>();

    /// <summary>CPT / HCPCS -> CLFS short description.</summary>
    public IReadOnlyDictionary<string, string> CptDescriptions { get; init; } = new Dictionary<string, string>();
}

/// <summary>
/// Writes the Revenue Analysis dashboard: the report team's page
/// (Templates/RevenueAnalysis/RevenueAnalysisTemplate.html, built by
/// tools/RevenueAnalysisTemplate/build_template.py) with its three data blobs filled from one lab's
/// claims and lines, in exactly the columnar layout the page's script reads:
/// <list type="bullet">
///   <item><c>data-blob</c>: one entry per claim; categorical fields as <c>{d:[values], i:[index per claim]}</c>,
///         dates as days since 1970-01-01.</item>
///   <item><c>line-blob</c>: one entry per CPT line, grouped by claim (<c>ci</c> ascending).</item>
///   <item><c>lineexport-blob</c>: gzip + base64 JSON of the same lines with export-only columns.</item>
/// </list>
/// Every figure on the page is recomputed in the browser from these rows.
/// </summary>
internal static class RevenueAnalysisHtmlWriter
{
    // AR Category and Claim Status values the page's script switches on (template constants AR / CS).
    public const string ArClosed = "Closed Claims";
    public const string ArPartiallyPaid = "Partially Paid and Outstanding AR";
    public const string ArPartiallyAdjusted = "Partially Adjusted";
    public const string ArPatient = "Patient AR";
    public const string ArDenied = "Denied";
    public const string ArNoResponse = "Non Responded AR";
    public const string ArZero = "$0 Billed Charges";

    public const string CsPaid = "Fully Paid and Closed Claims";
    public const string CsAdjusted = "Fully Adjusted";
    public const string CsPatient = "Patient Responsibility Outstanding";
    public const string CsCollectible = "Possible Collectible AR";
    public const string CsNonCollectible = "Non Collectible Denials";
    public const string CsZero = "$0 Billed Charges";

    private static readonly string[] AgeCats = ["0-30 days", "31-60 days", "61-90 days", "91-180 days", "181-365 days", "Over 365 days"];

    private const double Cent = 0.005;

    private static readonly Lazy<string> Template = new(LoadTemplate, LazyThreadSafetyMode.ExecutionAndPublication);

    private static string LoadTemplate()
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream("RevenueAnalysisTemplate.html")
            ?? throw new InvalidOperationException("Embedded resource RevenueAnalysisTemplate.html is missing from the build.");
        using var reader = new StreamReader(s, Encoding.UTF8);
        return reader.ReadToEnd();
    }

    private static readonly JsonWriterOptions JsonOptions = new()
    {
        // The default encoder escapes < > & ' and non-ASCII, so no value can close the <script> block.
        Encoder = JavaScriptEncoder.Default,
        Indented = false,
    };

    /// <summary>Writes the finished page (UTF-8) to <paramref name="output"/>.</summary>
    public static async Task WriteAsync(Stream output, RevenueAnalysisDataset data, RevenueAnalysisWriteContext ctx, CancellationToken ct)
    {
        var claims = data.Claims;
        var genDay = RaValue.DaysSinceEpoch(ctx.GeneratedOn);

        // Lines grouped by claim (the page walks each claim's lines by offset), plus one zero line for a
        // claim with none, on its claim-level post date, so Posted Date mode still places the claim.
        var hasLine = new bool[claims.Count];
        foreach (var l in data.Lines) hasLine[l.Ci] = true;
        var lines = new List<RaLine>(data.Lines.Count + 16);
        lines.AddRange(data.Lines);
        for (int i = 0; i < claims.Count; i++)
            if (!hasLine[i]) lines.Add(new RaLine { Ci = i, Pd = claims[i].Post, Dos = claims[i].Dos });
        var ordered = lines.OrderBy(l => l.Ci).ToArray(); // stable: keeps each claim's line order

        var derived = Derive(claims, ctx, genDay);

        int dosMin = claims.Where(c => c.Dos is not null).Select(c => c.Dos!.Value).DefaultIfEmpty(genDay).Min();
        int dosMax = claims.Where(c => c.Dos is not null).Select(c => c.Dos!.Value).DefaultIfEmpty(genDay).Max();
        var validFrom = RaValue.FromDays(dosMin);

        var cptInfo = BuildCptInfo(ordered, ctx.CptDescriptions);

        var page = Template.Value
            .Replace("__LRN_LAB_NAME__", SafeText(ctx.LabName), StringComparison.Ordinal)
            .Replace("__LRN_SOURCE_LABEL__", SafeText(ctx.SourceLabel), StringComparison.Ordinal)
            .Replace("__LRN_SOURCE_SHORT__", SafeText(ctx.SourceShort), StringComparison.Ordinal)
            .Replace("__LRN_FILE_TAG__", ctx.FileTag, StringComparison.Ordinal)
            .Replace("__LRN_GEN_DAY__", genDay.ToString(CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("__LRN_GENERATED__", ctx.GeneratedOn.ToString("MMM d, yyyy", CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("__LRN_VALID_FROM__", validFrom.ToString("yyyy-MM", CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("__LRN_PERIOD__",
                RaValue.FromDays(dosMin).ToString("MM/dd/yyyy", CultureInfo.InvariantCulture) + " – " +
                RaValue.FromDays(dosMax).ToString("MM/dd/yyyy", CultureInfo.InvariantCulture), StringComparison.Ordinal)
            .Replace("__LRN_CPT_INFO__", cptInfo, StringComparison.Ordinal);

        var parts = SplitOn(page, "__LRN_DATA_BLOB__", "__LRN_LINE_BLOB__", "__LRN_LINEEXPORT_BLOB__");

        await WriteTextAsync(output, parts[0], ct);
        await using (var w = new Utf8JsonWriter(output, JsonOptions)) { WriteClaimBlob(w, claims, derived); await w.FlushAsync(ct); }
        await WriteTextAsync(output, parts[1], ct);
        await using (var w = new Utf8JsonWriter(output, JsonOptions)) { WriteLineBlob(w, ordered); await w.FlushAsync(ct); }
        await WriteTextAsync(output, parts[2], ct);
        await WriteLineExportAsync(output, ordered, ctx.CptDescriptions, ct);
        await WriteTextAsync(output, parts[3], ct);
    }

    // ---------------------------------------------------------------- per-claim derivations
    private sealed class Derived
    {
        public required string[] Ar, Cs, Bm, DCode, DDesc, DCat, AgeCat, Panel, PayerType, Payer, Clinic, Referring;
        public required int[] Aging;
        public required int?[] PaidDate;
    }

    private static Derived Derive(List<RaClaim> claims, RevenueAnalysisWriteContext ctx, int genDay)
    {
        int n = claims.Count;
        var d = new Derived
        {
            Ar = new string[n], Cs = new string[n], Bm = new string[n], DCode = new string[n], DDesc = new string[n],
            DCat = new string[n], AgeCat = new string[n], Panel = new string[n], PayerType = new string[n],
            Payer = new string[n], Clinic = new string[n], Referring = new string[n], Aging = new int[n], PaidDate = new int?[n]
        };

        for (int i = 0; i < n; i++)
        {
            var c = claims[i];
            d.Panel[i] = Or(c.Panel, "(No panel)");
            d.PayerType[i] = Or(c.PayerType, "Unknown");
            d.Payer[i] = Or(c.Payer, "(No payer)");
            d.Clinic[i] = Or(c.Clinic, "(No clinic)");
            d.Referring[i] = Or(c.Referring, "(Not assigned)");

            // Denial: the first code on the claim, rolled up the way the Denial Claim Report does (CO-45 -> 45).
            var codes = DenialCodeHelper.SplitCodes(c.DenialRaw)
                .Select(DenialCodeKey.Normalize).Where(x => x.Length > 0).Distinct(StringComparer.OrdinalIgnoreCase).ToArray();
            var code = codes.FirstOrDefault() ?? "";
            d.DCode[i] = code;
            if (code.Length > 0)
            {
                var hit = codes.Select(x => ctx.DenialMaster.TryGetValue(x, out var m) ? m : default)
                    .FirstOrDefault(m => m.Category is { Length: > 0 } || m.Description is { Length: > 0 });
                d.DDesc[i] = hit.Description ?? "";
                d.DCat[i] = hit.Category is { Length: > 0 } ? hit.Category : "Uncategorized denial code";
            }
            else
            {
                d.DDesc[i] = "";
                d.DCat[i] = "";
            }
            var nonCollectible = codes.Any(ctx.NonCollectible.Contains);

            d.Ar[i] = ArCategory(c, code.Length > 0);
            d.Cs[i] = ClaimStatus(c, d.Ar[i], code.Length > 0, nonCollectible);
            d.Bm[i] = BillingMethod(c);

            var aging = c.Dos is { } dos ? Math.Max(0, genDay - dos) : 0;
            d.Aging[i] = aging;
            d.AgeCat[i] = AgeCats[aging <= 30 ? 0 : aging <= 60 ? 1 : aging <= 90 ? 2 : aging <= 180 ? 3 : aging <= 365 ? 4 : 5];
            d.PaidDate[i] = c.Ip > Cent ? c.Post : null;
        }
        return d;
    }

    private static string Or(string value, string fallback) => value.Length > 0 ? value : fallback;

    /// <summary>
    /// The claim's AR Category. The LIS claim status leads; balances decide where a status alone is
    /// ambiguous (a "Partially Paid" claim with nothing left owing is closed), and a status the
    /// mapping does not recognise falls back to the balances entirely.
    /// </summary>
    internal static string ArCategory(RaClaim c, bool hasDenialCode)
    {
        if (c.Ch <= Cent) return ArZero;
        var s = c.Status.Trim().ToLowerInvariant();
        bool insOpen = c.Ib > Cent, patOpen = c.Pb > Cent, paid = c.Tp > Cent, adjusted = c.Adj > Cent;

        string ByBalance()
        {
            if (insOpen)
            {
                if (paid) return ArPartiallyPaid;
                if (adjusted) return ArPartiallyAdjusted;
                return hasDenialCode ? ArDenied : ArNoResponse;
            }
            return patOpen ? ArPatient : ArClosed;
        }
        string Settled() => patOpen ? ArPatient : ArClosed;

        if (s.Length == 0) return ByBalance();
        if (s.Contains("void")) return ArClosed;
        if (s.Contains("no response") || s.Contains("unbilled") || s.Contains("not billed") || s.Contains("pending")
            || s.Contains("submitted") || s.Contains("in process") || s.Contains("open"))
            return paid || adjusted ? ByBalance() : ArNoResponse;
        if (s.Contains("partially denied") || s.Contains("partial denied") || s.Contains("partially paid") || s.Contains("partial paid"))
            return insOpen ? ArPartiallyPaid : Settled();
        if (s.Contains("partially adjusted") || s.Contains("partial adjusted"))
            return insOpen ? ArPartiallyAdjusted : Settled();
        if (s.Contains("denied") || s.Contains("denial") || s.Contains("rejected") || s.Contains("w/o payment") || s.Contains("without payment"))
            return insOpen ? ArDenied : Settled();
        if (s.Contains("patient"))
            return patOpen ? ArPatient : insOpen ? ByBalance() : ArClosed;
        if (s.Contains("fully paid") || s.Contains("fully adjusted") || s == "paid" || s == "adjusted" || s.Contains("closed"))
            return insOpen ? ByBalance() : Settled();
        return ByBalance();
    }

    /// <summary>
    /// The claim's collectibility, a second lens on the same balances: settled, adjusted off, owed
    /// by the patient, or owed by the payer - and payer AR on a non-collectible denial code is called out.
    /// </summary>
    internal static string ClaimStatus(RaClaim c, string ar, bool hasDenialCode, bool nonCollectible)
    {
        if (ar == ArZero) return CsZero;
        if (c.Ib > Cent) return hasDenialCode && nonCollectible ? CsNonCollectible : CsCollectible;
        if (c.Pb > Cent) return CsPatient;
        return c.Tp > Cent ? CsPaid : CsAdjusted;
    }

    /// <summary>Who carries the charge: insurance, the patient, both, or the ordering client.</summary>
    internal static string BillingMethod(RaClaim c)
    {
        var p = (c.PayerType + " " + c.Payer).ToLowerInvariant();
        if (p.Contains("client")) return "Client Bill";
        var selfPay = c.Payer.Length == 0 || p.Contains("self") || p.Contains("patient pay") || p.Contains("cash")
                      || p.Contains("uninsured") || p.Contains("no insurance");
        if (selfPay) return c.Ch <= Cent ? "No Bill / No Insurance" : "Patient Only";
        return c.Pp > Cent || c.Pb > Cent ? "Insurance & Patient" : "Insurance Only";
    }

    // ---------------------------------------------------------------- blobs
    private static void WriteClaimBlob(Utf8JsonWriter w, List<RaClaim> claims, Derived d)
    {
        int n = claims.Count;
        var empty = new string[n];
        Array.Fill(empty, "");

        w.WriteStartObject();
        WriteStrings(w, "ticket", claims.Select(c => c.Ticket));
        WriteDays(w, "tdate", claims.Select(c => c.Tdate));
        WriteDays(w, "dos", claims.Select(c => c.Dos));
        WriteDays(w, "dos0", claims.Select(c => c.Dos));
        WriteDays(w, "ffd", claims.Select(c => c.Ffd));
        WriteDays(w, "lfd", claims.Select(c => c.Lfd ?? c.Ffd));
        WriteDays(w, "post", claims.Select(c => c.Post));
        WriteDays(w, "ppd", d.PaidDate);
        WriteDict(w, "otype", d.Panel);
        WriteDict(w, "otype0", d.Panel);
        WriteDict(w, "icode", claims.Select(c => c.PayerCode).ToArray());
        WriteDict(w, "igroup", d.PayerType);
        WriteDict(w, "payer", d.Payer);
        WriteDict(w, "bm", d.Bm);
        WriteDict(w, "prov", d.Clinic);
        WriteDict(w, "provc", claims.Select(c => c.SalesRep).ToArray());
        WriteDict(w, "rprov", d.Referring);
        WriteDict(w, "rprovc", empty);
        WriteDict(w, "rprov0", d.Referring);
        WriteStrings(w, "pid", claims.Select(c => c.PatientId));
        WriteDict(w, "np", empty);
        WriteDict(w, "npc", empty);
        w.WriteStartArray("aging");
        foreach (var a in d.Aging) w.WriteNumberValue(a);
        w.WriteEndArray();
        WriteDict(w, "agecat", d.AgeCat);
        WriteMoney(w, "ch", claims.Select(c => c.Ch));
        WriteMoney(w, "tp", claims.Select(c => c.Tp));
        WriteMoney(w, "ip", claims.Select(c => c.Ip));
        WriteMoney(w, "pp", claims.Select(c => c.Pp));
        WriteMoney(w, "adj", claims.Select(c => c.Adj));
        WriteMoney(w, "pb", claims.Select(c => c.Pb));
        WriteMoney(w, "ib", claims.Select(c => c.Ib));
        WriteDict(w, "dcode", d.DCode);
        WriteDict(w, "ddesc", d.DDesc);
        WriteDict(w, "dcat", d.DCat);
        WriteDict(w, "ar", d.Ar);
        WriteDict(w, "cs", d.Cs);
        w.WriteEndObject();
    }

    private static void WriteLineBlob(Utf8JsonWriter w, RaLine[] lines)
    {
        w.WriteStartObject();
        w.WriteStartArray("ci");
        foreach (var l in lines) w.WriteNumberValue(l.Ci);
        w.WriteEndArray();
        WriteDays(w, "pd", lines.Select(l => l.Pd));
        WriteLineMoney(w, lines);
        WriteDict(w, "cpt", lines.Select(l => l.Cpt).ToArray());
        WriteMoney(w, "un", lines.Select(l => l.Units));
        WriteDict(w, "mods", lines.Select(l => l.Mods).ToArray());
        WriteDict(w, "ot", lines.Select(l => l.Panel).ToArray());
        WriteDict(w, "rp", lines.Select(l => l.Referring).ToArray());
        w.WriteEndObject();
    }

    private static void WriteLineMoney(Utf8JsonWriter w, RaLine[] lines)
    {
        WriteMoney(w, "ch", lines.Select(l => l.Ch));
        WriteMoney(w, "tp", lines.Select(l => l.Tp));
        WriteMoney(w, "ip", lines.Select(l => l.Ip));
        WriteMoney(w, "pp", lines.Select(l => l.Pp));
        WriteMoney(w, "adj", lines.Select(l => l.Adj));
        WriteMoney(w, "pb", lines.Select(l => l.Pb));
        WriteMoney(w, "ib", lines.Select(l => l.Ib));
    }

    /// <summary>The Source Data page's CPT line-level CSV, gzip-compressed and base64-encoded (unpacked on first use).</summary>
    private static async Task WriteLineExportAsync(Stream output, RaLine[] lines, IReadOnlyDictionary<string, string> cptDesc, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        await using (var gz = new GZipStream(buffer, CompressionLevel.Optimal, leaveOpen: true))
        await using (var w = new Utf8JsonWriter(gz, JsonOptions))
        {
            var mods = lines.Select(l => l.Mods.Split('|', StringSplitOptions.RemoveEmptyEntries)).ToArray();
            w.WriteStartObject();
            w.WriteStartArray("ci");
            foreach (var l in lines) w.WriteNumberValue(l.Ci);
            w.WriteEndArray();
            WriteDays(w, "dos", lines.Select(l => l.Dos));
            WriteDays(w, "pd", lines.Select(l => l.Pd));
            WriteLineMoney(w, lines);
            WriteMoney(w, "un", lines.Select(l => l.Units));
            WriteDict(w, "ot", lines.Select(l => l.Panel).ToArray());
            WriteDict(w, "rpc", lines.Select(_ => "").ToArray());
            WriteDict(w, "rpn", lines.Select(l => l.Referring).ToArray());
            WriteDict(w, "cpt", lines.Select(l => l.Cpt).ToArray());
            WriteDict(w, "desc", lines.Select(l => cptDesc.TryGetValue(l.Cpt, out var x) ? x : "").ToArray());
            WriteDict(w, "m1", mods.Select(m => m.Length > 0 ? m[0] : "").ToArray());
            WriteDict(w, "m2", mods.Select(m => m.Length > 1 ? m[1] : "").ToArray());
            w.WriteEndObject();
            await w.FlushAsync(ct);
        }

        var b64 = Convert.ToBase64String(buffer.GetBuffer(), 0, (int)buffer.Length);
        await WriteTextAsync(output, b64, ct);
    }

    /// <summary>The page's CPT_INFO object: {code: {cat, desc}} for every code billed.</summary>
    private static string BuildCptInfo(RaLine[] lines, IReadOnlyDictionary<string, string> cptDesc)
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms, JsonOptions))
        {
            w.WriteStartObject();
            foreach (var code in lines.Select(l => l.Cpt).Where(c => c.Length > 0).Distinct(StringComparer.Ordinal).OrderBy(c => c, StringComparer.Ordinal))
            {
                w.WriteStartObject(code);
                w.WriteString("cat", RevenueAnalysisCptCatalog.Categorize(code));
                w.WriteString("desc", cptDesc.TryGetValue(code, out var desc) ? desc : "");
                w.WriteEndObject();
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(ms.ToArray());
    }

    private static void WriteDict(Utf8JsonWriter w, string name, string[] values)
    {
        var distinct = values.Distinct(StringComparer.Ordinal)
            .OrderBy(v => v.Length == 0 ? 1 : 0)
            .ThenBy(v => v, StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var index = new Dictionary<string, int>(distinct.Length, StringComparer.Ordinal);
        for (int k = 0; k < distinct.Length; k++) index[distinct[k]] = k;

        w.WriteStartObject(name);
        w.WriteStartArray("d");
        foreach (var v in distinct) w.WriteStringValue(v);
        w.WriteEndArray();
        w.WriteStartArray("i");
        foreach (var v in values) w.WriteNumberValue(index[v]);
        w.WriteEndArray();
        w.WriteEndObject();
        w.Flush();
    }

    // Each column is flushed as soon as it is written: the writer otherwise buffers a whole blob,
    // which for a large lab is tens of MB held in memory per build.
    private static void WriteStrings(Utf8JsonWriter w, string name, IEnumerable<string> values)
    {
        w.WriteStartArray(name);
        foreach (var v in values) w.WriteStringValue(v);
        w.WriteEndArray();
        w.Flush();
    }

    private static void WriteDays(Utf8JsonWriter w, string name, IEnumerable<int?> values)
    {
        w.WriteStartArray(name);
        foreach (var v in values)
        {
            if (v is { } x) w.WriteNumberValue(x);
            else w.WriteNullValue();
        }
        w.WriteEndArray();
        w.Flush();
    }

    private static void WriteMoney(Utf8JsonWriter w, string name, IEnumerable<double> values)
    {
        w.WriteStartArray(name);
        foreach (var v in values)
        {
            var r = Math.Round(v, 2, MidpointRounding.AwayFromZero);
            if (r == Math.Floor(r) && Math.Abs(r) < 1e15) w.WriteNumberValue((long)r);
            else w.WriteNumberValue(r);
        }
        w.WriteEndArray();
        w.Flush();
    }

    private static async Task WriteTextAsync(Stream output, string text, CancellationToken ct)
    {
        var bytes = Encoding.UTF8.GetBytes(text);
        await output.WriteAsync(bytes, ct);
    }

    private static string[] SplitOn(string text, params string[] tokens)
    {
        var parts = new List<string>(tokens.Length + 1);
        var start = 0;
        foreach (var token in tokens)
        {
            var at = text.IndexOf(token, start, StringComparison.Ordinal);
            if (at < 0) throw new InvalidOperationException($"Template placeholder {token} is missing.");
            parts.Add(text[start..at]);
            start = at + token.Length;
        }
        parts.Add(text[start..]);
        return parts.ToArray();
    }

    /// <summary>
    /// A name the template drops into HTML text, JS single-quoted strings and JS template literals
    /// alike, so it is held to characters that are inert in all three.
    /// </summary>
    internal static string SafeText(string? value)
    {
        var sb = new StringBuilder();
        foreach (var ch in value ?? "")
        {
            if (char.IsLetterOrDigit(ch) || ch is ' ' or '-' or '.' or ',' or '(' or ')' or '/' or ':' or '_' or '–' or '#')
                sb.Append(ch);
            else if (ch == '&')
                sb.Append(" and ");
            else
                sb.Append(' ');
        }
        var s = string.Join(' ', sb.ToString().Split(' ', StringSplitOptions.RemoveEmptyEntries));
        return s.Length == 0 ? "Lab" : s;
    }
}
