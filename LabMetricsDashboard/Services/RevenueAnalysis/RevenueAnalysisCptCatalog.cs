using System.Text.RegularExpressions;

namespace LabMetricsDashboard.Services.RevenueAnalysis;

/// <summary>
/// The CPT Analysis page's service category and short description for a lab CPT / HCPCS code.
/// <para>Categories follow the AMA CPT Pathology &amp; Laboratory section ranges (80047-89398), plus
/// PLA (####U) and MAAA (####M) codes, specimen collection, E/M and HCPCS Level II. The names must
/// match <c>CPT_CAT_ORDER</c> in the template (tools/RevenueAnalysisTemplate/build_template.py), which
/// fixes their order on the page.</para>
/// <para>Descriptions come from LRNMaster.dbo.FeeSchedule.ShortDescription (the Medicare CLFS short
/// description imported under Master Values &gt; Fees Schedule Import); a code not on the schedule
/// shows without one.</para>
/// </summary>
public static partial class RevenueAnalysisCptCatalog
{
    public const string DrugTesting = "Drug Testing (Toxicology)";
    public const string Molecular = "Molecular Pathology";
    public const string Maaa = "Multianalyte Assays (MAAA)";
    public const string Pla = "Proprietary Lab Analyses (PLA)";
    public const string IdMolecular = "Infectious Disease (Molecular)";
    public const string Microbiology = "Microbiology";
    public const string Chemistry = "Chemistry";
    public const string OrganPanels = "Organ / Disease Panels";
    public const string Hematology = "Hematology & Coagulation";
    public const string Immunology = "Immunology";
    public const string Urinalysis = "Urinalysis";
    public const string Surgical = "Anatomic & Surgical Pathology";
    public const string Cytopathology = "Cytopathology";
    public const string Transfusion = "Transfusion Medicine";
    public const string OtherPathology = "Other Pathology & Lab";
    public const string Collection = "Specimen Collection & Handling";
    public const string EvaluationManagement = "Evaluation & Management";
    public const string Hcpcs = "HCPCS Level II";
    public const string Other = "Other Codes";

    private static readonly HashSet<string> DrugHcpcs = new(StringComparer.OrdinalIgnoreCase)
        { "G0480", "G0481", "G0482", "G0483", "G0659" };

    private static readonly HashSet<string> CollectionCodes = new(StringComparer.OrdinalIgnoreCase)
        { "36415", "36416", "99000", "99001", "P9603", "P9604", "P9612", "P9615", "G0471" };

    /// <summary>The page's category for <paramref name="code"/> (already trimmed and upper-cased).</summary>
    public static string Categorize(string code)
    {
        if (string.IsNullOrEmpty(code)) return Other;
        if (DrugHcpcs.Contains(code)) return DrugTesting;
        if (CollectionCodes.Contains(code)) return Collection;
        if (PlaCode().IsMatch(code)) return Pla;
        if (MaaaCode().IsMatch(code)) return Maaa;
        if (HcpcsCode().IsMatch(code)) return Hcpcs;
        if (code.Length != 5 || !int.TryParse(code, out var n)) return Other;

        return n switch
        {
            >= 80047 and <= 80081 => OrganPanels,
            >= 80143 and <= 80377 => DrugTesting,
            >= 80400 and <= 80439 => Chemistry,
            >= 81000 and <= 81099 => Urinalysis,
            >= 81105 and <= 81479 => Molecular,
            >= 81490 and <= 81599 => Maaa,
            >= 82009 and <= 84999 => Chemistry,
            >= 85002 and <= 85999 => Hematology,
            >= 86000 and <= 86849 => Immunology,
            >= 86850 and <= 86999 => Transfusion,
            >= 87470 and <= 87801 => IdMolecular,
            >= 87900 and <= 87913 => IdMolecular,
            >= 87001 and <= 87999 => Microbiology,
            >= 88104 and <= 88199 => Cytopathology,
            >= 88230 and <= 88299 => Molecular,
            >= 88300 and <= 88399 => Surgical,
            >= 88000 and <= 89398 => OtherPathology,
            >= 99202 and <= 99499 => EvaluationManagement,
            _ => Other
        };
    }

    [GeneratedRegex(@"^\d{4}U$", RegexOptions.CultureInvariant)]
    private static partial Regex PlaCode();

    [GeneratedRegex(@"^\d{4}M$", RegexOptions.CultureInvariant)]
    private static partial Regex MaaaCode();

    [GeneratedRegex(@"^[A-V]\d{4}$", RegexOptions.CultureInvariant)]
    private static partial Regex HcpcsCode();
}
