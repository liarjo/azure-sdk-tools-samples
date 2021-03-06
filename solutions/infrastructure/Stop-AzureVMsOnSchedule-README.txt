This sample demonstrates stopping a single Virtual Machine or set of Virtual Machines (using a wildcard pattern) within a Cloud Service.  It does this by creating scheduled tasks to start and stop the Virtual Machine(s) on a schedule at the time specified.

For example, suppose you have a test machine or set of test machines that you want turned off everyday at 5:30PM.  This script will register the scheduled task to stop the virtual machines you specify.

***** NOTE *****
NOTE: Wildcard pattern support mentioned above is not released yet.  It will be part of the Start-AzureVM and Stop-AzureVM feautures, currently under code review.  See this commit for more details:
https://github.com/rickrain/azure-sdk-tools/commit/d7403c67e995d39cfdce8548ff57d8e1f9297ac2
****************

Requirements:
- PowerShell Version 3.0
- Windows Azure PowerShell - June 2013

Cmdlets Used:
- New-ScheduledTask
- New-ScheduledTaskAction
- New-ScheduledTaskTrigger
- Register-ScheduledTask
- Set-StrictMode
- Stop-AzureVM
- Stop-AzureVMsOnSchedule
- Write-Verbose