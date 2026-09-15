namespace LRN.CpuMonitor.Models;

/// <summary>
/// One in-flight SQL Server request, ordered by CPU consumed. This is what attributes
/// <c>sqlservr.exe</c> CPU to a caller: the engine is a single process serving every
/// client, so process-level usage says nothing about the cause on its own.
/// </summary>
/// <param name="ProgramName">
/// Client-supplied application name. Shows as ".Net SqlClient Data Provider" unless
/// the connection string sets Application Name, so set it in every service.
/// </param>
/// <param name="HostProcessId">
/// PID of the client process on <paramref name="HostName"/>. The most direct answer
/// to "which application triggered this".
/// </param>
public sealed record SqlRequestActivity(
    short SessionId,
    string LoginName,
    string HostName,
    string ProgramName,
    string ClientInterface,
    int? HostProcessId,
    string DatabaseName,
    string Command,
    string StatementText,
    long CpuTimeMs,
    long ElapsedMs,
    long LogicalReads,
    long Writes,
    string WaitType,
    short? BlockingSessionId);
