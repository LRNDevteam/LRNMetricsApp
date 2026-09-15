using LRN.CpuMonitor.Models;

namespace LRN.CpuMonitor.Services;

public interface ICpuSampler
{
    /// <summary>
    /// Measures every visible process across one window and returns usage sorted
    /// highest first. Completes no sooner than <paramref name="window"/>.
    /// </summary>
    Task<CpuSnapshot> SampleAsync(TimeSpan window, bool normalizeByCoreCount, CancellationToken cancellationToken);
}
