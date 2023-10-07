Connect-CIServer -Server "$Env:VCD_SERVER" -Org "$Env:VCD_ORG" -User "$Env:VCD_USER" -Pass "$Env:VCD_PASSWORD"
$a = Get-CIVApp -OrgVdc "$Env:VCD_ORG_VDC"
if (-not $?)
{
    exit
}
Write-Output success >> "$Env:INSTANCE_DATA"
for($i = 0; $i -le $a.Length-1; $i++)
{
    $a.GetValue($i).Name >> "$Env:INSTANCE_DATA"
}