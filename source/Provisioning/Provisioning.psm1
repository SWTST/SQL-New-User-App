Set-DbatoolsInsecureConnection -SessionOnly
Set-ExecutionPolicy -ExecutionPolicy Bypass -Scope CurrentUser

function Get-AllServers {
    param(
        [string]$SqlInstance = "DESKTOP-AD0K85U\MSSQL",
        [string]$JsonPath = ".\config\servers.json",
        [int]$Mode = 1
    )

    if ($mode -eq 1) {
        $servers = Get-DbaRegServer -SqlInstance $SqlInstance -ErrorAction Stop
        return $servers
    }
    if ($mode -eq 2) {
        return (Get-Content $JsonPath -Raw | ConvertFrom-Json)
    }
}
# Get-AllServers

function Get-ServerLogins {
    param(
        [string]$Server,
        [string]$Login
    )

    $check = Get-DbaLogin -SqlInstance $Server -Login $Login
    if ($check) {
        Write-Host("$login - Exists on this server")
        $true
    }
    else {
        Write-Host("$login - Does not exist on this server")
        $false
    }
}
#Get-ServerLogins -Server DESKTOP-AD0K85U\mssql2 -Login DESKTOP-AD0K85U\steve

function Get-ServerRoles {
    param(
        [string]$Server
    )

    $roles = Get-DbaServerRole -SqlInstance $Server
    $roles | Select-Object -Property Role
    Return $roles

}
# Getting top 1 server roles - Tweak logic for app
# $Server1 = Get-AllServers | Select-object -First 1
# Get-ServerRoles -Server $Server1.ServerName

function Get-Databases {
    param (
        [string]$Server
    )
    Get-DbaDatabase -SqlInstance $Server | Select-Object -Property Name
}
# Get-Databases -Server DESKTOP-AD0K85U\mssql2

function Get-DatabaseRoles {
    param (
        [string]$Server
    )

    $allRoles = @()

    foreach ($db in (Get-Databases $Server)) {
        $allRoles += Get-DBADbRole -SqlInstance $Server -Database $db.Name | Select-Object -Property Database, Name
    }
    Return $allRoles
}
# Get-DatabaseRoles -Server $Server1.ServerName

function Get-DatabaseUsers {
    param (
        [string]$Server
    )

    $allUsers = @()

    foreach ($db in (Get-Databases $Server)) {
        $allUsers += Get-DbaDbUser -SqlInstance $Server -Database $db.name | Select-Object -Property Database, Name
    }
    Return $allUsers 


}
# Get-DatabaseUsers -Server DESKTOP-AD0K85U\MSSQL
