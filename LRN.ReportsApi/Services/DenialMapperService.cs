using System.Data;
using ClosedXML.Excel;
using LRN.ReportsApi.Models;
using Microsoft.Data.SqlClient;

namespace LRN.ReportsApi.Services;

public interface IDenialMapperRepository
{
    Task<DenialMapperDashboard> DashboardAsync(int? labId, CancellationToken ct);
    Task<DenialMapperMasterData> MasterDataAsync(CancellationToken ct);
    Task<PagedResult<DenialMapperRecord>> SuperMasterAsync(string? search, string? classification, int page, int pageSize, CancellationToken ct);
    Task<long> SaveSuperMasterAsync(long? id, DenialMapperSaveRequest request, string user, string role, CancellationToken ct);
    Task DeleteSuperMasterAsync(long id, string user, string role, CancellationToken ct);
    Task<IReadOnlyList<DenialMapperLabStatus>> LabsAsync(CancellationToken ct);
    Task<int> PushAsync(IReadOnlyList<int> labIds, string user, string role, CancellationToken ct);
    Task<DenialMapperPushCompareResult> ComparePushAsync(IReadOnlyList<int> labIds, string user, CancellationToken ct);
    Task<int> ConfirmPushAsync(IReadOnlyList<long> pushAuditIds, string user, string role, CancellationToken ct);
    Task CancelPushAsync(IReadOnlyList<long> pushAuditIds, string user, CancellationToken ct);
    Task<DenialMapperPushAuditView?> PushAuditAsync(long pushAuditId, CancellationToken ct);
    Task<IReadOnlyList<DenialMapperPushSummary>> ListPushesAsync(int take, CancellationToken ct);
    Task UpdatePushAuditDetailAsync(long pushAuditId, long detailId, DenialMapperPushDetailEditRequest request, string user, string role, CancellationToken ct);
    Task<IReadOnlyList<DenialMapperNotification>> PendingNotificationsAsync(int labId, string user, CancellationToken ct);
    Task<int> AcknowledgeNotificationAsync(long pushAuditId, int labId, string user, CancellationToken ct);
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

    public async Task<DenialMapperMasterData> MasterDataAsync(CancellationToken ct)
    {
        await using var c=Open();
        await c.OpenAsync(ct);
        await EnsureMasterDataSchemaAsync(c,ct);
        var result=new DenialMapperMasterData();
        var values=new Dictionary<string,List<string>>(StringComparer.OrdinalIgnoreCase);
        await using(var cmd=new SqlCommand("SELECT LookupType,LookupValue FROM dbo.DenialMapperLookupMaster WHERE IsActive=1 ORDER BY LookupType,SortOrder,LookupValue",c))
        await using(var r=await cmd.ExecuteReaderAsync(ct))
        {
            while(await r.ReadAsync(ct))
            {
                var type=r.GetString(0);
                if(!values.TryGetValue(type,out var list))values[type]=list=[];
                list.Add(r.GetString(1));
            }
        }
        var categories=new List<DenialMapperActionCategoryMaster>();
        await using(var cmd=new SqlCommand("SELECT ActionCategory,ActionCode FROM dbo.DenialMapperActionCategoryMaster WHERE IsActive=1 ORDER BY SortOrder,ActionCategory",c))
        await using(var r=await cmd.ExecuteReaderAsync(ct))
            while(await r.ReadAsync(ct))categories.Add(new(){ActionCategory=r.GetString(0),ActionCode=r.GetString(1)});

        result.DenialClassifications=values.GetValueOrDefault("DenialClassification")??[];
        result.CoverageStatuses=values.GetValueOrDefault("CoverageStatus")??[];
        result.ICDComplianceStatuses=values.GetValueOrDefault("ICDComplianceStatus")??[];
        result.DenialValidities=values.GetValueOrDefault("DenialValidity")??[];
        result.SLADays=values.GetValueOrDefault("SLADays")??[];
        result.Priorities=values.GetValueOrDefault("Priority")??[];
        result.ActionCategories=categories;
        return result;
    }

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
        const string where="IsActive=1 AND (@Search IS NULL OR DenialCode LIKE @Search ESCAPE '\\' OR DenialDescription LIKE @Search ESCAPE '\\') AND (@Class IS NULL OR UPPER(LTRIM(RTRIM(DenialClassification)))=UPPER(LTRIM(RTRIM(@Class))))";
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
            var before=id.HasValue?await FindSuperMasterAsync(c,tx,id.Value,ct):null;
            var saved=Convert.ToInt64(await cmd.ExecuteScalarAsync(ct) ?? throw new KeyNotFoundException("Super Master mapping was not found."));
            await AuditChanges(c,tx,eventType,null,saved,q.DenialCode,before,ToRecord(saved,q),user,role,ct);
            await tx.CommitAsync(ct);return saved;
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
        var active=(await ActiveLabsAsync(ct)).Select(x=>x.Id).ToHashSet();
        var selected=labIds.Distinct().Where(active.Contains).ToList();
        if(selected.Count==0)throw new InvalidOperationException("No active target lab was selected for the mapper push.");

        var rows=new List<DenialMapperRecord>();
        for(var page=1;;page++)
        {
            var batch=await SuperMasterAsync(null,null,page,200,ct);
            rows.AddRange(batch.Items);
            if(batch.Items.Count<200)break;
        }
        if(rows.Count==0)throw new InvalidOperationException("The Super Master has no active mappings to push.");

