# NTU Gemini Local Vibe Bridge

Use NTU Gemini Enterprise to edit a project folder on your Windows PC. When you run the local watcher (`vibe-sync.ps1`), it packs your project into `repo-context.txt` directly inside your project folder. You upload `repo-context.txt` into the chat, describe your changes with `/vibecode`, and drag the generated `apply-changes.txt` file back into your project folder.

**Current workflow.**
1. Start the Windows watcher (`start-vibe-bridge.cmd` or `vibe-sync.ps1`) and select your local project folder. It generates `repo-context.txt` inside that project folder.
2. Upload `repo-context.txt` to a Gemini chat, trigger `/vibecode`, and describe your task (or trigger `/vibecode` without `repo-context.txt` when starting a new project).
3. Gemini tests the changes in an isolated Python workspace and outputs `apply-changes.txt` as a downloadable file in the chat.
4. Download and drag `apply-changes.txt` (or browser-renamed `apply-changes (*).txt`) into your project folder. The watcher validates and applies the Delta v2 patch, removes the completed `apply-changes.txt`, and automatically re-packs a fresh `repo-context.txt`.

Each change travels as one verified UTF-8 Delta v2 package named `apply-changes.txt`. The watcher checks the project name, snapshot ID, patch ID, and file operations (`edit`, `create`, `delete`) before applying it.

**Start with a practice folder.** The watcher applies verified changes under your selected local project. Keep a backup and use files you are allowed to share with Gemini.

## 1. Get the project files

