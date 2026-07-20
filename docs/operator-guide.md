# SQL User Management — Operator Guide

A step-by-step guide for using the SQL User Management desktop app to grant,
review, and edit a user's access across one or more SQL Server instances.

> Screenshots referenced below live in `docs/images/`. If a file is missing,
> the step still stands on its own — capture a fresh screenshot and drop it in
> with the matching name.

---

## 1. Before you start

You need:

- **Windows 10/11** with **Windows PowerShell 5.1** (built in).
- The **dbatools** PowerShell module (2.7.6 confirmed):
  ```powershell
  Install-Module dbatools -Scope CurrentUser
  ```
- **SQL permissions** on the target instances sufficient to create logins/users
  and grant roles — `sysadmin`, or equivalent, on each server you will touch.
- Either your current Windows account has that access, **or** you have a
  separate account you can supply as *alternate connection credentials*
  (see §3).

---

## 2. Launching the app

From the repo root:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File source\UI\App.ps1
```

Every launch writes a timestamped log to `logs\app-YYYYMMDD-HHMMSS.log`. If
anything looks wrong, that log is the first place to check (see §9).

---

## 3. The login dialog (choose the user to manage)

`![Login dialog](images/login-dialog.png)`

This dialog defines **who you are managing** — not who you connect as.

1. **Authentication** — pick *Windows Authentication* or *SQL Authentication*
   for the login you are creating/editing.
   - *SQL Authentication* reveals a **Password** field, used only if the login
     has to be **created**.
2. **Username** — the login to manage (e.g. `DOMAIN\jsmith` or a SQL login
   name). **Current Login** fills in your own Windows account.
3. **Connect to SQL using different credentials** *(optional)* — tick this only
   if you need to connect **to the target servers** as a different account than
   the one you are logged in to Windows as. Enter that account under
   **Connect as** / **Password**. This is passed to SQL as the connection
   credential and never changes which login you are managing.
4. Click **OK**.

> Leave the alternate-credentials box unticked to connect using your current
> Windows session — the normal case.

---

## 4. Main window tour

`![Main window](images/main-window.png)`

- **Left — Server List:** every server from the Central Management Server (CMS),
  each with a checkbox. Tick a server to bring it into scope.
- **Centre top — Server dropdown:** lists the servers you have ticked. Switching
  it changes which server the middle and right panels describe. Your ticks on
  each server are remembered as you switch.
- **Centre — Database cards:** one card per database on the selected server,
  each listing that database's roles as checkboxes.
- **Centre bottom — Existing Logins on Server:** click any login to load its
  **current** access into the ticks (see §6).
- **Right — Server Roles:** server-level roles for the selected server.
- **Header bar:** shows `Editing: <login>` so you always know who you are
  working on.
- **Bottom toolbar:** Exit · Refresh Server List · Refresh Database List ·
  Settings… · Templates… · Select User… · **Apply Changes**.

---

## 5. Granting access to a user

1. In **Server List**, tick each server the user needs access on. Each ticked
   server appears in the dropdown.
2. Use the **Server dropdown** to visit each ticked server in turn. For each:
   - Tick the **Server Roles** they need (right panel).
   - Tick the **database roles** they need on each **Database card**.
   - Your selections are saved automatically when you switch servers.
3. Click **Apply Changes**.

---

## 6. Reviewing / editing an existing user

1. Select or switch to the user via **Select User…** (bottom toolbar), or click
   a name in **Existing Logins on Server**.
2. The app reads that login's **current** server and database roles and ticks
   them for you. The header shows `Editing: <login>`.
3. Add access by ticking more roles; remove access by **unticking**.
4. Click **Apply Changes**. The app compares current vs. desired and shows you
   exactly what it will **add** (`+`) and **remove** (`-`) before doing anything
   (see §7).

---

## 7. Apply Changes — the confirmation step

`![Confirm changes](images/confirm-changes.png)`

**Apply Changes** never acts blindly. It:

1. Reads each ticked server's current access for the user.
2. Computes a per-server **diff** (roles to add, roles to remove).
3. Shows a summary dialog, e.g.:
   ```
   [SRV1\INST]
     + Server roles: dbcreator
     + [Sales]: db_datareader
     - [HR]: db_datawriter
   [SRV2\INST]
     (no changes)
   ```
4. Only on **Yes** does it apply: it creates the login if missing, creates
   database users if missing, then revokes and grants roles.

If nothing differs, it tells you "Current access already matches selections"
and stops.

---

## 8. Templates and Settings

**Templates…** — save the current multi-server selection as a named blueprint,
then re-apply it to another user later.
- *Save:* tick your servers and roles, open Templates…, name it, **Save**.
- *Apply:* select a template, **Apply**. Servers not in the current CMS and
  databases not present on a target are skipped (and logged).

**Settings…**
- **Dark mode** — toggles the whole app's theme.
- **CMS snapshot** — when on, each successful CMS load is cached to
  `config\cms-snapshot.json`; if the CMS is later unreachable, the server list
  falls back to that snapshot.
- **CMS server** — the Central Management Server instance the server list is
  read from. Change this to point at your environment.

---

## 9. Logs & troubleshooting

Each run logs to `logs\app-YYYYMMDD-HHMMSS.log`, including every dbatools call's
output during **Apply Changes**.

| Symptom | Likely cause / fix |
|---|---|
| Server list is empty | CMS unreachable and no snapshot. Check **Settings… → CMS server**; enable CMS snapshot for offline fallback. |
| "Access is denied" / connection fails | Your account (or the alternate connection account) lacks rights on that server. Re-open **Select User…** and set alternate credentials. |
| A role grant fails but others succeed | See the log line for that server/role. The app continues and reports errors at the end. |
| Parser error on launch | A `.ps1`/`.psm1`/`.xaml` file was saved without a UTF-8 BOM. Re-save it as **UTF-8 with BOM**. |

---

## 10. Quick reference

| I want to… | Do this |
|---|---|
| Manage a different user | **Select User…** |
| Add a server to scope | Tick it in **Server List** |
| See a user's current access | Click the login in **Existing Logins on Server** |
| Preview before applying | **Apply Changes** → read the diff dialog |
| Reuse a set of selections | **Templates…** → Save / Apply |
| Connect as a different account | Login dialog → **Connect to SQL using different credentials** |
| Switch theme / point at your CMS | **Settings…** |
