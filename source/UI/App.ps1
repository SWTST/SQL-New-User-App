Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ModulePath = Join-Path $script:ScriptDir "..\Provisioning\Provisioning.psm1"

$script:LogDir = Join-Path $script:ScriptDir "..\..\logs"
if (-not (Test-Path $script:LogDir)) { New-Item -ItemType Directory -Path $script:LogDir | Out-Null }
$script:LogFile = Join-Path $script:LogDir ("app-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Message
    Add-Content -Path $script:LogFile -Value $line -Encoding UTF8
}

Write-Log "App starting. User=$([Environment]::UserName) Host=$([Environment]::MachineName)"
Import-Module $script:ModulePath -Force
Write-Log "Provisioning module imported from $script:ModulePath"

# ── Shared state ──────────────────────────────────────────────────────────────
$script:NewUserLogin = $null
$script:NewUserPassword = $null   # SecureString or $null for Windows auth
$script:AuthType = 'Windows'

# Per-server selections: @{ serverName = @{ ServerRoles = @(); DatabaseRoles = @{ db = @(roles) } } }
$script:ServerSelections = @{}
$script:CurrentServer = $null

# ── UI control references (populated in Show-MainWindow) ──────────────────────
$script:ServerListPanel = $null
$script:ServerCombo = $null
$script:DbWrapPanel = $null
$script:ServerRolesPanel = $null
$script:QueryBox = $null
$script:StatusText = $null
$script:StatusUserText = $null

# ── XAML loader ───────────────────────────────────────────────────────────────
function Import-Xaml([string]$Path) {
    $xaml = Get-Content $Path -Raw
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
    [Windows.Markup.XamlReader]::Load($reader)
}

# ── Script-scope helpers (callable from any event handler) ────────────────────
function Set-Status([string]$Msg) {
    if ($script:StatusText) { $script:StatusText.Text = $Msg }
}

function Sync-ServerCombo {
    $prev = $script:ServerCombo.SelectedItem
    $script:ServerCombo.Items.Clear()
    foreach ($name in ($script:ServerSelections.Keys | Sort-Object)) {
        $script:ServerCombo.Items.Add($name) | Out-Null
    }
    if ($prev -and $script:ServerCombo.Items.Contains($prev)) {
        $script:ServerCombo.SelectedItem = $prev
    }
    elseif ($script:ServerCombo.Items.Count -gt 0) {
        $script:ServerCombo.SelectedIndex = 0
    }
    else {
        $script:CurrentServer = $null
        $script:ServerRolesPanel.Children.Clear()
        $script:DbWrapPanel.Children.Clear()
    }
}

function Invoke-PopulateServerList {
    $script:ServerListPanel.Children.Clear()
    $script:ServerCombo.Items.Clear()
    $script:ServerSelections.Clear()
    $script:CurrentServer = $null
    Set-Status "Loading servers..."
    try {
        $servers = Get-AllServers
        foreach ($srv in $servers) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $srv.ServerName
            $cb.Margin = [System.Windows.Thickness]::new(2)
            $cb.Add_Checked({
                    $name = $this.Content
                    if (-not $script:ServerSelections.ContainsKey($name)) {
                        $script:ServerSelections[$name] = @{ ServerRoles = @(); DatabaseRoles = @{} }
                    }
                    Sync-ServerCombo
                    $script:ServerCombo.SelectedItem = $name
                })
            $cb.Add_Unchecked({
                    $name = $this.Content
                    $script:ServerSelections.Remove($name) | Out-Null
                    if ($script:CurrentServer -eq $name) { $script:CurrentServer = $null }
                    Sync-ServerCombo
                })
            $script:ServerListPanel.Children.Add($cb) | Out-Null
        }
        Set-Status "Loaded $($servers.Count) server(s). Check one or more to begin."
    }
    catch {
        Set-Status "Error loading servers: $_"
    }
}

function Save-CurrentSelections {
    if ([string]::IsNullOrEmpty($script:CurrentServer)) { return }
    if (-not $script:ServerSelections.ContainsKey($script:CurrentServer)) { return }
    $sel = $script:ServerSelections[$script:CurrentServer]
    $sel.ServerRoles = @(Get-CheckedServerRoles)
    $sel.DatabaseRoles = Get-CheckedDatabaseRoles
}

