<#
.Synopsis
    Deploy a number of VMs based on the same given image, on an availablility set, load balanced on the provided endpoint. 
    Subsequent calls targeting the same service name adds new instances.
.DESCRIPTION
    The VMs based on the provided image on the Azure image library are deployed on the same availability set, and load 
    balanced on the provided endpoint. If there is an existing service with the given name with VMs deployed having the 
    same base host name, it simply adds new Vms load balanced on the same endpoint.
.EXAMPLE
    Use the following to query an image that was created by the user. This is just an example, and any other published 
    image can also be used.
    $images = Get-AzureVMImage | 
              where {($_.ImageName -ilike "myimage") -and ($_.PublisherName -ilike "*User*")} | 
              Sort-Object PublishedDate 

    $image = $images[0]

    New-AzureRedundantVm.ps1 -NewService -ServiceName redundantTest -ComputerNameBase test `
    -InstanceSize Small -ImageName $image.ImageName -Location "West US" -VNetName "myengine" `
    -EndpointName "http" -EndpointProtocol tcp -EndpointPublicPort 80 -EndpointLocalPort 80 `
    -InstanceCount 3
.INPUTS
    None
.OUTPUTS
    None
#>
param
(
    
    # Switch to indicate adding VMs to an existing service, already load balanced.
    [Parameter(ParameterSetName = "Existing deployment")]
    [Switch]
    $ExistingService,
    
    # Switch to indicate to create a new deployment from scratch
    [Parameter(ParameterSetName = "New deployment")]
    [Switch]
    $NewService,
    
    # Cloud service name to deploy the VMs to
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName,
    
    # Base of the computer name the VMs are going to assume. E.g. myhost, where the result will be myhost1, myhost2
    [Parameter(Mandatory = $true)]
    [String]
    $ComputerNameBase,
    
    # Size of the VMs that will be deployed
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $InstanceSize,
    
    # The image name to be used from the image library. 
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $ImageName,
    
    # Location where the VMs will be deployed to
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $Location,
    
    # VNet name the VMs will be placed on
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $VNetName,
    
    # Name of the load balanced endpoint on the VMs
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [String]
    $EndpointName,
    
    # The protocol for the endpoint
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [ValidateSet("tcp", "udp")]
    [String]
    $EndpointProtocol,
    
    # Endpoint's public port number
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [Int]
    $EndpointPublicPort,
    
    # Endpoint's private port number
    [Parameter(Mandatory = $true, ParameterSetName = "New deployment")]
    [Int]
    $EndpointLocalPort,
    
    # Number of VM instances
    [Parameter(Mandatory = $false)]
    [Int]
    $InstanceCount = 6)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

<#
.SYNOPSIS
    Adds a new affinity group if it does not exist.
.DESCRIPTION
   Looks up the current subscription's (as set by Set-AzureSubscription cmdlet) affinity groups and creates a new
   affinity group if it does not exist.
.EXAMPLE
   New-AzureAffinityGroupIfNotExists -AffinityGroupNme newAffinityGroup -Locstion "West US"
.INPUTS
   None
.OUTPUTS
   None
#>
function New-AzureAffinityGroupIfNotExists
{
    param
    (
        
        # Name of the affinity group
        [Parameter(Mandatory = $true)]
        [String]
        $AffinityGroupName,
        
        # Location where the affinity group will be pointing to
        [Parameter(Mandatory = $true)]
        [String]
        $Location)
    
    $affinityGroup = Get-AzureAffinityGroup -Name $AffinityGroupName -ErrorAction SilentlyContinue
    if ($affinityGroup -eq $null)
    {
        New-AzureAffinityGroup -Name $AffinityGroupName -Location $Location -Label $AffinityGroupName `
        -ErrorVariable lastError -ErrorAction SilentlyContinue | Out-Null
        if (!($?))
        {
            throw "Cannot create the affinity group $AffinityGroupName on $Location"
        }
        Write-Verbose "Created affinity group $AffinityGroupName"
    }
    else
    {
        if ($affinityGroup.Location -ne $Location)
        {
            Write-Warning "Affinity group with name $AffinityGroupName already exists but in location `
            $affinityGroup.Location, not in $Location"
        }
    }
}

if ($NewService.IsPresent)
{
    # Check the related affinity group
    $affinityGroupName = $VNetName + "affinity"
    New-AzureAffinityGroupIfNotExists -AffinityGroupName $affinityGroupName -Location $Location
}

