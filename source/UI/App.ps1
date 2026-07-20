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

# Optional alternate account used ONLY for connecting to target SQL instances
# (dbatools -SqlCredential). Separate from the target login being managed.
# $null = connect using the operator's current Windows context.
$script:SqlCredential = $null

# Per-server selections: @{ serverName = @{ ServerRoles = @(); DatabaseRoles = @{ db = @(roles) } } }
$script:ServerSelections = @{}
$script:CurrentServer = $null

# ── UI control references (populated in Show-MainWindow) ──────────────────────
$script:ServerListPanel = $null
$script:ServerCombo = $null
$script:DbWrapPanel = $null
$script:ServerRolesPanel = $null
$script:UserListBox = $null
$script:StatusText = $null
$script:StatusUserText = $null
$script:EditingUserText = $null
$script:MainWindow = $null
$script:SuppressUserListSelection = $false
$script:LastLoadedServers = @()

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

function Update-EditingUserIndicator {
    $login = $script:NewUserLogin
    $auth = $script:AuthType
    if ([string]::IsNullOrEmpty($login)) {
        $label = "(no user selected)"
        $title = "SQL User Management"
    }
    else {
        $label = "$login  ($auth Auth)"
        $title = "SQL User Management — $login"
    }
    if ($script:EditingUserText) { $script:EditingUserText.Text = $label }
    if ($script:StatusUserText) { $script:StatusUserText.Text = "Managing user: $login" }
    if ($script:MainWindow) { $script:MainWindow.Title = $title }
}

function New-LiteralCheckBox {
    param([string]$Text, [object]$Tag = $null)
    $cb = New-Object System.Windows.Controls.CheckBox
    $tb = New-Object System.Windows.Controls.TextBlock
    $tb.Text = $Text
    $cb.Content = $tb
    $cb.Tag = if ($Tag) { $Tag } else { $Text }
    $cb.Margin = [System.Windows.Thickness]::new(2)
    return $cb
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
    $cfg = Get-AppConfig
    $servers = $null
    $fromSnapshot = $false
    try {
        $servers = Get-AllServers -SqlInstance $cfg.CmsInstance
        if ($servers -and $servers.Count -gt 0) {
            $script:LastLoadedServers = @($servers)
        }
        if ($cfg.CmsSnapshotEnabled -and $servers) {
            try {
                Save-CmsSnapshot $servers
                Write-Log "CMS snapshot saved ($($servers.Count) servers)"
            }
            catch { Write-Log "CMS snapshot save failed: $_" 'ERROR' }
        }
    }
    catch {
        Write-Log "CMS unreachable: $_" 'ERROR'
        if ($cfg.CmsSnapshotEnabled) {
            $servers = Get-CmsSnapshot
            if ($servers.Count -gt 0) {
                $fromSnapshot = $true
                Write-Log "Loaded $($servers.Count) server(s) from CMS snapshot"
            }
        }
        if (-not $servers -or $servers.Count -eq 0) {
            Set-Status "Error loading servers: $_"
            return
        }
    }
    try {
        foreach ($srv in $servers) {
            $cb = New-LiteralCheckBox -Text $srv.ServerName
            $cb.Add_Checked({
                    $name = $this.Tag
                    if (-not $script:ServerSelections.ContainsKey($name)) {
                        $script:ServerSelections[$name] = @{ ServerRoles = @(); DatabaseRoles = @{} }
                    }
                    Sync-ServerCombo
                    $script:ServerCombo.SelectedItem = $name
                })
            $cb.Add_Unchecked({
                    $name = $this.Tag
                    $script:ServerSelections.Remove($name) | Out-Null
                    if ($script:CurrentServer -eq $name) { $script:CurrentServer = $null }
                    Sync-ServerCombo
                })
            $script:ServerListPanel.Children.Add($cb) | Out-Null
        }
        $src = if ($fromSnapshot) { " (from snapshot - CMS unreachable)" } else { "" }
        Set-Status "Loaded $($servers.Count) server(s)$src. Check one or more to begin."
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
            $cb.IsChecked = ($sel.ServerRoles -contains $cb.Tag)
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
                $child.IsChecked = ($roles -contains $child.Tag)
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
            $cb = New-LiteralCheckBox -Text $role.Name
            $script:ServerRolesPanel.Children.Add($cb) | Out-Null
        }
    }
    catch {
        Set-Status "Error loading server roles: $_"
    }
}

