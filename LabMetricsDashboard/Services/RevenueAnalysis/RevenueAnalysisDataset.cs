using System.Globalization;

namespace LabMetricsDashboard.Services.RevenueAnalysis;

/// <summary>
/// Column names the builder reads, each with the spellings the lab tables use. Claim Level and Line
/// Level share most of them; lab variants (VariantX has PlanType / Facility instead of PayerType /
/// ClinicName) are covered by the later aliases. The first alias present in the table wins.
/// </summary>
internal static class RaColumns
{
    public static readonly string[] ClaimId = ["ClaimID", "ClaimId", "Claim_ID"];
    public static readonly string[] Accession = ["AccessionNumber", "Accession"];
    public static readonly string[] Dos = ["DateofService", "DateOfService", "DOS", "ServiceDate"];
    public static readonly string[] Entered = ["ChargeEnteredDate", "EnteredDate"];
    public static readonly string[] FirstBilled = ["FirstBilledDate", "EmedixSubmissionDate"];
    public static readonly string[] LastBilled = ["LastBilledDate", "LastFiledDate"];
    public static readonly string[] Check = ["CheckDate", "PostingDate", "PostedDate"];
    public static readonly string[] Posting = ["PostingDate", "CheckDate", "PostedDate"];
    public static readonly string[] Panel = ["Panelname", "PanelName"];
    public static readonly string[] PayerCode = ["Payer_Code", "Payer_Common_Code", "PayerCode"];
    public static readonly string[] PayerType = ["PayerType", "PlanType", "Payer_Group_Code"];
    public static readonly string[] Payer = ["PayerName", "PayerName_Raw"];
    public static readonly string[] Clinic = ["ClinicName", "Facility", "Clinic"];
    public static readonly string[] SalesRep = ["SalesRepname", "SalesRepName", "SalesRep"];
    public static readonly string[] Referring = ["ReferringProvider", "OrderingProvider", "ReferringPhysician"];
    public static readonly string[] Patient = ["PatientID", "PatientId", "UID"];
    public static readonly string[] Status = ["ClaimStatus"];
    public static readonly string[] Denial = ["DenialCode"];
    public static readonly string[] Charge = ["ChargeAmount", "BilledAmount"];
    public static readonly string[] InsPay = ["InsurancePayment"];
    public static readonly string[] PatPay = ["PatientPayment"];
    public static readonly string[] TotPay = ["TotalPayments", "TotalPayment"];
    public static readonly string[] InsAdj = ["InsuranceAdjustments"];
    public static readonly string[] PatAdj = ["PatientAdjustments"];
    public static readonly string[] TotAdj = ["TotalAdjustments"];
    public static readonly string[] InsBal = ["InsuranceBalance"];
    public static readonly string[] PatBal = ["PatientBalance"];
    public static readonly string[] TotBal = ["TotalBalance"];
    public static readonly string[] Cpt = ["CPTCode", "CPT", "CptCode"];
    public static readonly string[] Units = ["Units"];
    public static readonly string[] Modifier = ["Modifier", "Modifiers"];

    private static readonly string[][] Shared =
    [
        ClaimId, Accession, Dos, Panel, Referring, Denial, Charge, InsPay, PatPay, TotPay,
        InsAdj, PatAdj, TotAdj, InsBal, PatBal, TotBal
    ];

    public static readonly IReadOnlyList<string> ClaimLevel = Shared
        .Concat([Entered, FirstBilled, LastBilled, Check, PayerCode, PayerType, Payer, Clinic, SalesRep, Patient, Status])
        .SelectMany(a => a).Distinct(StringComparer.OrdinalIgnoreCase).ToList();

    public static readonly IReadOnlyList<string> LineLevel = Shared
        .Concat([Posting, Cpt, Units, Modifier])
        .SelectMany(a => a).Distinct(StringComparer.OrdinalIgnoreCase).ToList();
}

/// <summary>Resolves logical fields to positions in a row, by the first alias the source has.</summary>
internal sealed class RaColumnMap
{
    private readonly Dictionary<string, int> _index;

    public RaColumnMap(IReadOnlyList<string> columns)
    {
        _index = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        for (int i = 0; i < columns.Count; i++) _index.TryAdd(columns[i], i);
    }

