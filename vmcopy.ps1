<#
 Copyright (c) Opsgility.  All rights reserved.
 Copyright (c) David Sabater 2014.  All rights reserved.

 Licensed under the Apache License, Version 2.0 (the "License");
 you may not use this file except in compliance with the License.
 You may obtain a copy of the License at
   http://www.apache.org/licenses/LICENSE-2.0


 Unless required by applicable law or agreed to in writing, software
 distributed under the License is distributed on an "AS IS" BASIS,
 WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and
 limitations under the License.
#>


<#
  .SYNOPSIS
  This cmdlet takes an existing virtual machine, makes a copy of its disks in the local storage account and then copies the virtual machine to a seperate subscription.
  Running this script can take several minutes and up to hours if copying a virtual machine to a remote storage account.

  Ensure the source subscription and the destination subscription are configured for PowerShell access.
  
  Verify by running the following command to ensure that both subscriptions are listed: 
  Get-AzureSubscription | select SubscriptionName 

  New functionality added by David Sabater:
  1. Fixed issues with Location variable with new Azure SDK version
  2. Modify disk name appending VM new name to be able to copy VM within same subscription and renaming VM to new one
  

  .DESCRIPTION

  This script works by creating a copy of all of the disks of the virtual machine to a container in the same storage account. 
  You may optionally specify -ShutdownVM to shut the virtual machine down to ensure the backup is clean first.

  Once the disks are backed up locally the script validates that the remote cloud service name, storage account, virtual network and subnet are all accessible from the current configuration.
  
  Once validation is complete the script will copy the disks from the backup in the source storage account to the destination storage account. 

  Once the copy is complete the script will register the disks in the subscription with the same disk names but appending the new Virtual Machine name to match new Virtual Machine cloned, this gives the capability to clone VM within same Subscription

  The script next will export the virtual machine settings to a local file on the file system and import them into the target subscription and create the virtual machine with the new name selected. 
   
  
  .EXAMPLE


  # Copy a virtual machine to a different subscription 

  .\vmcopy.ps1 -SourceSubscription "source subscription" `
             -DestinationSubscription "destination subscription" `
             -VirtualMachineName "existingvmname" `
             -SourceServiceName "sourcecloudservice" `
             -DestinationVirtualMachineName "destinationvirtualmachineName" `
             -DestinationServiceName "destinationcloudservice" `
             -DestinationStorageAccount "destinationstorageaccount" `
             -Location "West US"


  # Copy a virtual machine to a different subscription and specify an existing virtual network and subnet.

  .\vmcopy.ps1 -SourceSubscription "source subscription" `
               -DestinationSubscription "destination subscription" `
               -VirtualMachineName "existingvmname" `
               -SourceServiceName "sourcecloudservice" `
               -DestinationVirtualMachineName "destinationvirtualmachineName" `
               -DestinationServiceName "destinationcloudservice" `
               -DestinationStorageAccount "destinationstorageaccount" `
               -VNETName "DestinationVNET" `
               -SubnetName "DestinationSubnet"
#>




[CmdletBinding(DefaultParameterSetName="Default")]
param(
  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$SourceSubscription,
  
  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$DestinationSubscription,

  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$VirtualMachineName, 

  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$SourceServiceName, 

  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$DestinationVirtualMachineName,

  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$DestinationServiceName, 

  [parameter(Mandatory, ParameterSetName="Default")]
  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$DestinationStorageAccount,

  [parameter(Mandatory, ParameterSetName="Default")]
  [string]$Location,

  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$VNETName,

  [parameter(Mandatory, ParameterSetName="VNET")]
  [string]$SubnetName,

  [parameter()]
  [string]$DestinationContainer="vhds",

  [parameter()]
  [switch]$ShutdownVM
)



## Validation ## 

# Validate source virtual machine 
Select-AzureSubscription $SourceSubscription

$sourceVM = Get-AzureVM -ServiceName $SourceServiceName -Name $VirtualMachineName

if($sourceVM -eq $null)
{
    Write-Error "Virtual Machine $VirtualMachineName in cloud service $SourceServiceName cannot be accessed using the subscription $SourceSubscription"
    return
}

# Validate destination cloud service and storage account 
Select-AzureSubscription $DestinationSubscription

# Required to create storage account if it does not exist
$g_DestinationStorageAccountLocation = ""

# Used to track disk copy status
$g_diskCopyStates = @()

# If part of a vnet save the affinity group for later reference
$g_vnetAffinityGroup = ""

# The name of the container to locally backup the virtual machine disks to. 
$g_BackupContainer = "vmbackup"

if($PSCmdlet.ParameterSetName -eq "VNET"){
    # Validate VNET and Subnet Settings 
    $vnetXMLPath = Join-Path $env:TEMP "NetworkConfig.xml"
    Get-AzureVNetConfig -ExportToFile $vnetXMLPath

    [xml] $vnetXML = Get-Content $vnetXMLPath

    $vnetExists = $false
    $subnetExists = $false
    foreach($tmpVNET in $vnetXML.NetworkConfiguration.VirtualNetworkConfiguration.VirtualNetworkSites.VirtualNetworkSite)
    {
        if($tmpVNET.name -eq $VNETName)
        {
            $vnetExists = $true
            $g_vnetAffinityGroup = $tmpVNET.AffinityGroup
            $DestinationAG = Get-AzureAffinityGroup -Name $g_vnetAffinityGroup
            $g_DestinationStorageAccountLocation = $DestinationAG.Location 

            foreach($tmpSubnet in $tmpVNET.Subnets.Subnet)
            {
                if($tmpSubnet.name -eq $SubnetName)
                {
                    $subnetExists = $true
                    break
                }
            }
            break
        }
    }

    if($vnetExists -eq $false)
    {
        Write-Error "VNET $VNETName does not exist in $DesinationSubscription"
        return
    }
    
    if($subnetExists -eq $false)
    {
        Write-Error "Subnet $subnet does not exist in $DesinationSubscription"
        return
    }
}
else
{
    $g_DestinationStorageAccountLocation = $Location 

    $existingSubnet = $sourceVM | Get-AzureSubnet

    if($existingSubnet -ne $null)
    {
        Write-Host "Not deploying to a virtual network. Existing Subnet will be removed from Virtual Machine configuration." -ForegroundColor Yellow
    }
    
}

if((Get-AzureService -ServiceName $DestinationServiceName -ErrorAction SilentlyContinue ) -eq $null)
{
    # doesn't exist in destination subscripton 
    # check if can create (created later)
    if((Test-AzureName -Service $DestinationServiceName) -eq $true)
    {
        Write-Error "Destination Cloud Service $DestinationServiceName already exists in another subscription. Choose another name to continue." 
        return 
    }
}
else
{
    $tmpDestService = Get-AzureService -ServiceName $DestinationServiceName

    if($PSCmdlet.ParameterSetName -eq "VNET")
    {
        if($tmpDestService.AffinityGroup -ne $g_vnetAffinityGroup)
        {
            Write-Error "Existing Destination Cloud Service is not in virtual network affinity group location."
            return
        }
    }
    else 
    {
        if($tmpDestService.Location -ne $g_DestinationStorageAccountLocation)
        {
            Write-Error "Existing Destination Cloud Service Location does not match specified location or virtual network affinity group location."
            return
        }
    }
}

if((Get-AzureStorageAccount -StorageAccountName $DestinationStorageAccount -ErrorAction SilentlyContinue) -eq $null)
{
    # doesn't exist in destination subscripton 
    # check if can create
    if((Test-AzureName -Storage $DestinationStorageAccount) -eq $true)
    {
        Write-Error "Destination Storage Account $DestinationStorageAccount already exists in another subscription. Choose another name to continue"
        return
    }
    else
    {
        New-AzureStorageAccount -StorageAccountName $DestinationStorageAccount -Location $g_DestinationStorageAccountLocation
    }
}
else 
{
    # Destination storage account exists 
    # Validate storage account location matches destination location
    $tmpDestStorage = Get-AzureStorageAccount -StorageAccountName $DestinationStorageAccount 
    $templocation=$tmpDestStorage.GeoPrimaryLocation
    # DS - 1. Fixed issues with Location variable with new Azure SDK version
    if($tmpDestStorage.GeoPrimaryLocation -ne $g_DestinationStorageAccountLocation)
    {
        Write-Error "Destination Storage Account Location $templocation does not match specified location or virtual network affinity group location $g_DestinationStorageAccountLocation."
        return
    }
}

# Shutdown if specified 
if($ShutdownVM.IsPresent)
{
    Select-AzureSubscription $SourceSubscription
    Write-Output "Stopping Virtual Machine $VirtualMachineName" 
    Stop-AzureVM -ServiceName $SourceServiceName -Name $sourceVM.Name -Force
}

$disk_configs = @{}


# Copies to local storage account 
# Returns URI to backed up disk 
function BackupDisk($diskUri)
{
    Select-AzureSubscription $SourceSubscription
    $vhdName = $diskUri.Segments[$diskUri.Segments.Length - 1].Replace("%20"," ") # fix encoding for space in data disk name
    $sourceContainer = $diskUri.Segments[$diskUri.Segments.Length - 2].Replace("/", "")
    $storageAccount = $diskUri.Host.Replace(".blob.core.windows.net", "")
    $storageAccountKey = (Get-AzureStorageKey -StorageAccountName $storageAccount).Primary
    $context = New-AzureStorageContext -StorageAccountName $storageAccount -StorageAccountKey $storageAccountKey
    
    if((Get-AzureStorageContainer -Name $g_BackupContainer -Context $context -ErrorAction SilentlyContinue) -eq $null)
    {
        New-AzureStorageContainer -Name $g_BackupContainer -Context $context | Out-Null
        
        while((Get-AzureStorageContainer -Name $g_BackupContainer -Context $context -ErrorAction SilentlyContinue) -eq $null)
        {
            Write-Host "Pausing to ensure container $g_BackupContainer is created.." -ForegroundColor Green
            Start-Sleep 10
        }
    }

    $backupUri = "https://$storageAccount.blob.core.windows.net/$g_BackupContainer/$vhdName"

    Write-Host "Backing up disk $vhdName to local storage account" -ForegroundColor Green
    Start-AzureStorageBlobCopy -SrcContainer $sourceContainer -SrcBlob $vhdName -DestContainer $g_BackupContainer -DestBlob $vhdName -Context $context -Force | Out-Null

    $backupUri = [System.Uri] $backupUri
    return $backupUri
}

# Copies to remote storage account
# Returns blob copy state to poll against
function StartCopyDisk($sourceDiskUri, $diskName, $OS, $destStorageAccount, $destContainer)
{
    Select-AzureSubscription $SourceSubscription    
    $sourceStorageAccount = $sourceDiskUri.Host.Replace(".blob.core.windows.net", "")
    Set-AzureSubscription -SubscriptionName $SourceSubscription -CurrentStorageAccountName $sourceStorageAccount

    $vhdName = $sourceDiskUri.Segments[$sourceDiskUri.Segments.Length - 1].Replace("%20"," ") # fix encoding for space in data disk name
    $sourceContainer = $sourceDiskUri.Segments[$sourceDiskUri.Segments.Length - 2].Replace("/", "")

    $sourceStorageAccountKey = (Get-AzureStorageKey -StorageAccountName $sourceStorageAccount).Primary
    $sourceContext = New-AzureStorageContext -StorageAccountName $sourceStorageAccount -StorageAccountKey $sourceStorageAccountKey

    Select-AzureSubscription $DestinationSubscription
    $destStorageAccountKey = (Get-AzureStorageKey -StorageAccountName $destStorageAccount).Primary
    $destContext = New-AzureStorageContext -StorageAccountName $destStorageAccount -StorageAccountKey $destStorageAccountKey
    if((Get-AzureStorageContainer -Name $destContainer -Context $destContext -ErrorAction SilentlyContinue) -eq $null)
    {
        New-AzureStorageContainer -Name $destContainer -Context $destContext | Out-Null

        while((Get-AzureStorageContainer -Name $destContainer -Context $destContext -ErrorAction SilentlyContinue) -eq $null)
        {
            Write-Host "Pausing to ensure container $destContainer is created.." -ForegroundColor Green
            Start-Sleep 10
        }
    }

    # Save for later disk registration 
    $destinationUri = "https://$destStorageAccount.blob.core.windows.net/$destContainer/$vhdName"
    
    if($OS -eq $null)
    {
        $disk_configs.Add($diskName, "$destinationUri")
    }
    else
    {
       $disk_configs.Add($diskName, "$destinationUri;$OS")
    }

    $copyState = Start-AzureStorageBlobCopy -SrcBlob $vhdName -SrcContainer $sourceContainer -SrcContext $sourceContext -DestContainer $destContainer -DestBlob $vhdName -DestContext $destContext -Force

    return $copyState
}

# Backup OS Disk
$osdisk = $sourceVM | Get-AzureOSDisk

$osBackupUri = BackupDisk $osdisk.MediaLink
$ddBackupUris = @()

# Backup any data disks
foreach($dduri in ($sourceVM | Get-AzureDataDisk))
{
    $ddBackupUris += BackupDisk $dduri.MediaLink
}

# Copy disks using the async API from the backup URL to the destination storage account
$g_diskCopyStates += StartCopyDisk -sourceDiskUri $osBackupUri -destStorageAccount $DestinationStorageAccount -destContainer $DestinationContainer -diskName $osdisk.DiskName -OS $osdisk.OS


$sourceVM | Get-AzureDataDisk | foreach {
   $g_diskCopyStates += StartCopyDisk -sourceDiskUri $_.MediaLink -destStorageAccount $DestinationStorageAccount -destContainer $DestinationContainer -diskName $_.DiskName
}

function CheckBlobCopyStatus()
{
    param($diskCopyStates)
    do
    {
        $backupComplete = $true
        Write-Host "Checking Disk Copy Status for VM Copy" -ForegroundColor Green
        foreach($diskCopy in $diskCopyStates)
        {
            $state = $diskCopy | Get-AzureStorageBlobCopyState | Format-Table -AutoSize -Property Status,BytesCopied,TotalBytes,Source
            if($state -ne "Success")
            {
                $backupComplete = $true
                Write-Host "Current Status" -ForegroundColor Green
                $hideHeader = $false
                $inprogress = 0
                $complete = 0
                foreach($diskCopyTmp in $diskCopyStates)
                { 
                    $stateTmp = $diskCopyTmp | Get-AzureStorageBlobCopyState
                    $source = $stateTmp.Source
                    if($stateTmp.Status -eq "Success")
                    {
                        Write-Host (($stateTmp | Format-Table -HideTableHeaders:$hideHeader -AutoSize -Property Status,BytesCopied,TotalBytes,Source | Out-String)) -ForegroundColor Green
                        $complete++
                    }
                    elseif(($stateTmp.Status -like "*failed*") -or ($stateTmp.Status -like "*aborted*"))
                    {
                        Write-Error ($stateTmp | Format-Table -HideTableHeaders:$hideHeader -AutoSize -Property Status,BytesCopied,TotalBytes,Source | Out-String)
                        return $false
                    }
                    else
                    {
                        Write-Host (($stateTmp | Format-Table -HideTableHeaders:$hideHeader -AutoSize -Property Status,BytesCopied,TotalBytes,Source | Out-String)) -ForegroundColor DarkYellow
                        $backupComplete = $false
                        $inprogress++
                    }
                    $hideHeader = $true
                }
                if($backupComplete -eq $false)
                {
                    Write-Host "$complete Blob Copies are completed with $inprogress that are still in progress." -ForegroundColor Magenta
                    Write-Host "Pausing 30 seconds before next status check." -ForegroundColor Green 
                    Start-Sleep 30
                }
                else
                {
                    Write-Host "Disk Copy Complete" -ForegroundColor Green
                    break 
                }
            }
        }
    } while($backupComplete -ne $true) 
    Write-Host "Successfully Copied up all Disks" -ForegroundColor Green
}


# Wait for disks to complete copying
CheckBlobCopyStatus -diskCopyStates $g_diskCopyStates

# Register Disks

Write-Host "Registering Copied Disk in Destination Subscription" -ForegroundColor Green
Select-AzureSubscription $DestinationSubscription

foreach($diskName in $disk_configs.Keys)
{
    $diskConfig = $disk_configs[$diskName].Split(";")
    if($diskConfig.Length -gt 1)
    {
        Add-AzureDisk -DiskName $diskName-$DestinationVirtualMachineName -OS $diskConfig[1] -MediaLocation $diskConfig[0]
    }
    else
    {
        Add-AzureDisk -DiskName $diskName-$DestinationVirtualMachineName -MediaLocation $diskConfig[0]
    }
}

# Export source virtual machine configuration 
Select-AzureSubscription $SourceSubscription

$configFile = $sourceVM.Name + ".xml"
$configPath = Join-Path $env:TEMP $configFile
Write-Host "Saving Virtual Machine Configuration to $configPath" -ForegroundColor Green
Export-AzureVM -ServiceName $SourceServiceName -Name $VirtualMachineName -Path $configPath

[xml] $configVMXML = Get-Content $configPath
# DS.BEGIN - 2.Modify disk name appending VM new name to be able to copy VM within same subscription and renaming VM to destination selected name
$configVMXML.PersistentVM.OSVirtualHardDisk.DiskName = $configVMXML.PersistentVM.OSVirtualHardDisk.DiskName + "-" + $DestinationVirtualMachineName
$configVMXML.PersistentVM.RoleName = $DestinationVirtualMachineName
$configVMXML.Save($configPath)
# DS.END - 2.Modify disk name appending VM new name to be able to copy VM within same subscription and renaming VM to destination selected name

# Import and create virtual machine in destination subscription
Select-AzureSubscription $DestinationSubscription

$serviceExists = $false
$deploymentExists = $false

if((Get-AzureService -ServiceName $DestinationServiceName -ErrorAction SilentlyContinue) -ne $null)
{
    $serviceExists = $true
}

if((Get-AzureDeployment -ServiceName $DestinationServiceName -Slot Production -ErrorAction SilentlyContinue) -ne $null)
{
    $deploymentExists = $true
}


$vmConfig = Import-AzureVM -Path $configPath

Set-AzureSubscription -SubscriptionName $DestinationSubscription -CurrentStorageAccountName $DestinationStorageAccount

Write-Host "Creating virtual machine in destination subscription" -ForegroundColor Green

if($PSCmdlet.ParameterSetName -eq "VNET")
{
    $vmConfig | Set-AzureSubnet -SubnetNames $SubnetName

    if($serviceExists -eq $false -and $deploymentExists -eq $false)
    {
        $vmConfig | New-AzureVM -ServiceName $DestinationServiceName -VNetName $VNETName -AffinityGroup $g_vnetAffinityGroup
    }
    elseif($serviceExists -eq $true -and $deploymentExists -eq $false)
    {
        $vmConfig | New-AzureVM -ServiceName $DestinationServiceName -VNetName $VNETName 
    }
    else
    {
       $vmConfig | New-AzureVM -ServiceName $DestinationServiceName 
    }
}
else
{
    $existingSubnet = $vmConfig | Get-AzureSubnet

    # Remove existing subnet since we are not deploying to a virtual network.
    if($existingSubnet -ne $null)
    {
        $vmConfig.ConfigurationSets[0].SubnetNames = $null
    }

    if($serviceExists -eq $false)
    {
        $vmConfig | New-AzureVM -ServiceName $DestinationServiceName -Location $Location
    }
    else
    {
        $vmConfig | New-AzureVM -ServiceName $DestinationServiceName
    }
}


Write-Host "Virtual Machine Copy is Complete. Check script execution for any errors." -ForegroundColor Green