function Invoke-PopulateUserList([string]$Server) {
    $script:SuppressUserListSelection = $true
    $script:UserListBox.Items.Clear()
    if ([string]::IsNullOrEmpty($Server)) { $script:SuppressUserListSelection = $false; return }
    try {
        $logins = Get-AllServerLogins -Server $Server
        foreach ($l in $logins) { $script:UserListBox.Items.Add($l) | Out-Null }
    }
    catch {
        Set-Status "Error loading logins: $_"
    }
    $script:SuppressUserListSelection = $false
}

function Invoke-LoadUserAccess([string]$Server, [string]$Login) {
    if ([string]::IsNullOrEmpty($Server) -or [string]::IsNullOrEmpty($Login)) { return }
    Set-Status "Loading access for '$Login' on $Server..."
    Write-Log "Loading access for '$Login' on $Server"
    try {
        $access = Get-UserAccess -Server $Server -Login $Login
        if (-not $script:ServerSelections.ContainsKey($Server)) {
            $script:ServerSelections[$Server] = @{ ServerRoles = @(); DatabaseRoles = @{} }
        }
        $script:ServerSelections[$Server].ServerRoles = @($access.ServerRoles)
        $script:ServerSelections[$Server].DatabaseRoles = $access.DatabaseRoles
        $script:NewUserLogin = $Login
        $script:AuthType = 'Windows'
        $script:NewUserPassword = $null
        Update-EditingUserIndicator
        Restore-Selections $Server
        Set-Status "Loaded access for '$Login' on $Server. ServerRoles=$($access.ServerRoles.Count), DBs=$($access.DatabaseRoles.Count)"
        Write-Log "Loaded: ServerRoles=$($access.ServerRoles -join ',') DbRoles=$(($access.DatabaseRoles.Keys | ForEach-Object { "$_=$($access.DatabaseRoles[$_] -join ',')" }) -join '; ')"
    }
    catch {
        Set-Status "Error loading user access: $_"
        Write-Log "Error loading access for $Login on $Server`: $_" 'ERROR'
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
                $roles = Get-DbRoleList -Server $Server -Database $dbName
                foreach ($role in $roles) {
                    $cb = New-LiteralCheckBox -Text $role.Name -Tag $role.Name
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
    ForEach-Object { $_.Tag }
}

function Get-CheckedServerRoles {
    $script:ServerRolesPanel.Children |
    Where-Object { $_ -is [System.Windows.Controls.CheckBox] -and $_.IsChecked } |
    ForEach-Object { $_.Tag }
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
        ForEach-Object { $_.Tag }
        if ($checked) { $result[$dbName] = @($checked) }
    }
    return $result
}

# ── App Config ────────────────────────────────────────────────────────────────
function Get-AppConfigPath {
    Join-Path $script:ScriptDir "..\..\config\app-config.json"
}

function Get-CmsSnapshotPath {
    Join-Path $script:ScriptDir "..\..\config\cms-snapshot.json"
}

function Get-AppConfig {
    $path = Get-AppConfigPath
    $defaults = @{
        DarkMode           = $false
        CmsSnapshotEnabled = $false
        CmsInstance        = 'DESKTOP-AD0K85U\MSSQL'
    }
    if (-not (Test-Path $path)) { return $defaults }
    $raw = Get-Content $path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return $defaults }
    try {
        $obj = $raw | ConvertFrom-Json
        $cms = if ([string]::IsNullOrWhiteSpace($obj.CmsInstance)) { $defaults.CmsInstance } else { [string]$obj.CmsInstance }
        return @{
            DarkMode           = [bool]$obj.DarkMode
            CmsSnapshotEnabled = [bool]$obj.CmsSnapshotEnabled
            CmsInstance        = $cms
        }
    }
    catch {
        Write-Log "Failed to parse app-config.json: $_" 'ERROR'
        return $defaults
    }
}

function Save-AppConfig([hashtable]$Config) {
    $path = Get-AppConfigPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    ($Config | ConvertTo-Json) | Set-Content -Path $path -Encoding UTF8
}

