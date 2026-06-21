using System.Data;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface IDenialMapperRepository
{
    Task<DenialMapperDashboard> DashboardAsync(int? labId, CancellationToken ct);
    Task<PagedResult<DenialMapperRecord>> SuperMasterAsync(string? search, string? classification, int page, int pageSize, CancellationToken ct);
    Task<long> SaveSuperMasterAsync(long? id, DenialMapperSaveRequest request, string user, string role, CancellationToken ct);
    Task DeleteSuperMasterAsync(long id, string user, string role, CancellationToken ct);
    Task<IReadOnlyList<DenialMapperLabStatus>> LabsAsync(CancellationToken ct);
    Task<int> PushAsync(IReadOnlyList<int> labIds, string user, string role, CancellationToken ct);
    Task<PagedResult<DenialMapperRecord>> LabMasterAsync(int labId, string? search, string? classification, int page, int pageSize, CancellationToken ct);
    Task SaveOverrideAsync(int labId, long superMasterId, DenialMapperOverrideRequest request, string user, string role, CancellationToken ct);
    Task RemoveOverrideAsync(int labId, long superMasterId, string user, string role, CancellationToken ct);
    Task<IReadOnlyList<DenialMapperAuditRecord>> AuditAsync(int? labId, int take, CancellationToken ct);
    Task<IReadOnlyList<string>> ClassificationsAsync(int? labId, CancellationToken ct);
    Task<DenialCodeMasterImportResult> ImportSuperMasterAsync(Stream stream, string fileName, string user, string role, CancellationToken ct);
}

public sealed class SqlDenialMapperRepository : IDenialMapperRepository
{
    private readonly IConfiguration _configuration;
    private readonly SqlDenialCodeMasterRepository _labDatabases;
    public SqlDenialMapperRepository(IConfiguration configuration)
    {
        _configuration = configuration;
        _labDatabases = new SqlDenialCodeMasterRepository(configuration);
    }

    private SqlConnection Open() => new(_configuration.GetConnectionString("DefaultConnection")
        ?? _configuration.GetConnectionString("LabMetrics")
        ?? throw new InvalidOperationException("A central DefaultConnection or LabMetrics connection string is required for Denial Mapper."));

    private SqlConnection OpenLab(int labId) => _labDatabases.OpenLab(labId);

    public async Task<DenialMapperDashboard> DashboardAsync(int? labId, CancellationToken ct)
    {
        await using var master=Open(); await master.OpenAsync(ct);
        await using var countCmd=new SqlCommand("SELECT COUNT(*) FROM dbo.DenialMapperSuperMaster WHERE IsActive=1",master);
        var total=Convert.ToInt32(await countCmd.ExecuteScalarAsync(ct));
        var labs=await LabsAsync(ct); var scoped=(labId.HasValue?labs.Where(x=>x.LabId==labId):labs).ToList();
        return new() { TotalDenialCodes=labId.HasValue?scoped.FirstOrDefault()?.MappingCount??0:total, ActiveLabs=labs.Count(x=>x.IsActive), PendingPushLabs=labs.Count(x=>!x.IsActive), TotalOverrides=scoped.Sum(x=>x.OverrideCount), LastModifiedOn=scoped.Count==0?null:scoped.Max(x=>x.LastPushedOn) };
    }

    public async Task<PagedResult<DenialMapperRecord>> SuperMasterAsync(string? search,string? classification,int page,int pageSize,CancellationToken ct)
    {
        page=Math.Max(1,page); pageSize=Math.Clamp(pageSize,10,200); var result=new PagedResult<DenialMapperRecord>{Page=page,PageSize=pageSize};
        const string where="IsActive=1 AND (@Search IS NULL OR DenialCode LIKE '%'+@Search+'%' OR DenialDescription LIKE '%'+@Search+'%') AND (@Class IS NULL OR UPPER(LTRIM(RTRIM(DenialClassification)))=UPPER(LTRIM(RTRIM(@Class))))";
        await using var c=Open(); await c.OpenAsync(ct);
        await using(var count=new SqlCommand($"SELECT COUNT(*) FROM dbo.DenialMapperSuperMaster WHERE {where}",c)){ AddFilters(count,search,classification); result.TotalCount=Convert.ToInt32(await count.ExecuteScalarAsync(ct)); }
        await using var cmd=new SqlCommand($"SELECT Id,DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,DenialValidity,ActionCode,ActionCategory,Task,RecommendedAction,SLA,Priority,ModifiedOn FROM dbo.DenialMapperSuperMaster WHERE {where} ORDER BY DenialCode OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY",c);
        AddFilters(cmd,search,classification); cmd.Parameters.AddWithValue("@Skip",(page-1)*pageSize);cmd.Parameters.AddWithValue("@Take",pageSize);
        await using var r=await cmd.ExecuteReaderAsync(ct); while(await r.ReadAsync(ct)) result.Items.Add(Map(r,false)); return result;
    }

