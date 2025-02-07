<#
	output.ps1 could output the execution commands, and then
	pass the content to `Invoke-Expression` via pipe character
 #>

$ErrorActionPreference = 'Stop'
$WarningPreference = 'SilentlyContinue'
$VerbosePreference = 'SilentlyContinue'
$DebugPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'

# create directories on the host
# windows docker only can mount the existing path into container
try
{
    New-Item -Force -ItemType Directory -Path @(
        "c:\host\opt"
        "c:\host\opt\bin"
        "c:\host\opt\cni"
        "c:\host\opt\cni\bin"
        "c:\host\etc"
        "c:\host\etc\rancher"
        "c:\host\etc\rancher\wins"
        "c:\host\etc\kubernetes"
        "c:\host\etc\kubernetes\bin"
        "c:\host\etc\cni"
        "c:\host\etc\cni\net.d"
        "c:\host\etc\nginx"
        "c:\host\etc\nginx\logs"
        "c:\host\etc\nginx\temp"
        "c:\host\etc\nginx\conf"
        "c:\host\etc\kube-flannel"
        "c:\host\var"
        "c:\host\var\run"
        "c:\host\var\log"
        "c:\host\var\log\pods"
        "c:\host\var\log\containers"
        "c:\host\var\lib"
        "c:\host\var\lib\cni"
        "c:\host\var\lib\rancher"
        "c:\host\var\lib\kubelet"
        "c:\host\var\lib\kubelet\volumeplugins"
        "c:\host\run"
        "c:\host\ProgramData\docker\certs.d"
    ) | Out-Null
} catch { }

# copy cleanup.ps1 & wins.exe to the host
# wins needs to run as a server on the host to accept the request from container
try
{
    Copy-Item -Force -Destination "c:\host\etc\rancher" -Path @(
        "c:\etc\rancher\utils.psm1"
        "c:\etc\rancher\cleanup.ps1"
        "c:\Windows\wins.exe"
    )
} catch { }

$verfication = @"
Log-Info "Detecting running permission ..."
if (-not (Is-Administrator))
{
    Log-Fatal "You need elevated Administrator privileges in order to run this script, start Windows PowerShell by using the Run as Administrator option"
}

Log-Info "Detecting host CPU reservation ..."
try
{
    `$cpuLogicalProccessors = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty NumberOfLogicalProcessors
    if (`$cpuLogicalProccessors -le 1) {
        Log-Fatal "The CPU resource could not satisfy the default reservation for both Windows system and Kuberentes components, please increase the CPU resource to more than 2 logic processors"
    } elseif (`$cpuLogicalProccessors -lt 2) {
        Log-Warn "The CPU resource only satisfies the lowest limit for running Kubernetes components"
        Log-Warn "Please increase the CPU resource to more than 2 logic processors if you are unable to schedule Pods on this Node"
    }
}
catch
{
    Log-Warn "Could not detect the CPU resource: `$(`$_.Exception.Message)"
}

Log-Info "Detecting host RAM reservation ..."
try
{
    `$lowestLimitGB = 2.5
    `$systemType = Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty PCSystemType
    if (`$systemType -eq 1) {
        # system with GUI
        `$lowestLimitGB = 4.5
    }

    `$ramTotalGB = `$(Get-WmiObject -Class Win32_ComputerSystem | Select-Object -ExpandProperty TotalPhysicalMemory)/1GB
    if (`$ramTotalGB -lt `$lowestLimitGB) {
        Log-Fatal "The RAM resource could not satisfy the default reservation for both Windows system and Kubernetes components, please increase the RAM resource to more than `$lowestLimitGB GB"
    }

    `$ramAvailableMB = `$(Get-WmiObject -Class Win32_PerfFormattedData_PerfOS_Memory | Measure-Object -Sum -Property AvailableBytes | Select-Object -ExpandProperty Sum)/1MB
    if (`$ramAvailableMB -le 500) {
        Log-Fatal "The RAM resource could not satisfy the default reservation for Kuberentes components, please increase the RAM resource to more than `$lowestLimitGB GB"
    } elseif (`$ramAvailableMB -le 600) {
        Log-Warn "The RAM resource only satisfies the lowest limit for running Kubernetes components"
        Log-Warn "Please increase the RAM resource to more than `$lowestLimitGB GB if you are unable to schedule Pods on this Node"
    }
}
catch
{
    Log-Warn "Could not detect the RAM resource: `$(`$_.Exception.Message)"
}