function Save-CmsSnapshot([array]$Servers) {
    $path = Get-CmsSnapshotPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $payload = @{
        CapturedAt = (Get-Date).ToString('o')
        Servers    = @($Servers | ForEach-Object { @{ ServerName = $_.ServerName } })
    }
    ($payload | ConvertTo-Json -Depth 4) | Set-Content -Path $path -Encoding UTF8
}

function Get-CmsSnapshot {
    $path = Get-CmsSnapshotPath
    if (-not (Test-Path $path)) { return @() }
    $raw = Get-Content $path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $obj = $raw | ConvertFrom-Json
        return @($obj.Servers | ForEach-Object { [PSCustomObject]@{ ServerName = $_.ServerName } })
    }
    catch {
        Write-Log "Failed to parse cms-snapshot.json: $_" 'ERROR'
        return @()
    }
}

# ── Theming ───────────────────────────────────────────────────────────────────
function New-Brush([string]$Hex) {
    New-Object System.Windows.Media.SolidColorBrush (
        [System.Windows.Media.ColorConverter]::ConvertFromString($Hex))
}

function Add-ImplicitStyle {
    param(
        [System.Windows.Window]$Window,
        [type]$TargetType,
        [hashtable]$Setters
    )
    $style = New-Object System.Windows.Style ($TargetType)
    foreach ($key in $Setters.Keys) {
        $style.Setters.Add( (New-Object System.Windows.Setter $key, $Setters[$key]) )
    }
    if ($Window.Resources.Contains($TargetType)) { $Window.Resources.Remove($TargetType) }
    $Window.Resources.Add($TargetType, $style)
}

function Set-Theme {
    param([System.Windows.Window]$Window, [bool]$Dark)
    if (-not $Window) { return }
    $typesWithStyles = @(
        [System.Windows.Controls.TextBlock],
        [System.Windows.Controls.ListBox],
        [System.Windows.Controls.ListBoxItem],
        [System.Windows.Controls.TextBox],
        [System.Windows.Controls.Button],
        [System.Windows.Controls.ComboBox],
        [System.Windows.Controls.ComboBoxItem]
    )
    foreach ($t in $typesWithStyles) {
        if ($Window.Resources.Contains($t)) { $Window.Resources.Remove($t) }
    }

    if (-not $Dark) {
        $Window.Background = [System.Windows.Media.Brushes]::White
        [System.Windows.Documents.TextElement]::SetForeground($Window, [System.Windows.Media.Brushes]::Black)
        return
    }

    $bg = New-Brush '#1E1E1E'
    $ctrlBg = New-Brush '#2D2D2D'
    $fg = New-Brush '#E6E6E6'
    $border = New-Brush '#3C3C3C'

    $Window.Background = $bg
    # Inheritable attached property — cascades Foreground to all descendant text-rendering controls
    [System.Windows.Documents.TextElement]::SetForeground($Window, $fg)

    Add-ImplicitStyle $Window ([System.Windows.Controls.TextBlock]) @{
        ([System.Windows.Controls.TextBlock]::ForegroundProperty) = $fg
    }
    Add-ImplicitStyle $Window ([System.Windows.Controls.ListBox]) @{
        ([System.Windows.Controls.ListBox]::ForegroundProperty)  = $fg
        ([System.Windows.Controls.ListBox]::BackgroundProperty)  = $ctrlBg
        ([System.Windows.Controls.ListBox]::BorderBrushProperty) = $border
    }
    Add-ImplicitStyle $Window ([System.Windows.Controls.ListBoxItem]) @{
        ([System.Windows.Controls.ListBoxItem]::ForegroundProperty) = $fg
        ([System.Windows.Controls.ListBoxItem]::BackgroundProperty) = $ctrlBg
    }
    Add-ImplicitStyle $Window ([System.Windows.Controls.TextBox]) @{
        ([System.Windows.Controls.TextBox]::ForegroundProperty)  = $fg
        ([System.Windows.Controls.TextBox]::BackgroundProperty)  = $ctrlBg
        ([System.Windows.Controls.TextBox]::BorderBrushProperty) = $border
        ([System.Windows.Controls.TextBox]::CaretBrushProperty)  = $fg
    }
    Add-ImplicitStyle $Window ([System.Windows.Controls.Button]) @{
        ([System.Windows.Controls.Button]::ForegroundProperty)  = $fg
        ([System.Windows.Controls.Button]::BackgroundProperty)  = $ctrlBg
        ([System.Windows.Controls.Button]::BorderBrushProperty) = $border
    }
    Add-ImplicitStyle $Window ([System.Windows.Controls.ComboBox]) @{
        ([System.Windows.Controls.ComboBox]::ForegroundProperty)  = $fg
        ([System.Windows.Controls.ComboBox]::BackgroundProperty)  = $ctrlBg
        ([System.Windows.Controls.ComboBox]::BorderBrushProperty) = $border
    }
    Add-ImplicitStyle $Window ([System.Windows.Controls.ComboBoxItem]) @{
        ([System.Windows.Controls.ComboBoxItem]::ForegroundProperty) = $fg
        ([System.Windows.Controls.ComboBoxItem]::BackgroundProperty) = $ctrlBg
    }
}

