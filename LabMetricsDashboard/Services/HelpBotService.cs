using LabMetricsDashboard.Models;

namespace LabMetricsDashboard.Services;

/// <summary>
/// Loads the help-bot knowledge base from <c>wwwroot/data/helpbot-kb.json</c>
/// and matches user questions using keyword scoring.
/// </summary>
public sealed class HelpBotService
{
    private readonly List<HelpBotEntry> _entries;
    private readonly ILogger<HelpBotService> _logger;

    public HelpBotService(IWebHostEnvironment env, ILogger<HelpBotService> logger)
    {
        _logger = logger;
        var path = Path.Combine(env.WebRootPath, "data", "helpbot-kb.json");

        if (File.Exists(path))
        {
            var json = File.ReadAllText(path);
            _entries = System.Text.Json.JsonSerializer.Deserialize<List<HelpBotEntry>>(json,
                new System.Text.Json.JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                ?? [];
            _logger.LogInformation("HelpBot KB loaded with {Count} entries.", _entries.Count);
        }
        else
        {
            _entries = [];
            _logger.LogWarning("HelpBot KB file not found at {Path}.", path);
        }
    }

    /// <summary>
    /// Returns the best-matching answer for the given user question,
    /// or a fallback message if no good match is found.
    /// Also returns up to 3 suggested follow-up questions.
    /// </summary>
    public (string Answer, List<string> Suggestions) GetAnswer(string userQuestion)
    {
        if (string.IsNullOrWhiteSpace(userQuestion))
            return ("Please type a question and I'll do my best to help!", []);

        var queryWords = Tokenize(userQuestion);

        var scored = _entries
            .Select(e => new
            {
                Entry = e,
                Score = ScoreMatch(queryWords, e.Keywords, e.Question)
            })
            .Where(x => x.Score > 0)
            .OrderByDescending(x => x.Score)
            .ToList();

        if (scored.Count == 0)
        {
            var suggestions = _entries.Take(3).Select(e => e.Question).ToList();
            return ("I'm not sure about that. Here are some topics I can help with:", suggestions);
        }

        var best = scored[0];
        var followUps = scored
            .Skip(1)
            .Take(3)
            .Select(x => x.Entry.Question)
            .ToList();

        return (best.Entry.Answer, followUps);
    }

    /// <summary>
    /// Returns all available questions for the suggestions list.
    /// </summary>
    public List<string> GetAllTopics() =>
        _entries.Select(e => e.Question).ToList();

    private static double ScoreMatch(HashSet<string> queryWords, List<string> keywords, string question)
    {
        double score = 0;

        // Keyword hits (weighted heavily)
        var matchedKeywords = keywords.Count(k => queryWords.Contains(k));
        score += matchedKeywords * 2.0;

        // Question word overlap
        var questionWords = Tokenize(question);
        var overlap = queryWords.Count(w => questionWords.Contains(w));
        score += overlap * 1.0;

        // Bonus for substring match in the question
        foreach (var word in queryWords)
        {
            if (word.Length >= 4 && question.Contains(word, StringComparison.OrdinalIgnoreCase))
                score += 0.5;
        }

        return score;
    }

    private static HashSet<string> Tokenize(string text)
    {
        var words = text
            .ToLowerInvariant()
            .Split([' ', '?', '!', '.', ',', ';', ':', '-', '_', '/', '\\', '(', ')', '"', '\''],
                   StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w.Length > 1);

        return new HashSet<string>(words, StringComparer.OrdinalIgnoreCase);
    }
}
