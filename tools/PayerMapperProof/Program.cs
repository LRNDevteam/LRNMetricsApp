// Read-only step-by-step proof runner for the payer matching pipeline.
// Loads the REAL reference index from LRNMaster, evaluates the given LabInsuranceMaster
// rows through Steps 1A-8 and prints every intermediate MatchContext field per the
// dev spec / workflow diagram. Nothing is persisted.
//
// Usage: dotnet run -- <connectionString> <labInsuranceMasterId> [id2 id3 ...]

using LRN.PayerPolicyMapper.Core;
using LRN.PayerPolicyMapper.Core.Abstractions;
using LRN.PayerPolicyMapper.Core.Data;
using LRN.PayerPolicyMapper.Core.Steps;
using Microsoft.Extensions.Logging;

if (args.Length < 2)
{
    Console.Error.WriteLine("Usage: PayerMapperProof <connectionString> <labInsuranceMasterId> [more ids...]");
    return 1;
}

var connectionString = args[0];
var ids = args.Skip(1).Select(int.Parse).ToArray();

using var loggerFactory = LoggerFactory.Create(b => b.SetMinimumLevel(LogLevel.Warning).AddConsole());
var referenceData = new SqlReferenceDataRepository(connectionString);
var labRepository = new SqlLabInsuranceRepository(connectionString);
var indexProvider = new CachedPayerPolicyIndexProvider(referenceData, loggerFactory.CreateLogger<CachedPayerPolicyIndexProvider>());
var pipeline = new MatchingPipeline(indexProvider, labRepository, new NoopAudit(), new NoopNotify(), new MatchingOptions());

var index = await indexProvider.GetAsync(CancellationToken.None);
Console.WriteLine($"STEP 0 - Reference index: {index.PolicyRecords.Count} active policy rows, " +
                  $"{index.PolicyRecordsByFamily.Count} family buckets, {index.Aliases.Count} aliases, " +
                  $"{index.FamilyRules.Count} family rules, {index.BrandMappings.Count} state-brand mappings, " +
                  $"{index.PlanCodesByLength.Count} plan codes, {index.RecordsMissingGlobalPayerId.Count} rows missing Global Payer ID");
Console.WriteLine(new string('=', 110));

foreach (var id in ids)
{
    var row = await labRepository.GetRowAsync(id, CancellationToken.None);
    if (row is null) { Console.WriteLine($"Row {id}: not found"); continue; }

    var result = pipeline.Evaluate(row, index);
    var c = result.Context;

    Console.WriteLine($"LabInsuranceMasterId {id}");
    Console.WriteLine($"  INPUT      RawName='{row.PayerNameRaw}'  LabState='{row.LabState}'  LabStateCode='{row.LabStateCode}'  PlanType='{row.PlanType}'");
    Console.WriteLine($"  STEP 1A    Canonicalize (cosmetic)        -> '{c.CosmeticName}'");
    Console.WriteLine($"  STEP 1B    Strip plan/network codes       -> '{c.CanonicalName}'{(c.CanonicalName != c.CosmeticName ? "   [codes stripped]" : "   [nothing to strip]")}");
    Console.WriteLine($"  STEP 2     Resolve state                  -> {(c.ResolvedStateCode ?? "none")}  (source: {c.StateSignalSource})");
    Console.WriteLine($"  STEP 3     Resolve program type           -> {c.ResolvedProgramType ?? "none"}{(!string.IsNullOrWhiteSpace(row.PlanType) ? "   [Lab PlanType wins]" : "   [inferred from name]")}");
    Console.WriteLine($"  STEP 4     Family classification          -> {c.CandidateFamily ?? "none (full-master fallback)"}");
    Console.WriteLine($"  STEP 5     Alias (CanonicalName, State)   -> {(c.AliasHit ? $"HIT -> Global Payer ID {c.AliasGlobalPayerId} (skip 6-8, AutoMap @100)" : "miss -> continue to scoring")}");

    if (!c.AliasHit)
    {
        var pool = Step6SelectCandidates.Run(c, index);
        Console.WriteLine($"  STEP 6     Candidate pool                 -> {pool.Count} record(s){(PayerPolicyIndex.FamilyKey(c.CandidateFamily) != null && pool.Count != index.PolicyRecords.Count ? $" (family '{c.CandidateFamily}')" : " (full master)")}");
        Console.WriteLine($"  STEP 7     Top candidates (base = 0.40*TokenSet + 0.25*Weighted + 0.20*Partial + 0.15*TokenSort):");
        foreach (var cand in result.Candidates.Take(3))
            Console.WriteLine($"             #{cand.Rank} '{cand.Record.PayerNameRaw}' (PP {cand.Record.PPInsuranceMasterId}, GID {(cand.Record.GlobalPayerId?.ToString() ?? "MISSING")}) " +
                              $"base {cand.BaseNameScore}  state {cand.StateAdjustment:+0;-0;0} ({cand.Record.StateCode ?? "-"})  program {cand.ProgramAdjustment:+0;-0;0} ({cand.Record.ProgramType ?? "-"})  => {cand.Score}");
        if (result.Candidates.Count == 0) Console.WriteLine("             (no candidates)");
    }

    Console.WriteLine($"  STEP 8     Decision                       -> {result.Decision}" +
                      $"  (confidence {result.ConfidenceScore?.ToString() ?? "n/a"}" +
                      $"{(result.TieGuardTriggered ? ", TIE-GUARD forced ManualReview" : "")}" +
                      $"{(result.Decision == MatchDecision.AutoMap ? $", writes Global Payer ID {result.SelectedGlobalPayerId}" : "")})");
    Console.WriteLine($"             Thresholds: >=95 AutoMap | 70-94 ManualReview | <70 NoMatch");
    Console.WriteLine(new string('-', 110));
}
return 0;

sealed class NoopAudit : IAuditRepository
{
    public Task WriteAsync(PayerMatchAuditEntry entry, CancellationToken ct) => Task.CompletedTask;
    public Task UpsertAliasAsync(string canonicalName, string? resolvedStateCode, string? stateSignalSource,
        int globalPayerId, string confirmedBy, string sourceAction, string? exampleRawName, CancellationToken ct) => Task.CompletedTask;
}

sealed class NoopNotify : INotificationService
{
    public Task NotifyReviewNeededAsync(LabInsuranceRow row, MatchResult result, CancellationToken ct) => Task.CompletedTask;
}