function Show-SettingsDialog {
    $dlg = Import-Xaml (Join-Path $script:ScriptDir "SettingsWindow.xaml")
    $dlg.Owner = $script:MainWindow
    $cfg = Get-AppConfig
    Set-Theme -Window $dlg -Dark:$cfg.DarkMode

    # Stash in script: scope so event handlers can reach them without GetNewClosure
    # (GetNewClosure isolates $script: which breaks Set-Theme on $script:MainWindow)
    $script:_SettingsDlg = $dlg
    $script:_SettingsDarkCheck = $dlg.FindName("DarkModeCheck")
    $script:_SettingsSnapCheck = $dlg.FindName("CmsSnapshotCheck")
    $script:_SettingsCmsBox = $dlg.FindName("CmsInstanceBox")
    $script:_SettingsPrevSnap = [bool]$cfg.CmsSnapshotEnabled
    $script:_SettingsPrevCms = [string]$cfg.CmsInstance

    $snapInfo = $dlg.FindName("SnapshotInfo")
    $logPath = $dlg.FindName("LogPathText")
    $saveBtn = $dlg.FindName("SaveBtn")
    $cancelBtn = $dlg.FindName("CancelBtn")

    $script:_SettingsDarkCheck.IsChecked = $cfg.DarkMode
    $script:_SettingsSnapCheck.IsChecked = $cfg.CmsSnapshotEnabled
    $script:_SettingsCmsBox.Text = $cfg.CmsInstance

    $snapPath = Get-CmsSnapshotPath
    if (Test-Path $snapPath) {
        $ts = (Get-Item $snapPath).LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        $snapInfo.Text = "Last snapshot: $ts at $snapPath"
    }
    else {
        $snapInfo.Text = "No snapshot yet. One will be captured on next successful CMS load."
    }
    $logPath.Text = $script:LogFile

    $saveBtn.Add_Click({
            $dark = [bool]$script:_SettingsDarkCheck.IsChecked
            $snap = [bool]$script:_SettingsSnapCheck.IsChecked
            $cms = $script:_SettingsCmsBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($cms)) {
                [System.Windows.MessageBox]::Show("CMS server cannot be empty.",
                    "Validation", 'OK', 'Warning') | Out-Null
                return
            }
            Write-Log "Settings Save clicked: dark=$dark snap=$snap cms='$cms' MainWin=$($null -ne $script:MainWindow) LastLoaded=$($script:LastLoadedServers.Count)"
            Save-AppConfig @{ DarkMode = $dark; CmsSnapshotEnabled = $snap; CmsInstance = $cms }
            Set-Theme -Window $script:MainWindow -Dark:$dark
            if ($snap -and -not $script:_SettingsPrevSnap -and $script:LastLoadedServers.Count -gt 0) {
                try {
                    Save-CmsSnapshot $script:LastLoadedServers
                    Write-Log "CMS snapshot captured on toggle-on ($($script:LastLoadedServers.Count) servers)"
                }
                catch { Write-Log "CMS snapshot save on toggle failed: $_" 'ERROR' }
            }
            if ($cms -ne $script:_SettingsPrevCms) {
                Write-Log "CMS instance changed '$($script:_SettingsPrevCms)' -> '$cms'; reloading server list"
                try { Invoke-PopulateServerList } catch { Write-Log "Reload after CMS change failed: $_" 'ERROR' }
            }
            $script:_SettingsDlg.Close()
        })
    $cancelBtn.Add_Click({ $script:_SettingsDlg.Close() })
    $dlg.ShowDialog() | Out-Null
}