    public int Find(string[] aliases)
    {
        foreach (var a in aliases)
            if (_index.TryGetValue(a, out var i)) return i;
        return -1;
    }
}

/// <summary>Lenient readers for the lab tables, whose dates and amounts are mostly NVARCHAR.</summary>
internal static class RaValue
{
    private static readonly DateTime Epoch = new(1970, 1, 1, 0, 0, 0, DateTimeKind.Unspecified);

    private static readonly string[] DateFormats =
    [
        "yyyy-MM-dd", "M/d/yyyy", "MM/dd/yyyy", "M/d/yy", "MM/dd/yy", "yyyyMMdd", "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm:ss.fff", "yyyy-MM-ddTHH:mm:ss", "M/d/yyyy h:mm:ss tt", "M/d/yyyy H:mm", "MM/dd/yyyy HH:mm:ss",
        "dd-MMM-yyyy", "d-MMM-yy", "MMM d, yyyy", "MMM dd yyyy"
    ];

    public static int DaysSinceEpoch(DateTime date) => (int)(date.Date - Epoch).TotalDays;

    public static DateOnly FromDays(int days) => DateOnly.FromDateTime(Epoch.AddDays(days));

    public static bool Has(object?[] row, int i) =>
        i >= 0 && row[i] is not null && !(row[i] is string s && string.IsNullOrWhiteSpace(s));

    public static string Text(object?[] row, int i)
    {
        if (i < 0) return "";
        return row[i] switch
        {
            null => "",
            string s => s.Trim(),
            DateTime d => d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture),
            decimal m => TrimNumber(m.ToString(CultureInfo.InvariantCulture)),
            double d => TrimNumber(d.ToString(CultureInfo.InvariantCulture)),
            IFormattable f => f.ToString(null, CultureInfo.InvariantCulture).Trim(),
            var o => o.ToString()?.Trim() ?? ""
        };
    }

    /// <summary>"87798.00" -> "87798" so a numeric CPT or ID column reads like its text form.</summary>
    private static string TrimNumber(string s) =>
        s.Contains('.') ? s.TrimEnd('0').TrimEnd('.') : s;

    public static double Money(object?[] row, int i)
    {
        if (i < 0) return 0;
        switch (row[i])
        {
            case null: return 0;
            case decimal m: return (double)m;
            case double d: return double.IsFinite(d) ? d : 0;
            case float f: return double.IsFinite(f) ? f : 0;
            case int n: return n;
            case long l: return l;
            case short s: return s;
            case string str: return ParseMoney(str);
            default: return ParseMoney(Convert.ToString(row[i], CultureInfo.InvariantCulture));
        }
    }

    public static double ParseMoney(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return 0;
        var s = raw.Trim();
        var negative = false;
        if (s.StartsWith('(') && s.EndsWith(')')) { negative = true; s = s[1..^1]; }
        s = s.Replace("$", "", StringComparison.Ordinal).Replace(",", "", StringComparison.Ordinal).Trim();
        if (s.EndsWith('-')) { negative = !negative; s = s[..^1]; }
        if (!double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var v) || !double.IsFinite(v)) return 0;
        return negative ? -v : v;
    }

    /// <summary>Days since 1970-01-01, or null when blank / unparseable / implausible.</summary>
    public static int? Day(object?[] row, int i)
    {
        if (i < 0) return null;
        DateTime dt;
        switch (row[i])
        {
            case null: return null;
            case DateTime d: dt = d; break;
            case DateTimeOffset o: dt = o.DateTime; break;
            case DateOnly d: dt = d.ToDateTime(TimeOnly.MinValue); break;
            case string s:
                if (!TryParseDate(s, out dt)) return null;
                break;
            default:
                if (!TryParseDate(Convert.ToString(row[i], CultureInfo.InvariantCulture), out dt)) return null;
                break;
        }
        if (dt.Year < 1990 || dt.Year > 2100) return null;
        return DaysSinceEpoch(dt);
    }

    public static bool TryParseDate(string? raw, out DateTime value)
    {
        value = default;
        if (string.IsNullOrWhiteSpace(raw)) return false;
        var s = raw.Trim();
        if (DateTime.TryParseExact(s, DateFormats, CultureInfo.InvariantCulture, DateTimeStyles.AllowWhiteSpaces, out value))
            return true;
        // An Excel serial day number that slipped through a CSV import (45658 = 2025-01-01).
        if (s.Length == 5 && int.TryParse(s, NumberStyles.None, CultureInfo.InvariantCulture, out var serial) && serial is > 32000 and < 73000)
        {
            value = DateTime.FromOADate(serial);
            return true;
        }
        return DateTime.TryParse(s, CultureInfo.GetCultureInfo("en-US"), DateTimeStyles.AllowWhiteSpaces, out value);
    }
}

