using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace CaptureDataApp.Models
{
    public sealed class LineLevelModel
    {
        public string FileLogId { get; set; } = string.Empty;
        public string WeekFolder { get; set; } = string.Empty;
        public string SourceFilePath { get; set; } = string.Empty;
        public string RunNumber { get; set; } = string.Empty;

        public string AccessionNo { get; set; } = string.Empty;
    }
}
