# SQL User Management — Context for Claude

## Purpose
Windows PowerShell + WPF desktop app for DBAs/operators. Manages SQL Server
access: creates/modifies logins, database users, and role memberships for a
target user across one or more SQL instances in a single action. Pivoted from
"new user only" to full user-management (view + edit existing logins).
Being prepared for handover to a senior colleague — ease-of-use is the #1 priority.

## Tech stack
- Windows PowerShell 5.1 (WPF via `PresentationFramework`)
- [dbatools](https://dbatools.io/) PowerShell module (2.7.6 confirmed installed on dev box)
- XAML loaded at runtime via `XamlReader`

## Layout
- `source/Provisioning/Provisioning.psm1` — all backend logic (queries + provisioning)
- `source/UI/App.ps1` — entry point; loads XAML, wires events, holds script-scope state
- `source/UI/App.xaml` — main window
- `source/UI/LoginWindow.xaml` — target-user capture dialog (shown first)
- `config/servers.json` — fallback/static server list (empty)
- `config/access-templates.json` — role bundles (empty, NOT YET IMPLEMENTED)
- `logs/app-YYYYMMDD-HHMMSS.log` — per-run log (created on launch)
- `app-plan/initial-plan.md` — feature checklist

## Entry point
`source/UI/App.ps1` — runs `Show-LoginDialog`, then `Show-MainWindow` if a user was captured.

## Per-server selection model (important)
`$script:ServerSelections` is a hashtable:
```
@{ serverName = @{ ServerRoles = @(strings); DatabaseRoles = @{ dbName = @(role strings) } } }
```
- Ticking a server in the left panel adds an entry and adds the server to the dropdown.
- Unticking a server **discards** its selections and removes it from the dropdown.
- Switching the dropdown saves current panel state to `$script:ServerSelections[$CurrentServer]`
  then restores from `$script:ServerSelections[$newServer]` via `Save-CurrentSelections` /
  `Restore-Selections`.
- `Assign` iterates `$script:ServerSelections.Keys`, NOT the current view.

## Logging
`Write-Log` in `App.ps1` appends timestamped lines to `$script:LogFile`. Provisioning
module output (Write-Host / Write-Warning / errors) is captured via `*>&1` redirection
inside the Assign handler and forwarded to `Write-Log`.

## Status (2026-04-14)
Working end-to-end for Windows and SQL auth. Confirmed:
- Server role grants + revokes succeed
- Database user creation succeeds
- Database role grants + revokes succeed
- Per-server selection persists across dropdown switches
- Unticking a server discards its selections
- User list (bottom-center panel) shows all existing logins on the current
  server; clicking one loads its current access into the ticks
- Apply Changes runs in diff mode: computes add/remove per server, shows
  a confirmation dialog summarising `+` and `-` lines, then applies
- Header bar at top of main window shows "Editing: <login> (<auth> Auth)"
  plus reflected in window Title
- Single "Select User..." button replaces the old New User / Current Login pair

## Critical gotchas (learned the hard way)
1. **UTF-8 BOM required** on all `.ps1` / `.psm1` / `.xaml` files. PS 5.1
   reads BOMless files as ANSI and corrupts em-dash (`—`) characters into
   `�?`, causing parser errors. If adding new files, save with UTF-8 BOM.
2. **Do NOT use `.GetNewClosure()` on WPF event handlers** that write to
   `$script:` scope. It creates an isolated closure scope — the `$script:` write
   goes into the closure, not the real script scope, and the value vanishes
   when the handler returns. Attach the scriptblock directly.
3. **dbatools needs `-Confirm:$false`** on `Add-DbaServerRoleMember`,
   `Add-DbaDbRoleMember`, `New-DbaLogin`, `New-DbaDbUser` when called from
   a WPF/non-interactive context. Without it they throw:
   `Exception calling "ShouldProcess" with "2" argument(s): "Object reference not set to an instance of an object."`
4. `Write-Host` / `Write-Warning` inside the provisioning module are NOT
   captured by `Start-Transcript` from a WPF event handler. Use `*>&1`
   redirection on the call site to pipe into our file logger.
5. `Get-ServerRoles` used to leak empty rows via `$roles | Select-Object -Property Role`
   (the property is `Name`, not `Role`). Removed — don't re-add.
6. **WPF CheckBox `_` is an accelerator char** — `Content="db_datareader"`
   renders as `dbdatareader` with `d` underlined. Fix: wrap text in a
   `TextBlock` element and set that as the CheckBox Content. Role identity
   is stored in `$cb.Tag` (not `.Content`) — all comparators use `.Tag`.
   See `New-LiteralCheckBox` helper in App.ps1.

## Still to do (priority order)
1. **Access templates** — JSON-backed, editable from the UI. Save-current-selection,
   apply-template, delete-template. Stored in `config/access-templates.json`.
   Per-server role bundle shape `@{ ServerRoles=[]; DatabaseRoles=@{db=[roles]} }`.
   Apply to the currently-selected server in the dropdown (DBs not present get skipped).
2. **"Run as other user" connection context** — login dialog should optionally
   accept alternate Windows creds used when connecting TO SQL via dbatools
   (separate from the target login being managed). Pass as
   `-SqlCredential` (PSCredential) to dbatools cmdlets.
3. **CMS host to config + JSON fallback** — `Get-AllServers` currently
   hardcodes `DESKTOP-AD0K85U\MSSQL` as CMS. Move to `config/app-config.json`,
   auto-fallback to `config/servers.json` if CMS unreachable.
4. **Operator guide with screenshots** (`docs/`) for handover.
5. Module manifest (`.psd1`) + `Export-ModuleMember`. Low priority.
6. Remove `Invoke-UserProvisioning` once we're sure nothing else depends on it.
   Low priority — harmless dead code.

## Conventions
- Use dbatools for all SQL; do not hand-roll `Invoke-Sqlcmd`.
- Script-scope (`$script:`) holds UI control refs so helper functions reach them.
- `Set-DbatoolsInsecureConnection -SessionOnly` at module top — dev/desktop
  env without TLS certs. Revisit before production handover.
- `Set-ExecutionPolicy` at the module top is noisy and inappropriate for a
  module. Candidate for removal (low priority).

## How to run (dev)
```
powershell.exe -NoProfile -ExecutionPolicy Bypass -File source/UI/App.ps1
```
Logs to `logs/app-*.log`. App exits cleanly on window close.
