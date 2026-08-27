namespace LabMetricsDashboard.Models;

/// <summary>Backing model for the Reimbursement Insights chat screen.</summary>
public sealed class ReimbursementChatViewModel
{
    /// <summary>False when this environment has no agent configured — the page shows a notice instead of an input box.</summary>
    public bool IsConfigured { get; set; }

    /// <summary>One-click example questions, mirroring the agent's own starter prompts in Foundry.</summary>
    public IReadOnlyList<string> StarterPrompts { get; set; } = [];
}
