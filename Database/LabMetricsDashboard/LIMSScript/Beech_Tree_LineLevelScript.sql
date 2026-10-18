

--Select * from LIMSMaster


SELECT OrderId,
Accession SampleId,
PaymentMethod,
Barcode,
Specimen,
Collector,
OrderStatus,
BillingStatus,
SampleStatus,
RequestSubmittedDate,
RequestCollectDate,
ReqReceivedDate,
ReqReportedDate,
RessultedStatus ResultedStatus,
ClientStatus,
TimetoResult,
TurnaroundTime,
[Performing Laboratory],
Results,
PatientFirstName,
PatientLastName,
PatientDateofBirth,
VisitNumber,
AMDDOE,
AMDLBD,
TimetoBill,
ClaimStatus,
BilledorNot,
Provider,
Facility [Clinic Name],
PrimaryInsurance,
PrimaryInsuranceID,
ICD10Codes,
Tests,
PanelCategory

FROM LIMSMaster 
