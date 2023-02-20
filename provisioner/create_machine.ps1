Connect-CIServer -Server "$Env:VCD_SERVER" -Org "$Env:VCD_ORG" -User "$Env:VCD_USER" -Pass "$Env:VCD_PASSWORD"
New-CIVApp -Name "$Env:VAPP_NAME" -OrgVdc "$Env:VCD_ORG_VDC" -VAppTemplate "rhcos OpenShift 4.10.16" -StorageLease $null -RuntimeLease $null
for($i = 0; $i -le 10; $i++)
{
 New-CIVAppNetwork -Direct -ParentOrgVdcNetwork "$Env:VCD_NETWORK" -Vapp "$Env:VAPP_NAME"
 if ( $?)
 {
  break
 }
 Start-Sleep -Seconds 60
}
Remove-CIVAppNetwork -VappNetwork "VM Network" -Confirm:$false
$vm = Get-CIVApp -OrgVdc "$Env:VCD_ORG_VDC" -Name "$Env:VAPP_NAME" | Get-CIVM
$vm.ExtensionData.Name="$Env:VAPP_NAME"
$vm.ExtensionData.UpdateServerData()
$vm = Get-CIVApp -OrgVdc "$Env:VCD_ORG_VDC" -Name "$Env:VAPP_NAME" | Get-CIVM
$memresize = [int]$Env:MEM_MB
$cpuresize = [int]$Env:CPU
for($i = 0; $i -le $vm.ExtensionData.Section[0].Item.Length; $i++)
{
 if($vm.ExtensionData.Section[0].Item[$i].Description.Value -eq "Memory Size")
  {
   $vm.ExtensionData.Section[0].Item[$i].VirtualQuantity.Value = $memresize
  }
 elseif ($vm.ExtensionData.Section[0].Item[$i].Description.Value -eq "Number of Virtual CPUs") {
   $vm.ExtensionData.Section[0].Item[$i].VirtualQuantity.Value = $cpuresize
  }
}
$vm.ExtensionData.Section[0].UpdateServerData()
$vmProductSection = $vm.ExtensionData.GetProductSections()
$vsa = $vmProductSection.ProductSection[0]
$entry1 = New-Object -TypeName VMware.VimAutomation.Cloud.Views.OvfPropertyConfigurationValue  -Property @{Value="aaaa"}
$initarray1 = @( $entry1 )
$entry2 = New-Object -TypeName VMware.VimAutomation.Cloud.Views.OvfPropertyConfigurationValue  -Property @{Value="aaaa"}
$initarray2 = @( $entry2 )
$vsa.Items[0].OvfPropertyConfigurationValue = $initarray1
$vsa.Items[1].OvfPropertyConfigurationValue = $initarray2
$ignitionData = Get-Content -path "$Env:IGN_FILE_PATH_WITH_HOSTNAME_64"
$vsa.Items[0].OvfPropertyConfigurationValue[0].Value = $ignitionData
$vsa.Items[1].OvfPropertyConfigurationValue[0].Value = "base64"
$vmProductSection.UpdateServerData()
$myVappNetwork2 = Get-CIVAppNetwork -Name "$Env:VCD_NETWORK"  -VApp "$Env:VAPP_NAME"
Get-CIVApp -OrgVdc "$Env:VCD_ORG_VDC" -Name "$Env:VAPP_NAME"  | Get-CIVM | Get-CINetworkAdapter | Set-CINetworkAdapter -Connected $true -IPAddressAllocationMode Dhcp  -Primary -VAppNetwork $myVappNetwork2
Update-CIVMDiskSize -VM $vm -BusType paravirtual -BusId 0 -UnitID 0 -NewDiskSize "$ENV:DISKS" -TaskTimeout 600
for($i = 0; $i -le 10; $i++)
{
 Start-CIVApp -VApp "$Env:VAPP_NAME"
 if ( $?)
 {
  exit
 }
 Start-Sleep -Seconds 60
}