    public async Task<long> SaveSuperMasterAsync(long? id,DenialMapperSaveRequest q,string user,string role,CancellationToken ct)
    {
        await using var c=Open();await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);
        try {
            var eventType=id.HasValue?"Super Master Updated":"Super Master Added";
            const string update="UPDATE dbo.DenialMapperSuperMaster SET DenialCode=@Code,DenialDescription=@Description,DenialClassification=@Class,CoverageStatus=@Coverage,ICDComplianceStatus=@Icd,DenialValidity=@Validity,ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,SLA=@Sla,Priority=@Priority,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() OUTPUT inserted.Id WHERE Id=@Id AND IsActive=1";
            const string insert="INSERT dbo.DenialMapperSuperMaster(DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,DenialValidity,ActionCode,ActionCategory,Task,RecommendedAction,SLA,Priority,CreatedBy,ModifiedBy) OUTPUT inserted.Id VALUES(@Code,@Description,@Class,@Coverage,@Icd,@Validity,@ActionCode,@ActionCategory,@Task,@Recommended,@Sla,@Priority,@User,@User)";
            await using var cmd=new SqlCommand(id.HasValue?update:insert,c,tx); AddMaster(cmd,q,user); if(id.HasValue)cmd.Parameters.AddWithValue("@Id",id.Value);
            var saved=Convert.ToInt64(await cmd.ExecuteScalarAsync(ct) ?? throw new KeyNotFoundException("Super Master mapping was not found."));
            await Audit(c,tx,eventType,null,saved,q.DenialCode,null,null,null,user,role,ct); await tx.CommitAsync(ct);return saved;
        } catch {await tx.RollbackAsync(CancellationToken.None);throw;}
    }

    public async Task DeleteSuperMasterAsync(long id,string user,string role,CancellationToken ct)
    {
        await using var c=Open();await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);try{string? code=null;await using(var find=new SqlCommand("SELECT DenialCode FROM dbo.DenialMapperSuperMaster WHERE Id=@Id AND IsActive=1",c,tx)){find.Parameters.AddWithValue("@Id",id);code=Convert.ToString(await find.ExecuteScalarAsync(ct));}if(string.IsNullOrWhiteSpace(code))throw new KeyNotFoundException("Super Master mapping was not found.");await using(var cmd=new SqlCommand("UPDATE dbo.DenialMapperSuperMaster SET IsActive=0,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE Id=@Id",c,tx)){cmd.Parameters.AddWithValue("@Id",id);cmd.Parameters.AddWithValue("@User",user);await cmd.ExecuteNonQueryAsync(ct);}await Audit(c,tx,"Super Master Deleted",null,id,code,null,code,null,user,role,ct);await tx.CommitAsync(ct);}catch{await tx.RollbackAsync(CancellationToken.None);throw;}
    }

    public async Task<IReadOnlyList<DenialMapperLabStatus>> LabsAsync(CancellationToken ct)
    {
        var labs=new List<DenialMapperLabStatus>(); await using(var c=Open()){await c.OpenAsync(ct);await using var cmd=new SqlCommand("SELECT LabId,LabName FROM dbo.Labs WHERE IsActive=1 ORDER BY LabName",c);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))labs.Add(new(){LabId=r.GetInt32(0),LabName=r.GetString(1),LabCode=Initials(r.GetString(1))});}
        foreach(var lab in labs){try{await using var c=OpenLab(lab.LabId);await c.OpenAsync(ct);await using var cmd=new SqlCommand("IF OBJECT_ID('dbo.DenialMapperLabMaster','U') IS NULL SELECT 0,0,CAST(NULL AS datetime2) ELSE SELECT COUNT(*),(SELECT COUNT(*) FROM dbo.DenialMapperLabOverride WHERE IsActive=1),MAX(PushedOn) FROM dbo.DenialMapperLabMaster WHERE IsActive=1",c);await using var r=await cmd.ExecuteReaderAsync(ct);await r.ReadAsync(ct);lab.MappingCount=r.GetInt32(0);lab.OverrideCount=r.GetInt32(1);lab.LastPushedOn=r.IsDBNull(2)?null:r.GetDateTime(2);lab.IsActive=lab.MappingCount>0;}catch(SqlException){lab.IsActive=false;}catch(InvalidOperationException){lab.IsActive=false;}}
        return labs;
    }

    public async Task<int> PushAsync(IReadOnlyList<int> labIds,string user,string role,CancellationToken ct)
    {
        var active=(await ActiveLabsAsync(ct)).Select(x=>x.Id).ToHashSet();var selected=labIds.Distinct().Where(active.Contains).ToList();if(selected.Count==0)return 0;
        var rows=new List<DenialMapperRecord>();for(var page=1;;page++){var batch=await SuperMasterAsync(null,null,page,200,ct);rows.AddRange(batch.Items);if(batch.Items.Count<200)break;}
        foreach(var labId in selected){await using var c=OpenLab(labId);await c.OpenAsync(ct);await EnsureLabTables(c,ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);try{foreach(var row in rows){const string sql="MERGE dbo.DenialMapperLabMaster t USING(SELECT @SuperId SuperMasterId) s ON t.SuperMasterId=s.SuperMasterId WHEN MATCHED THEN UPDATE SET LabId=@LabId,DenialCode=@Code,DenialDescription=@Description,DenialClassification=@Class,CoverageStatus=@Coverage,ICDComplianceStatus=@Icd,DenialValidity=@Validity,ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,SLA=@Sla,Priority=@Priority,IsActive=1,PushedBy=@User,PushedOn=SYSUTCDATETIME(),ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(LabId,SuperMasterId,DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,DenialValidity,ActionCode,ActionCategory,Task,RecommendedAction,SLA,Priority,PushedBy,CreatedBy,ModifiedBy) VALUES(@LabId,@SuperId,@Code,@Description,@Class,@Coverage,@Icd,@Validity,@ActionCode,@ActionCategory,@Task,@Recommended,@Sla,@Priority,@User,@User,@User);";await using var cmd=new SqlCommand(sql,c,tx);AddLabRow(cmd,labId,row,user);await cmd.ExecuteNonQueryAsync(ct);}if(rows.Count>0){var names=rows.Select((_,i)=>$"@Keep{i}").ToArray();await using var deactivate=new SqlCommand($"UPDATE dbo.DenialMapperLabMaster SET IsActive=0,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE IsActive=1 AND SuperMasterId NOT IN ({string.Join(',',names)})",c,tx);deactivate.Parameters.AddWithValue("@User",user);for(var i=0;i<rows.Count;i++)deactivate.Parameters.AddWithValue(names[i],rows[i].SuperMasterId);await deactivate.ExecuteNonQueryAsync(ct);}await tx.CommitAsync(ct);}catch{await tx.RollbackAsync(CancellationToken.None);throw;}
            await using var master=Open();await master.OpenAsync(ct);await using var auditTx=(SqlTransaction)await master.BeginTransactionAsync(ct);await Audit(master,auditTx,"Push to Lab",labId,null,null,null,null,$"{rows.Count} mappings",user,role,ct);await auditTx.CommitAsync(ct);
        }return selected.Count;
    }

    public async Task<PagedResult<DenialMapperRecord>> LabMasterAsync(int labId,string? search,string? classification,int page,int pageSize,CancellationToken ct)
    {
        page=Math.Max(1,page);pageSize=Math.Clamp(pageSize,10,200);var result=new PagedResult<DenialMapperRecord>{Page=page,PageSize=pageSize};await using var c=OpenLab(labId);await c.OpenAsync(ct);await EnsureLabTables(c,ct);if(!await LabTablesExist(c,ct))return result;
        const string where="m.IsActive=1 AND (@Search IS NULL OR m.DenialCode LIKE '%'+@Search+'%' OR m.DenialDescription LIKE '%'+@Search+'%') AND (@Class IS NULL OR UPPER(LTRIM(RTRIM(m.DenialClassification)))=UPPER(LTRIM(RTRIM(@Class))))";
        await using(var count=new SqlCommand($"SELECT COUNT(*) FROM dbo.DenialMapperLabMaster m WHERE {where}",c)){count.Parameters.AddWithValue("@Search",Db(search));count.Parameters.AddWithValue("@Class",Db(classification));result.TotalCount=Convert.ToInt32(await count.ExecuteScalarAsync(ct));}
        var sql=$"SELECT m.SuperMasterId,m.DenialCode,m.DenialDescription,m.DenialClassification,m.CoverageStatus,m.ICDComplianceStatus,m.DenialValidity,COALESCE(o.ActionCode,m.ActionCode),COALESCE(o.ActionCategory,m.ActionCategory),COALESCE(o.Task,m.Task),COALESCE(o.RecommendedAction,m.RecommendedAction),m.SLA,m.Priority,COALESCE(o.ModifiedOn,m.ModifiedOn),CASE WHEN o.Id IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,m.ActionCode,m.ActionCategory,m.Task,m.RecommendedAction FROM dbo.DenialMapperLabMaster m LEFT JOIN dbo.DenialMapperLabOverride o ON o.SuperMasterId=m.SuperMasterId AND o.LabId=@LabId AND o.IsActive=1 WHERE {where} ORDER BY m.DenialCode OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY";
        await using var cmd=new SqlCommand(sql,c);cmd.Parameters.AddWithValue("@LabId",labId);cmd.Parameters.AddWithValue("@Search",Db(search));cmd.Parameters.AddWithValue("@Class",Db(classification));cmd.Parameters.AddWithValue("@Skip",(page-1)*pageSize);cmd.Parameters.AddWithValue("@Take",pageSize);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))result.Items.Add(Map(r,true,labId));return result;
    }

    public async Task SaveOverrideAsync(int labId,long superId,DenialMapperOverrideRequest q,string user,string role,CancellationToken ct)
    {
        const string sql="MERGE dbo.DenialMapperLabOverride AS t USING(SELECT @LabId LabId,@SuperId SuperMasterId) s ON t.LabId=s.LabId AND t.SuperMasterId=s.SuperMasterId AND t.IsActive=1 WHEN MATCHED THEN UPDATE SET ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(LabId,SuperMasterId,ActionCode,ActionCategory,Task,RecommendedAction,CreatedBy,ModifiedBy) VALUES(@LabId,@SuperId,@ActionCode,@ActionCategory,@Task,@Recommended,@User,@User);";
        await using(var c=OpenLab(labId)){await c.OpenAsync(ct);await EnsureLabTables(c,ct);await using var cmd=new SqlCommand(sql,c);AddOverride(cmd,labId,superId,q,user);await cmd.ExecuteNonQueryAsync(ct);}await WriteAudit("Lab Override Updated",labId,superId,"Action fields",null,$"{q.ActionCode} | {q.ActionCategory} | {q.Task} | {q.RecommendedAction}",user,role,ct);
    }

    public async Task RemoveOverrideAsync(int labId,long superId,string user,string role,CancellationToken ct){await using(var c=OpenLab(labId)){await c.OpenAsync(ct);await using var cmd=new SqlCommand("UPDATE dbo.DenialMapperLabOverride SET IsActive=0,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE LabId=@LabId AND SuperMasterId=@SuperId AND IsActive=1",c);cmd.Parameters.AddWithValue("@User",user);cmd.Parameters.AddWithValue("@LabId",labId);cmd.Parameters.AddWithValue("@SuperId",superId);await cmd.ExecuteNonQueryAsync(ct);}await WriteAudit("Lab Override Removed",labId,superId,null,null,null,user,role,ct);}

    public async Task<IReadOnlyList<DenialMapperAuditRecord>> AuditAsync(int? labId,int take,CancellationToken ct){var rows=new List<DenialMapperAuditRecord>();await using var c=Open();await c.OpenAsync(ct);await using var cmd=new SqlCommand("SELECT TOP(@Take) Id,PerformedOn,PerformedBy,PerformedRole,LabId,DenialCode,EventType,FieldName,FromValue,ToValue FROM dbo.DenialMapperAuditLog WHERE @LabId IS NULL OR LabId=@LabId ORDER BY PerformedOn DESC",c);cmd.Parameters.AddWithValue("@Take",Math.Clamp(take,1,500));cmd.Parameters.AddWithValue("@LabId",(object?)labId??DBNull.Value);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))rows.Add(new(){Id=r.GetInt64(0),PerformedOn=r.GetDateTime(1),PerformedBy=S(r,2),PerformedRole=S(r,3),LabId=r.IsDBNull(4)?null:r.GetInt32(4),DenialCode=S(r,5),EventType=r.GetString(6),FieldName=S(r,7),FromValue=S(r,8),ToValue=S(r,9)});return rows;}

    public async Task<IReadOnlyList<string>> ClassificationsAsync(int? labId,CancellationToken ct)
    {
        await using var c=labId.HasValue?OpenLab(labId.Value):Open();await c.OpenAsync(ct);if(labId.HasValue)await EnsureLabTables(c,ct);var table=labId.HasValue?"dbo.DenialMapperLabMaster":"dbo.DenialMapperSuperMaster";await using var cmd=new SqlCommand($"SELECT DISTINCT LTRIM(RTRIM(DenialClassification)) FROM {table} WHERE IsActive=1 AND NULLIF(LTRIM(RTRIM(DenialClassification)),'') IS NOT NULL ORDER BY 1",c);await using var r=await cmd.ExecuteReaderAsync(ct);var rows=new List<string>();while(await r.ReadAsync(ct))rows.Add(r.GetString(0));return rows;
    }

    public async Task<DenialCodeMasterImportResult> ImportSuperMasterAsync(Stream stream,string fileName,string user,string role,CancellationToken ct)
    {
        using var book=new XLWorkbook(stream);var sheet=book.Worksheets.First();var used=sheet.RangeUsed();if(used is null)return new(){FailedCount=1,Errors=["The workbook is empty."],Message="The workbook is empty."};
        static string Key(string s)=>new(s.Where(char.IsLetterOrDigit).Select(char.ToUpperInvariant).ToArray());
        var headerRow=sheet.RowsUsed().Take(20).FirstOrDefault(row=>
        {
            var keys=row.CellsUsed().Select(cell=>Key(cell.GetString())).Where(x=>x.Length>0).ToHashSet(StringComparer.OrdinalIgnoreCase);
            return keys.Contains("DENIALCODE")&&keys.Contains("ACTIONCODE");
        });
        if(headerRow is null)return new(){FailedCount=1,Errors=["Could not find a header row containing Denial Code and Action Code."],Message="Mapper upload failed: the Excel header row was not recognized."};
        var headers=headerRow.Cells()
            .Select(x=>new { Name=Key(x.GetString()), Column=x.Address.ColumnNumber })
            .Where(x=>x.Name.Length>0)
            .GroupBy(x=>x.Name,StringComparer.OrdinalIgnoreCase)
            .ToDictionary(x=>x.Key,x=>x.First().Column,StringComparer.OrdinalIgnoreCase);
        string Cell(IXLRow row,params string[] names){foreach(var n in names)if(headers.TryGetValue(Key(n),out var col))return row.Cell(col).GetFormattedString().Trim();return "";}
        var records=new List<DenialMapperSaveRequest>();var errors=new List<string>();var firstDataRow=headerRow.RowNumber()+1;
        foreach(var row in sheet.Rows(firstDataRow,sheet.LastRowUsed()?.RowNumber()??firstDataRow)){var rowNo=row.RowNumber();var q=new DenialMapperSaveRequest{DenialCode=Cell(row,"Denial Code","DenialCode"),DenialDescription=Cell(row,"Denial Description","Description"),DenialClassification=Cell(row,"Denial Classification","Classification"),CoverageStatus=Cell(row,"Coverage Status","CoverageStatus"),ICDComplianceStatus=Cell(row,"ICD Compliance Status","ICD Compliance","ICDComplianceStatus"),DenialValidity=Cell(row,"Denial Validity","DenialValidity"),ActionCode=Cell(row,"Action Code","ActionCode"),ActionCategory=Cell(row,"Action Category","ActionCategory"),Task=Cell(row,"Task"),RecommendedAction=Cell(row,"Recommended Action","RecommendedAction"),SLA=Cell(row,"SLA","SLA Days","SLA (Days)","SLADays"),Priority=Cell(row,"Priority")};if(string.IsNullOrWhiteSpace(q.DenialCode)&&string.IsNullOrWhiteSpace(q.ActionCode))continue;if(new[]{q.DenialCode,q.ActionCode,q.ActionCategory,q.Task,q.RecommendedAction,q.SLA,q.Priority}.Any(string.IsNullOrWhiteSpace)){errors.Add($"Row {rowNo}: required mapping fields are missing.");continue;}records.Add(q);}
        if(records.Count==0){var details=errors.Count==0?["No valid mapping rows were found."]:errors;return new(){FailedCount=details.Count,Errors=details,Message=$"Mapper upload failed. {details[0]}"};}
        var inserted=0;var updated=0;await using var c=Open();await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);try{foreach(var q in records){const string existsSql="SELECT Id FROM dbo.DenialMapperSuperMaster WHERE DenialCode=@Code AND ISNULL(DenialClassification,'')=ISNULL(@Class,'') AND ISNULL(CoverageStatus,'')=ISNULL(@Coverage,'') AND ISNULL(ICDComplianceStatus,'')=ISNULL(@Icd,'') AND IsActive=1";long? id;await using(var find=new SqlCommand(existsSql,c,tx)){find.Parameters.AddWithValue("@Code",q.DenialCode);find.Parameters.AddWithValue("@Class",Db(q.DenialClassification));find.Parameters.AddWithValue("@Coverage",Db(q.CoverageStatus));find.Parameters.AddWithValue("@Icd",Db(q.ICDComplianceStatus));var found=await find.ExecuteScalarAsync(ct);id=found is null?null:Convert.ToInt64(found);}const string insert="INSERT dbo.DenialMapperSuperMaster(DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,DenialValidity,ActionCode,ActionCategory,Task,RecommendedAction,SLA,Priority,CreatedBy,ModifiedBy) VALUES(@Code,@Description,@Class,@Coverage,@Icd,@Validity,@ActionCode,@ActionCategory,@Task,@Recommended,@Sla,@Priority,@User,@User)";const string update="UPDATE dbo.DenialMapperSuperMaster SET DenialDescription=@Description,DenialValidity=@Validity,ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,SLA=@Sla,Priority=@Priority,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE Id=@Id";await using var cmd=new SqlCommand(id.HasValue?update:insert,c,tx);AddMaster(cmd,q,user);if(id.HasValue){cmd.Parameters.AddWithValue("@Id",id.Value);updated++;}else inserted++;await cmd.ExecuteNonQueryAsync(ct);}await Audit(c,tx,"Super Master Uploaded",null,null,"All",null,null,$"{records.Count} rows from {fileName}",user,role,ct);await tx.CommitAsync(ct);}catch{await tx.RollbackAsync(CancellationToken.None);throw;}
        return new(){InsertedCount=inserted,UpdatedCount=updated,FailedCount=errors.Count,Errors=errors,Message=$"Uploaded {records.Count} mapping rows to LRNMaster."};
    }

    private async Task<IReadOnlyList<(int Id,string Name)>> ActiveLabsAsync(CancellationToken ct){var rows=new List<(int,string)>();await using var c=Open();await c.OpenAsync(ct);await using var cmd=new SqlCommand("SELECT LabId,LabName FROM dbo.Labs WHERE IsActive=1 ORDER BY LabName",c);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))rows.Add((r.GetInt32(0),r.GetString(1)));return rows;}
    private static string Initials(string name)=>string.Concat(name.Split([' ','_'],StringSplitOptions.RemoveEmptyEntries).Take(3).Select(x=>char.ToUpperInvariant(x[0])));
    private static async Task<bool> LabTablesExist(SqlConnection c,CancellationToken ct){await using var cmd=new SqlCommand("SELECT CASE WHEN OBJECT_ID('dbo.DenialMapperLabMaster','U') IS NULL THEN 0 ELSE 1 END",c);return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct))==1;}
    private static async Task EnsureLabTables(SqlConnection c,CancellationToken ct){const string sql="""
IF OBJECT_ID('dbo.DenialMapperLabMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperLabMaster(Id bigint IDENTITY PRIMARY KEY,LabId int NOT NULL,SuperMasterId bigint NOT NULL,DenialCode nvarchar(50) NOT NULL,DenialDescription nvarchar(500) NULL,DenialClassification nvarchar(100) NULL,CoverageStatus nvarchar(100) NULL,ICDComplianceStatus nvarchar(100) NULL,DenialValidity nvarchar(100) NULL,ActionCode nvarchar(100) NOT NULL,ActionCategory nvarchar(100) NOT NULL,Task nvarchar(300) NOT NULL,RecommendedAction nvarchar(1000) NOT NULL,SLA nvarchar(50) NOT NULL,Priority nvarchar(50) NOT NULL,IsActive bit NOT NULL DEFAULT 1,PushedBy nvarchar(200) NOT NULL,PushedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),CreatedBy nvarchar(200) NOT NULL,CreatedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),ModifiedBy nvarchar(200) NOT NULL,ModifiedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),CONSTRAINT UQ_DenialMapperLabMaster_Super UNIQUE(SuperMasterId));
IF COL_LENGTH('dbo.DenialMapperLabMaster','LabId') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD LabId int NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialCode') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialCode nvarchar(50) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialDescription') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialDescription nvarchar(500) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialClassification') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialClassification nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','CoverageStatus') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD CoverageStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','ICDComplianceStatus') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD ICDComplianceStatus nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','DenialValidity') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD DenialValidity nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','ActionCode') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD ActionCode nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','ActionCategory') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD ActionCategory nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','Task') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD Task nvarchar(300) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','RecommendedAction') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD RecommendedAction nvarchar(1000) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','SLA') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD SLA nvarchar(50) NULL;
IF COL_LENGTH('dbo.DenialMapperLabMaster','Priority') IS NULL ALTER TABLE dbo.DenialMapperLabMaster ADD Priority nvarchar(50) NULL;
DECLARE @DropMasterFks nvarchar(max)='';
SELECT @DropMasterFks=@DropMasterFks+'ALTER TABLE dbo.DenialMapperLabMaster DROP CONSTRAINT '+QUOTENAME(fk.name)+';'
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id=fk.object_id
JOIN sys.columns col ON col.object_id=fkc.parent_object_id AND col.column_id=fkc.parent_column_id
WHERE fk.parent_object_id=OBJECT_ID('dbo.DenialMapperLabMaster') AND col.name='SuperMasterId';
IF @DropMasterFks<>'' EXEC sys.sp_executesql @DropMasterFks;
IF OBJECT_ID('dbo.DenialMapperLabOverride','U') IS NULL
CREATE TABLE dbo.DenialMapperLabOverride(Id bigint IDENTITY PRIMARY KEY,LabId int NOT NULL,SuperMasterId bigint NOT NULL,ActionCode nvarchar(100) NOT NULL,ActionCategory nvarchar(100) NOT NULL,Task nvarchar(300) NOT NULL,RecommendedAction nvarchar(1000) NOT NULL,IsActive bit NOT NULL DEFAULT 1,CreatedBy nvarchar(200) NOT NULL,CreatedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),ModifiedBy nvarchar(200) NOT NULL,ModifiedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME());
IF COL_LENGTH('dbo.DenialMapperLabOverride','LabId') IS NULL ALTER TABLE dbo.DenialMapperLabOverride ADD LabId int NULL;
DECLARE @DropOverrideFks nvarchar(max)='';
SELECT @DropOverrideFks=@DropOverrideFks+'ALTER TABLE dbo.DenialMapperLabOverride DROP CONSTRAINT '+QUOTENAME(fk.name)+';'
FROM sys.foreign_keys fk
JOIN sys.foreign_key_columns fkc ON fkc.constraint_object_id=fk.object_id
JOIN sys.columns col ON col.object_id=fkc.parent_object_id AND col.column_id=fkc.parent_column_id
WHERE fk.parent_object_id=OBJECT_ID('dbo.DenialMapperLabOverride') AND col.name='SuperMasterId';
IF @DropOverrideFks<>'' EXEC sys.sp_executesql @DropOverrideFks;
IF NOT EXISTS(SELECT 1 FROM sys.indexes WHERE name='UX_DenialMapperLabOverride_Active') CREATE UNIQUE INDEX UX_DenialMapperLabOverride_Active ON dbo.DenialMapperLabOverride(SuperMasterId) WHERE IsActive=1;
""";await using var cmd=new SqlCommand(sql,c);await cmd.ExecuteNonQueryAsync(ct);}
    private async Task WriteAudit(string type,int? lab,long? super,string? field,string? from,string? to,string user,string role,CancellationToken ct){await using var c=Open();await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);await Audit(c,tx,type,lab,super,null,field,from,to,user,role,ct);await tx.CommitAsync(ct);}
    private static void AddLabRow(SqlCommand c,int labId,DenialMapperRecord q,string user){c.Parameters.AddWithValue("@LabId",labId);c.Parameters.AddWithValue("@SuperId",q.SuperMasterId);c.Parameters.AddWithValue("@Code",q.DenialCode);c.Parameters.AddWithValue("@Description",Db(q.DenialDescription));c.Parameters.AddWithValue("@Class",Db(q.DenialClassification));c.Parameters.AddWithValue("@Coverage",Db(q.CoverageStatus));c.Parameters.AddWithValue("@Icd",Db(q.ICDComplianceStatus));c.Parameters.AddWithValue("@Validity",Db(q.DenialValidity));c.Parameters.AddWithValue("@ActionCode",q.ActionCode);c.Parameters.AddWithValue("@ActionCategory",q.ActionCategory);c.Parameters.AddWithValue("@Task",q.Task);c.Parameters.AddWithValue("@Recommended",q.RecommendedAction);c.Parameters.AddWithValue("@Sla",q.SLA);c.Parameters.AddWithValue("@Priority",q.Priority);c.Parameters.AddWithValue("@User",user);}

    private static DenialMapperRecord Map(SqlDataReader r,bool lab,int? labId=null)=>new(){Id=r.GetInt64(0),SuperMasterId=r.GetInt64(0),LabId=labId,DenialCode=r.GetString(1),DenialDescription=S(r,2),DenialClassification=S(r,3),CoverageStatus=S(r,4),ICDComplianceStatus=S(r,5),DenialValidity=S(r,6),ActionCode=S(r,7)??"",ActionCategory=S(r,8)??"",Task=S(r,9)??"",RecommendedAction=S(r,10)??"",SLA=S(r,11)??"",Priority=S(r,12)??"",ModifiedOn=r.IsDBNull(13)?null:r.GetDateTime(13),IsOverride=lab&&!r.IsDBNull(14)&&r.GetBoolean(14),OriginalActionCode=lab?S(r,15):null,OriginalActionCategory=lab?S(r,16):null,OriginalTask=lab?S(r,17):null,OriginalRecommendedAction=lab?S(r,18):null};
    private static string? S(SqlDataReader r,int i)=>r.IsDBNull(i)?null:r.GetString(i);private static object Db(string? s)=>string.IsNullOrWhiteSpace(s)?DBNull.Value:s.Trim();
    private static void AddFilters(SqlCommand c,string? search,string? classification){c.Parameters.AddWithValue("@Search",Db(search));c.Parameters.AddWithValue("@Class",Db(classification));}
    private static void AddMaster(SqlCommand c,DenialMapperSaveRequest q,string user){c.Parameters.AddWithValue("@Code",q.DenialCode.Trim());c.Parameters.AddWithValue("@Description",Db(q.DenialDescription));c.Parameters.AddWithValue("@Class",Db(q.DenialClassification));c.Parameters.AddWithValue("@Coverage",Db(q.CoverageStatus));c.Parameters.AddWithValue("@Icd",Db(q.ICDComplianceStatus));c.Parameters.AddWithValue("@Validity",Db(q.DenialValidity));c.Parameters.AddWithValue("@ActionCode",q.ActionCode.Trim());c.Parameters.AddWithValue("@ActionCategory",q.ActionCategory.Trim());c.Parameters.AddWithValue("@Task",q.Task.Trim());c.Parameters.AddWithValue("@Recommended",q.RecommendedAction.Trim());c.Parameters.AddWithValue("@Sla",q.SLA.Trim());c.Parameters.AddWithValue("@Priority",q.Priority.Trim());c.Parameters.AddWithValue("@User",user);}
    private static void AddOverride(SqlCommand c,int lab,long superId,DenialMapperOverrideRequest q,string user){c.Parameters.AddWithValue("@LabId",lab);c.Parameters.AddWithValue("@SuperId",superId);c.Parameters.AddWithValue("@ActionCode",q.ActionCode.Trim());c.Parameters.AddWithValue("@ActionCategory",q.ActionCategory.Trim());c.Parameters.AddWithValue("@Task",q.Task.Trim());c.Parameters.AddWithValue("@Recommended",q.RecommendedAction.Trim());c.Parameters.AddWithValue("@User",user);}
    private static async Task Audit(SqlConnection c,SqlTransaction tx,string type,int? lab,long? super,string? code,string? field,string? from,string? to,string user,string role,CancellationToken ct){await using var cmd=new SqlCommand("INSERT dbo.DenialMapperAuditLog(EventType,LabId,SuperMasterId,DenialCode,FieldName,FromValue,ToValue,PerformedBy,PerformedRole) VALUES(@Type,@Lab,@Super,@Code,@Field,@From,@To,@User,@Role)",c,tx);cmd.Parameters.AddWithValue("@Type",type);cmd.Parameters.AddWithValue("@Lab",(object?)lab??DBNull.Value);cmd.Parameters.AddWithValue("@Super",(object?)super??DBNull.Value);cmd.Parameters.AddWithValue("@Code",(object?)code??DBNull.Value);cmd.Parameters.AddWithValue("@Field",(object?)field??DBNull.Value);cmd.Parameters.AddWithValue("@From",(object?)from??DBNull.Value);cmd.Parameters.AddWithValue("@To",(object?)to??DBNull.Value);cmd.Parameters.AddWithValue("@User",user);cmd.Parameters.AddWithValue("@Role",role);await cmd.ExecuteNonQueryAsync(ct);}
}
