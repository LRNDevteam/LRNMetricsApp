--Select * from LIMSMaster

SELECT
Accession [Specimen ID],
OrderStatus [Order Status],
RequestCollectDate,
ReqReceivedDate,
ReqResultedDate,
RessultedStatus [Resulted / Not],
ClientStatus [Client Status],
TimetoResult [Time to Result (Resulted - Received)],
PatientName [Patient Name],
VisitNumber,
AMDDOE,
AMDLBD,
TimetoBill,
ClaimStatus,
BilledorNot [Billed/Not],
PrimaryInsurance,
PanelCategory,
InsuranceCategory,
Client
FROM LIMSMaster