internal sealed class RaClaim
{
    public string Ticket = "";
    public string Accession = "";
    public int? Tdate, Dos, Ffd, Lfd, Post;
    public string Panel = "", PayerCode = "", PayerType = "", Payer = "", Clinic = "", SalesRep = "",
        Referring = "", PatientId = "", Status = "", DenialRaw = "";
    public double Ch, Tp, Ip, Pp, Adj, Pb, Ib;
}

internal sealed class RaLine
{
    public int Ci;
    public int? Pd, Dos;
    public double Ch, Tp, Ip, Pp, Adj, Pb, Ib, Units;
    public string Cpt = "", Mods = "", Panel = "", Referring = "";
}

/// <summary>
/// The claims and lines of one dashboard, read row by row from either source (live table or
/// Parquet snapshot) and kept in a compact form. Claims are read first; each line is attached to
/// its claim by ClaimID (or AccessionNumber), and lines of claims outside the window are dropped.
/// </summary>
internal sealed class RevenueAnalysisDataset
{
    private readonly int? _fromDay, _toDay;
    private readonly int _maxClaims;
    private readonly Dictionary<string, int> _byTicket = new(StringComparer.OrdinalIgnoreCase);
    private readonly Dictionary<string, int> _byAccession = new(StringComparer.OrdinalIgnoreCase);

    public List<RaClaim> Claims { get; } = [];
    public List<RaLine> Lines { get; } = [];
    public int DuplicateClaims { get; private set; }
    public int UnmatchedLines { get; private set; }
    public int ClaimsOutsideWindow { get; private set; }
    public List<string> Warnings { get; } = [];

    public RevenueAnalysisDataset(DateOnly? dosFrom, DateOnly? dosTo, int maxClaims)
    {
        _fromDay = dosFrom is { } f ? RaValue.DaysSinceEpoch(f.ToDateTime(TimeOnly.MinValue)) : null;
        _toDay = dosTo is { } t ? RaValue.DaysSinceEpoch(t.ToDateTime(TimeOnly.MinValue)) : null;
        _maxClaims = maxClaims;
    }

    // ---------------------------------------------------------------- claims
    private int _cId, _cAcc, _cDos, _cEnt, _cFfd, _cLfd, _cChk, _cPanel, _cPcode, _cPtype, _cPayer, _cClinic,
        _cRep, _cRef, _cPat, _cStatus, _cDen, _cCh, _cIp, _cPp, _cTp, _cIa, _cPa, _cTa, _cIb, _cPb, _cTb;

    public void BeginClaims(IReadOnlyList<string> columns)
    {
        var m = new RaColumnMap(columns);
        _cId = m.Find(RaColumns.ClaimId); _cAcc = m.Find(RaColumns.Accession); _cDos = m.Find(RaColumns.Dos);
        _cEnt = m.Find(RaColumns.Entered); _cFfd = m.Find(RaColumns.FirstBilled); _cLfd = m.Find(RaColumns.LastBilled);
        _cChk = m.Find(RaColumns.Check); _cPanel = m.Find(RaColumns.Panel); _cPcode = m.Find(RaColumns.PayerCode);
        _cPtype = m.Find(RaColumns.PayerType); _cPayer = m.Find(RaColumns.Payer); _cClinic = m.Find(RaColumns.Clinic);
        _cRep = m.Find(RaColumns.SalesRep); _cRef = m.Find(RaColumns.Referring); _cPat = m.Find(RaColumns.Patient);
        _cStatus = m.Find(RaColumns.Status); _cDen = m.Find(RaColumns.Denial); _cCh = m.Find(RaColumns.Charge);
        _cIp = m.Find(RaColumns.InsPay); _cPp = m.Find(RaColumns.PatPay); _cTp = m.Find(RaColumns.TotPay);
        _cIa = m.Find(RaColumns.InsAdj); _cPa = m.Find(RaColumns.PatAdj); _cTa = m.Find(RaColumns.TotAdj);
        _cIb = m.Find(RaColumns.InsBal); _cPb = m.Find(RaColumns.PatBal); _cTb = m.Find(RaColumns.TotBal);

        if (_cId < 0 && _cAcc < 0)
            throw new InvalidOperationException("The Claim Level data has neither a ClaimID nor an AccessionNumber column.");
        if (_cDos < 0)
            throw new InvalidOperationException("The Claim Level data has no DateofService column.");
        if (_cCh < 0)
            throw new InvalidOperationException("The Claim Level data has no ChargeAmount column.");
        if (_cStatus < 0) Warnings.Add("Claim Level has no ClaimStatus column - AR categories are derived from balances only.");
        if (_cClinic < 0) Warnings.Add("Claim Level has no ClinicName / Facility column - the Clinic view shows one group.");
    }

