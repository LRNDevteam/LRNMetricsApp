using System.Data;
using System.Data.Common;
using System.Diagnostics;

namespace LRN.SnapshotGenerator;

/// <summary>One SQL command a report ran while it was being snapshotted.</summary>
public sealed record RecordedSqlCommand(string? DataSource, string? Database, CommandType CommandType, string CommandText);

/// <summary>
/// Records the SQL commands run inside a <see cref="Start"/> scope, from SqlClient's own diagnostic
/// events - so the snapshot learns which stored procedures, views and functions the page's code really
/// ran for this lab (its prefix, _v3 / _ClientLogic variant, fallback), without a list kept here.
/// The scope is an AsyncLocal: commands run by parallel tasks the report starts are included, commands
/// of anything else running in the process are not.
/// </summary>
public static class SqlCommandRecorder
{
    private static readonly AsyncLocal<Recording?> Current = new();
    private static int _subscribed;

    public static Recording Start()
    {
        if (Interlocked.Exchange(ref _subscribed, 1) == 0)
            DiagnosticListener.AllListeners.Subscribe(new ListenerObserver());
        var recording = new Recording();
        Current.Value = recording;
        return recording;
    }

    public sealed class Recording : IDisposable
    {
        private readonly List<RecordedSqlCommand> _commands = [];

        public IReadOnlyList<RecordedSqlCommand> Commands
        {
            get { lock (_commands) return _commands.ToList(); }
        }

        internal void Add(RecordedSqlCommand command)
        {
            lock (_commands) _commands.Add(command);
        }

        public void Dispose()
        {
            if (ReferenceEquals(Current.Value, this)) Current.Value = null;
        }
    }

    private sealed class ListenerObserver : IObserver<DiagnosticListener>
    {
        public void OnNext(DiagnosticListener listener)
        {
            // Microsoft.Data.SqlClient and System.Data.SqlClient both publish under this name.
            if (listener.Name == "SqlClientDiagnosticListener")
                listener.Subscribe(new EventObserver());
        }

        public void OnError(Exception error) { }
        public void OnCompleted() { }
    }

    private sealed class EventObserver : IObserver<KeyValuePair<string, object?>>
    {
        public void OnNext(KeyValuePair<string, object?> e)
        {
            if (Current.Value is not { } recording || !e.Key.EndsWith("WriteCommandBefore", StringComparison.Ordinal)) return;
            try
            {
                // The payload carries the command as a property named Command (typed in SqlClient 5, anonymous before).
                if (e.Value?.GetType().GetProperty("Command")?.GetValue(e.Value) is not DbCommand cmd) return;
                recording.Add(new RecordedSqlCommand(cmd.Connection?.DataSource, cmd.Connection?.Database, cmd.CommandType, cmd.CommandText ?? ""));
            }
            catch
            {
                // Never let a diagnostic hook fail the report's query.
            }
        }

        public void OnError(Exception error) { }
        public void OnCompleted() { }
    }
}
