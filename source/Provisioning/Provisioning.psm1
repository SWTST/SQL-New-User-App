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
    return $roles
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

# ── Provisioning Functions ────────────────────────────────────────────────────

function New-ServerLogin {
    param(
        [string]$Server,
        [string]$Login,
        [ValidateSet('Windows', 'SQL')]
        [string]$AuthType = 'Windows',
        [System.Security.SecureString]$SecurePassword = $null
    )

    $exists = Get-ServerLogins -Server $Server -Login $Login
    if ($exists) {
        Write-Host "Login '$Login' already exists on '$Server'. Skipping creation."
        return
    }

    if ($AuthType -eq 'Windows') {
        New-DbaLogin -SqlInstance $Server -Login $Login -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Host "Created Windows login '$Login' on '$Server'."
    }
    else {
        if ($null -eq $SecurePassword) {
            throw "SecurePassword is required for SQL Authentication."
        }
        New-DbaLogin -SqlInstance $Server -Login $Login `
            -SecurePassword $SecurePassword -Confirm:$false -ErrorAction Stop | Out-Null
        Write-Host "Created SQL login '$Login' on '$Server'."
    }
}

function New-DatabaseUser {
    param(
        [string]$Server,
        [string]$Database,
        [string]$Login
    )

    $existing = Get-DbaDbUser -SqlInstance $Server -Database $Database |
    Where-Object { $_.Login -eq $Login -or $_.Name -eq $Login }

    if ($existing) {
        Write-Host "User for '$Login' already exists in '$Database' on '$Server'. Skipping."
        return
    }

    New-DbaDbUser -SqlInstance $Server -Database $Database -Login $Login -Confirm:$false -ErrorAction Stop | Out-Null
    Write-Host "Created database user for '$Login' in '$Database' on '$Server'."
}

function Grant-ServerRole {
    param(
        [string]$Server,
        [string]$Login,
        [string[]]$Roles
    )

    if (-not $Roles -or $Roles.Count -eq 0) { return }

    foreach ($role in $Roles) {
        try {
            Add-DbaServerRoleMember -SqlInstance $Server -ServerRole $role `
                -Login $Login -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Host "Granted server role '$role' to '$Login' on '$Server'."
        }
        catch {
            Write-Warning "Failed to grant server role '$role' to '$Login' on '$Server': $_"
        }
    }
}

function Grant-DatabaseRole {
    param(
        [string]$Server,
        [string]$Database,
        [string]$User,
        [string[]]$Roles
    )

    if (-not $Roles -or $Roles.Count -eq 0) { return }

    foreach ($role in $Roles) {
        try {
            Add-DbaDbRoleMember -SqlInstance $Server -Database $Database `
                -Role $role -User $User -Confirm:$false -ErrorAction Stop | Out-Null
            Write-Host "Granted DB role '$role' to '$User' in '$Database' on '$Server'."
        }
        catch {
            Write-Warning "Failed to grant DB role '$role' to '$User' in '$Database': $_"
        }
    }
}

function Invoke-UserProvisioning {
    param(
        [string]$Server,
        [string]$Login,
        [ValidateSet('Windows', 'SQL')]
        [string]$AuthType = 'Windows',
        [System.Security.SecureString]$SecurePassword = $null,
        [string[]]$ServerRoles = @(),
        # @{ "DatabaseName" = @("role1","role2") }
        [hashtable]$DatabaseRoles = @{}
    )

    Write-Host "=== Provisioning '$Login' on '$Server' ==="

    # 1. Ensure server login exists
    New-ServerLogin -Server $Server -Login $Login `
        -AuthType $AuthType -SecurePassword $SecurePassword

    # 2. Grant server-level roles
    Grant-ServerRole -Server $Server -Login $Login -Roles $ServerRoles

    # 3. For each database with selected roles: create user + grant roles
    foreach ($dbName in $DatabaseRoles.Keys) {
        $roles = $DatabaseRoles[$dbName]
        if (-not $roles -or $roles.Count -eq 0) { continue }

        $dbExists = Get-Databases -Server $Server | Where-Object { $_.Name -eq $dbName }
        if (-not $dbExists) {
            Write-Warning "Database '$dbName' not found on '$Server'. Skipping."
            continue
        }

        New-DatabaseUser  -Server $Server -Database $dbName -Login $Login
        Grant-DatabaseRole -Server $Server -Database $dbName -User $Login -Roles $roles
    }

    Write-Host "=== Provisioning complete for '$Login' on '$Server' ==="
}