    public void AddClaim(object?[] r)
    {
        var dos = RaValue.Day(r, _cDos);
        if (_fromDay is not null || _toDay is not null)
        {
            if (dos is null || (_fromDay is { } f && dos < f) || (_toDay is { } t && dos > t)) { ClaimsOutsideWindow++; return; }
        }

        var ticket = RaValue.Text(r, _cId);
        var accession = RaValue.Text(r, _cAcc);
        var key = ticket.Length > 0 ? ticket : accession;
        if (key.Length > 0 && _byTicket.ContainsKey(key)) { DuplicateClaims++; return; }
        if (Claims.Count >= _maxClaims)
            throw new InvalidOperationException(
                $"More than {_maxClaims:N0} claims fall in this date-of-service window. Narrow the window and generate again.");

        var c = new RaClaim
        {
            Ticket = key.Length > 0 ? key : $"(row {Claims.Count + 1})",
            Accession = accession,
            Dos = dos,
            Tdate = RaValue.Day(r, _cEnt),
            Ffd = RaValue.Day(r, _cFfd),
            Lfd = RaValue.Day(r, _cLfd),
            Post = RaValue.Day(r, _cChk),
            Panel = RaValue.Text(r, _cPanel),
            PayerCode = RaValue.Text(r, _cPcode),
            PayerType = RaValue.Text(r, _cPtype),
            Payer = RaValue.Text(r, _cPayer),
            Clinic = RaValue.Text(r, _cClinic),
            SalesRep = RaValue.Text(r, _cRep),
            Referring = RaValue.Text(r, _cRef),
            PatientId = RaValue.Text(r, _cPat),
            Status = RaValue.Text(r, _cStatus),
            DenialRaw = RaValue.Text(r, _cDen),
        };
        ReadAmounts(r, _cCh, _cIp, _cPp, _cTp, _cIa, _cPa, _cTa, _cIb, _cPb, _cTb,
            out c.Ch, out c.Ip, out c.Pp, out c.Tp, out c.Adj, out c.Ib, out c.Pb);

        var index = Claims.Count;
        Claims.Add(c);
        if (key.Length > 0) _byTicket[key] = index;
        if (accession.Length > 0) _byAccession.TryAdd(accession, index);
    }

    // ---------------------------------------------------------------- lines
    private int _lId, _lAcc, _lDos, _lPost, _lPanel, _lRef, _lCh, _lIp, _lPp, _lTp, _lIa, _lPa, _lTa, _lIb, _lPb, _lTb,
        _lCpt, _lUnits, _lMod;