Log-Info "Detecting host DISK reservation ..."
try
{
    `$diskAvaliableGB = `$(Get-WmiObject -Class Win32_LogicalDisk | Where-Object {`$_.DeviceID -eq "C:"} | Select-Object -ExpandProperty Size)/1GB
    if (`$diskAvaliableGB -lt 29.5) {
        Log-Fatal "The DISK resource could not satisfy the default reservation for both Windows system and Kubernetes components, please increase the DISK resource to more than 30 GB"
    } elseif (`$diskAvaliableGB -lt 49.5) {
        Log-Warn "The DISK resource only satisfies the lowest limit for running Kubernetes components"
        Log-Warn "Please increase the DISK resource to more than 50 GB if you are unable to schedule Pods on this Node"
    }
}
catch
{
    Log-Warn "Could not detect the DISK resource: `$(`$_.Exception.Message)"
}

Log-Info "Detecting host system locale ..."
`$sysLocale = Get-WinSystemLocale | Select-Object -ExpandProperty "IetfLanguageTag"
if (-not `$sysLocale.StartsWith('en-'))
{
    Log-Fatal "Only support with English System Locale"
}

Log-Info "Detecting host Docker name pipe existing ..."
`$dockerNPipe = Get-ChildItem //./pipe/ -ErrorAction Ignore | ? Name -eq "docker_engine"
if (-not `$dockerNPipe)
{
    Log-Warn "Default docker named pipe is not available"
    Log-Warn "Please create '//./pipe/docker_engine' named pipe to access docker daemon if docker errors occur"
}

Log-Info "Detecting host Docker release version ..."
try
{
    `$dockerPlatform = docker.exe version -f "{{.Server.Platform.Name}}"
    if (-not (`$dockerPlatform -like '*Enterprise*'))
    {
        Log-Fatal "Only support with Docker EE"
    }
}
catch
{
    Log-Fatal "Could not found Docker service: `$(`$_.Exception.Message)"
}

Log-Info "Detecting host network interface ..."
`$vNetAdapters = Get-HnsNetwork | Select-Object -ExpandProperty "Subnets" | Select-Object -ExpandProperty "GatewayAddress"
`$allNetAdapters = Get-WmiObject -Class Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" | Sort-Object Index | ForEach-Object { `$_.IPAddress[0] } | Where-Object { -not (`$vNetAdapters -contains `$_) }
`$networkCount = `$allNetAdapters | Measure-Object | Select-Object -ExpandProperty "Count"
if (`$networkCount -gt 1)
{
    Log-Warn "More than 1 network interfaces are found: `$(`$allNetAdapters -join ", ")"
    Log-Warn "Please indicate --internal-address when adding failed"
}

Log-Info "Configuring host Docker startup mode to automatical ..."
try
{
    Get-Service -Name "docker" -ErrorAction Ignore | Where-Object {`$_.StartType -ne "Automatic"} | Set-Service -StartupType Automatic
}
catch
{
    Log-Warn "Could not configure the docker to start automatically: `$(`$_.Exception.Message)"
    Log-Warn "Please configure the 'StartupType' to 'Automatic' for the docker service"
}

Log-Info "Enabling host msiscsi service to support iscsi storage ..."
`$svcMsiscsi = Get-Service -Name "msiscsi" -ErrorAction Ignore
if (`$svcMsiscsi -and (`$svcMsiscsi.Status -ne "Running"))
{
    Set-Service -Name "msiscsi" -StartupType Automatic -WarningAction Ignore
    Start-Service -Name "msiscsi" -ErrorAction Ignore -WarningAction Ignore
    if (-not `$?) {
        Log-Warn "Failed to start msiscsi service, you may not be able to use the iSCSI flexvolume properly"
    }
}
"@

# allow user to disable the verfication
if ($env:WITHOUT_VERIFICATION -eq "true") {
    $verfication = ""
}

Out-File -Encoding ascii -FilePath "c:\host\etc\rancher\bootstrap.ps1" -InputObject @"
`$ErrorActionPreference = 'Stop'
`$WarningPreference = 'SilentlyContinue'
`$VerbosePreference = 'SilentlyContinue'
`$DebugPreference = 'SilentlyContinue'
`$InformationPreference = 'SilentlyContinue'

# import modules
Import-Module -WarningAction Ignore -Name "`$PSScriptRoot\utils.psm1"

# remove script
Remove-Item -Force -Path "`$PSScriptRoot\bootstrap.ps1" -ErrorAction Ignore

$verfication

# repair Get-GcePdName method
# this's a stopgap, we could drop this after https://github.com/kubernetes/kubernetes/issues/74674 fixed
# related: rke-tools container
`$getGcePodNameCommand = Get-Command -Name "Get-GcePdName" -ErrorAction Ignore
if (-not `$getGcePodNameCommand)
{
    `$profilePath = "`$PsHome\profile.ps1"
    if (-not (Test-Path `$profilePath)) {
        New-Item -ItemType File -Path `$profilePath -ErrorAction Ignore | Out-Null
    }
    `$appendProfile = @'
Unblock-File -Path DLLPATH -ErrorAction Ignore
Import-Module -Name DLLPATH -ErrorAction Ignore
'@
    Add-Content -Path `$profilePath -Value `$appendProfile.replace('DLLPATH', "c:\run\GetGcePdName.dll") -ErrorAction Ignore
}

# clean up the stale HNS network if required
try
{
    # warm up HNS network
    1..5 | ForEach-Object { Invoke-HNSRequest -Method "GET" -Type "networks" | Out-Null }

    # remove the HNS networks
    Invoke-HNSRequest -Method "GET" -Type "networks" | Where-Object {@('cbr0', 'vxlan0') -contains `$_.Name} | ForEach-Object {
        Log-Info "Cleaning up stale HNSNetwork `$(`$_.Name) ..."
        Invoke-HNSRequest -Method "DELETE" -Type "networks" -Id `$_.Id
    }

    # remove the HNS policies
    Invoke-HNSRequest -Method "GET" -Type "policylists" | Where-Object {-not [string]::IsNullOrEmpty(`$_.Id)} | ForEach-Object {
        Log-Info "Cleaning up HNSPolicyList `$(`$_.Id) ..."
        Invoke-HNSRequest -Method "DELETE" -Type "policylists" -Id `$_.Id
    }
}
catch
{
    Log-Warn "Could not clean: `$(`$_.Exception.Message)"
}

# output wins config
@{
    whiteList = @{
        processPaths = @(
            "c:\etc\wmi-exporter\wmi-exporter.exe"
            "c:\etc\kubernetes\bin\kube-proxy.exe"
            "c:\etc\kubernetes\bin\kubelet.exe"
            "c:\etc\nginx\nginx.exe"
            "c:\opt\bin\flanneld.exe"
        )
    }
} | ConvertTo-Json -Compress -Depth 32 | Out-File -NoNewline -Encoding utf8 -Force -FilePath "c:\etc\rancher\wins\config"

# register wins
Start-Process -NoNewWindow -Wait ``
    -FilePath "c:\etc\rancher\wins.exe" ``
    -ArgumentList "srv app run --register"

# start wins
Start-Service -Name "rancher-wins" -ErrorAction Ignore

# run agent
Start-Process -NoNewWindow -Wait ``
    -FilePath "docker.exe" ``
    -ArgumentList "run -d --restart=unless-stopped -v //./pipe/docker_engine://./pipe/docker_engine -v c:/ProgramData/docker/certs.d:c:/etc/docker/certs.d -v c:/etc/kubernetes:c:/etc/kubernetes -v //./pipe/rancher_wins://./pipe/rancher_wins -v c:/etc/rancher/wins:c:/etc/rancher/wins $($env:AGENT_IMAGE) execute $($args -join " ")"
"@

Write-Output -InputObject "c:\etc\rancher\bootstrap.ps1"
