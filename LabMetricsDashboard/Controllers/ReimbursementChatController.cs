using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services.ReimbursementAgent;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.RateLimiting;
using Microsoft.Extensions.Options;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// Reimbursement Insights chat — a full screen that talks to the Foundry ReimbursementAnalyst
/// agent through the ReimbursementAgentProxy App Service.
///
/// Nothing here reaches the database. The agent answers from the MCP bridge (Data API Builder over
/// dbo.CPTAverage plus the three pricing views), and this controller is only the relay:
///
///   browser --POST /ReimbursementChat/Ask--> this controller --signed ticket--> agent proxy
///
/// The relay is what makes sign-in the real boundary. Every action inherits the application-wide
/// AuthorizeFilter, so an unauthenticated request never gets as far as a signed ticket being
/// minted — hiding the menu entry is convenience, this is enforcement.
/// </summary>
public sealed class ReimbursementChatController : Controller
{
    /// <summary>Matches the starter prompts configured on the agent in Foundry.</summary>
    private static readonly string[] DefaultStarterPrompts =
    [
        "Average Reimbursement for 87798",
        "Average Reimbursement for Aetna for 87798",
        "Average Reimbursement for UTI Panel"
    ];

    private readonly IReimbursementAgentApiClient _agent;
    private readonly IOptionsMonitor<ReimbursementAgentOptions> _options;

    public ReimbursementChatController(
        IReimbursementAgentApiClient agent,
        IOptionsMonitor<ReimbursementAgentOptions> options)
    {
        _agent = agent;
        _options = options;
    }

    // GET /ReimbursementChat
    [HttpGet]
    public IActionResult Index()
    {
        var options = _options.CurrentValue;

        // No ViewData["Title"] / ["PageLabel"] here: the view sets Layout = null and renders its
        // own document, so the shared layout's title and breadcrumb never read them.

        return View(new ReimbursementChatViewModel
        {
            // Configured but unreachable is a deployment problem; not configured at all is an
            // environment that simply does not have the agent. The page distinguishes the two.
            IsConfigured = options.Enabled && !string.IsNullOrWhiteSpace(options.BaseUrl),
            StarterPrompts = DefaultStarterPrompts
        });
    }

    // POST /ReimbursementChat/Ask
    [HttpPost]
    [ValidateAntiForgeryToken]
    [EnableRateLimiting(ReimbursementChatRateLimit.PolicyName)]
    public async Task<IActionResult> Ask([FromBody] AskQuestionRequest request, CancellationToken ct)
    {
        var question = request?.Question?.Trim();

        if (string.IsNullOrWhiteSpace(question))
        {
            return BadRequest(new { error = "Please type a question first." });
        }

        // A question is a sentence, not a payload. Capping it here keeps a paste of a whole
        // spreadsheet from becoming an expensive model run.
        if (question.Length > 1000)
        {
            return BadRequest(new { error = "That question is too long. Please shorten it to under 1000 characters." });
        }

        if (!_options.CurrentValue.Enabled)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable,
                new { error = "The reimbursement agent is turned off in this environment." });
        }

        var result = await _agent.AskAsync(question, User, ct);

        return result.Error is null
            ? Ok(new { answer = result.Answer })
            : StatusCode(StatusCodes.Status502BadGateway, new { error = result.Error });
    }

    public sealed class AskQuestionRequest
    {
        public string? Question { get; set; }
    }
}

/// <summary>Names the per-user rate limit policy registered in Program.cs.</summary>
public static class ReimbursementChatRateLimit
{
    public const string PolicyName = "reimbursement-chat";
}
