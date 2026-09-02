namespace LabMetricsDashboard.Models;

/// <summary>
/// Points this app at the Reimbursement Agent proxy (the ReimbursementAgentProxy App Service),
/// which fronts the Foundry ReimbursementAnalyst agent.
///
/// Bound from the "ReimbursementAgent" section. The proxy's own address is not a secret; the
/// shared signing key that authenticates us to it is — see <see cref="ReimbursementChatTokenOptions"/>.
/// </summary>
public sealed class ReimbursementAgentOptions
{
    public const string Section = "ReimbursementAgent";

    /// <summary>Base address of the proxy, e.g. https://reimb-agent-proxy.azurewebsites.net (no trailing path).</summary>
    public string BaseUrl { get; set; } = "";

    /// <summary>
    /// How long to wait for one question. A single answer is a full agent run — the model reasons,
    /// calls the MCP bridge, then writes a per-lab breakdown — so this is measured in tens of
    /// seconds, not the few seconds a normal API call takes.
    ///
    /// Keep it under 230 seconds. That is where the proxy App Service's front end drops an idle
    /// inbound request, and past it a slow answer stops arriving as our timeout and starts arriving
    /// as its 502 instead.
    /// </summary>
    public int TimeoutSeconds { get; set; } = 200;

    /// <summary>Turns the Reimbursement Chat screen off without removing the menu entry or redeploying code.</summary>
    public bool Enabled { get; set; } = true;
}

/// <summary>
/// The short-lived ticket this app signs to prove to the proxy that a real, signed-in user asked
/// the question. Bound from the "ChatToken" section.
///
/// SigningKey must be byte-identical to the ChatToken__SigningKey application setting on the
/// reimb-agent-proxy App Service — that shared value is the only thing making the two apps trust
/// each other, and a mismatch surfaces as a 401 on every question. It is a secret: it belongs in
/// Key Vault (secret name ChatToken--SigningKey) or appsettings.Local.json, never in appsettings.json.
/// </summary>
public sealed class ReimbursementChatTokenOptions
{
    public const string Section = "ChatToken";

    public string SigningKey { get; set; } = "";

    /// <summary>Must match ChatToken__Issuer on the proxy.</summary>
    public string Issuer { get; set; } = "ReimbursementWebApp";

    /// <summary>Must match ChatToken__Audience on the proxy.</summary>
    public string Audience { get; set; } = "ReimbursementAgentProxy";

    /// <summary>Ticket lifetime. The walkthrough specifies 30 minutes.</summary>
    public int LifetimeMinutes { get; set; } = 30;
}
