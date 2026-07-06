using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace DenialDatabaseProcessorWorker.Notifications
{
	public interface ITeamsNotifier
	{
		Task SendAsync(string title, string message, CancellationToken ct = default);
	}

}
