function Register-IPAddress()
{    
    Param(      
        [Parameter(Mandatory=$true)] [string] $zone,
        [Parameter(Mandatory=$true)] [string] $serverName
    )


    $zoneId = (Get-R53HostedZones | where {$_.Name -eq "$zone"}).Id
    
   # Defines Resourse Record Value with IP
    $ipAddress = (Get-WmiObject Win32_NetworkAdapterConfiguration -Filter "IPEnabled = True" `
                    | Where-Object { $_.IPAddress -match '^10\.' }).IPAddress `
                    | Select-Object -First 1

    $resourceRecord = (new-object Amazon.Route53.Model.ResourceRecord)
    $resourceRecord.Value= $ipAddress

    # Define ResourceRecordSet
    $resourceRecordSet =  (new-object Amazon.Route53.Model.ResourceRecordSet)
    $resourceRecordSet.Name = $serverName + "." + $zone
    $resourceRecordSet.TTL = 60
    $resourceRecordSet.Type = "A"
    $resourceRecordSet.ResourceRecords = $resourceRecord    

    # Delete Record If Exists
    $myRecordSet = (Get-R53ResourceRecordSet -HostedZoneId "$zoneId").ResourceRecordSets `
                     | where {$_.Name -eq ($serverName + "." + $zone) }
    if ($myRecordSet -ne $null)
    {
        "Record Already Exists, deleting."
        $change= (new-object Amazon.Route53.Model.Change)
        $change.Action = "DELETE"
        $change.ResourceRecordSet = $myRecordSet 

        Edit-R53ResourceRecordSet -HostedZoneId "$zoneId" -ChangeBatch_Changes $change        
    }


    # Create Record
    $change= (new-object Amazon.Route53.Model.Change)
    $change.Action = "CREATE"
    $change.ResourceRecordSet = $resourceRecordSet

    Edit-R53ResourceRecordSet -HostedZoneId "$zoneId" -ChangeBatch_Changes $change
}

function Get-NIC
{
    (Get-WmiObject -Class Win32_NetworkAdapterConfiguration | where { $_.IPAddress -like "*10.*"})
}

function Update-DNSSuffix
{
    Param(      
        [Parameter(Mandatory=$true)] [string] $tld
    )
  
    # Get DNS Suffixes form NIC
    $myNic =  Get-NIC
    $suffixes = (Get-NIC).DNSDomainSuffixSearchOrder

    # Add TLD to suffix
    if ($suffixes -notContains "$tld")
    {
     "Adding $tkd to DNS search order:"
     $suffixes +="$tld"
     invoke-wmimethod -Class win32_networkadapterconfiguration -Name setDNSSuffixSearchOrder  -ArgumentList @($suffixes), $null
    }
    else
    {
        "DNS Search order already contains $tld"
    }

    # Output new config
    (Get-NIC).DNSDomainSuffixSearchOrder
}

function AllowScripts()
{
    # Update Powershell Exec Policy
    Set-ExecutionPolicy RemoteSigned -Scope LocalMachine -Force
}

function CreateUsers()
{
    Param(      
        [Parameter(Mandatory=$true)] [string] $bucketName,
        [Parameter(Mandatory=$true)] [string] $key       
    )
    
    Import-Module carbon
    
    Set-DefaultAWSRegion us-west-1
    $folderName = "c:\temp"
    mkdir -force $folderName
    cd "$folderName"
    $fileName = "$folderName\" + $key.Split('/')[-1]
    Read-S3ObJect  -BucketName "$bucketName" -Key "$key" -File $fileName
    $users = ([xml] (gc $fileName)).users.user
    foreach ($user in $users)
    {
        Create-User $user.name $user.password
        $groups = $user.groups.Split(',')
        foreach ($group in $groups)
        {
            $group = $group.Trim()
            Add-GroupMember -Name $group -Member $user.name
        }
    }

    ri -force "C:\temp\users.xml"
}

function Disable-ComplexPasswords()
{
  # Export Security Config
  $fileName="c:\temp\old.cfg"
  $newFile ="c:\temp\new.cfg"
  mkdir -force (Split-Path $fileName)
  secedit /export /cfg $fileName

  # Change Password Requirements
  (gc $fileName) | % {$_ -replace "PasswordComplexity = 1", "PasswordComplexity = 0"} | sc $newFile
  secedit /configure /cfg $newFile /db C:\Windows\security\passwordcomplexity.sdb /areas SECURITYPOLICY
  
  if (test-path $fileName) {rm -force $fileName}
  if (test-path $newFile) {rm -force $newFile}  
}

function Create-User
{
    Param(      
        [Parameter(Mandatory=$true)] [string] $userName,
        [Parameter(Mandatory=$true)] [string] $password
    )

    # Delete User if already exists
    if (Check-UserExists $userName) {Delete-User $userName}

    # Create a User
    $objOu = [ADSI]"WinNT://$env:computername"
    $objUser = $objOU.Create("User", $userName)
    $objUser.setpassword($password)
    $objUser.SetInfo()

    # Set User Password to Never Expire
    $ADS_UF_DONT_EXPIRE_PASSWD = 65536
    $u = [adsi]"WinNT://$env:computername/$userName,user"
    $u.invokeSet("userFlags", ($u.userFlags[0] -BOR $ADS_UF_DONT_EXPIRE_PASSWD))
    $u.commitChanges()

}

function Delete-User
{
    Param(      
        [Parameter(Mandatory=$true)] [string] $userName
    )

    $objOu = [ADSI]"WinNT://$env:ComputerName" 
    $objOu.Delete("User",$userName) 
}

function Check-UserExists
{
    Param(      
        [Parameter(Mandatory=$true)] [string] $userName
    )
    $objComputer = [ADSI]("WinNT://$env:computername")

    $colUsers = ($objComputer.psbase.children |
                    Where-Object {$_.psBase.schemaClassName -eq "User"} |
                        Select-Object -expand Name)

    $blnFound = $colUsers -contains "$userName"

    $blnFound
}



$region = (new-object net.webclient).DownloadString("http://169.254.169.254/latest/meta-data/placement/availability-zone") -replace ".$"
Set-DefaultAWSRegion $region
