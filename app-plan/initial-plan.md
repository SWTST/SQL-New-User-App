## First App Draft (Figma)

![image](/app-plan/Images/Initial-App-Plan.PNG)

### App Features and Functionality

The below features have been identified from the first draft

**Backend Functions**
- [x] All Servers
- [x] All Server Roles
- [x] All Server Logins (`Get-ServerLogins`)
- [x] All Databases
- [x] All Database Roles
- [x] All Database Users
- [x] Store Login information (captured via LoginWindow dialog)
- [x] Check if Login exists on Server
  - [x] Create Login on Server
  - [x] Grant Server roles to Login
- [x] Check for Login in Database Users
  - [x] Create Database User
  - [x] Grant Database roles to user
- [x] Refresh Server List
- [x] Refresh Database List
- [x] Assign Permissions (per-server selections; persists across dropdown switches)

**Still to do**
- [x] Access templates (config/access-templates.json + UI save/apply/delete)
- [x] Alternate connection credentials ("run as other user" when connecting to SQL)
- [x] Move CMS host to config; JSON fallback when CMS unavailable
- [x] Operator guide (docs/operator-guide.md) — text complete; screenshots pending (docs/images/)
