#Requires -Modules psake
[CmdletBinding(DefaultParameterSetName='Do')]
PARAM (
	[Parameter(Position=0,ParameterSetName='Do')][string[]]$Tasks = 'Build',
	[Parameter(ParameterSetName='Show')][switch]$ListTasks
)

[string]$ModuleVersion = (Import-PowerShellDataFile -Path "$PSScriptRoot/src/Cofl.Util.PowerShell/Cofl.Util.psd1").ModuleVersion

if($ListTasks){
	Invoke-Psake $PSScriptRoot\Cofl.Util.psake.ps1 -docs -parameters @{ ModuleVersion = $ModuleVersion }
} else {
	Invoke-Psake $PSScriptRoot\Cofl.Util.psake.ps1 -taskList $Tasks -parameters @{ ModuleVersion = $ModuleVersion }
}
