using LabMetricsDashboard.Models;
using LabMetricsDashboard.Services;
using Microsoft.AspNetCore.Mvc;

namespace LabMetricsDashboard.Controllers;

/// <summary>
/// CPT Code Search.
///
/// Everything is driven from <c>dbo.LabRegistry</c> on LRNMaster
/// (DefaultConnection) — no lab config JSON files are read here.
///
/// Flow:
///   1. Read active labs + their SP names from dbo.LabRegistry
///   2. Call each lab's SP (e.g. dbo.usp_CPTCodeSearch_Augustus_LRN)
///      in parallel on DefaultConnection
///   3. Assemble results into the view model
///
/// To enable a new lab: run LabRegistry_AddSprocName.sql to set SprocName,
/// then deploy that lab's SP on LRNMaster.
/// </summary>
public sealed class CptSearchController : Controller
{
    private readonly IConfiguration       _config;
    private readonly ICptSearchRepository _repo;
    private readonly ILogger<CptSearchController> _logger;

    public CptSearchController(
        IConfiguration config,
        ICptSearchRepository repo,
        ILogger<CptSearchController> logger)
    {
        _config = config;
        _repo   = repo;
        _logger = logger;
    }

    // GET /CptSearch
    [HttpGet]
    public IActionResult Index()
        => View(new CptSearchViewModel { HasSearched = false });

    // GET  /CptSearch/Search?cptCode=87798
    // POST /CptSearch/Search
    [HttpGet, HttpPost]
    public async Task<IActionResult> Search(string? cptCode, CancellationToken ct)
    {
        cptCode = cptCode?.Trim().ToUpperInvariant() ?? string.Empty;

        if (string.IsNullOrWhiteSpace(cptCode))
        {
            ModelState.AddModelError("cptCode", "Please enter a CPT code.");
            return View("Index", new CptSearchViewModel { HasSearched = false });
        }

        // All SPs and LabRegistry live on LRNMaster → DefaultConnection
        var connStr = _config.GetConnectionString("DefaultConnection");
        if (string.IsNullOrWhiteSpace(connStr))
        {
            _logger.LogError("CPTSearch: DefaultConnection not found in appsettings.json.");
            return View("Index", new CptSearchViewModel
            {
                HasSearched       = true,
                SearchedCptCode   = cptCode,
                TotalLabsSearched = 0,
            });
        }

        // Step 1 — read active labs from dbo.LabRegistry (no config files)
        var activeLabs = await _repo.GetActiveLabsAsync(connStr, ct);

        if (activeLabs.Count == 0)
        {
            _logger.LogWarning(
                "CPTSearch: dbo.LabRegistry has no active labs with a SprocName set. " +
                "Run LabRegistry_AddSprocName.sql on LRNMaster to configure labs.");

            return View("Index", new CptSearchViewModel
            {
                HasSearched       = true,
                SearchedCptCode   = cptCode,
                TotalLabsSearched = 0,
            });
        }

        // Step 2 — search all active labs in parallel (max 4 concurrent)
        var semaphore = new SemaphoreSlim(4, 4);
        var tasks = activeLabs.Select(async lab =>
        {
            await semaphore.WaitAsync(ct);
            try
            {
                return await _repo.SearchAsync(
                    connStr,
                    lab.SprocName,
                    lab.LabName,
                    lab.DisplayName,
                    cptCode,
                    ct);
            }
            finally
            {
                semaphore.Release();
            }
        });

        var allResults = await Task.WhenAll(tasks);

        var vm = new CptSearchViewModel
        {
            HasSearched       = true,
            SearchedCptCode   = cptCode,
            TotalLabsSearched = activeLabs.Count,
            LabResults        = allResults
                .Where(r => r.HasData || r.ErrorMessage != null)
                .OrderByDescending(r => r.TotalUnits)
                .ToList(),
        };

        return View("Index", vm);
    }
}
