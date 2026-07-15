using System.Text.RegularExpressions;

namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 1B - strip plan/network-type codes (PPO, HMO, POS II, ...) as whole words,
/// multi-word codes first. The result is the CanonicalName that Step 7 scores and
/// that is written to LabInsuranceMaster.PayerNameNormalized.
/// "AETNA CHOICE POS II" -> "AETNA CHOICE".
/// </summary>
public static class Step1BStripPlanCodes
{
    public static string Run(string cosmeticName, IReadOnlyList<string> planCodesByLength)
    {
        var text = cosmeticName;
        foreach (var code in planCodesByLength)
            text = Regex.Replace(text, $@"(?<=^| ){Regex.Escape(code)}(?= |$)", " ");
        text = Regex.Replace(text, " {2,}", " ").Trim();
        // A name made up entirely of plan codes must not vanish - keep the cosmetic form.
        return text.Length == 0 ? cosmeticName : text;
    }

    public static void Run(MatchContext context, PayerPolicyIndex index)
        => context.CanonicalName = Run(context.CosmeticName, index.PlanCodesByLength);
}
