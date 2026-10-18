
--PhiLife_LRN
Select
RequestCollectDate [Sample Collected Date],
ReqReceivedDate [Sample Received Date],
ReqReportedDate [Sample Resulted Date],
PanelCategory [Panel Name],
Facility [Clinic],
Provider [Referring Provider],
Collector
from LIMSMaster


--BeechTree_LRN
Select
RequestCollectDate [Sample Collected Date],
ReqReceivedDate [Sample Received Date],
ReqReportedDate [Sample Resulted Date],
PanelCategory [Panel Name],
Facility [Clinic],
Provider [Referring Provider],
Collector
from LIMSMaster


--RisingTides
Select
RequestCollectDate [Sample Collected Date],
ReqReceivedDate [Sample Received Date],
ReqReportedDate [Sample Resulted Date],
PanelCategory [Panel Name],
Facility [Clinic],
Provider [Referring Provider],
Collector
from LIMSMaster


--PCRLOA_LRN
Select
RequestCollectDate [Sample Collected Date],
ReqReceivedDate [Sample Received Date],
ReqResultedDate [Sample Resulted Date],
PanelCategory [Panel Name]
from LIMSMaster

--CoveLRN
Select
DateOfCollection [Sample Collected Date],
ReceivedDate [Sample Received Date],
ValidatedDate [Sample Resulted Date],
PanelType [Panel Name],
FacilityName [Clinic],
ProviderName [Referring Provider],
SaleRepName [Sales Rep]
from LIMSMaster


--Elixir_LRN
Select
DateOfCollection [Sample Collected Date],
ReceivedDate [Sample Received Date],
SampleResultedDate [Sample Resulted Date],
PanelName [Panel Name],
FacilityName [Clinic],
ProviderName [Referring Provider],
SaleRepName [Sales Rep]
from LIMSMaster



--InHealthDTRLRN
Select
LastTest [Sample Collected Date],
LRNPanelName [Panel Name],
Account [Clinic],
ProviderFirstName + ProviderLastName [Referring Provider],
SalesRepEmail [Sales Rep]
from LIMSMaster

--Augustus_LRN
Select
RequestCollectDate [Sample Collected Date],
ReqReceivedDate [Sample Received Date],
ResultDate [Sample Resulted Date],
PanelName [Panel Name],
ClinicName [Clinic],
ISNULL((DoctorLastName +','+ DoctorFirstName), DoctorMiddleName) [Referring Provider]
from LIMSMaster



--NWL_LRN (NorthWest Lab)
Select
RequestCollectDate [Sample Collected Date],
RequestReceivedDate [Sample Received Date],
ResultDate [Sample Resulted Date],
PanelType [Panel Name],
ClinicName [Clinic],
ReferringProvider [Referring Provider]
from LIMSMaster




--Certus_LRN (Certus Lab)
Select
ReqCollectDate [Sample Collected Date],
ReqReceivedDate [Sample Received Date],
ResultDate [Sample Resulted Date],
PanelName [Panel Name],
DoctorFullName [Referring Provider]
from LIMSMaster

