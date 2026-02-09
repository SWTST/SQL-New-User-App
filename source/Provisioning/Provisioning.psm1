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


function Get-ServerRoles {
        param(
            [string]$Server
        )

    $roles = Get-DbaServerRole -SqlInstance $Server
    Return $roles

}

# Getting top 1 server roles - Tweak logic for app
$Server1 = Get-AllServers | Select-object -First 1
Get-ServerRoles -Server $Server1.ServerName

function Get-AllServerLogins {
    param (
    )
    
}

function Get-AllDatabases {
    param (
    )
    
}

function Get-AllDatabaseRoles {
    param (
    )
    
}

function Get-AllDatabaseUsers {
    param (
    )
    
}