Azure-VM-clone
==============

Azure Powershell script to clone VMs accross Subscription or within the same.
The Original script comes from:
http://gallery.technet.microsoft.com/scriptcenter/Copy-a-Virtual-Machine-83d192a5#content


SYNOPSIS
========
  This cmdlet takes an existing virtual machine, makes a copy of its disks in the local storage account and then copies the virtual machine to a seperate subscription.
  Running this script can take several minutes and up to hours if copying a virtual machine to a remote storage account.

  Ensure the source subscription and the destination subscription are configured for PowerShell access.
  
  Verify by running the following command to ensure that both subscriptions are listed: 
  Get-AzureSubscription | select SubscriptionName 

  New functionality added by David Sabater:
  1. Fixed issues with Location variable with new Azure SDK version
  2. Modify disk name appending VM new name to be able to copy VM within same subscription and renaming VM to new one
  

DESCRIPTION
===========
  This script works by creating a copy of all of the disks of the virtual machine to a container in the same storage account. 
  You may optionally specify -ShutdownVM to shut the virtual machine down to ensure the backup is clean first.

  Once the disks are backed up locally the script validates that the remote cloud service name, storage account, virtual network and subnet are all accessible from the current configuration.
  
  Once validation is complete the script will copy the disks from the backup in the source storage account to the destination storage account. 

  Once the copy is complete the script will register the disks in the subscription with the same disk names but appending the new Virtual Machine name to match new Virtual Machine cloned, this gives the capability to clone VM within same Subscription

  The script next will export the virtual machine settings to a local file on the file system and import them into the target subscription and create the virtual machine with the new name selected. 
   
  
EXAMPLE
=======
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
