using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// API controller for the in-app help chatbot.
/// </summary>
[Route("api/helpbot")]
[ApiController]
public class HelpBotController : ControllerBase
{
    private readonly HelpBotService _bot;

    public HelpBotController(HelpBotService bot) => _bot = bot;

    /// <summary>POST /api/helpbot/ask — returns an answer + suggestions.</summary>
    [HttpPost("ask")]
    public IActionResult Ask([FromBody] HelpBotRequest request)
    {
        var (answer, suggestions) = _bot.GetAnswer(request.Question ?? string.Empty);

        return Ok(new HelpBotResponse
        {
            Answer = answer,
            Suggestions = suggestions
        });
    }

    /// <summary>GET /api/helpbot/topics — returns all available topics.</summary>
    [HttpGet("topics")]
    public IActionResult Topics()
    {
        return Ok(_bot.GetAllTopics());
    }

    public sealed class HelpBotRequest
    {
        public string? Question { get; set; }
    }

    public sealed class HelpBotResponse
    {
        public string Answer { get; set; } = string.Empty;
        public List<string> Suggestions { get; set; } = [];
    }
}
