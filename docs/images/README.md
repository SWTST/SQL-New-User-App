# Operator guide screenshots

Drop PNG screenshots here to illustrate `../operator-guide.md`. Expected names:

- `login-dialog.png` — the login dialog with the alternate-credentials section expanded
- `main-window.png` — the main window with a couple of servers ticked
- `confirm-changes.png` — the Apply Changes diff confirmation dialog

To capture: launch the app (`powershell.exe -NoProfile -ExecutionPolicy Bypass -File source\UI\App.ps1`),
reach the relevant screen, and use **Win + Shift + S** (Snip & Sketch) or Alt+PrtScn.
Once the images exist, remove the surrounding backticks from the `![...](images/...)`
lines in `operator-guide.md` so they render inline.
