# Denial Mapper push audit — manual validation

1. Same mapper values: compare one lab, verify zero differences is shown, cancel once, then compare again and confirm. Verify the lab is updated and a `Pushed` audit remains available to its AR Manager.
2. Change Action Code, Action Category, Task, or Recommended Action for the same Denial Code + ICD Compliance + Coverage key. Verify old/new values and the difference labels appear before confirmation.
3. Assign a matching `DenialTaskBoard` row to a reviewer with a non-closed status. Confirm the push and verify a pending `DenialCodeActionChangeVerification` item is created while the task-board action values remain unchanged.
4. Repeat with both `Status` and `WorkFlowStatus` closed. Verify no action-change verification item is created.
5. Log in as the target lab AR Manager. Verify the persistent update alert, Review Now summary/grid, Later behavior, and acknowledgement.
6. Log in as AR Reviewer, Client Manager, or Account Manager. Verify push, comparison, notification, verification, and confirmation actions are unavailable and the API returns 403.
7. Select multiple labs, including a lab with no mapper rows. Verify a separate audit is recorded per lab and a new-code difference is shown.
