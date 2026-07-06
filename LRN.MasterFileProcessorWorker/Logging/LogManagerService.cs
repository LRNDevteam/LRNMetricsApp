using log4net;
using log4net.Config;
using log4net.Util;
using System.Reflection;

namespace Common.Logging
{
    public sealed class LogManagerService : ILoggerService
    {
        private static readonly object _sync = new();
        private static bool _configured = false;

        private static ILog Log
        {
            get
            {
                EnsureConfigured();
                return log4net.LogManager.GetLogger("APP");
            }
        }

        private static void EnsureConfigured()
        {
            if (_configured) return;

            lock (_sync)
            {
                if (_configured) return;

                var repo = log4net.LogManager.GetRepository(Assembly.GetEntryAssembly() ?? typeof(LogManagerService).Assembly);

                var logDir = Path.Combine(AppContext.BaseDirectory, "logs");
                Directory.CreateDirectory(logDir);

                GlobalContext.Properties["LogFilePath"] = Path.Combine(logDir, "application-log.txt");

                var configPath = Path.Combine(AppContext.BaseDirectory, "log4net.config");
                if (!File.Exists(configPath))
                    throw new FileNotFoundException($"log4net.config not found at {configPath}");

                XmlConfigurator.ConfigureAndWatch(repo, new FileInfo(configPath));
                _configured = true;
            }
        }

        public void Info(string message) => Log.Info(message);
        public void Warn(string message) => Log.Warn(message);
        public void Error(string message, Exception? ex = null) => Log.Error(message, ex);
        public void Fatal(string message, Exception? ex = null) => Log.Fatal(message, ex);
    }
}