    public void BeginLines(IReadOnlyList<string> columns)
    {
        var m = new RaColumnMap(columns);
        _lId = m.Find(RaColumns.ClaimId); _lAcc = m.Find(RaColumns.Accession); _lDos = m.Find(RaColumns.Dos);
        _lPost = m.Find(RaColumns.Posting); _lPanel = m.Find(RaColumns.Panel); _lRef = m.Find(RaColumns.Referring);
        _lCh = m.Find(RaColumns.Charge); _lIp = m.Find(RaColumns.InsPay); _lPp = m.Find(RaColumns.PatPay);
        _lTp = m.Find(RaColumns.TotPay); _lIa = m.Find(RaColumns.InsAdj); _lPa = m.Find(RaColumns.PatAdj);
        _lTa = m.Find(RaColumns.TotAdj); _lIb = m.Find(RaColumns.InsBal); _lPb = m.Find(RaColumns.PatBal);
        _lTb = m.Find(RaColumns.TotBal); _lCpt = m.Find(RaColumns.Cpt); _lUnits = m.Find(RaColumns.Units);
        _lMod = m.Find(RaColumns.Modifier);

        if (_lId < 0 && _lAcc < 0)
            throw new InvalidOperationException("The Line Level data has neither a ClaimID nor an AccessionNumber column.");
        if (_lCpt < 0) Warnings.Add("Line Level has no CPTCode column - the CPT Analysis page will be empty.");
    }

    public void AddLine(object?[] r)
    {
        var ticket = RaValue.Text(r, _lId);
        int ci;
        if (!(ticket.Length > 0 && _byTicket.TryGetValue(ticket, out ci)))
        {
            var acc = RaValue.Text(r, _lAcc);
            if (!(acc.Length > 0 && _byAccession.TryGetValue(acc, out ci)))
            {
                UnmatchedLines++;
                return;
            }
        }

        var l = new RaLine
        {
            Ci = ci,
            Dos = RaValue.Day(r, _lDos),
            Pd = RaValue.Day(r, _lPost),
            Cpt = NormalizeCpt(RaValue.Text(r, _lCpt)),
            Mods = NormalizeModifiers(RaValue.Text(r, _lMod)),
            Panel = RaValue.Text(r, _lPanel),
            Referring = RaValue.Text(r, _lRef),
        };
        ReadAmounts(r, _lCh, _lIp, _lPp, _lTp, _lIa, _lPa, _lTa, _lIb, _lPb, _lTb,
            out l.Ch, out l.Ip, out l.Pp, out l.Tp, out l.Adj, out l.Ib, out l.Pb);
        var units = RaValue.Money(r, _lUnits);
        l.Units = units > 0 ? units : (l.Cpt.Length > 0 ? 1 : 0);
        Lines.Add(l);
    }

    /// <summary>
    /// The seven amounts. Totals fall back to their parts when the total column is missing or blank,
    /// and a source with only TotalBalance books it as insurance balance (a lab's open AR is payer AR).
    /// </summary>
    private static void ReadAmounts(object?[] r, int ch, int ip, int pp, int tp, int ia, int pa, int ta, int ib, int pb, int tb,
        out double charge, out double insPay, out double patPay, out double totPay, out double adj, out double insBal, out double patBal)
    {
        charge = Round(RaValue.Money(r, ch));
        insPay = Round(RaValue.Money(r, ip));
        patPay = Round(RaValue.Money(r, pp));
        totPay = Round(RaValue.Has(r, tp) ? RaValue.Money(r, tp) : insPay + patPay);
        if (!RaValue.Has(r, ip) && !RaValue.Has(r, pp) && totPay != 0) insPay = totPay;
        adj = Round(RaValue.Has(r, ta) ? RaValue.Money(r, ta) : RaValue.Money(r, ia) + RaValue.Money(r, pa));
        insBal = Round(RaValue.Money(r, ib));
        patBal = Round(RaValue.Money(r, pb));
        if (!RaValue.Has(r, ib) && !RaValue.Has(r, pb) && RaValue.Has(r, tb)) insBal = Round(RaValue.Money(r, tb));
    }

    private static double Round(double v) => Math.Round(v, 2, MidpointRounding.AwayFromZero);

    private static string NormalizeCpt(string raw)
    {
        var s = raw.Trim().ToUpperInvariant();
        if (s.EndsWith(".00", StringComparison.Ordinal)) s = s[..^3];
        return s;
    }

    /// <summary>"59, 91" / "59;QW" / "59 XU" -> "59|91". Single letters are diagnosis pointers, not modifiers.</summary>
    private static string NormalizeModifiers(string raw)
    {
        if (raw.Length == 0) return "";
        var parts = raw.Split([',', ';', '|', ' ', '/', '-'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(p => p.ToUpperInvariant())
            .Where(p => p.Length >= 2 && p.Length <= 3)
            .Distinct(StringComparer.Ordinal);
        return string.Join('|', parts);
    }
}
