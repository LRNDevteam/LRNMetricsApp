namespace LRN.MasterFileProcessorWorker.Logging;

/// <summary>
/// The worker's own file log (log4net). Deliberately separate from <c>ILogger&lt;T&gt;</c>:
/// only messages written through this interface land in the application log file, so
/// framework chatter never pollutes it.
/// </summary>
public interface ILoggerService
{
    void Info(string message);
    void Warn(string message);
    void Error(string message, Exception? ex = null);
    void Fatal(string message, Exception? ex = null);
}