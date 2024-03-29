﻿<#

See logons from target host to other hosts:

    $l.logonevent4648 | select SourceAccount,TargetAccount,TargetServer,Count,Times | ft

See logons to target host:

    $l.logonevent4624 | select NewLogonAccount,LogonType,WorkstationName,SourceNetworkAddress,Count | sort -desc Count | ft

See RDP logons from target hosts to other hosts:

    $l.RdpClientData | select SourceAccount,TargetServer,TargetAccount


#>

function Get-ComputerDetails
{
<#
.SYNOPSIS

This script is used to get useful information from a computer.

Function: Get-ComputerDetails
Author: Joe Bialek, Twitter: @JosephBialek
Required Dependencies: None
Optional Dependencies: None
Version: 1.1

.DESCRIPTION

This script is used to get useful information from a computer. Currently, the script gets the following information:
-Explicit Credential Logons (Event ID 4648)
-Logon events (Event ID 4624)
-AppLocker logs to find what processes are created
-PowerShell logs to find PowerShell scripts which have been executed
-RDP Client Saved Servers, which indicates what servers the user typically RDP's in to

.PARAMETER ToString

Switch: Outputs the data as text instead of objects, good if you are using this script through a backdoor.
	
.EXAMPLE

Get-ComputerDetails
Gets information about the computer and outputs it as PowerShell objects.

Get-ComputerDetails -ToString
Gets information about the computer and outputs it as raw text.

.NOTES
This script is useful for fingerprinting a server to see who connects to this server (from where), and where users on this server connect to. 
You can also use it to find Powershell scripts and executables which are typically run, and then use this to backdoor those files.

#>

    Param(
        [Parameter(Position=0)]
        [Switch]
        $ToString
    )

    Set-StrictMode -Version 2



    $SecurityLog = Get-EventLog -LogName Security
    $Filtered4624 = Find-4624Logons $SecurityLog
    $Filtered4648 = Find-4648Logons $SecurityLog
    # $AppLockerLogs = Find-AppLockerLogs
    # $PSLogs = Find-PSScriptsInPSAppLog
    $RdpClientData = Find-RDPClientConnections

    if ($ToString)
    {
        Write-Output "Event ID 4624 (Logon):"
        Write-Output $Filtered4624.Values | Format-List
        Write-Output "Event ID 4648 (Explicit Credential Logon):"
        Write-Output $Filtered4648.Values | Format-List
        Write-Output "AppLocker Process Starts:"
        Write-Output $AppLockerLogs.Values | Format-List
        Write-Output "PowerShell Script Executions:"
        Write-Output $PSLogs.Values | Format-List
        Write-Output "RDP Client Data:"
        Write-Output $RdpClientData.Values | Format-List
    }
    else
    {
        $Properties = @{
            LogonEvent4624 = $Filtered4624.Values
            LogonEvent4648 = $Filtered4648.Values
            # AppLockerProcessStart = $AppLockerLogs.Values
            # PowerShellScriptStart = $PSLogs.Values
            RdpClientData = $RdpClientData.Values
        }

        $ReturnObj = New-Object PSObject -Property $Properties
        return $ReturnObj
    }
}