You need Windows 10 or 11 and access to [NTU Gemini Enterprise](https://vertexaisearch.cloud.google.com/). Use Chrome or Edge if you want the optional elapsed-time and completion-alert userscript.

1. If you are viewing the project on GitHub, choose **Code → Download ZIP**. In **Downloads**, right-click the ZIP and choose **Extract All… → Extract**. If someone gave you the project folder directly, open that folder in File Explorer.
2. Open the folder that contains [setup.ps1](./setup.ps1), [vibe-sync.ps1](./vibe-sync.ps1), [bridge-delta.cjs](./bridge-delta.cjs), and [start-vibe-bridge.cmd](./start-vibe-bridge.cmd). Keep the bridge files together.
3. In File Explorer, click the address bar at the top, type `powershell`, and press **Enter**. A PowerShell window opens in that folder. Paste commands into that window with **Ctrl+V**, then press **Enter**.

## 2. Install the tools that prepare your files

Run this command in PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\setup.ps1
```

The setup installs or checks **Node.js**, which runs the delta packer/validator, and **Repomix**, which collects your project files into `repo-context.txt`. Wait for **Setup complete**.

- **Setup says to reopen PowerShell.** Close the window, reopen PowerShell from the same File Explorer folder, and run the same command.
- **Setup says Node.js is missing or too old.** Download the Windows **LTS** installer from the [official Node.js download page](https://nodejs.org/en/download). Repomix requires Node.js 22 or later.
- **Windows says the script is unsigned or downloaded from the internet.** If you trust the copy you downloaded, right-click **setup.ps1** in File Explorer, choose **Properties**, tick **Unblock** if shown, and select **Apply**. Repeat for **vibe-sync.ps1**.

## 3. Start the watcher with a practice folder

1. In File Explorer, enter `%LOCALAPPDATA%` in the address bar and press **Enter**. Create a folder named **VibeBridgePractice**.
2. Open the practice folder in File Explorer. Press **Ctrl+L**, then **Ctrl+C** to copy its full path. In Notepad, type `This is the Vibe Bridge practice project.` and save it inside **VibeBridgePractice** as **hello.txt**.
3. Return to the **bridge folder** from step 1 and double-click **start-vibe-bridge.cmd** (or run `vibe-sync.ps1` in PowerShell). At the prompt, paste the full path to **VibeBridgePractice** and press **Enter**. You can also pass the path directly via CLI:
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File .\vibe-sync.ps1 -ProjectPath "C:\Path\To\VibeBridgePractice"
   ```
4. Check that **Project Path** points to your practice folder. Wait for **[READY] repo-context.txt generated in project folder** and **WATCHING FOR AI PATCHES**. Keep the PowerShell window open. Look inside your practice folder in File Explorer to see the generated `repo-context.txt`.

## 4. Import the Gemini skill and start a chat

1. Zip the `vibecode` folder (containing `SKILL.md` and `scripts/pack_delta.py`) into `vibecode.zip` if not already zipped. In Gemini Enterprise, open **Skills** in the left menu, choose **+ → Upload skill**, select `vibecode.zip`, and click **Import**.
2. Open a **New chat** in Gemini Enterprise.
3. Drag or upload `repo-context.txt` from your local project folder into the chat message box.
4. Select `/vibecode` from the skill menu (no project name argument is needed) and write your request:

   ```text
   /vibecode
   Quote the sentence in hello.txt.
   ```

If **Skills** or **Upload skill** is unavailable, paste the prompt from [PROMPT.md](./PROMPT.md) along with your uploaded `repo-context.txt`.

## 5. Send a practice change and apply `apply-changes.txt`

1. In the same chat (or a new chat with `repo-context.txt` uploaded), send a change request with `/vibecode`:

   ```text
   /vibecode
   Create bridge-test.txt containing the sentence "Bridge works!". Keep the other project files as they are.
   ```

2. Gemini edits and tests the workspace in Python and outputs **`apply-changes.txt`** as a downloadable file in the chat response.
3. Download **`apply-changes.txt`** and drag it into your local **VibeBridgePractice** folder. (If your browser renames repeated downloads to `apply-changes (1).txt`, the watcher automatically detects `apply-changes (*).txt` as well.)
4. In PowerShell, look for **[PATCH]** with the patch ID, **[APPLIED]** for the same ID, and a fresh **[READY]**. For this test, look for `[CREATE] bridge-test.txt`. The watcher deletes the completed `apply-changes.txt` from your project folder and generates an updated `repo-context.txt`.

## Everyday use

1. **Back up your project** and review it for secrets or private files before starting the watcher. To exclude files, create `.repomixignore` in the local project folder and list one project-relative path or pattern per line.
2. **Start the watcher** by double-clicking [start-vibe-bridge.cmd](./start-vibe-bridge.cmd) and entering your local project folder path. Wait for **[READY]**.
3. **Upload `repo-context.txt` once at the start of a chat** and use `/vibecode` to request changes. For follow-up tasks in the same conversation, Gemini retains the updated workspace state in memory so you do not need to re-upload `repo-context.txt` on every turn unless you modified files locally outside of the AI session.
4. **Starting a brand-new project:** If you trigger `/vibecode` without uploading `repo-context.txt`, Gemini initializes a new project from an empty baseline and outputs all new files as `create` operations in `apply-changes.txt`.
5. **Manual local edits:** After editing files yourself on your computer, press **R** in the watcher window to re-pack `repo-context.txt`, and upload the fresh `repo-context.txt` to your chat so Gemini has your latest changes. Press **Q** to stop the watcher.

## Optional completion alerts and turn timer userscript

Install [ntu-gemini-auto-approve.user.js](./ntu-gemini-auto-approve.user.js) in Tampermonkey if you want an on-screen elapsed turn timer and completion alerts (flashing tab title, checkmark favicon badge, chime, in-page banner, and desktop notification) when Gemini finishes a turn.

1. Install [Tampermonkey](https://www.tampermonkey.net/) for Chrome or Edge and enable **Allow User Scripts** in your browser’s extension settings.
2. Open **ntu-gemini-auto-approve.user.js** in Notepad, copy its contents, create a new script in Tampermonkey, paste the code, and press **Ctrl+S**.
3. Refresh the Gemini Enterprise tab. A compact draggable widget appears in the bottom-right corner showing the elapsed turn time (`⌛`) and current state (`🌙 idle`, `⚡ working...`, or `✅ DONE!`).
4. Drag the widget to reposition it, double-click it (or press **Shift+~**) to reset its position, or click it to grant browser notification permissions and dismiss active completion alerts.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| PowerShell says it cannot find `setup.ps1` | Open the extracted bridge folder, type `powershell` into the File Explorer address bar, and retry setup. |
| The launcher says it cannot find `vibe-sync.ps1` | Keep `start-vibe-bridge.cmd`, `vibe-sync.ps1`, and `bridge-delta.cjs` together in the same folder. |
| The watcher rejects a stale snapshot (`Stale snapshot`) | Press **R** in the watcher to refresh `repo-context.txt`, then upload the latest `repo-context.txt` to the chat (or include `VibeBridge: snapshot <ID>` from the latest `[SNAPSHOT]` line) and regenerate `apply-changes.txt`. |
| A patch fails validation | The watcher renames the rejected file to `apply-changes.failed.txt` (or `apply-changes.failed.<timestamp>.txt`) so you can inspect it, and keeps watching. |
| `repo-context.txt` is too large | Add a `.repomixignore` file in your project folder to exclude large data files or build artifacts, then press **R** in the watcher. |
| The timer widget is missing in the browser | Confirm Tampermonkey and the script are enabled, check that **Allow User Scripts** is turned on in your browser extensions page, and refresh the Gemini tab. |

## Project files

| File | Purpose |
| --- | --- |
| [setup.ps1](./setup.ps1) | Installs or checks Node.js and Repomix. |
| [start-vibe-bridge.cmd](./start-vibe-bridge.cmd), [vibe-sync.ps1](./vibe-sync.ps1), [bridge-delta.cjs](./bridge-delta.cjs) | Start the local project watcher, generate `repo-context.txt`, and apply verified `apply-changes.txt` patches. |
| `vibecode/` ([SKILL.md](./vibecode/SKILL.md), [scripts/pack_delta.py](./vibecode/scripts/pack_delta.py)) | `/vibecode` skill instructions and UTF-8 Delta v2 packer. |
| [PROMPT.md](./PROMPT.md) | Standalone prompt alternative to the `/vibecode` skill. |
| [ntu-gemini-auto-approve.user.js](./ntu-gemini-auto-approve.user.js) | Optional Tampermonkey userscript for elapsed turn time and completion alerts. |
| [TEST_LOG.md](./TEST_LOG.md) | Historical test log from development. |