$existingVMs = Get-AzureVM -ServiceName $ServiceName | Where-Object {$_.Name -Like "$ComputerNameBase*"} 
$vmNumberStart = 1
if ($existingVMs -ne $null)
{
    if (!($ExistingService.IsPresent) -and $NewService.IsPresent)
    {
        throw "Cannot add new instances to an existing set of instances when the ""new deployment"" parameter set `
        is active"
    }
    
    # Build the parameters for adding new VMs from the existing ones
    $instanceNumbers = $existingVMs | 
    ForEach-Object 
    {$_.Name.Substring($ComputerNameBase.Length, ($_.Name.Length - $ComputerNameBase.Length))} | 
    Sort-Object
    $highestInstanceNumber = [Int]$instanceNumbers[$instanceNumbers.Length - 1]
    $vmNumberStart = $highestInstanceNumber + 1
    $firstVm = $existingVMs[0]
    
    $loadBalancedEndpoint = Get-AzureEndpoint -VM $firstVm | Where-Object {$_.LBSetName -ne $null}
    if ($loadBalancedEndpoint -eq $null)
    {
        throw "No load balanced endpoints on the VMs"
    }
    
    $availabilitySetName = $firstVm.AvailabilitySetName
    $ImageName = (Get-AzureOSDisk -VM $firstVm).SourceImageName
    $InstanceSize = $firstVm.InstanceSize
    $EndpointName = $loadBalancedEndpoint.Name
    $EndpointProtocol = $loadBalancedEndpoint.Protocol
    $EndpointLocalPort = $loadBalancedEndpoint.LocalPort
    $EndpointPublicPort = $loadBalancedEndpoint.Port
    $lbSetName = $loadBalancedEndpoint.LBSetName
    $DirectServerReturn = $loadBalancedEndpoint.EnableDirectServerReturn
} 

$vms = @()

$lbSetName = "LB" + $EndpointName
$availabilitySetName = $EndpointName + "availability"

$credential = Get-Credential

$vmCreationScript = 
{
    param 
    (
        
        [String] $serviceName, 
        [String] $computerNameBase,
        [Int] $index,
        [String] $instanceSize,
        [String] $imageName,
        [String] $availabilitySetName,
        [String] $endpointName,
        [String] $endpointProtocol,
        [String] $endpointLocalPort,
        [String] $endpointPublicPort,
        [String] $lbSetName,
        [String] $userName,
        [String] $password)
    
    $ComputerName = $computerNameBase + $index
    $directLocalPort = 30000 + $index
    $directInstanceEndpointName = "directInstance" + $index
    $vm = New-AzureVMConfig -Name $ComputerName -InstanceSize $instanceSize -ImageName $imageName `
    -AvailabilitySetName $availabilitySetName | 
    Add-AzureEndpoint -Name $endpointName -Protocol $endpointProtocol -LocalPort $endpointLocalPort `
    -PublicPort $endpointPublicPort -LBSetName $lbSetName -ProbeProtocol $endpointProtocol `
    -ProbePort $endpointPublicPort | 
    Add-AzureEndpoint -Name "directInstancePort" -Protocol $endpointProtocol -LocalPort $endpointLocalPort `
    -PublicPort $directLocalPort | 
    Add-AzureProvisioningConfig -Windows -AdminUsername $userName -Password $password 
    
    New-AzureVM -ServiceName $serviceName -VMs $vm -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VM."
    }    
}

$service = Get-AzureService -ServiceName $ServiceName -ErrorAction SilentlyContinue

if ($service -eq $null)
{
    New-AzureService -ServiceName $ServiceName -Location $Location
}

$jobs = @()

for ($index = $vmNumberStart; $index -lt $InstanceCount + $vmNumberStart; $index++)
{
    $argumentList = @(
        $ServiceName, 
        $ComputerNameBase, 
        $index, 
        $InstanceSize,
        $ImageName,
        $availabilitySetName,
        $EndpointName, 
        $EndpointProtocol,
        $EndpointLocalPort,
        $EndpointPublicPort,
        $lbSetName,
        $credential.GetNetworkCredential().UserName,
        $credential.GetNetworkCredential().Password)
    
    $jobs += Start-Job -ScriptBlock $vmCreationScript -ArgumentList $argumentList
    
    # The amount of time required for the VM configuration to be accepted by the platform. 
    Start-Sleep 75
}

Wait-Job -Job $jobs

$jobs | ForEach-Object {$_ | Receive-Job}