function Find-4648Logons
{
<#
.SYNOPSIS

Retrieve the unique 4648 logon events. This will often find cases where a user is using remote desktop to connect to another computer. It will give the 
the account that RDP was launched with and the account name of the account being used to connect to the remote computer. This is useful
for identifying normal authenticaiton patterns. Other actions that will trigger this include any runas action.

.DESCRIPTION

Retrieve the unique 4648 logon events. This will often find cases where a user is using remote desktop to connect to another computer. It will give the 
the account that RDP was launched with and the account name of the account being used to connect to the remote computer. This is useful
for identifying normal authenticaiton patterns. Other actions that will trigger this include any runas action.

.EXAMPLE

Find-4648Logons
Gets the unique 4648 logon events.

.NOTES

#>
    Param(
        $SecurityLog
    )

    $ExplicitLogons = $SecurityLog | Where {$_.InstanceID -eq 4648}
    $ReturnInfo = @{}

    foreach ($ExplicitLogon in $ExplicitLogons)
    {
        $Subject = $false
        $AccountWhosCredsUsed = $false
        $TargetServer = $false
        $SourceAccountName = ""
        $SourceAccountDomain = ""
        $TargetAccountName = ""
        $TargetAccountDomain = ""
        $TargetServer = ""
        foreach ($line in $ExplicitLogon.Message -split "\r\n")
        {
            if ($line -cmatch "^Subject:$")
            {
                $Subject = $true
            }
            elseif ($line -cmatch "^Account\sWhose\sCredentials\sWere\sUsed:$")
            {
                $Subject = $false
                $AccountWhosCredsUsed = $true
            }
            elseif ($line -cmatch "^Target\sServer:")
            {
                $AccountWhosCredsUsed = $false
                $TargetServer = $true
            }
            elseif ($Subject -eq $true)
            {
                if ($line -cmatch "\s+Account\sName:\s+(\S.*)")
                {
                    $SourceAccountName = $Matches[1]
                }
                elseif ($line -cmatch "\s+Account\sDomain:\s+(\S.*)")
                {
                    $SourceAccountDomain = $Matches[1]
                }
            }
            elseif ($AccountWhosCredsUsed -eq $true)
            {
                if ($line -cmatch "\s+Account\sName:\s+(\S.*)")
                {
                    $TargetAccountName = $Matches[1]
                }
                elseif ($line -cmatch "\s+Account\sDomain:\s+(\S.*)")
                {
                    $TargetAccountDomain = $Matches[1]
                }
            }
            elseif ($TargetServer -eq $true)
            {
                if ($line -cmatch "\s+Target\sServer\sName:\s+(\S.*)")
                {
                    $TargetServer = $Matches[1]
                }
            }
        }

        #Filter out logins that don't matter
        if (-not ($TargetAccountName -cmatch "^DWM-.*" -and $TargetAccountDomain -cmatch "^Window\sManager$"))
        {
            $Key = $SourceAccountName + $SourceAccountDomain + $TargetAccountName + $TargetAccountDomain + $TargetServer
            if (-not $ReturnInfo.ContainsKey($Key))
            {
                $Properties = @{
                    LogType = 4648
                    LogSource = "Security"
                    SourceAccount = $SourceAccountDomain + "\" + $SourceAccountName
                    TargetAccount = $TargetAccountDomain + "\" + $TargetAccountName
                    TargetServer = $TargetServer
                    Count = 1
                    Times = @($ExplicitLogon.TimeGenerated)
                }

                $ResultObj = New-Object PSObject -Property $Properties
                $ReturnInfo.Add($Key, $ResultObj)
            }
            else
            {
                $ReturnInfo[$Key].Count++
                $ReturnInfo[$Key].Times += ,$ExplicitLogon.TimeGenerated
            }
        }
    }

    return $ReturnInfo
}

