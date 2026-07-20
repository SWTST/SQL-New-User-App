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
- `source/UI/TemplatesWindow.xaml` — access templates dialog
- `source/UI/SettingsWindow.xaml` — settings dialog (dark mode, CMS snapshot)
- `config/servers.json` — fallback/static server list (empty)
- `config/access-templates.json` — multi-server blueprints: `{Name:{Servers:{srv:{ServerRoles:[],DatabaseRoles:{db:[]}}}}}`
- `config/app-config.json` — `{DarkMode:bool, CmsSnapshotEnabled:bool}`
- `config/cms-snapshot.json` — `{CapturedAt, Servers:[{ServerName}]}` — auto-saved on CMS success when enabled, used as fallback on CMS failure
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

## Status (2026-04-23)
Working end-to-end for Windows and SQL auth. Confirmed earlier:
- Server + database role grants/revokes succeed
- Database user creation succeeds
- Per-server selection persists across dropdown switches; unticking discards
- User list clicks load existing access into ticks
- Apply Changes runs in diff mode with confirmation dialog
- "Editing: <login>" header + window title
- Single "Select User..." button

**Added 2026-04-23 session 3:**
- **Multi-server blueprint templates** — `TemplatesWindow.xaml` + `Show-TemplatesDialog`. Save captures all ticked servers' selections; Apply ticks each server in the template and populates selections, skipping servers not in CMS + DBs not on each target (both logged).
- **SettingsWindow** — `Show-SettingsDialog`. Dark mode toggle, CMS snapshot toggle, shows last snapshot timestamp + current log path.
- **`Set-Theme`** — applies via `TextElement.Foreground` attached property on Window (inheritable, cascades to dynamic controls) + implicit styles on Window.Resources for ListBox/TextBox/Button/ComboBox/etc.
- **CMS snapshot fallback** — `Invoke-PopulateServerList` tries CMS, saves snapshot on success when toggle on, falls back to snapshot on CMS failure. Snapshot also captured immediately when toggle flipped on if server list is already loaded (via `$script:LastLoadedServers`).

**Pending user verification (end of session 3):** Dark-mode-applies-to-whole-app and snapshot-fallback-loads-servers fixes both shipped after discovering `.GetNewClosure()` isolates `$script:` reads as well as writes (see gotcha #2). User hadn't retested at session end.

## Critical gotchas (learned the hard way)
1. **UTF-8 BOM required** on all `.ps1` / `.psm1` / `.xaml` files. PS 5.1
   reads BOMless files as ANSI and corrupts em-dash (`—`) characters into
   `�?`, causing parser errors. If adding new files, save with UTF-8 BOM.
2. **Do NOT use `.GetNewClosure()` on WPF event handlers** that touch
   `$script:` scope AT ALL — reads or writes. Creates an isolated scope:
   writes vanish (value goes into closure's own script scope); reads return
   `$null`/empty (closure's script scope has no value). Observed:
   (a) `$script:NewUserLogin` empty after login OK handler, (b) Settings Save
   handler's `Set-Theme -Window $script:MainWindow` silently no-op'd because
   `$script:MainWindow` resolved to `$null` → main window wasn't themed, only
   the settings dialog was. Pattern: stash dialog-local refs in
   `$script:_PrefixedVars` right after `FindName`, attach handlers directly
   without `.GetNewClosure()`. See `Show-SettingsDialog`.
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

## Alternate connection credentials (added — the "run as other user" feature)
The login dialog optionally captures credentials used **only** for the
connection TO target SQL (dbatools `-SqlCredential`), separate from the target
login being managed. Implementation:
- **Module scope** (`Provisioning.psm1`): `$script:ConnCredential` +
  `Set-ConnectionCredential` (setter) + `Get-ConnSplat` (returns `@{}` or
  `@{ SqlCredential = ... }`). Every dbatools call splats `@conn` so the cred
  flows through uniformly — no per-function signature changes.
- **App.ps1**: `$script:SqlCredential` holds the `PSCredential`. `Show-LoginDialog`
  builds it from the `UseAltCredCheck` / `AltUserBox` / `AltPassBox` controls and
  calls `Set-ConnectionCredential` on OK (always — sets `$null` to clear).
- **`Get-DbRoleList -Server -Database`** was added so the per-DB card load in
  `Invoke-PopulateDatabaseCards` goes through the module (and thus the cred)
  instead of calling `Get-DbaDbRole` directly.
- `Set-ExecutionPolicy` was removed from the module top (inappropriate at import;
  launcher already uses `-ExecutionPolicy Bypass`).

## Still to do (priority order)
1. **Verify dark mode + snapshot fallback fixes** — user hadn't retested at
   end of session 3 after switching Settings dialog from `.GetNewClosure()`
   to `$script:_Settings*` stashing. If still broken, first add Write-Log
   diagnostics inside `Show-SettingsDialog` Save handler showing
   `$script:MainWindow` is non-null and `$script:LastLoadedServers.Count > 0`.
2. **Verify alternate connection credentials end-to-end** against a real
   instance the operator can only reach with a second account. Module-level
   plumbing is unit-verified (empty splat vs. `SqlCredential` injection);
   the interactive WPF path parses and loads but wasn't driven against live SQL.
3. **Seed a real CMS default** — `Get-AppConfig` and `Get-AllServers` still
   default to the dev box `DESKTOP-AD0K85U\MSSQL`. It's now overridable in
   Settings, but the seeded default should be the operator's CMS before handover.
4. **Operator guide screenshots** — `docs/operator-guide.md` is written;
   capture the 3 screenshots named in `docs/images/README.md`.
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
