function Get-AllServers {
    param (
        [string]$SqlInstance
    )

    if ((Get-DbaRegServer -SqlInstance $SqlInstance) -le 0) {
        $AllServers = Get-DbaRegServer -SqlInstance $SqlInstance
        return $AllServers 
    }

    else {
        $AllServers = Get-Content .\config\servers.json
        Return $AllServers
    }
    
}

Get-AllServers

function Get-AllServerRoles {
    param (
    )
    
}

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