function Restore-Selections([string]$Server) {
    if ([string]::IsNullOrEmpty($Server)) { return }
    if (-not $script:ServerSelections.ContainsKey($Server)) { return }
    $sel = $script:ServerSelections[$Server]
    foreach ($cb in $script:ServerRolesPanel.Children) {
        if ($cb -is [System.Windows.Controls.CheckBox]) {
            $cb.IsChecked = ($sel.ServerRoles -contains $cb.Content)
        }
    }
    foreach ($card in $script:DbWrapPanel.Children) {
        if (-not ($card -is [System.Windows.Controls.Border])) { continue }
        $sp = $card.Child
        $hdr = $sp.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] } | Select-Object -First 1
        if (-not $hdr) { continue }
        $dbName = $hdr.Text
        $roles = @()
        if ($sel.DatabaseRoles.ContainsKey($dbName)) { $roles = @($sel.DatabaseRoles[$dbName]) }
        foreach ($child in $sp.Children) {
            if ($child -is [System.Windows.Controls.CheckBox]) {
                $child.IsChecked = ($roles -contains $child.Content)
            }
        }
    }
}

function Invoke-PopulateServerRoles([string]$Server) {
    $script:ServerRolesPanel.Children.Clear()
    if ([string]::IsNullOrEmpty($Server)) { return }
    try {
        $roles = Get-ServerRoles -Server $Server
        foreach ($role in $roles) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $role.Name
            $cb.Margin = [System.Windows.Thickness]::new(2)
            $script:ServerRolesPanel.Children.Add($cb) | Out-Null
        }
    }
    catch {
        Set-Status "Error loading server roles: $_"
    }
}

function Invoke-PopulateDatabaseCards([string]$Server) {
    $script:DbWrapPanel.Children.Clear()
    if ([string]::IsNullOrEmpty($Server)) { return }
    Set-Status "Loading databases..."
    try {
        $databases = Get-Databases -Server $Server
        foreach ($db in $databases) {
            $dbName = $db.Name

            $border = New-Object System.Windows.Controls.Border
            $border.BorderThickness = [System.Windows.Thickness]::new(1)
            $border.BorderBrush = [System.Windows.Media.Brushes]::Gray
            $border.Margin = [System.Windows.Thickness]::new(4)
            $border.Padding = [System.Windows.Thickness]::new(6)
            $border.Width = 185
            $border.VerticalAlignment = "Top"

            $sp = New-Object System.Windows.Controls.StackPanel

            $hdr = New-Object System.Windows.Controls.TextBlock
            $hdr.Text = $dbName
            $hdr.FontWeight = [System.Windows.FontWeights]::Bold
            $hdr.Margin = [System.Windows.Thickness]::new(0, 0, 0, 4)
            $hdr.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
            $hdr.ToolTip = $dbName
            $sp.Children.Add($hdr) | Out-Null

            try {
                $roles = Get-DbaDbRole -SqlInstance $Server -Database $dbName
                foreach ($role in $roles) {
                    $cb = New-Object System.Windows.Controls.CheckBox
                    $cb.Content = $role.Name
                    $cb.Tag = $dbName
                    $cb.Margin = [System.Windows.Thickness]::new(2, 1, 2, 1)
                    $sp.Children.Add($cb) | Out-Null
                }
            }
            catch {
                $err = New-Object System.Windows.Controls.TextBlock
                $err.Text = "(error loading roles)"
                $err.Foreground = [System.Windows.Media.Brushes]::Red
                $sp.Children.Add($err) | Out-Null
            }

            $border.Child = $sp
            $script:DbWrapPanel.Children.Add($border) | Out-Null
        }
        Set-Status "Loaded $($databases.Count) database(s) for $Server."
    }
    catch {
        Set-Status "Error loading databases: $_"
    }
}

function Get-CheckedServers {
    $script:ServerListPanel.Children |
    Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } |
    ForEach-Object { $_.Content }
}

function Get-CheckedServerRoles {
    $script:ServerRolesPanel.Children |
    Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } |
    ForEach-Object { $_.Content }
}

function Get-CheckedDatabaseRoles {
    $result = @{}
    foreach ($card in $script:DbWrapPanel.Children) {
        if (-not ($card -is [System.Windows.Controls.Border])) { continue }
        $sp = $card.Child
        $dbName = ($sp.Children |
            Where-Object { $_ -is [System.Windows.Controls.TextBlock] } |
            Select-Object -First 1).Text
        $checked = $sp.Children |
        Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } |
        ForEach-Object { $_.Content }
        if ($checked) { $result[$dbName] = @($checked) }
    }
    return $result
}

