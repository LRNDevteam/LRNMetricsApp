namespace LRN.PayerPolicyMapper.Core.Steps;

/// <summary>
/// Step 3 - program type: a populated LabInsuranceMaster.PlanType wins outright; otherwise the
/// first ProgramTypeRule hit in Priority order (Dual=5, Railroad Medicare=8, Medicaid/Medicare=10,
/// Exchange/Federal=20, Commercial NULL-pattern fallback=999).
/// </summary>
public static class Step3ResolveProgramType
{
    public static void Run(MatchContext context, PayerPolicyIndex index)
    {
        if (!string.IsNullOrWhiteSpace(context.LabPlanType))
        {
            context.ResolvedProgramType = context.LabPlanType.Trim();
            return;
        }
        foreach (var (program, regex) in index.ProgramRules)
        {
            if (regex is null || regex.IsMatch(context.CanonicalName))
            {
                context.ResolvedProgramType = program;
                return;
            }
        }
    }
}
