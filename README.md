# SQL User Management

A Windows PowerShell + WPF desktop app for managing SQL Server access:
create/modify logins, database users, and role memberships across one or
more SQL instances in a single action.

## What it does
1. Captures a target user (Windows or SQL auth) via a small login dialog.
2. Lists available SQL Servers (from a Central Management Server, or a JSON fallback).
3. Lets you tick the servers you want to apply access on.
4. For each ticked server, pick server-level roles and per-database roles.
5. On **Assign Permissions**, creates the login (if missing), creates database
   users (if missing), and grants the selected roles. Per-server selections
   persist while you switch between servers.

## Requirements
- Windows 10/11 with Windows PowerShell 5.1.
- [dbatools](https://dbatools.io/) module installed (tested with 2.7.6):
  ```powershell
  Install-Module dbatools -Scope CurrentUser
  ```
- SQL permissions sufficient to create logins/users and grant roles on the
  target instances (sysadmin or equivalent).

## How to run
From the repo root:
```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File source\UI\App.ps1
```
Or double-click `source\UI\App.ps1` if `.ps1` is associated with PowerShell
and execution policy allows.

## First-use walkthrough
1. **Login dialog** appears. Choose Windows or SQL authentication and enter
   the user to provision. Click **Current Login** to pre-fill your Windows
   account. Click OK.
2. **Main window** loads the server list on the left.
3. **Tick the servers** you want to grant access on. Each ticked server
   appears in the dropdown above the database cards.
4. Use the dropdown to **switch between ticked servers**. For each:
   - Tick server roles on the right panel.
   - Tick per-database roles in the database cards.
5. Click **Assign Permissions**. Confirm the prompt. The app iterates every
   ticked server and applies its own selections.
6. Check `logs/app-YYYYMMDD-HHMMSS.log` for a detailed record.

## Repo layout
- `source/UI/` — WPF app (`App.ps1`, `App.xaml`, `LoginWindow.xaml`)
- `source/Provisioning/Provisioning.psm1` — all SQL logic (dbatools wrappers)
- `config/servers.json` — optional static server list (used when no CMS)
- `config/access-templates.json` — role bundles (placeholder — feature WIP)
- `logs/` — per-run log files
- `app-plan/` — original design notes and feature checklist

## Logs
Every launch creates `logs/app-YYYYMMDD-HHMMSS.log` with a full record of:
- App start, module load, login dialog input
- Assign operations: for each server, the roles requested, every
  dbatools call's output (creation messages, warnings, errors)

If something didn't land as expected, this log is the first place to look.

## Status
- **Access templates** — available via **Templates…** (save/apply/delete
  multi-server blueprints).
- **Alternate connection credentials** — tick *"Connect to SQL using different
  credentials"* in the login dialog to connect to target instances as a
  different account (passed to dbatools as `-SqlCredential`), separate from the
  login being managed.
- **CMS host is configurable** — set the CMS server in **Settings…**; it is
  stored in `config/app-config.json`. When *CMS snapshot* is enabled, the last
  successful server list is cached and used as a fallback if the CMS is
  unreachable.

## Known limitations
- The seeded default CMS instance in config is still the dev box
  (`DESKTOP-AD0K85U\MSSQL`); set your own in **Settings…** before handover.
- Operator guide screenshots are not yet captured — see
  [docs/operator-guide.md](docs/operator-guide.md) and `docs/images/`.

## Troubleshooting
- *"Parser error / MissingEndCurlyBrace" on launch* — a `.ps1`/`.psm1`/`.xaml`
  file was saved without UTF-8 BOM and contains em-dash or other non-ASCII
  characters. Re-save the file as UTF-8 with BOM.
- *"Exception calling ShouldProcess ... Object reference not set"* from a
  dbatools cmdlet — the cmdlet was invoked without `-Confirm:$false`. All
  write cmdlets in the provisioning module already include this; if you add
  a new one, include `-Confirm:$false`.
- *Login dialog OK closes but no main window* — check the latest log. If you
  see `NewUserLogin=''` after OK was clicked, a `.GetNewClosure()` on the
  handler is eating the `$script:` scope assignment. Remove `.GetNewClosure()`.

## For maintainers
See [source/CLAUDE.md](source/CLAUDE.md) for architecture notes, gotchas,
and the remaining backlog.