# ── Login Dialog ──────────────────────────────────────────────────────────────
function Show-LoginDialog {
    $dlg = Import-Xaml (Join-Path $script:ScriptDir "LoginWindow.xaml")
    $authCombo = $dlg.FindName("AuthTypeCombo")
    $userBox = $dlg.FindName("UsernameBox")
    $passBox = $dlg.FindName("PasswordBox")
    $passRow = $dlg.FindName("PasswordRow")
    $fillWinBtn = $dlg.FindName("CurrentLoginBtn")
    $okBtn = $dlg.FindName("OkBtn")
    $cancelBtn = $dlg.FindName("CancelBtn")

    $userBox.Text = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $authCombo.Add_SelectionChanged({
            $passRow.Visibility = if ($authCombo.SelectedIndex -eq 1) {
                [System.Windows.Visibility]::Visible
            }
            else {
                [System.Windows.Visibility]::Collapsed
            }
        })

    $fillWinBtn.Add_Click({
            $userBox.Text = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        })

    $okBtn.Add_Click({
            Write-Log "OK clicked. Raw text='$($userBox.Text)'"
            $user = $userBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($user)) {
                Write-Log "Empty username - validation failed"
                [System.Windows.MessageBox]::Show("Please enter a username.", "Validation",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
                return
            }
            $script:NewUserLogin = $user
            $script:AuthType = if ($authCombo.SelectedIndex -eq 1) { 'SQL' } else { 'Windows' }
            $script:NewUserPassword = if ($script:AuthType -eq 'SQL') { $passBox.SecurePassword } else { $null }
            Write-Log "OK handler set NewUserLogin='$script:NewUserLogin' AuthType='$script:AuthType'"
            $dlg.Close()
        })

    $cancelBtn.Add_Click({ $dlg.Close() })

    $dlg.ShowDialog() | Out-Null
}