function Find-4624Logons
{
<#
.SYNOPSIS

Find all unique 4624 Logon events to the server. This will tell you who is logging in and how. You can use this to figure out what accounts do
network logons in to the server, what accounts RDP in, what accounts log in locally, etc...

Function: Find-4624Logons


.DESCRIPTION

Find all unique 4624 Logon events to the server. This will tell you who is logging in and how. You can use this to figure out what accounts do
network logons in to the server, what accounts RDP in, what accounts log in locally, etc...

.EXAMPLE

Find-4624Logons
Find unique 4624 logon events.

#>
    Param (
        $SecurityLog
    )

    $Logons = $SecurityLog | Where {$_.InstanceID -eq 4624}
    $ReturnInfo = @{}

    foreach ($Logon in $Logons)
    {
        $SubjectSection = $false
        $NewLogonSection = $false
        $NetworkInformationSection = $false
        $AccountName = ""
        $AccountDomain = ""
        $LogonType = ""
        $NewLogonAccountName = ""
        $NewLogonAccountDomain = ""
        $WorkstationName = ""
        $SourceNetworkAddress = ""
        $SourcePort = ""

        foreach ($line in $Logon.Message -Split "\r\n")
        {
            if ($line -cmatch "^Subject:$")
            {
                $SubjectSection = $true
            }
            elseif ($line -cmatch "^Logon\sType:\s+(\S.*)")
            {
                $LogonType = $Matches[1]
            }
            elseif ($line -cmatch "^New\sLogon:$")
            {
                $SubjectSection = $false
                $NewLogonSection = $true
            }
            elseif ($line -cmatch "^Network\sInformation:$")
            {
                $NewLogonSection = $false
                $NetworkInformationSection = $true
            }
            elseif ($SubjectSection)
            {
                if ($line -cmatch "^\s+Account\sName:\s+(\S.*)")
                {
                    $AccountName = $Matches[1]
                }
                elseif ($line -cmatch "^\s+Account\sDomain:\s+(\S.*)")
                {
                    $AccountDomain = $Matches[1]
                }
            }
            elseif ($NewLogonSection)
            {
                if ($line -cmatch "^\s+Account\sName:\s+(\S.*)")
                {
                    $NewLogonAccountName = $Matches[1]
                }
                elseif ($line -cmatch "^\s+Account\sDomain:\s+(\S.*)")
                {
                    $NewLogonAccountDomain = $Matches[1]
                }
            }
            elseif ($NetworkInformationSection)
            {
                if ($line -cmatch "^\s+Workstation\sName:\s+(\S.*)")
                {
                    $WorkstationName = $Matches[1]
                }
                elseif ($line -cmatch "^\s+Source\sNetwork\sAddress:\s+(\S.*)")
                {
                    $SourceNetworkAddress = $Matches[1]
                }
                elseif ($line -cmatch "^\s+Source\sPort:\s+(\S.*)")
                {
                    $SourcePort = $Matches[1]
                }
            }
        }

        #Filter out logins that don't matter
        if (-not ($NewLogonAccountDomain -cmatch "NT\sAUTHORITY" -or $NewLogonAccountDomain -cmatch "Window\sManager"))
        {
            $Key = $AccountName + $AccountDomain + $NewLogonAccountName + $NewLogonAccountDomain + $LogonType + $WorkstationName + $SourceNetworkAddress + $SourcePort
            if (-not $ReturnInfo.ContainsKey($Key))
            {
                $Properties = @{
                    LogType = 4624
                    LogSource = "Security"
                    SourceAccount = $AccountDomain + "\" + $AccountName
                    NewLogonAccount = $NewLogonAccountDomain + "\" + $NewLogonAccountName
                    LogonType = $LogonType
                    WorkstationName = $WorkstationName
                    SourceNetworkAddress = $SourceNetworkAddress
                    SourcePort = $SourcePort
                    Count = 1
                    Times = @($Logon.TimeGenerated)
                }

                $ResultObj = New-Object PSObject -Property $Properties
                $ReturnInfo.Add($Key, $ResultObj)
            }
            else
            {
                $ReturnInfo[$Key].Count++
                $ReturnInfo[$Key].Times += ,$Logon.TimeGenerated
            }
        }
    }

    return $ReturnInfo
}


Function Find-RDPClientConnections
{
<#
.SYNOPSIS

Search the registry to find saved RDP client connections. This shows you what connections an RDP client has remembered, indicating what servers the user 
usually RDP's to.

.DESCRIPTION

Search the registry to find saved RDP client connections. This shows you what connections an RDP client has remembered, indicating what servers the user 
usually RDP's to.

.EXAMPLE

Find-RDPClientConnections
Find unique saved RDP client connections.

.NOTES

.LINK

#>
    $ReturnInfo = @{}

    New-PSDrive -Name HKU -PSProvider Registry -Root Registry::HKEY_USERS | Out-Null

    #Attempt to enumerate the servers for all users
    $Users = Get-ChildItem -Path "HKU:\"
    foreach ($UserSid in $Users.PSChildName)
    {
        $Servers = Get-ChildItem "HKU:\$($UserSid)\Software\Microsoft\Terminal Server Client\Servers" -ErrorAction SilentlyContinue

        foreach ($Server in $Servers)
        {
            $Server = $Server.PSChildName
            $UsernameHint = (Get-ItemProperty -Path "HKU:\$($UserSid)\Software\Microsoft\Terminal Server Client\Servers\$($Server)").UsernameHint
                
            $Key = $UserSid + "::::" + $Server + "::::" + $UsernameHint

            if (!$ReturnInfo.ContainsKey($Key))
            {
                $SIDObj = New-Object System.Security.Principal.SecurityIdentifier($UserSid)
                $User = ($SIDObj.Translate([System.Security.Principal.NTAccount])).Value

                $Properties = @{
                    SourceAccount = $User
                    TargetServer = $Server
                    TargetAccount = $UsernameHint
                }

                $Item = New-Object PSObject -Property $Properties
                $ReturnInfo.Add($Key, $Item)
            }
        }
    }

    return $ReturnInfo
}

Get-ComputerDetails