# ── Access Templates ──────────────────────────────────────────────────────────
function Get-TemplatesPath {
    Join-Path $script:ScriptDir "..\..\config\access-templates.json"
}

function ConvertTo-ServerSelection($Value) {
    $dbRoles = @{}
    if ($Value.DatabaseRoles) {
        foreach ($dp in $Value.DatabaseRoles.PSObject.Properties) {
            $dbRoles[$dp.Name] = @($dp.Value)
        }
    }
    return @{
        ServerRoles   = @($Value.ServerRoles)
        DatabaseRoles = $dbRoles
    }
}

function Get-Templates {
    $path = Get-TemplatesPath
    if (-not (Test-Path $path)) { return @{} }
    $raw = (Get-Content $path -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @{} }
    try {
        $obj = $raw | ConvertFrom-Json
        $h = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $servers = @{}
            if ($p.Value.Servers) {
                foreach ($sp in $p.Value.Servers.PSObject.Properties) {
                    $servers[$sp.Name] = ConvertTo-ServerSelection $sp.Value
                }
            }
            $h[$p.Name] = @{ Servers = $servers }
        }
        return $h
    }
    catch {
        Write-Log "Failed to parse access-templates.json: $_" 'ERROR'
        return @{}
    }
}

function Save-Templates([hashtable]$Templates) {
    $path = Get-TemplatesPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    ($Templates | ConvertTo-Json -Depth 6) | Set-Content -Path $path -Encoding UTF8
}