# ── Main Window ───────────────────────────────────────────────────────────────
function Show-MainWindow {
    Write-Log "Show-MainWindow: loading XAML"
    try {
        $win = Import-Xaml (Join-Path $script:ScriptDir "App.xaml")
    }
    catch {
        Write-Log "Show-MainWindow: XAML load failed: $($_.Exception.Message)" 'ERROR'
        throw
    }
    Write-Log "Show-MainWindow: XAML loaded, wiring controls"

    # Bind controls to script-scope variables so helper functions can reach them
    $script:ServerListPanel = $win.FindName("ServerListPanel")
    $script:ServerCombo = $win.FindName("ServerCombo")
    $script:DbWrapPanel = $win.FindName("DatabaseWrapPanel")
    $script:ServerRolesPanel = $win.FindName("ServerRolesPanel")
    $script:QueryBox = $win.FindName("QueryBox")
    $script:StatusText = $win.FindName("StatusText")
    $script:StatusUserText = $win.FindName("StatusUserText")

    # Local refs for controls only needed within event handlers
    $executeQueryBtn = $win.FindName("ExecuteQueryBtn")
    $exitBtn = $win.FindName("ExitBtn")
    $refreshServersBtn = $win.FindName("RefreshServersBtn")
    $refreshDbBtn = $win.FindName("RefreshDbBtn")
    $currentLoginBtn = $win.FindName("CurrentLoginBtn")
    $assignBtn = $win.FindName("AssignBtn")

    $script:StatusUserText.Text = "Provisioning user: $($script:NewUserLogin)"

    # ── Events ────────────────────────────────────────────────────────────────

    $script:ServerCombo.Add_SelectionChanged({
            Save-CurrentSelections
            $srv = $script:ServerCombo.SelectedItem
            if ($srv) {
                Invoke-PopulateServerRoles   $srv
                Invoke-PopulateDatabaseCards $srv
                Restore-Selections $srv
                $script:CurrentServer = $srv
            }
            else {
                $script:ServerRolesPanel.Children.Clear()
                $script:DbWrapPanel.Children.Clear()
                $script:CurrentServer = $null
            }
        })

    $refreshServersBtn.Add_Click({ Invoke-PopulateServerList })

    $refreshDbBtn.Add_Click({
            $srv = $script:ServerCombo.SelectedItem
            if ($srv) { Invoke-PopulateDatabaseCards $srv }
        })

    $currentLoginBtn.Add_Click({
            Show-LoginDialog
            $script:StatusUserText.Text = "Provisioning user: $($script:NewUserLogin)"
        })

    $executeQueryBtn.Add_Click({
            $sql = $script:QueryBox.Text.Trim()
            $srv = $script:ServerCombo.SelectedItem
            if ([string]::IsNullOrEmpty($sql) -or $null -eq $srv) { return }
            Set-Status "Executing query..."
            try {
                $rows = Invoke-DbaQuery -SqlInstance $srv -Query $sql
                if ($rows) { $rows | Out-GridView -Title "Results — $srv" }
                Set-Status "Query complete."
            }
            catch {
                Set-Status "Query error: $_"
            }
        })

    $assignBtn.Add_Click({
            if ([string]::IsNullOrEmpty($script:NewUserLogin)) {
                [System.Windows.MessageBox]::Show(
                    "No target user set. Click 'Current Login' to define the user to provision.",
                    "No User", [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
                return
            }

            Save-CurrentSelections
            $servers = @($script:ServerSelections.Keys)

            if ($servers.Count -eq 0) {
                [System.Windows.MessageBox]::Show(
                    "Please check at least one server in the Server List.",
                    "No Servers Selected", [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
                return
            }

            $confirm = [System.Windows.MessageBox]::Show(
                "Provision '$($script:NewUserLogin)' on $($servers.Count) server(s)?`n`nThis will create logins, database users, and grant the selected roles.",
                "Confirm Provisioning",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question)

            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

            Set-Status "Provisioning..."
            Write-Log "Assign clicked for '$($script:NewUserLogin)' on $($servers.Count) server(s)"
            $errors = @()
            foreach ($server in $servers) {
                $sel = $script:ServerSelections[$server]
                Write-Log "  [$server] ServerRoles=$($sel.ServerRoles -join ',') DbRoles=$(($sel.DatabaseRoles.Keys | ForEach-Object { "$_=$($sel.DatabaseRoles[$_] -join ',')" }) -join '; ')"
                try {
                    $streams = Invoke-UserProvisioning `
                        -Server         $server `
                        -Login          $script:NewUserLogin `
                        -AuthType       $script:AuthType `
                        -SecurePassword $script:NewUserPassword `
                        -ServerRoles    $sel.ServerRoles `
                        -DatabaseRoles  $sel.DatabaseRoles *>&1
                    foreach ($line in $streams) { Write-Log "[$server] $line" }
                }
                catch {
                    $errors += "[$server] $_"
                    Write-Log "Provisioning error on $server`: $_" 'ERROR'
                }
            }

            if ($errors.Count -gt 0) {
                Set-Status "Provisioning completed with errors."
                [System.Windows.MessageBox]::Show(
                    "Errors occurred:`n`n" + ($errors -join "`n"),
                    "Provisioning Errors",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
            }
            else {
                Set-Status "Provisioning complete for: $($checkedServers -join ', ')"
                [System.Windows.MessageBox]::Show(
                    "Provisioning complete!",
                    "Done", [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Information)
            }
        })

    $exitBtn.Add_Click({ $win.Close() }.GetNewClosure())

    $win.Add_Loaded({
            Write-Log "Main window Loaded event fired"
            try { Invoke-PopulateServerList } catch { Write-Log "PopulateServerList error: $_" 'ERROR' }
        })

    Write-Log "Show-MainWindow: calling ShowDialog"
    $win.ShowDialog() | Out-Null
    Write-Log "Show-MainWindow: ShowDialog returned"
}

# ── Entry Point ───────────────────────────────────────────────────────────────
try {
    Write-Log "Showing login dialog"
    Show-LoginDialog
    Write-Log "Login dialog closed. NewUserLogin='$script:NewUserLogin' AuthType='$script:AuthType'"
    if (-not [string]::IsNullOrEmpty($script:NewUserLogin)) {
        Write-Log "Opening main window"
        Show-MainWindow
        Write-Log "Main window closed"
    }
    else {
        Write-Log "No login captured - exiting"
    }
}
catch {
    $msg = "FATAL: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    Write-Log $msg 'ERROR'
    [System.Windows.MessageBox]::Show($msg, "Error", 'OK', 'Error') | Out-Null
}
Write-Log "App exiting"
