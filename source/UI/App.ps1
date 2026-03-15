Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$script:ModulePath = Join-Path $script:ScriptDir "..\Provisioning\Provisioning.psm1"

Import-Module $script:ModulePath -Force

# ── Shared state ──────────────────────────────────────────────────────────────
$script:NewUserLogin = $null
$script:NewUserPassword = $null   # SecureString or $null for Windows auth
$script:AuthType = 'Windows'

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

function Invoke-PopulateServerList {
    $script:ServerListPanel.Children.Clear()
    $script:ServerCombo.Items.Clear()
    Set-Status "Loading servers..."
    try {
        $servers = Get-AllServers
        foreach ($srv in $servers) {
            $cb = New-Object System.Windows.Controls.CheckBox
            $cb.Content = $srv.ServerName
            $cb.Margin = [System.Windows.Thickness]::new(2)
            $script:ServerListPanel.Children.Add($cb) | Out-Null
            $script:ServerCombo.Items.Add($srv.ServerName) | Out-Null
        }
        if ($script:ServerCombo.Items.Count -gt 0) { $script:ServerCombo.SelectedIndex = 0 }
        Set-Status "Loaded $($servers.Count) server(s)."
    }
    catch {
        Set-Status "Error loading servers: $_"
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
        }.GetNewClosure())

    $fillWinBtn.Add_Click({
            $userBox.Text = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        }.GetNewClosure())

    $okBtn.Add_Click({
            $user = $userBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($user)) {
                [System.Windows.MessageBox]::Show("Please enter a username.", "Validation",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
                return
            }
            $script:NewUserLogin = $user
            $script:AuthType = if ($authCombo.SelectedIndex -eq 1) { 'SQL' } else { 'Windows' }
            $script:NewUserPassword = if ($script:AuthType -eq 'SQL') { $passBox.SecurePassword } else { $null }
            $dlg.Close()
        }.GetNewClosure())

    $cancelBtn.Add_Click({ $dlg.Close() }.GetNewClosure())

    $dlg.ShowDialog() | Out-Null
}

# ── Main Window ───────────────────────────────────────────────────────────────
function Show-MainWindow {
    $win = Import-Xaml (Join-Path $script:ScriptDir "App.xaml")

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
            $srv = $script:ServerCombo.SelectedItem
            if ($srv) {
                Invoke-PopulateServerRoles   $srv
                Invoke-PopulateDatabaseCards $srv
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

            $checkedServers = @(Get-CheckedServers)
            $checkedServerRoles = @(Get-CheckedServerRoles)
            $checkedDbRoles = Get-CheckedDatabaseRoles

            if ($checkedServers.Count -eq 0) {
                [System.Windows.MessageBox]::Show(
                    "Please check at least one server in the Server List.",
                    "No Servers Selected", [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
                return
            }

            $confirm = [System.Windows.MessageBox]::Show(
                "Provision '$($script:NewUserLogin)' on $($checkedServers.Count) server(s)?`n`nThis will create logins, database users, and grant the selected roles.",
                "Confirm Provisioning",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question)

            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

            Set-Status "Provisioning..."
            $errors = @()
            foreach ($server in $checkedServers) {
                try {
                    Invoke-UserProvisioning `
                        -Server         $server `
                        -Login          $script:NewUserLogin `
                        -AuthType       $script:AuthType `
                        -SecurePassword $script:NewUserPassword `
                        -ServerRoles    $checkedServerRoles `
                        -DatabaseRoles  $checkedDbRoles
                }
                catch {
                    $errors += "[$server] $_"
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

    $win.Add_Loaded({ Invoke-PopulateServerList })

    $win.ShowDialog() | Out-Null
}

# ── Entry Point ───────────────────────────────────────────────────────────────
Show-LoginDialog
if (-not [string]::IsNullOrEmpty($script:NewUserLogin)) {
    Show-MainWindow
}