        foreach(var labId in selected)
        {
            await using var c=OpenLab(labId);
            await c.OpenAsync(ct);
            await EnsureLabTables(c,ct);
            await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);
            try
            {
                foreach(var row in rows)
                {
                    const string sql="MERGE dbo.DenialMapperLabMaster t USING(SELECT @SuperId SuperMasterId) s ON t.SuperMasterId=s.SuperMasterId WHEN MATCHED THEN UPDATE SET LabId=@LabId,DenialCode=@Code,DenialDescription=@Description,DenialClassification=@Class,CoverageStatus=@Coverage,ICDComplianceStatus=@Icd,DenialValidity=@Validity,ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,SLA=@Sla,Priority=@Priority,IsActive=1,PushedBy=@User,PushedOn=SYSUTCDATETIME(),ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(LabId,SuperMasterId,DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,DenialValidity,ActionCode,ActionCategory,Task,RecommendedAction,SLA,Priority,PushedBy,CreatedBy,ModifiedBy) VALUES(@LabId,@SuperId,@Code,@Description,@Class,@Coverage,@Icd,@Validity,@ActionCode,@ActionCategory,@Task,@Recommended,@Sla,@Priority,@User,@User,@User);";
                    await using var cmd=new SqlCommand(sql,c,tx);
                    AddLabRow(cmd,labId,row,user);
                    await cmd.ExecuteNonQueryAsync(ct);
                }

                var names=rows.Select((_,i)=>$"@Keep{i}").ToArray();
                await using(var deactivate=new SqlCommand($"UPDATE dbo.DenialMapperLabMaster SET IsActive=0,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE IsActive=1 AND SuperMasterId NOT IN ({string.Join(',',names)})",c,tx))
                {
                    deactivate.Parameters.AddWithValue("@User",user);
                    for(var i=0;i<rows.Count;i++)deactivate.Parameters.AddWithValue(names[i],rows[i].SuperMasterId);
                    await deactivate.ExecuteNonQueryAsync(ct);
                }

                await using(var verify=new SqlCommand("SELECT COUNT(*) FROM dbo.DenialMapperLabMaster WHERE LabId=@LabId AND IsActive=1",c,tx))
                {
                    verify.Parameters.AddWithValue("@LabId",labId);
                    var activeRows=Convert.ToInt32(await verify.ExecuteScalarAsync(ct));
                    if(activeRows!=rows.Count)
                        throw new InvalidOperationException($"Mapper push verification failed for LabId {labId}. Expected {rows.Count} active mappings but found {activeRows}.");
                }

                await tx.CommitAsync(ct);
            }
            catch
            {
                await tx.RollbackAsync(CancellationToken.None);
                throw;
            }
            await using var master=Open();await master.OpenAsync(ct);await using var auditTx=(SqlTransaction)await master.BeginTransactionAsync(ct);await Audit(master,auditTx,"Push to Lab",labId,null,null,null,null,$"{rows.Count} mappings",user,role,ct);await auditTx.CommitAsync(ct);
        }
        return selected.Count;
    }

    public async Task<DenialMapperPushCompareResult> ComparePushAsync(IReadOnlyList<int> labIds,string user,CancellationToken ct)
    {
        var labs=(await ActiveLabsAsync(ct)).ToDictionary(x=>x.Id,x=>x.Name);
        var selected=labIds.Distinct().Where(labs.ContainsKey).ToList();
        if(selected.Count==0)throw new ArgumentException("Select at least one active target lab.");
        var masterRows=new List<DenialMapperRecord>();
        for(var page=1;;page++){var batch=await SuperMasterAsync(null,null,page,200,ct);masterRows.AddRange(batch.Items);if(batch.Items.Count<200)break;}
        var allDetails=new List<DenialMapperPushDifference>();var auditIds=new List<long>();var totalCompared=0;var totalOpen=0;
        await using var central=Open();await central.OpenAsync(ct);await EnsurePushAuditSchemaAsync(central,ct);
        foreach(var labId in selected)
        {
            var target=new Dictionary<string,DenialMapperRecord>(StringComparer.OrdinalIgnoreCase);
            await using(var lab=OpenLab(labId)){await lab.OpenAsync(ct);await EnsureLabTables(lab,ct);
                const string sql="SELECT m.SuperMasterId,m.DenialCode,m.DenialDescription,m.DenialClassification,m.CoverageStatus,m.ICDComplianceStatus,m.DenialValidity,COALESCE(o.ActionCode,m.ActionCode),COALESCE(o.ActionCategory,m.ActionCategory),COALESCE(o.Task,m.Task),COALESCE(o.RecommendedAction,m.RecommendedAction),m.SLA,m.Priority,COALESCE(o.ModifiedOn,m.ModifiedOn),CASE WHEN o.Id IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,m.ActionCode,m.ActionCategory,m.Task,m.RecommendedAction FROM dbo.DenialMapperLabMaster m LEFT JOIN dbo.DenialMapperLabOverride o ON o.SuperMasterId=m.SuperMasterId AND o.LabId=@LabId AND o.IsActive=1 WHERE m.IsActive=1";
                await using var cmd=new SqlCommand(sql,lab);cmd.Parameters.AddWithValue("@LabId",labId);await using var reader=await cmd.ExecuteReaderAsync(ct);while(await reader.ReadAsync(ct)){var row=Map(reader,true,labId);target[MapperKey(row.DenialCode,row.ICDComplianceStatus,row.CoverageStatus)]=row;}}
            var details=new List<DenialMapperPushDifference>();
            foreach(var master in masterRows)
            {
                target.TryGetValue(MapperKey(master.DenialCode,master.ICDComplianceStatus,master.CoverageStatus),out var old);
                var types=new List<string>();
                if(old is null)types.Add("New Code");
                else {if(Different(old.ActionCode,master.ActionCode))types.Add("Action Code Changed");if(Different(old.ActionCategory,master.ActionCategory))types.Add("Action Category Changed");if(Different(old.Task,master.Task))types.Add("Task Changed");if(Different(old.RecommendedAction,master.RecommendedAction))types.Add("Short Category Changed");if(Different(old.DenialClassification,master.DenialClassification))types.Add("Denial Classification Changed");}
                if(types.Count==0)continue;
                var d=new DenialMapperPushDifference{TargetLabId=labId,TargetLabName=labs[labId],DenialCode=master.DenialCode,ICDComplianceStatus=master.ICDComplianceStatus,CoverageStatus=master.CoverageStatus,ExistingActionCode=old?.ActionCode,NewActionCode=master.ActionCode,ExistingActionCategory=old?.ActionCategory,NewActionCategory=master.ActionCategory,ExistingTask=old?.Task,NewTask=master.Task,ExistingShortCategory=old?.RecommendedAction,NewShortCategory=master.RecommendedAction,ExistingDenialClassification=old?.DenialClassification,NewDenialClassification=master.DenialClassification,DifferenceType=string.Join(", ",types)};
                d.OpenAssignedTaskCount=await CountOpenTasksAsync(labId,d,ct);d.IsAssignedToOpenTask=d.OpenAssignedTaskCount>0;details.Add(d);
            }
            totalCompared+=masterRows.Count;totalOpen+=details.Sum(x=>x.OpenAssignedTaskCount);
            await using var tx=(SqlTransaction)await central.BeginTransactionAsync(ct);try
            {
                await using var head=new SqlCommand("INSERT dbo.DenialMapperPushAudit(SourceLabId,TargetLabId,PushedByUserId,PushStatus,TotalCompared,TotalDifferences,TotalAssignedOpenTasksAffected) OUTPUT inserted.PushAuditId VALUES(0,@Lab,@User,'PendingConfirmation',@Compared,@Differences,@Open)",central,tx);
                head.Parameters.AddWithValue("@Lab",labId);head.Parameters.AddWithValue("@User",user);head.Parameters.AddWithValue("@Compared",masterRows.Count);head.Parameters.AddWithValue("@Differences",details.Count);head.Parameters.AddWithValue("@Open",details.Sum(x=>x.OpenAssignedTaskCount));var auditId=Convert.ToInt64(await head.ExecuteScalarAsync(ct));auditIds.Add(auditId);
                foreach(var d in details){d.PushAuditId=auditId;await InsertPushDetailAsync(central,tx,d,ct);}await tx.CommitAsync(ct);
            }catch{await tx.RollbackAsync(CancellationToken.None);throw;}
            allDetails.AddRange(details);
        }
        return new(){PushAuditIds=auditIds,TotalLabs=selected.Count,TotalCompared=totalCompared,TotalDifferences=allDetails.Count,TotalAssignedOpenTasksAffected=totalOpen,Differences=allDetails,Message=allDetails.Count==0?"No action/task difference found. Ready to push.":"Action/Task differences found between Master Lab and selected lab(s). Please verify before pushing."};
    }

    public async Task<int> ConfirmPushAsync(IReadOnlyList<long> pushAuditIds,string user,string role,CancellationToken ct)
    {
        var done=0;
        foreach(var id in pushAuditIds.Distinct())
        {
            var audit=await PushAuditAsync(id,ct);if(audit is null||audit.PushStatus!="PendingConfirmation")continue;
            try{await PushAsync([audit.TargetLabId],user,role,ct);await ApplyPushAuditValuesAsync(audit,user,ct);await AcceptMasterValuesAsync(audit,user,ct);await CreateOpenTaskVerificationAsync(audit,user,ct);await SetPushStatusAsync(id,"Pushed",user,null,ct);done++;}
            catch(Exception ex){await SetPushStatusAsync(id,"Failed",user,ex.Message,ct);throw;}
        }
        if(done==0)throw new InvalidOperationException("No pending mapper push was confirmed. Refresh the comparison and try again.");
        return done;
    }

    public async Task CancelPushAsync(IReadOnlyList<long> ids,string user,CancellationToken ct)
    {await using var c=Open();await c.OpenAsync(ct);await EnsurePushAuditSchemaAsync(c,ct);foreach(var id in ids.Distinct()){await using var cmd=new SqlCommand("UPDATE dbo.DenialMapperPushAudit SET PushStatus='Cancelled',CancelledOn=SYSUTCDATETIME(),CancelledByUserId=@User WHERE PushAuditId=@Id AND PushStatus='PendingConfirmation'",c);cmd.Parameters.AddWithValue("@Id",id);cmd.Parameters.AddWithValue("@User",user);await cmd.ExecuteNonQueryAsync(ct);}}

    public async Task<DenialMapperPushAuditView?> PushAuditAsync(long id,CancellationToken ct)
    {
        await using var c=Open();await c.OpenAsync(ct);await EnsurePushAuditSchemaAsync(c,ct);DenialMapperPushAuditView? result=null;
        await using(var cmd=new SqlCommand("SELECT a.PushAuditId,a.SourceLabId,a.TargetLabId,ISNULL(l.LabName,''),a.PushedByUserId,a.PushStatus,a.TotalCompared,a.TotalDifferences,a.TotalAssignedOpenTasksAffected,a.CreatedOn,a.ConfirmedOn FROM dbo.DenialMapperPushAudit a LEFT JOIN dbo.Labs l ON l.LabId=a.TargetLabId WHERE a.PushAuditId=@Id",c)){cmd.Parameters.AddWithValue("@Id",id);await using var r=await cmd.ExecuteReaderAsync(ct);if(await r.ReadAsync(ct))result=new(){PushAuditId=r.GetInt64(0),SourceLabId=r.GetInt32(1),TargetLabId=r.GetInt32(2),TargetLabName=r.GetString(3),PushedByUserId=r.GetString(4),PushStatus=r.GetString(5),TotalCompared=r.GetInt32(6),TotalDifferences=r.GetInt32(7),TotalAssignedOpenTasksAffected=r.GetInt32(8),CreatedOn=r.GetDateTime(9),ConfirmedOn=r.IsDBNull(10)?null:r.GetDateTime(10)};}
        if(result is null)return null;result.Differences=await ReadPushDetailsAsync(c,id,result.TargetLabName,ct);return result;
    }

    public async Task<IReadOnlyList<DenialMapperPushSummary>> ListPushesAsync(int take,CancellationToken ct)
    {
        var list=new List<DenialMapperPushSummary>();
        await using var c=Open();await c.OpenAsync(ct);await EnsurePushAuditSchemaAsync(c,ct);
        // Push Status page states: 'PendingConfirmation' (compared, awaiting the admin's confirm/
        // distribute — actionable), 'Pushed' (distributed, awaiting AR Manager), 'Confirmed', and
        // 'Failed'. 'Cancelled' rows are hidden; in-progress compare/distribute is surfaced separately
        // from the live push-job service.
        await using var cmd=new SqlCommand("SELECT TOP(@Take) a.PushAuditId,a.TargetLabId,ISNULL(l.LabName,''),a.PushStatus,a.TotalCompared,a.TotalDifferences,a.TotalAssignedOpenTasksAffected,a.PushedByUserId,a.ConfirmedByUserId,a.FailureMessage,a.CreatedOn,a.ConfirmedOn FROM dbo.DenialMapperPushAudit a LEFT JOIN dbo.Labs l ON l.LabId=a.TargetLabId WHERE a.PushStatus IN ('PendingConfirmation','Pushed','Confirmed','Failed') ORDER BY a.CreatedOn DESC",c);
        cmd.Parameters.AddWithValue("@Take",Math.Clamp(take,1,500));
        await using var r=await cmd.ExecuteReaderAsync(ct);
        while(await r.ReadAsync(ct))list.Add(new(){PushAuditId=r.GetInt64(0),TargetLabId=r.GetInt32(1),TargetLabName=r.GetString(2),PushStatus=r.GetString(3),TotalCompared=r.GetInt32(4),TotalDifferences=r.GetInt32(5),TotalAssignedOpenTasksAffected=r.GetInt32(6),PushedByUserId=S(r,7),ConfirmedByUserId=r.IsDBNull(8)?null:r.GetString(8),FailureMessage=r.IsDBNull(9)?null:r.GetString(9),CreatedOn=r.GetDateTime(10),ConfirmedOn=r.IsDBNull(11)?null:r.GetDateTime(11)});
        return list;
    }

    public async Task UpdatePushAuditDetailAsync(long pushAuditId,long detailId,DenialMapperPushDetailEditRequest q,string user,string role,CancellationToken ct)
    {
        await using var c=Open();await c.OpenAsync(ct);await EnsurePushAuditSchemaAsync(c,ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);
        try
        {
            DenialMapperPushDifference? before=null;string status="";int labId=0;
            await using(var find=new SqlCommand("SELECT a.PushStatus,d.TargetLabId,d.PushAuditDetailId,d.PushAuditId,d.DenialCode,d.ICDComplianceStatus,d.CoverageStatus,d.ExistingActionCode,d.NewActionCode,d.ExistingActionCategory,d.NewActionCategory,d.ExistingTask,d.NewTask,d.ExistingShortCategory,d.NewShortCategory,d.ExistingDenialClassification,d.NewDenialClassification,d.DifferenceType,d.IsAssignedToOpenTask,d.OpenAssignedTaskCount FROM dbo.DenialMapperPushAuditDetail d INNER JOIN dbo.DenialMapperPushAudit a ON a.PushAuditId=d.PushAuditId WHERE d.PushAuditId=@Audit AND d.PushAuditDetailId=@Detail",c,tx))
            {
                find.Parameters.AddWithValue("@Audit",pushAuditId);find.Parameters.AddWithValue("@Detail",detailId);
                await using var r=await find.ExecuteReaderAsync(ct);
                if(await r.ReadAsync(ct)){status=r.GetString(0);labId=r.GetInt32(1);before=new(){TargetLabId=labId,PushAuditDetailId=r.GetInt64(2),PushAuditId=r.GetInt64(3),DenialCode=r.GetString(4),ICDComplianceStatus=S(r,5),CoverageStatus=S(r,6),ExistingActionCode=S(r,7),NewActionCode=S(r,8),ExistingActionCategory=S(r,9),NewActionCategory=S(r,10),ExistingTask=S(r,11),NewTask=S(r,12),ExistingShortCategory=S(r,13),NewShortCategory=S(r,14),ExistingDenialClassification=S(r,15),NewDenialClassification=S(r,16),DifferenceType=r.GetString(17),IsAssignedToOpenTask=r.GetBoolean(18),OpenAssignedTaskCount=r.GetInt32(19)};}
            }
            if(before is null)throw new KeyNotFoundException("Mapper push detail was not found.");
            if(status!="PendingConfirmation"&&status!="Pushed")throw new InvalidOperationException("Only pending or unacknowledged mapper push details can be edited.");
            await using(var cmd=new SqlCommand("UPDATE dbo.DenialMapperPushAuditDetail SET NewActionCode=@ActionCode,NewActionCategory=@ActionCategory,NewTask=@Task,NewShortCategory=@Recommended,NewDenialClassification=@Class,DifferenceType=@Type WHERE PushAuditDetailId=@Detail AND PushAuditId=@Audit",c,tx))
            {
                cmd.Parameters.AddWithValue("@Audit",pushAuditId);cmd.Parameters.AddWithValue("@Detail",detailId);cmd.Parameters.AddWithValue("@ActionCode",q.ActionCode.Trim());cmd.Parameters.AddWithValue("@ActionCategory",q.ActionCategory.Trim());cmd.Parameters.AddWithValue("@Task",q.Task.Trim());cmd.Parameters.AddWithValue("@Recommended",q.RecommendedAction.Trim());cmd.Parameters.AddWithValue("@Class",Db(q.DenialClassification));cmd.Parameters.AddWithValue("@Type",BuildDifferenceType(before,q));await cmd.ExecuteNonQueryAsync(ct);
            }
            if(status=="Pushed")await ApplyPushAuditDetailValueAsync(labId,before,q,user,ct);
            await AuditPushEditChanges(c,tx,labId,before,q,user,role,ct);await tx.CommitAsync(ct);
        }catch{await tx.RollbackAsync(CancellationToken.None);throw;}
    }

    public async Task<IReadOnlyList<DenialMapperNotification>> PendingNotificationsAsync(int labId,string user,CancellationToken ct)
    {await using var c=Open();await c.OpenAsync(ct);await EnsurePushAuditSchemaAsync(c,ct);var list=new List<DenialMapperNotification>();await using var cmd=new SqlCommand("SELECT a.PushAuditId,a.SourceLabId,a.TargetLabId,ISNULL(l.LabName,''),a.PushStatus,a.TotalDifferences,a.CreatedOn FROM dbo.DenialMapperPushAudit a LEFT JOIN dbo.Labs l ON l.LabId=a.TargetLabId WHERE a.TargetLabId=@Lab AND a.PushStatus='Pushed' AND a.AcknowledgedOn IS NULL ORDER BY a.CreatedOn DESC",c);cmd.Parameters.AddWithValue("@Lab",labId);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))list.Add(new(){PushAuditId=r.GetInt64(0),SourceLabId=r.GetInt32(1),TargetLabId=r.GetInt32(2),TargetLabName=r.GetString(3),PushStatus=r.GetString(4),TotalDifferences=r.GetInt32(5),CreatedOn=r.GetDateTime(6)});return list;}

    public async Task<int> AcknowledgeNotificationAsync(long id,int labId,string user,CancellationToken ct)
    {
        await using(var central=Open())
        {
            await central.OpenAsync(ct);
            await EnsurePushAuditSchemaAsync(central,ct);
            await using var pending=new SqlCommand("SELECT COUNT(*) FROM dbo.DenialMapperPushAudit WHERE PushAuditId=@Id AND TargetLabId=@Lab AND PushStatus='Pushed' AND AcknowledgedOn IS NULL",central);
            pending.Parameters.AddWithValue("@Id",id);
            pending.Parameters.AddWithValue("@Lab",labId);
            if(Convert.ToInt32(await pending.ExecuteScalarAsync(ct))==0)
                throw new InvalidOperationException("This mapper push is no longer pending AR Manager confirmation.");
        }

        int mappingCount;
        await using(var lab=OpenLab(labId))
        {
            await lab.OpenAsync(ct);
            await EnsureLabTables(lab,ct);
            await using var tx=(SqlTransaction)await lab.BeginTransactionAsync(ct);
            try
            {
                const string applySql="""
                    IF OBJECT_ID('dbo.DenialCodeMaster','U') IS NULL
                        THROW 51000, 'DenialCodeMaster table is missing in the target lab database.', 1;

                    IF NOT EXISTS (SELECT 1 FROM dbo.DenialMapperLabMaster WHERE LabId=@LabId AND IsActive=1)
                        THROW 51001, 'The pending mapper push contains no active lab mappings.', 1;

                    ;WITH RankedMapper AS
                    (
                        SELECT
                            m.DenialCode,
                            m.DenialDescription,
                            m.DenialClassification,
                            ISNULL(NULLIF(LTRIM(RTRIM(m.CoverageStatus)),''),'N/A') AS CoverageStatus,
                            ISNULL(NULLIF(LTRIM(RTRIM(m.ICDComplianceStatus)),''),'N/A') AS ICDComplianceStatus,
                            m.DenialValidity,
                            COALESCE(o.ActionCode,m.ActionCode) AS ActionCode,
                            COALESCE(o.RecommendedAction,m.RecommendedAction) AS RecommendedAction,
                            COALESCE(o.ActionCategory,m.ActionCategory) AS ActionCategory,
                            COALESCE(o.Task,m.Task) AS Task,
                            m.Priority,
                            m.SLA AS SLADays,
                            ROW_NUMBER() OVER
                            (
                                PARTITION BY
                                    m.DenialCode,
                                    ISNULL(NULLIF(LTRIM(RTRIM(m.CoverageStatus)),''),'N/A'),
                                    ISNULL(NULLIF(LTRIM(RTRIM(m.ICDComplianceStatus)),''),'N/A')
                                ORDER BY m.ModifiedOn DESC,m.SuperMasterId DESC
                            ) AS RowRank
                        FROM dbo.DenialMapperLabMaster m
                        LEFT JOIN dbo.DenialMapperLabOverride o
                          ON o.LabId=m.LabId
                         AND o.SuperMasterId=m.SuperMasterId
                         AND o.IsActive=1
                        WHERE m.LabId=@LabId AND m.IsActive=1
                    ),
                    EffectiveMapper AS
                    (
                        SELECT DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,
                               DenialValidity,ActionCode,RecommendedAction,ActionCategory,Task,Priority,SLADays
                        FROM RankedMapper
                        WHERE RowRank=1
                    )
                    MERGE dbo.DenialCodeMaster AS target
                    USING EffectiveMapper AS source
                       ON target.DenialCode=source.DenialCode
                      AND target.CoverageStatus=source.CoverageStatus
                      AND target.ICDComplianceStatus=source.ICDComplianceStatus
                    WHEN MATCHED THEN UPDATE SET
                        DenialDescription=source.DenialDescription,
                        DenialClassification=source.DenialClassification,
                        DenialValidity=source.DenialValidity,
                        ActionCode=source.ActionCode,
                        RecommendedAction=source.RecommendedAction,
                        ActionCategory=source.ActionCategory,
                        Task=source.Task,
                        Priority=source.Priority,
                        SLADays=source.SLADays,
                        UpdatedOn=SYSUTCDATETIME(),
                        UpdatedBy=@User
                    WHEN NOT MATCHED THEN INSERT
                    (
                        DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,
                        DenialValidity,ActionCode,RecommendedAction,ActionCategory,Task,Priority,SLADays,CreatedBy
                    )
                    VALUES
                    (
                        source.DenialCode,source.DenialDescription,source.DenialClassification,source.CoverageStatus,
                        source.ICDComplianceStatus,source.DenialValidity,source.ActionCode,source.RecommendedAction,
                        source.ActionCategory,source.Task,source.Priority,source.SLADays,@User
                    );

                    SELECT COUNT(*)
                    FROM
                    (
                        SELECT DenialCode,
                               ISNULL(NULLIF(LTRIM(RTRIM(CoverageStatus)),''),'N/A') CoverageStatus,
                               ISNULL(NULLIF(LTRIM(RTRIM(ICDComplianceStatus)),''),'N/A') ICDComplianceStatus
                        FROM dbo.DenialMapperLabMaster
                        WHERE LabId=@LabId AND IsActive=1
                        GROUP BY DenialCode,
                                 ISNULL(NULLIF(LTRIM(RTRIM(CoverageStatus)),''),'N/A'),
                                 ISNULL(NULLIF(LTRIM(RTRIM(ICDComplianceStatus)),''),'N/A')
                    ) approved;
                    """;
                await using var apply=new SqlCommand(applySql,lab,tx){CommandTimeout=180};
                apply.Parameters.AddWithValue("@LabId",labId);
                apply.Parameters.AddWithValue("@User",user);
                mappingCount=Convert.ToInt32(await apply.ExecuteScalarAsync(ct));

                await using var verify=new SqlCommand("""
                    SELECT COUNT(*)
                    FROM dbo.DenialMapperLabMaster m
                    LEFT JOIN dbo.DenialCodeMaster d
                      ON d.DenialCode=m.DenialCode
                     AND d.CoverageStatus=ISNULL(NULLIF(LTRIM(RTRIM(m.CoverageStatus)),''),'N/A')
                     AND d.ICDComplianceStatus=ISNULL(NULLIF(LTRIM(RTRIM(m.ICDComplianceStatus)),''),'N/A')
                    WHERE m.LabId=@LabId AND m.IsActive=1 AND d.DenialCode IS NULL;
                    """,lab,tx);
                verify.Parameters.AddWithValue("@LabId",labId);
                var missing=Convert.ToInt32(await verify.ExecuteScalarAsync(ct));
                if(missing>0)throw new InvalidOperationException($"Denial Code Master verification failed. {missing} approved mapping(s) were not applied.");

                await tx.CommitAsync(ct);
            }
            catch
            {
                await tx.RollbackAsync(CancellationToken.None);
                throw;
            }
        }

        await using(var central=Open())
        {
            await central.OpenAsync(ct);
            await EnsurePushAuditSchemaAsync(central,ct);
            await using var tx=(SqlTransaction)await central.BeginTransactionAsync(ct);
            try
            {
                await using var cmd=new SqlCommand("""
                    UPDATE dbo.DenialMapperPushAudit
                    SET AcknowledgedOn=SYSUTCDATETIME(),
                        AcknowledgedByUserId=@User,
                        PushStatus='Confirmed',
                        ConfirmedOn=SYSUTCDATETIME(),
                        ConfirmedByUserId=@User
                    WHERE PushAuditId=@Id
                      AND TargetLabId=@Lab
                      AND PushStatus='Pushed'
                      AND AcknowledgedOn IS NULL;
                    """,central,tx);
                cmd.Parameters.AddWithValue("@Id",id);
                cmd.Parameters.AddWithValue("@Lab",labId);
                cmd.Parameters.AddWithValue("@User",user);
                if(await cmd.ExecuteNonQueryAsync(ct)!=1)
                    throw new InvalidOperationException("The mapper push confirmation status could not be updated.");
                await Audit(central,tx,"AR Manager Confirmed Push",labId,null,null,null,null,$"{mappingCount} mappings applied to DenialCodeMaster",user,"AR Manager",ct);
                await tx.CommitAsync(ct);
            }
            catch
            {
                await tx.RollbackAsync(CancellationToken.None);
                throw;
            }
        }

        return mappingCount;
    }

    public async Task<PagedResult<DenialMapperRecord>> LabMasterAsync(int labId,string? search,string? classification,int page,int pageSize,CancellationToken ct)
    {
        page=Math.Max(1,page);pageSize=Math.Clamp(pageSize,10,200);var result=new PagedResult<DenialMapperRecord>{Page=page,PageSize=pageSize};await using var c=OpenLab(labId);await c.OpenAsync(ct);await EnsureLabTables(c,ct);if(!await LabTablesExist(c,ct))return result;
        const string where="m.IsActive=1 AND (@Search IS NULL OR m.DenialCode LIKE @Search ESCAPE '\\' OR m.DenialDescription LIKE @Search ESCAPE '\\') AND (@Class IS NULL OR UPPER(LTRIM(RTRIM(m.DenialClassification)))=UPPER(LTRIM(RTRIM(@Class))))";
        await using(var count=new SqlCommand($"SELECT COUNT(*) FROM dbo.DenialMapperLabMaster m WHERE {where}",c)){AddFilters(count,search,classification);result.TotalCount=Convert.ToInt32(await count.ExecuteScalarAsync(ct));}
        var sql=$"SELECT m.SuperMasterId,m.DenialCode,m.DenialDescription,m.DenialClassification,m.CoverageStatus,m.ICDComplianceStatus,m.DenialValidity,COALESCE(o.ActionCode,m.ActionCode),COALESCE(o.ActionCategory,m.ActionCategory),COALESCE(o.Task,m.Task),COALESCE(o.RecommendedAction,m.RecommendedAction),m.SLA,m.Priority,COALESCE(o.ModifiedOn,m.ModifiedOn),CASE WHEN o.Id IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,m.ActionCode,m.ActionCategory,m.Task,m.RecommendedAction FROM dbo.DenialMapperLabMaster m LEFT JOIN dbo.DenialMapperLabOverride o ON o.SuperMasterId=m.SuperMasterId AND o.LabId=@LabId AND o.IsActive=1 WHERE {where} ORDER BY m.DenialCode OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY";
        await using var cmd=new SqlCommand(sql,c);cmd.Parameters.AddWithValue("@LabId",labId);AddFilters(cmd,search,classification);cmd.Parameters.AddWithValue("@Skip",(page-1)*pageSize);cmd.Parameters.AddWithValue("@Take",pageSize);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))result.Items.Add(Map(r,true,labId));return result;
    }

    public async Task SaveOverrideAsync(int labId,long superId,DenialMapperOverrideRequest q,string user,string role,CancellationToken ct)
    {
        const string sql="MERGE dbo.DenialMapperLabOverride AS t USING(SELECT @LabId LabId,@SuperId SuperMasterId) s ON t.LabId=s.LabId AND t.SuperMasterId=s.SuperMasterId AND t.IsActive=1 WHEN MATCHED THEN UPDATE SET ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHEN NOT MATCHED THEN INSERT(LabId,SuperMasterId,ActionCode,ActionCategory,Task,RecommendedAction,CreatedBy,ModifiedBy) VALUES(@LabId,@SuperId,@ActionCode,@ActionCategory,@Task,@Recommended,@User,@User);";
        DenialMapperRecord? before=null;await using(var c=OpenLab(labId)){await c.OpenAsync(ct);await EnsureLabTables(c,ct);before=await FindLabMappingAsync(c,labId,superId,ct);await using var cmd=new SqlCommand(sql,c);AddOverride(cmd,labId,superId,q,user);await cmd.ExecuteNonQueryAsync(ct);}
        var code=before?.DenialCode;await using(var c=Open()){await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);try{var changes=new (string Field,string? From,string? To)[]{("Action Code",before?.ActionCode,q.ActionCode),("Action Category",before?.ActionCategory,q.ActionCategory),("Task",before?.Task,q.Task),("Recommended Action",before?.RecommendedAction,q.RecommendedAction)};foreach(var x in changes.Where(x=>before is null||Different(x.From,x.To)))await Audit(c,tx,"Lab Override Updated",labId,superId,code,x.Field,x.From,x.To,user,role,ct);await tx.CommitAsync(ct);}catch{await tx.RollbackAsync(CancellationToken.None);throw;}}
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

    private static DenialMapperRecord ToRecord(long id,DenialMapperSaveRequest q)=>new(){Id=id,SuperMasterId=id,DenialCode=q.DenialCode.Trim(),DenialDescription=q.DenialDescription,DenialClassification=q.DenialClassification,CoverageStatus=q.CoverageStatus,ICDComplianceStatus=q.ICDComplianceStatus,DenialValidity=q.DenialValidity,ActionCode=q.ActionCode.Trim(),ActionCategory=q.ActionCategory.Trim(),Task=q.Task.Trim(),RecommendedAction=q.RecommendedAction.Trim(),SLA=q.SLA.Trim(),Priority=q.Priority.Trim()};
    private static async Task<DenialMapperRecord?> FindSuperMasterAsync(SqlConnection c,SqlTransaction tx,long id,CancellationToken ct)
    {await using var cmd=new SqlCommand("SELECT Id,DenialCode,DenialDescription,DenialClassification,CoverageStatus,ICDComplianceStatus,DenialValidity,ActionCode,ActionCategory,Task,RecommendedAction,SLA,Priority,ModifiedOn FROM dbo.DenialMapperSuperMaster WHERE Id=@Id AND IsActive=1",c,tx);cmd.Parameters.AddWithValue("@Id",id);await using var r=await cmd.ExecuteReaderAsync(ct);return await r.ReadAsync(ct)?Map(r,false):null;}
    private static async Task<DenialMapperRecord?> FindLabMappingAsync(SqlConnection c,int labId,long superId,CancellationToken ct)
    {await using var cmd=new SqlCommand("SELECT m.SuperMasterId,m.DenialCode,m.DenialDescription,m.DenialClassification,m.CoverageStatus,m.ICDComplianceStatus,m.DenialValidity,COALESCE(o.ActionCode,m.ActionCode),COALESCE(o.ActionCategory,m.ActionCategory),COALESCE(o.Task,m.Task),COALESCE(o.RecommendedAction,m.RecommendedAction),m.SLA,m.Priority,COALESCE(o.ModifiedOn,m.ModifiedOn),CASE WHEN o.Id IS NULL THEN CAST(0 AS bit) ELSE CAST(1 AS bit) END,m.ActionCode,m.ActionCategory,m.Task,m.RecommendedAction FROM dbo.DenialMapperLabMaster m LEFT JOIN dbo.DenialMapperLabOverride o ON o.SuperMasterId=m.SuperMasterId AND o.LabId=@LabId AND o.IsActive=1 WHERE m.SuperMasterId=@SuperId AND m.IsActive=1",c);cmd.Parameters.AddWithValue("@LabId",labId);cmd.Parameters.AddWithValue("@SuperId",superId);await using var r=await cmd.ExecuteReaderAsync(ct);return await r.ReadAsync(ct)?Map(r,true,labId):null;}
    private static async Task AuditChanges(SqlConnection c,SqlTransaction tx,string eventType,int? labId,long? superId,string code,DenialMapperRecord? before,DenialMapperRecord after,string user,string role,CancellationToken ct)
    {
        var changes=new (string Field,string? From,string? To)[]{("Denial Code",before?.DenialCode,after.DenialCode),("Description",before?.DenialDescription,after.DenialDescription),("Classification",before?.DenialClassification,after.DenialClassification),("Coverage Status",before?.CoverageStatus,after.CoverageStatus),("ICD Compliance",before?.ICDComplianceStatus,after.ICDComplianceStatus),("Denial Validity",before?.DenialValidity,after.DenialValidity),("Action Code",before?.ActionCode,after.ActionCode),("Action Category",before?.ActionCategory,after.ActionCategory),("Task",before?.Task,after.Task),("Recommended Action",before?.RecommendedAction,after.RecommendedAction),("SLA",before?.SLA,after.SLA),("Priority",before?.Priority,after.Priority)};
        var wrote=false;foreach(var x in changes.Where(x=>before is null||Different(x.From,x.To))){await Audit(c,tx,eventType,labId,superId,code,x.Field,x.From,x.To,user,role,ct);wrote=true;}if(!wrote)await Audit(c,tx,eventType,labId,superId,code,null,null,null,user,role,ct);
    }
    private static async Task AuditPushEditChanges(SqlConnection c,SqlTransaction tx,int labId,DenialMapperPushDifference before,DenialMapperPushDetailEditRequest after,string user,string role,CancellationToken ct)
    {
        var changes=new (string Field,string? From,string? To)[]{("Action Code",before.NewActionCode,after.ActionCode),("Action Category",before.NewActionCategory,after.ActionCategory),("Task",before.NewTask,after.Task),("Recommended Action",before.NewShortCategory,after.RecommendedAction),("Denial Classification",before.NewDenialClassification,after.DenialClassification)};
        foreach(var x in changes.Where(x=>Different(x.From,x.To)))await Audit(c,tx,"Push Verification Edited",labId,null,before.DenialCode,x.Field,x.From,x.To,user,role,ct);
    }
    private static string BuildDifferenceType(DenialMapperPushDifference before,DenialMapperPushDetailEditRequest after)
    {
        var types=new List<string>();if(Different(before.ExistingActionCode,after.ActionCode))types.Add("Action Code Changed");if(Different(before.ExistingActionCategory,after.ActionCategory))types.Add("Action Category Changed");if(Different(before.ExistingTask,after.Task))types.Add("Task Changed");if(Different(before.ExistingShortCategory,after.RecommendedAction))types.Add("Short Category Changed");if(Different(before.ExistingDenialClassification,after.DenialClassification))types.Add("Denial Classification Changed");return types.Count==0?"Reviewed - No Difference":string.Join(", ",types);
    }
    private static string MapperKey(string code,string? icd,string? coverage)=>$"{code.Trim()}\u001f{icd?.Trim()}\u001f{coverage?.Trim()}";
    private static bool Different(string? left,string? right)=>!string.Equals(left?.Trim()??"",right?.Trim()??"",StringComparison.OrdinalIgnoreCase);
    private async Task<int> CountOpenTasksAsync(int labId,DenialMapperPushDifference d,CancellationToken ct)
    {
        await using var c=OpenLab(labId);
        await c.OpenAsync(ct);
        await using var schema=new SqlCommand("""
            SELECT CASE WHEN OBJECT_ID('dbo.DenialTaskBoard','U') IS NOT NULL
                              AND COL_LENGTH('dbo.DenialTaskBoard','DenialCode') IS NOT NULL
                              AND COL_LENGTH('dbo.DenialTaskBoard','ICDComplianceStatus') IS NOT NULL
                              AND COL_LENGTH('dbo.DenialTaskBoard','CoverageStatus') IS NOT NULL
                              AND COL_LENGTH('dbo.DenialTaskBoard','AssignedTo') IS NOT NULL
                              AND COL_LENGTH('dbo.DenialTaskBoard','Status') IS NOT NULL
                              AND COL_LENGTH('dbo.DenialTaskBoard','WorkFlowStatus') IS NOT NULL
                        THEN 1 ELSE 0 END
            """,c);
        if(Convert.ToInt32(await schema.ExecuteScalarAsync(ct))==0)return 0;

        await using var cmd=new SqlCommand("SELECT COUNT(*) FROM dbo.DenialTaskBoard WHERE UPPER(LTRIM(RTRIM(ISNULL(DenialCode,''))))=UPPER(LTRIM(RTRIM(@Code))) AND UPPER(LTRIM(RTRIM(ISNULL(ICDComplianceStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Icd,'')))) AND UPPER(LTRIM(RTRIM(ISNULL(CoverageStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Coverage,'')))) AND NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) NOT IN ('close','closed') AND LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,'')))) NOT IN ('close','closed','closed claim')",c);
        cmd.Parameters.AddWithValue("@Code",d.DenialCode);
        cmd.Parameters.AddWithValue("@Icd",Db(d.ICDComplianceStatus));
        cmd.Parameters.AddWithValue("@Coverage",Db(d.CoverageStatus));
        return Convert.ToInt32(await cmd.ExecuteScalarAsync(ct));
    }
    private static async Task EnsurePushAuditSchemaAsync(SqlConnection c,CancellationToken ct)
    {const string sql="""
IF OBJECT_ID('dbo.DenialMapperPushAudit','U') IS NULL
CREATE TABLE dbo.DenialMapperPushAudit(PushAuditId bigint IDENTITY PRIMARY KEY,SourceLabId int NOT NULL,TargetLabId int NOT NULL,PushedByUserId nvarchar(100) NOT NULL,PushStatus nvarchar(50) NOT NULL,TotalCompared int NOT NULL DEFAULT 0,TotalDifferences int NOT NULL DEFAULT 0,TotalAssignedOpenTasksAffected int NOT NULL DEFAULT 0,CreatedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),ConfirmedOn datetime2 NULL,ConfirmedByUserId nvarchar(100) NULL,CancelledOn datetime2 NULL,CancelledByUserId nvarchar(100) NULL,AcknowledgedOn datetime2 NULL,AcknowledgedByUserId nvarchar(100) NULL,FailureMessage nvarchar(2000) NULL);
IF COL_LENGTH('dbo.DenialMapperPushAudit','AcknowledgedOn') IS NULL ALTER TABLE dbo.DenialMapperPushAudit ADD AcknowledgedOn datetime2 NULL,AcknowledgedByUserId nvarchar(100) NULL;
IF COL_LENGTH('dbo.DenialMapperPushAudit','FailureMessage') IS NULL ALTER TABLE dbo.DenialMapperPushAudit ADD FailureMessage nvarchar(2000) NULL;
IF OBJECT_ID('dbo.DenialMapperPushAuditDetail','U') IS NULL
CREATE TABLE dbo.DenialMapperPushAuditDetail(PushAuditDetailId bigint IDENTITY PRIMARY KEY,PushAuditId bigint NOT NULL,TargetLabId int NOT NULL,DenialCode nvarchar(100) NOT NULL,ICDComplianceStatus nvarchar(255) NULL,CoverageStatus nvarchar(255) NULL,ExistingActionCode nvarchar(255) NULL,NewActionCode nvarchar(255) NULL,ExistingActionCategory nvarchar(500) NULL,NewActionCategory nvarchar(500) NULL,ExistingTask nvarchar(500) NULL,NewTask nvarchar(500) NULL,ExistingShortCategory nvarchar(1000) NULL,NewShortCategory nvarchar(1000) NULL,ExistingDenialClassification nvarchar(255) NULL,NewDenialClassification nvarchar(255) NULL,DifferenceType nvarchar(255) NOT NULL,IsAssignedToOpenTask bit NOT NULL DEFAULT 0,OpenAssignedTaskCount int NOT NULL DEFAULT 0,CreatedOn datetime2 NOT NULL DEFAULT SYSUTCDATETIME(),CONSTRAINT FK_DMPAD_Audit FOREIGN KEY(PushAuditId) REFERENCES dbo.DenialMapperPushAudit(PushAuditId));
""";await using var cmd=new SqlCommand(sql,c);await cmd.ExecuteNonQueryAsync(ct);}
    private static async Task EnsureMasterDataSchemaAsync(SqlConnection c,CancellationToken ct)
    {
        const string sql="""
IF OBJECT_ID('dbo.DenialMapperLookupMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperLookupMaster
(
    LookupType nvarchar(50) NOT NULL,
    LookupValue nvarchar(255) NOT NULL,
    NormalizedValue AS UPPER(REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(LookupValue)),'-',''),' ',''),'/','')) PERSISTED,
    SortOrder int NOT NULL CONSTRAINT DF_DMLM_SortOrder DEFAULT 0,
    IsActive bit NOT NULL CONSTRAINT DF_DMLM_IsActive DEFAULT 1,
    CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DMLM_CreatedOn DEFAULT SYSUTCDATETIME(),
    CONSTRAINT PK_DenialMapperLookupMaster PRIMARY KEY(LookupType,LookupValue)
);

IF OBJECT_ID('dbo.DenialMapperActionCategoryMaster','U') IS NULL
CREATE TABLE dbo.DenialMapperActionCategoryMaster
(
    ActionCategory nvarchar(255) NOT NULL CONSTRAINT PK_DenialMapperActionCategoryMaster PRIMARY KEY,
    ActionCode nvarchar(100) NOT NULL,
    SortOrder int NOT NULL CONSTRAINT DF_DMACM_SortOrder DEFAULT 0,
    IsActive bit NOT NULL CONSTRAINT DF_DMACM_IsActive DEFAULT 1,
    CreatedOn datetime2(0) NOT NULL CONSTRAINT DF_DMACM_CreatedOn DEFAULT SYSUTCDATETIME()
);

DECLARE @Lookup TABLE(LookupType nvarchar(50),LookupValue nvarchar(255),SortOrder int);
INSERT @Lookup VALUES
('DenialClassification','Administrative Denial',10),
('DenialClassification','Administrative Denial / Denial Upheld on Appeal',20),
('DenialClassification','Authorization Denial',30),
('DenialClassification','Billing / Coding Error',40),
('DenialClassification','Billing Related Denial',50),
('DenialClassification','Bundling/Unbundling Denial',60),
('DenialClassification','COB / Coordination of Benefits Denial',70),
('DenialClassification','COB / Routing Denial',80),
('DenialClassification','Contractual Adjustment',90),
('DenialClassification','CPT Related Denial',100),
('DenialClassification','CPT Related Denial — Scenario 2 (Post EOB Review)',110),
('DenialClassification','Documentation Denial',120),
('DenialClassification','Duplicate Claim',130),
('DenialClassification','Eligibility / Coverage Denial',140),
('DenialClassification','Frequency Related Denial',150),
('DenialClassification','ICD/CPT Policy Compliance Denial',160),
('DenialClassification','Informational / No Action Required',170),
('DenialClassification','Medical Necessity / CPT Related Denial',180),
('DenialClassification','Medical Necessity / Utilization Review Denial',190),
('DenialClassification','Medical Necessity Denial',200),
('DenialClassification','Patient Responsibility',210),
('DenialClassification','Plan Benefit Denial',220),
('DenialClassification','Policy Related Denial',230),
('DenialClassification','Provider Credentialing',240),
('DenialClassification','Third Party Liability',250),
('DenialClassification','Timely Filing Denial',260),
('CoverageStatus','Covered',10),
('CoverageStatus','Conditional - Note',20),
('CoverageStatus','Conditional - Note & Dx',30),
('CoverageStatus','Conditional - Dx',40),
('CoverageStatus','N/A',50),
('CoverageStatus','No Policy Found',60),
('CoverageStatus','Non-Covered',70),
('CoverageStatus','No Policy Found - Payment Expected',80),
('CoverageStatus','No Policy Found - Payment Uncertain',90),
('ICDComplianceStatus','N/A',10),
('ICDComplianceStatus','ICD Non Payable',20),
('ICDComplianceStatus','ICD Not Found in Policy',30),
('ICDComplianceStatus','CPT Not Found in Policy',40),
('ICDComplianceStatus','ICD Potentially Compliant',50),
('ICDComplianceStatus','Payer Not Found',60),
('ICDComplianceStatus','Other ICD Covered but not billed as Primary',70),
('ICDComplianceStatus','ICD Validation Not Required',80),
('ICDComplianceStatus','ICD Compliant',90),
('ICDComplianceStatus','Policy Not Found',100),
('DenialValidity','Denial Not Valid as per Payer Policy',10),
('DenialValidity','Denial Upheld — Claim Processed Correctly',20),
('DenialValidity','Denial Valid as per Payer Policy',30),
('DenialValidity','Denial Validity Unknown',40),
('DenialValidity','Denial Validity Unknown — Review EOB',50),
('DenialValidity','N/A',60),
('DenialValidity','Provider Enrollment Missing / Inactive',70),
('DenialValidity','Wrong Payer Billed — Correct Payer Unknown',80),
('SLADays','0 days',10),('SLADays','5 days',20),('SLADays','7 days',30),('SLADays','10 days',40),('SLADays','15 days',50),('SLADays','30 days',60),
('Priority','High',10),('Priority','Medium',20),('Priority','Low',30);

MERGE dbo.DenialMapperLookupMaster AS target
USING @Lookup AS source
ON target.LookupType=source.LookupType AND target.LookupValue=source.LookupValue
WHEN MATCHED THEN UPDATE SET SortOrder=source.SortOrder,IsActive=1
WHEN NOT MATCHED THEN INSERT(LookupType,LookupValue,SortOrder) VALUES(source.LookupType,source.LookupValue,source.SortOrder);

DECLARE @Action TABLE(ActionCategory nvarchar(255),ActionCode nvarchar(100),SortOrder int);
INSERT @Action VALUES
('Appeal','APP',10),('Rebill','APP',20),('Client Info Pending','CIP',30),
('Client Info Pending / Write Off','CIP / WOFF',40),('Credentialing / Enrollment','CRED',50),
('Manual Review','MR',60),('No Action','NA',70);

MERGE dbo.DenialMapperActionCategoryMaster AS target
USING @Action AS source ON target.ActionCategory=source.ActionCategory
WHEN MATCHED THEN UPDATE SET ActionCode=source.ActionCode,SortOrder=source.SortOrder,IsActive=1
WHEN NOT MATCHED THEN INSERT(ActionCategory,ActionCode,SortOrder) VALUES(source.ActionCategory,source.ActionCode,source.SortOrder);
""";
        await using var cmd=new SqlCommand(sql,c){CommandTimeout=180};
        await cmd.ExecuteNonQueryAsync(ct);
    }
    private static async Task InsertPushDetailAsync(SqlConnection c,SqlTransaction tx,DenialMapperPushDifference d,CancellationToken ct)
    {const string sql="INSERT dbo.DenialMapperPushAuditDetail(PushAuditId,TargetLabId,DenialCode,ICDComplianceStatus,CoverageStatus,ExistingActionCode,NewActionCode,ExistingActionCategory,NewActionCategory,ExistingTask,NewTask,ExistingShortCategory,NewShortCategory,ExistingDenialClassification,NewDenialClassification,DifferenceType,IsAssignedToOpenTask,OpenAssignedTaskCount) OUTPUT inserted.PushAuditDetailId VALUES(@Audit,@Lab,@Code,@Icd,@Coverage,@OldCode,@NewCode,@OldCategory,@NewCategory,@OldTask,@NewTask,@OldShort,@NewShort,@OldClass,@NewClass,@Type,@Assigned,@Count)";await using var cmd=new SqlCommand(sql,c,tx);cmd.Parameters.AddWithValue("@Audit",d.PushAuditId);cmd.Parameters.AddWithValue("@Lab",d.TargetLabId);cmd.Parameters.AddWithValue("@Code",d.DenialCode);cmd.Parameters.AddWithValue("@Icd",Db(d.ICDComplianceStatus));cmd.Parameters.AddWithValue("@Coverage",Db(d.CoverageStatus));cmd.Parameters.AddWithValue("@OldCode",Db(d.ExistingActionCode));cmd.Parameters.AddWithValue("@NewCode",Db(d.NewActionCode));cmd.Parameters.AddWithValue("@OldCategory",Db(d.ExistingActionCategory));cmd.Parameters.AddWithValue("@NewCategory",Db(d.NewActionCategory));cmd.Parameters.AddWithValue("@OldTask",Db(d.ExistingTask));cmd.Parameters.AddWithValue("@NewTask",Db(d.NewTask));cmd.Parameters.AddWithValue("@OldShort",Db(d.ExistingShortCategory));cmd.Parameters.AddWithValue("@NewShort",Db(d.NewShortCategory));cmd.Parameters.AddWithValue("@OldClass",Db(d.ExistingDenialClassification));cmd.Parameters.AddWithValue("@NewClass",Db(d.NewDenialClassification));cmd.Parameters.AddWithValue("@Type",d.DifferenceType);cmd.Parameters.AddWithValue("@Assigned",d.IsAssignedToOpenTask);cmd.Parameters.AddWithValue("@Count",d.OpenAssignedTaskCount);d.PushAuditDetailId=Convert.ToInt64(await cmd.ExecuteScalarAsync(ct));}
    private static async Task<IReadOnlyList<DenialMapperPushDifference>> ReadPushDetailsAsync(SqlConnection c,long id,string labName,CancellationToken ct)
    {var list=new List<DenialMapperPushDifference>();await using var cmd=new SqlCommand("SELECT PushAuditDetailId,PushAuditId,TargetLabId,DenialCode,ICDComplianceStatus,CoverageStatus,ExistingActionCode,NewActionCode,ExistingActionCategory,NewActionCategory,ExistingTask,NewTask,ExistingShortCategory,NewShortCategory,ExistingDenialClassification,NewDenialClassification,DifferenceType,IsAssignedToOpenTask,OpenAssignedTaskCount FROM dbo.DenialMapperPushAuditDetail WHERE PushAuditId=@Id ORDER BY DenialCode",c);cmd.Parameters.AddWithValue("@Id",id);await using var r=await cmd.ExecuteReaderAsync(ct);while(await r.ReadAsync(ct))list.Add(new(){PushAuditDetailId=r.GetInt64(0),PushAuditId=r.GetInt64(1),TargetLabId=r.GetInt32(2),TargetLabName=labName,DenialCode=r.GetString(3),ICDComplianceStatus=S(r,4),CoverageStatus=S(r,5),ExistingActionCode=S(r,6),NewActionCode=S(r,7),ExistingActionCategory=S(r,8),NewActionCategory=S(r,9),ExistingTask=S(r,10),NewTask=S(r,11),ExistingShortCategory=S(r,12),NewShortCategory=S(r,13),ExistingDenialClassification=S(r,14),NewDenialClassification=S(r,15),DifferenceType=r.GetString(16),IsAssignedToOpenTask=r.GetBoolean(17),OpenAssignedTaskCount=r.GetInt32(18)});return list;}
    private async Task SetPushStatusAsync(long id,string status,string user,string? failure,CancellationToken ct)
    {await using var c=Open();await c.OpenAsync(ct);await EnsurePushAuditSchemaAsync(c,ct);await using var cmd=new SqlCommand("UPDATE dbo.DenialMapperPushAudit SET PushStatus=@Status,FailureMessage=@Failure WHERE PushAuditId=@Id",c);cmd.Parameters.AddWithValue("@Id",id);cmd.Parameters.AddWithValue("@Status",status);cmd.Parameters.AddWithValue("@Failure",Db(failure));await cmd.ExecuteNonQueryAsync(ct);}
    private async Task CreateOpenTaskVerificationAsync(DenialMapperPushAuditView audit,string user,CancellationToken ct)
    {
        var changed=audit.Differences.Where(x=>x.OpenAssignedTaskCount>0).ToList();if(changed.Count==0)return;
        await using var c=OpenLab(audit.TargetLabId);await c.OpenAsync(ct);await SqlDenialCodeMasterRepository.EnsureActionChangeSchemaAsync(c,null,ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);
        try{await using var batch=new SqlCommand("INSERT dbo.DenialCodeActionChangeBatch(SourceFileName,UploadedBy,TotalAffectedClaims,TotalAffectedTasks,PendingCount,Status) OUTPUT inserted.BatchId VALUES(@Source,@User,0,@Tasks,@Tasks,'Pending')",c,tx);batch.Parameters.AddWithValue("@Source",$"DenialMapperLabPush:{audit.PushAuditId}");batch.Parameters.AddWithValue("@User",user);batch.Parameters.AddWithValue("@Tasks",changed.Sum(x=>x.OpenAssignedTaskCount));var batchId=Convert.ToInt64(await batch.ExecuteScalarAsync(ct));
            foreach(var d in changed){const string sql="""
INSERT dbo.DenialCodeActionChangeVerification(BatchId,ClaimID,TaskID,AssignedTo,ClaimStatus,DenialCode,ICDComplianceStatus,CoverageStatus,ActionCode,ActionCategory,RecommendedAction,Task,OldActionCode,NewActionCode,OldActionCategory,NewActionCategory,OldTask,NewTask,OldShortCategory,NewShortCategory)
SELECT @Batch,CONVERT(nvarchar(100),ClaimID),CONVERT(nvarchar(100),TaskID),CONVERT(nvarchar(100),AssignedTo),CONVERT(nvarchar(100),ISNULL(NULLIF(WorkFlowStatus,''),Status)),@Code,@Icd,@Coverage,ActionCode,ActionCategory,RecommendedAction,Task,@OldCode,@NewCode,@OldCategory,@NewCategory,@OldTask,@NewTask,@OldShort,@NewShort
FROM dbo.DenialTaskBoard WHERE UPPER(LTRIM(RTRIM(ISNULL(DenialCode,''))))=UPPER(LTRIM(RTRIM(@Code))) AND UPPER(LTRIM(RTRIM(ISNULL(ICDComplianceStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Icd,'')))) AND UPPER(LTRIM(RTRIM(ISNULL(CoverageStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Coverage,'')))) AND NULLIF(LTRIM(RTRIM(ISNULL(AssignedTo,''))),'') IS NOT NULL AND LOWER(LTRIM(RTRIM(ISNULL(Status,'')))) NOT IN ('close','closed') AND LOWER(LTRIM(RTRIM(ISNULL(WorkFlowStatus,'')))) NOT IN ('close','closed','closed claim');
""";await using var cmd=new SqlCommand(sql,c,tx);cmd.Parameters.AddWithValue("@Batch",batchId);cmd.Parameters.AddWithValue("@Code",d.DenialCode);cmd.Parameters.AddWithValue("@Icd",Db(d.ICDComplianceStatus));cmd.Parameters.AddWithValue("@Coverage",Db(d.CoverageStatus));cmd.Parameters.AddWithValue("@OldCode",Db(d.ExistingActionCode));cmd.Parameters.AddWithValue("@NewCode",Db(d.NewActionCode));cmd.Parameters.AddWithValue("@OldCategory",Db(d.ExistingActionCategory));cmd.Parameters.AddWithValue("@NewCategory",Db(d.NewActionCategory));cmd.Parameters.AddWithValue("@OldTask",Db(d.ExistingTask));cmd.Parameters.AddWithValue("@NewTask",Db(d.NewTask));cmd.Parameters.AddWithValue("@OldShort",Db(d.ExistingShortCategory));cmd.Parameters.AddWithValue("@NewShort",Db(d.NewShortCategory));await cmd.ExecuteNonQueryAsync(ct);}await tx.CommitAsync(ct);
        }catch{await tx.RollbackAsync(CancellationToken.None);throw;}
    }
    private async Task AcceptMasterValuesAsync(DenialMapperPushAuditView audit,string user,CancellationToken ct)
    {
        if(audit.Differences.Count==0)return;await using var c=OpenLab(audit.TargetLabId);await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);
        try{foreach(var d in audit.Differences){await using var cmd=new SqlCommand("UPDATE o SET IsActive=0,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() FROM dbo.DenialMapperLabOverride o INNER JOIN dbo.DenialMapperLabMaster m ON m.SuperMasterId=o.SuperMasterId WHERE o.IsActive=1 AND UPPER(LTRIM(RTRIM(m.DenialCode)))=UPPER(LTRIM(RTRIM(@Code))) AND UPPER(LTRIM(RTRIM(ISNULL(m.ICDComplianceStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Icd,'')))) AND UPPER(LTRIM(RTRIM(ISNULL(m.CoverageStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Coverage,''))))",c,tx);cmd.Parameters.AddWithValue("@User",user);cmd.Parameters.AddWithValue("@Code",d.DenialCode);cmd.Parameters.AddWithValue("@Icd",Db(d.ICDComplianceStatus));cmd.Parameters.AddWithValue("@Coverage",Db(d.CoverageStatus));await cmd.ExecuteNonQueryAsync(ct);}await tx.CommitAsync(ct);}catch{await tx.RollbackAsync(CancellationToken.None);throw;}
    }
    private async Task ApplyPushAuditValuesAsync(DenialMapperPushAuditView audit,string user,CancellationToken ct)
    {
        if(audit.Differences.Count==0)return;await using var c=OpenLab(audit.TargetLabId);await c.OpenAsync(ct);await using var tx=(SqlTransaction)await c.BeginTransactionAsync(ct);
        try{foreach(var d in audit.Differences){await using var cmd=new SqlCommand("UPDATE dbo.DenialMapperLabMaster SET ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,DenialClassification=@Class,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE UPPER(LTRIM(RTRIM(DenialCode)))=UPPER(LTRIM(RTRIM(@Code))) AND UPPER(LTRIM(RTRIM(ISNULL(ICDComplianceStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Icd,'')))) AND UPPER(LTRIM(RTRIM(ISNULL(CoverageStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Coverage,''))))",c,tx);cmd.Parameters.AddWithValue("@ActionCode",Db(d.NewActionCode));cmd.Parameters.AddWithValue("@ActionCategory",Db(d.NewActionCategory));cmd.Parameters.AddWithValue("@Task",Db(d.NewTask));cmd.Parameters.AddWithValue("@Recommended",Db(d.NewShortCategory));cmd.Parameters.AddWithValue("@Class",Db(d.NewDenialClassification));cmd.Parameters.AddWithValue("@User",user);cmd.Parameters.AddWithValue("@Code",d.DenialCode);cmd.Parameters.AddWithValue("@Icd",Db(d.ICDComplianceStatus));cmd.Parameters.AddWithValue("@Coverage",Db(d.CoverageStatus));await cmd.ExecuteNonQueryAsync(ct);}await tx.CommitAsync(ct);}catch{await tx.RollbackAsync(CancellationToken.None);throw;}
    }
    private async Task ApplyPushAuditDetailValueAsync(int labId,DenialMapperPushDifference d,DenialMapperPushDetailEditRequest q,string user,CancellationToken ct)
    {
        await using var c=OpenLab(labId);await c.OpenAsync(ct);await using var cmd=new SqlCommand("UPDATE dbo.DenialMapperLabMaster SET ActionCode=@ActionCode,ActionCategory=@ActionCategory,Task=@Task,RecommendedAction=@Recommended,DenialClassification=@Class,ModifiedBy=@User,ModifiedOn=SYSUTCDATETIME() WHERE UPPER(LTRIM(RTRIM(DenialCode)))=UPPER(LTRIM(RTRIM(@Code))) AND UPPER(LTRIM(RTRIM(ISNULL(ICDComplianceStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Icd,'')))) AND UPPER(LTRIM(RTRIM(ISNULL(CoverageStatus,''))))=UPPER(LTRIM(RTRIM(ISNULL(@Coverage,''))))",c);
        cmd.Parameters.AddWithValue("@ActionCode",q.ActionCode.Trim());cmd.Parameters.AddWithValue("@ActionCategory",q.ActionCategory.Trim());cmd.Parameters.AddWithValue("@Task",q.Task.Trim());cmd.Parameters.AddWithValue("@Recommended",q.RecommendedAction.Trim());cmd.Parameters.AddWithValue("@Class",Db(q.DenialClassification));cmd.Parameters.AddWithValue("@User",user);cmd.Parameters.AddWithValue("@Code",d.DenialCode);cmd.Parameters.AddWithValue("@Icd",Db(d.ICDComplianceStatus));cmd.Parameters.AddWithValue("@Coverage",Db(d.CoverageStatus));await cmd.ExecuteNonQueryAsync(ct);
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
    private static void AddFilters(SqlCommand c,string? search,string? classification){c.Parameters.AddWithValue("@Search",string.IsNullOrWhiteSpace(search)?DBNull.Value:LikePattern(search));c.Parameters.AddWithValue("@Class",Db(classification));}
    private static string LikePattern(string value)=>$"%{EscapeLike(value.Trim())}%";
    private static string EscapeLike(string value)=>value.Replace("\\","\\\\",StringComparison.Ordinal).Replace("%","\\%",StringComparison.Ordinal).Replace("_","\\_",StringComparison.Ordinal).Replace("[","\\[",StringComparison.Ordinal);
    private static void AddMaster(SqlCommand c,DenialMapperSaveRequest q,string user){c.Parameters.AddWithValue("@Code",q.DenialCode.Trim());c.Parameters.AddWithValue("@Description",Db(q.DenialDescription));c.Parameters.AddWithValue("@Class",Db(q.DenialClassification));c.Parameters.AddWithValue("@Coverage",Db(q.CoverageStatus));c.Parameters.AddWithValue("@Icd",Db(q.ICDComplianceStatus));c.Parameters.AddWithValue("@Validity",Db(q.DenialValidity));c.Parameters.AddWithValue("@ActionCode",q.ActionCode.Trim());c.Parameters.AddWithValue("@ActionCategory",q.ActionCategory.Trim());c.Parameters.AddWithValue("@Task",q.Task.Trim());c.Parameters.AddWithValue("@Recommended",q.RecommendedAction.Trim());c.Parameters.AddWithValue("@Sla",q.SLA.Trim());c.Parameters.AddWithValue("@Priority",q.Priority.Trim());c.Parameters.AddWithValue("@User",user);}
    private static void AddOverride(SqlCommand c,int lab,long superId,DenialMapperOverrideRequest q,string user){c.Parameters.AddWithValue("@LabId",lab);c.Parameters.AddWithValue("@SuperId",superId);c.Parameters.AddWithValue("@ActionCode",q.ActionCode.Trim());c.Parameters.AddWithValue("@ActionCategory",q.ActionCategory.Trim());c.Parameters.AddWithValue("@Task",q.Task.Trim());c.Parameters.AddWithValue("@Recommended",q.RecommendedAction.Trim());c.Parameters.AddWithValue("@User",user);}
    private static async Task Audit(SqlConnection c,SqlTransaction tx,string type,int? lab,long? super,string? code,string? field,string? from,string? to,string user,string role,CancellationToken ct){await using var cmd=new SqlCommand("INSERT dbo.DenialMapperAuditLog(EventType,LabId,SuperMasterId,DenialCode,FieldName,FromValue,ToValue,PerformedBy,PerformedRole) VALUES(@Type,@Lab,@Super,@Code,@Field,@From,@To,@User,@Role)",c,tx);cmd.Parameters.AddWithValue("@Type",type);cmd.Parameters.AddWithValue("@Lab",(object?)lab??DBNull.Value);cmd.Parameters.AddWithValue("@Super",(object?)super??DBNull.Value);cmd.Parameters.AddWithValue("@Code",(object?)code??DBNull.Value);cmd.Parameters.AddWithValue("@Field",(object?)field??DBNull.Value);cmd.Parameters.AddWithValue("@From",(object?)from??DBNull.Value);cmd.Parameters.AddWithValue("@To",(object?)to??DBNull.Value);cmd.Parameters.AddWithValue("@User",user);cmd.Parameters.AddWithValue("@Role",role);await cmd.ExecuteNonQueryAsync(ct);}
}