function Show-TemplatesDialog {
    $dlg = Import-Xaml (Join-Path $script:ScriptDir "TemplatesWindow.xaml")
    $dlg.Owner = $script:MainWindow
    $listBox = $dlg.FindName("TemplatesList")
    $applyBtn = $dlg.FindName("ApplyBtn")
    $deleteBtn = $dlg.FindName("DeleteBtn")
    $nameBox = $dlg.FindName("NewNameBox")
    $saveBtn = $dlg.FindName("SaveBtn")
    $saveHint = $dlg.FindName("SaveHint")
    $closeBtn = $dlg.FindName("CloseBtn")

    $refresh = {
        $listBox.Items.Clear()
        foreach ($n in (Get-Templates).Keys | Sort-Object) {
            $listBox.Items.Add($n) | Out-Null
        }
    }
    & $refresh

    Save-CurrentSelections
    $checkedCount = (@(Get-CheckedServers)).Count
    if ($checkedCount -eq 0) {
        $saveHint.Text = "No servers ticked - Save disabled."
        $saveBtn.IsEnabled = $false
    }
    else {
        $saveHint.Text = "Saves selections for $checkedCount ticked server(s) as a blueprint."
    }

    $applyBtn.Add_Click({
            $name = $listBox.SelectedItem
            if (-not $name) { return }
            $templates = Get-Templates
            if (-not $templates.ContainsKey($name)) { return }
            $tpl = $templates[$name]
            Save-CurrentSelections

            $knownServers = @()
            foreach ($cb in $script:ServerListPanel.Children) {
                if ($cb -is [System.Windows.Controls.CheckBox]) { $knownServers += $cb.Tag }
            }

            $missingServers = @()
            $appliedServers = @()
            $skippedDbsByServer = @{}

            foreach ($srv in $tpl.Servers.Keys) {
                if (-not ($knownServers -contains $srv)) {
                    $missingServers += $srv
                    continue
                }
                $tplSrv = $tpl.Servers[$srv]
                $presentDbs = @()
                try { $presentDbs = @((Get-Databases -Server $srv) | ForEach-Object { $_.Name }) } catch { }
                $skipped = @()
                $applied = @{}
                foreach ($db in $tplSrv.DatabaseRoles.Keys) {
                    if ($presentDbs -contains $db) {
                        $applied[$db] = @($tplSrv.DatabaseRoles[$db])
                    }
                    else {
                        $skipped += $db
                    }
                }
                $script:ServerSelections[$srv] = @{
                    ServerRoles   = @($tplSrv.ServerRoles)
                    DatabaseRoles = $applied
                }
                if ($skipped.Count -gt 0) { $skippedDbsByServer[$srv] = $skipped }
                $appliedServers += $srv
            }

            # Tick the applied servers in the left panel (without re-triggering Checked handler erasing state)
            foreach ($cb in $script:ServerListPanel.Children) {
                if ($cb -is [System.Windows.Controls.CheckBox] -and ($appliedServers -contains $cb.Tag)) {
                    if (-not $cb.IsChecked) { $cb.IsChecked = $true }
                }
            }

            Sync-ServerCombo
            if ($script:CurrentServer) { Restore-Selections $script:CurrentServer }

            $msg = "Applied template '$name' to $($appliedServers.Count) server(s)."
            if ($missingServers.Count -gt 0) { $msg += " Missing from CMS: $($missingServers -join ', ')." }
            foreach ($srv in $skippedDbsByServer.Keys) {
                Write-Log "Template '$name' on $srv`: skipped DBs $($skippedDbsByServer[$srv] -join ', ')"
            }
            Write-Log $msg
            Set-Status $msg
            $dlg.Close()
        })

    $deleteBtn.Add_Click({
            $name = $listBox.SelectedItem
            if (-not $name) { return }
            $confirm = [System.Windows.MessageBox]::Show(
                "Delete template '$name'?",
                "Confirm Delete",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question)
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            $templates = Get-Templates
            $templates.Remove($name) | Out-Null
            Save-Templates $templates
            Write-Log "Deleted template '$name'"
            & $refresh
        })

    $saveBtn.Add_Click({
            $name = $nameBox.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($name)) {
                [System.Windows.MessageBox]::Show("Enter a template name.", "Validation",
                    'OK', 'Warning') | Out-Null
                return
            }
            Save-CurrentSelections
            $checked = @(Get-CheckedServers)
            if ($checked.Count -eq 0) {
                [System.Windows.MessageBox]::Show("No servers ticked. Tick one or more servers first.",
                    "Nothing to save", 'OK', 'Warning') | Out-Null
                return
            }
            $templates = Get-Templates
            if ($templates.ContainsKey($name)) {
                $confirm = [System.Windows.MessageBox]::Show(
                    "Overwrite existing template '$name'?",
                    "Confirm Overwrite",
                    [System.Windows.MessageBoxButton]::YesNo,
                    [System.Windows.MessageBoxImage]::Question)
                if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }
            }
            $servers = @{}
            foreach ($srv in $checked) {
                if ($script:ServerSelections.ContainsKey($srv)) {
                    $sel = $script:ServerSelections[$srv]
                    $servers[$srv] = @{
                        ServerRoles   = @($sel.ServerRoles)
                        DatabaseRoles = $sel.DatabaseRoles
                    }
                }
            }
            $templates[$name] = @{ Servers = $servers }
            Save-Templates $templates
            Write-Log "Saved template '$name' with $($servers.Count) server(s)"
            $nameBox.Text = ""
            & $refresh
        })

    $closeBtn.Add_Click({ $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
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
    # Optional alternate connection credentials (connect TO SQL as another account)
    $altCredCheck = $dlg.FindName("UseAltCredCheck")
    $altCredRow = $dlg.FindName("AltCredRow")
    $altUserBox = $dlg.FindName("AltUserBox")
    $altPassBox = $dlg.FindName("AltPassBox")

    $userBox.Text = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $authCombo.Add_SelectionChanged({
            $passRow.Visibility = if ($authCombo.SelectedIndex -eq 1) {
                [System.Windows.Visibility]::Visible
            }
            else {
                [System.Windows.Visibility]::Collapsed
            }
        })

    $altCredCheck.Add_Checked({ $altCredRow.Visibility = [System.Windows.Visibility]::Visible })
    $altCredCheck.Add_Unchecked({ $altCredRow.Visibility = [System.Windows.Visibility]::Collapsed })

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

            # Optional alternate connection credentials
            if ($altCredCheck.IsChecked -and -not [string]::IsNullOrWhiteSpace($altUserBox.Text)) {
                $script:SqlCredential = New-Object System.Management.Automation.PSCredential(
                    $altUserBox.Text.Trim(), $altPassBox.SecurePassword)
                Write-Log "Alternate connection credential set for '$($altUserBox.Text.Trim())'"
            }
            else {
                $script:SqlCredential = $null
                Write-Log "Using current Windows context for SQL connections"
            }
            Set-ConnectionCredential -Credential $script:SqlCredential

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
    $script:UserListBox = $win.FindName("UserListBox")
    $script:StatusText = $win.FindName("StatusText")
    $script:StatusUserText = $win.FindName("StatusUserText")
    $script:EditingUserText = $win.FindName("EditingUserText")
    $script:MainWindow = $win

    # Local refs for controls only needed within event handlers
    $exitBtn = $win.FindName("ExitBtn")
    $refreshServersBtn = $win.FindName("RefreshServersBtn")
    $refreshDbBtn = $win.FindName("RefreshDbBtn")
    $selectUserBtn = $win.FindName("SelectUserBtn")
    $templatesBtn = $win.FindName("TemplatesBtn")
    $settingsBtn = $win.FindName("SettingsBtn")
    $assignBtn = $win.FindName("AssignBtn")

    $templatesBtn.Add_Click({ Show-TemplatesDialog })
    $settingsBtn.Add_Click({ Show-SettingsDialog })

    Set-Theme -Window $win -Dark:((Get-AppConfig).DarkMode)

    $script:StatusUserText.Text = "Managing user: $($script:NewUserLogin)"

    # ── Events ────────────────────────────────────────────────────────────────

    $script:ServerCombo.Add_SelectionChanged({
            Save-CurrentSelections
            $srv = $script:ServerCombo.SelectedItem
            if ($srv) {
                Invoke-PopulateServerRoles   $srv
                Invoke-PopulateDatabaseCards $srv
                Invoke-PopulateUserList      $srv
                Restore-Selections $srv
                $script:CurrentServer = $srv
            }
            else {
                $script:ServerRolesPanel.Children.Clear()
                $script:DbWrapPanel.Children.Clear()
                $script:UserListBox.Items.Clear()
                $script:CurrentServer = $null
            }
        })

    $refreshServersBtn.Add_Click({ Invoke-PopulateServerList })

    $refreshDbBtn.Add_Click({
            $srv = $script:ServerCombo.SelectedItem
            if ($srv) { Invoke-PopulateDatabaseCards $srv }
        })

    $selectUserBtn.Add_Click({
            $prevLogin = $script:NewUserLogin
            Show-LoginDialog
            if ([string]::IsNullOrEmpty($script:NewUserLogin) -or $script:NewUserLogin -eq $prevLogin) {
                Update-EditingUserIndicator
                return
            }
            # New user context — clear all loaded selections
            foreach ($k in @($script:ServerSelections.Keys)) {
                $script:ServerSelections[$k] = @{ ServerRoles = @(); DatabaseRoles = @{} }
            }
            Update-EditingUserIndicator
            # Clear UI list selection so same-user clicks still fire
            $script:SuppressUserListSelection = $true
            $script:UserListBox.SelectedIndex = -1
            $script:SuppressUserListSelection = $false
            # If the chosen login exists on the current server, load its access
            if ($script:CurrentServer) {
                $exists = $script:UserListBox.Items -contains $script:NewUserLogin
                if ($exists) {
                    Invoke-LoadUserAccess -Server $script:CurrentServer -Login $script:NewUserLogin
                }
                else {
                    Restore-Selections $script:CurrentServer
                    Set-Status "Login '$($script:NewUserLogin)' not found on $($script:CurrentServer). Apply Changes will create it."
                }
            }
        })

    $script:UserListBox.Add_SelectionChanged({
            if ($script:SuppressUserListSelection) { return }
            $login = $script:UserListBox.SelectedItem
            $srv = $script:CurrentServer
            if ($login -and $srv) {
                Save-CurrentSelections
                Invoke-LoadUserAccess -Server $srv -Login $login
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

            Set-Status "Computing changes..."
            Write-Log "Apply clicked for '$($script:NewUserLogin)' on $($servers.Count) server(s)"

            # Compute diffs per server
            $plans = @{}
            $summary = New-Object System.Text.StringBuilder
            $anyChange = $false
            foreach ($server in $servers) {
                $desired = $script:ServerSelections[$server]
                try {
                    $current = Get-UserAccess -Server $server -Login $script:NewUserLogin
                }
                catch {
                    $current = @{ ServerRoles = @(); DatabaseRoles = @{} }
                    Write-Log "Could not read current access on $server (user may not exist yet): $_"
                }
                $diff = Get-AccessDiff -Current $current -Desired $desired
                $plans[$server] = @{ Desired = $desired; Diff = $diff }

                [void]$summary.AppendLine("[$server]")
                if ($diff.AddServerRoles.Count -gt 0) {
                    [void]$summary.AppendLine("  + Server roles: $($diff.AddServerRoles -join ', ')")
                    $anyChange = $true
                }
                if ($diff.RemoveServerRoles.Count -gt 0) {
                    [void]$summary.AppendLine("  - Server roles: $($diff.RemoveServerRoles -join ', ')")
                    $anyChange = $true
                }
                foreach ($db in ($diff.AddDbRoles.Keys | Sort-Object)) {
                    [void]$summary.AppendLine("  + [$db]: $($diff.AddDbRoles[$db] -join ', ')")
                    $anyChange = $true
                }
                foreach ($db in ($diff.RemoveDbRoles.Keys | Sort-Object)) {
                    [void]$summary.AppendLine("  - [$db]: $($diff.RemoveDbRoles[$db] -join ', ')")
                    $anyChange = $true
                }
                if (($diff.AddServerRoles.Count + $diff.RemoveServerRoles.Count + $diff.AddDbRoles.Count + $diff.RemoveDbRoles.Count) -eq 0) {
                    [void]$summary.AppendLine("  (no changes)")
                }
            }

            if (-not $anyChange) {
                Set-Status "No changes to apply."
                [System.Windows.MessageBox]::Show(
                    "Current access already matches selections.",
                    "No Changes", 'OK', 'Information') | Out-Null
                return
            }

            $confirm = [System.Windows.MessageBox]::Show(
                "Apply the following changes for '$($script:NewUserLogin)'?`n`n$($summary.ToString())",
                "Confirm Changes",
                [System.Windows.MessageBoxButton]::YesNo,
                [System.Windows.MessageBoxImage]::Question)
            if ($confirm -ne [System.Windows.MessageBoxResult]::Yes) { return }

            Set-Status "Applying changes..."
            $errors = @()
            foreach ($server in $servers) {
                $plan = $plans[$server]
                try {
                    $streams = Invoke-UserAccessDiff `
                        -Server         $server `
                        -Login          $script:NewUserLogin `
                        -AuthType       $script:AuthType `
                        -SecurePassword $script:NewUserPassword `
                        -Desired        $plan.Desired `
                        -Diff           $plan.Diff *>&1
                    foreach ($line in $streams) { Write-Log "[$server] $line" }
                }
                catch {
                    $errors += "[$server] $_"
                    Write-Log "Apply error on $server`: $_" 'ERROR'
                }
            }

            # Refresh the current server's user list and ticks so UI reflects reality
            if ($script:CurrentServer) {
                Invoke-PopulateUserList $script:CurrentServer
                try {
                    $fresh = Get-UserAccess -Server $script:CurrentServer -Login $script:NewUserLogin
                    $script:ServerSelections[$script:CurrentServer].ServerRoles = @($fresh.ServerRoles)
                    $script:ServerSelections[$script:CurrentServer].DatabaseRoles = $fresh.DatabaseRoles
                    Restore-Selections $script:CurrentServer
                } catch { }
            }

            if ($errors.Count -gt 0) {
                Set-Status "Apply completed with errors."
                [System.Windows.MessageBox]::Show(
                    "Errors occurred:`n`n" + ($errors -join "`n"),
                    "Apply Errors",
                    [System.Windows.MessageBoxButton]::OK,
                    [System.Windows.MessageBoxImage]::Warning)
            }
            else {
                Set-Status "Changes applied on: $($servers -join ', ')"
                [System.Windows.MessageBox]::Show(
                    "Changes applied successfully.",
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
