---
name: vibecode
description: Use the Local Vibe Bridge to read a manually uploaded repo-context.txt snapshot once (or initialize a new project if none is uploaded) and deliver requested changes as a verified downloadable apply-changes.txt delta file against the in-memory workspace state.
---

# Vibe Code (Local File Upload & Download Workflow)

Trigger `/vibecode` and write your task directly:

```text
/vibecode
Add a unit test for an empty schedule.
```

- **Existing project (`repo-context.txt` uploaded):** No project folder name is required in the command because the project metadata (`project` and `snapshotId`) is embedded inside the uploaded `repo-context.txt`. If the user uploads `repo-context.txt` without specifying a task, read and parse its snapshot in the Python workspace and wait for a task.
- **New project (no `repo-context.txt` uploaded):** If no `repo-context.txt` is uploaded at the start of the session, treat the request as starting a brand-new project from an empty baseline workspace (`files: {}`). Ask the user for the exact target project folder name only if `apply-changes.txt` requires a matching `"project"` name and none was mentioned in the prompt; otherwise use the folder name specified by the user.

An explicit change or project-creation request includes generating and outputting `apply-changes.txt` as a downloadable file in the same turn. Questions, reviews, and drafts are read-only.

## Recommended Workflow (Zero-Hallucination Agent Handoff & Single-Read Execution)

For all `/vibecode` tasks:

1. **Allow execution in the code-interpreter agent (`file_and_coding_agent`) with strict zero-hallucination handoffs.**
   - Execute inside or transfer to `file_and_coding_agent` (or the active Python code execution environment) to read the user-uploaded `repo-context.txt` (or initialize an empty project snapshot), reconstruct and test the workspace in Python, and write `apply-changes.txt` to disk as a downloadable file attachment.
   - **CRITICAL ANTI-HALLUCINATION RULE:** When transferring control or context between `root_agent` and `file_and_coding_agent`, **never hallucinate, fabricate, summarize away, or alter file paths, snapshot IDs, file contents, or task requirements.**
   - When `repo-context.txt` is provided, always parse it directly from the actual uploaded file in the Python runtime (`input_file_*.txt` or `repo-context.txt` on disk / conversation upload tags)—never rely on paraphrased memory or intermediate agent summaries of code content.
   - Generate `apply-changes.txt` directly inside the Python execution environment so the runtime attaches the exact, unmodified file to the chat response without copying or re-typing patch contents through agent text messages.
2. **Read `repo-context.txt` ONLY ONCE per uploaded snapshot.**
   - Parse the uploaded `repo-context.txt` at the start of the session (or when the user explicitly uploads a new `repo-context.txt`) to reconstruct the initial project workspace.
   - If no `repo-context.txt` is uploaded, initialize an in-memory `vibebridge-snapshot-v2` baseline object with an empty `files` dictionary (`{}`) and an isolated workspace directory.
   - For follow-up tasks in the same conversation where no new `repo-context.txt` is uploaded, **assume the project on the user's laptop reflects the exact state left by your previous patch** (i.e., your isolated Python workspace / updated in-memory snapshot baseline already represents the current ground truth). Update your in-memory snapshot baseline directly from your tested workspace.
   - If the user uploads a fresh `repo-context.txt` in a later turn, always parse and adopt that newly uploaded `repo-context.txt` as the authoritative baseline.
3. **Keep all code in UTF-8 format (no binary Base64 packaging).**
   - Use the Python code interpreter to reconstruct or create the workspace, run tests, and call the bundled `scripts/pack_delta.py` (`pack_delta` + `validate_delta_envelope`).
   - All file operations (`edit`, `create`, `delete`) operate strictly on UTF-8 text files.
4. **Output `apply-changes.txt` as a downloadable file in the chat.**
   - Write the exact two-line ASCII output of `pack_delta()` to `apply-changes.txt` in the current working directory of the Python code interpreter (`Path("apply-changes.txt").write_bytes(content.encode("ascii"))`) so the user can download `apply-changes.txt` and drag it directly into their local project folder.

## Read the initial snapshot or initialize a new project

### Case A: `repo-context.txt` is uploaded (Existing Project)
Locate the uploaded file in the Python execution environment (check `os.listdir('.')` for `repo-context.txt` or the corresponding `input_file_*.txt` attachment, or parse the exact uploaded file content). Do not guess or fabricate file contents.

The snapshot is JSON with format `vibebridge-snapshot-v2`. In the Python code interpreter:
- Parse the uploaded file as JSON and verify `snapshot["format"] == "vibebridge-snapshot-v2"`.
- Read `snapshot["project"]` and `snapshot["snapshotId"]` directly from the parsed JSON object.
- If the user includes `VibeBridge: snapshot <ID>`, compare it with the active `snapshot["snapshotId"]` before editing and pass that ID to `pack_delta` as `expected_snapshot_id`.
- For editable text files, reconstruct the original bytes with `snapshot_bytes(entry)` from `pack_delta.py` and write those exact bytes into an isolated workspace directory (e.g., `/tmp/workspace` or `./workspace`) before editing.
- Preserve each file's UTF-8 BOM, line endings (`lf` vs `crlf`), and final newline unless the task explicitly changes the final newline.
- If the uploaded snapshot uses an older format, ask the user to run the updated `vibe-sync.ps1` and upload the generated `repo-context.txt`.

### Case B: No `repo-context.txt` is uploaded (Starting a New Project)
If the user triggers `/vibecode` without uploading `repo-context.txt`, treat it as starting a new project:
- Create a clean isolated workspace directory (e.g., `./workspace`).
- Construct an initial in-memory `vibebridge-snapshot-v2` dictionary:
  ```python
  import uuid
  snapshot = {
      "format": "vibebridge-snapshot-v2",
      "project": project_name,  # Folder name provided by user (or ask if not specified)
      "snapshotId": expected_snapshot_id or str(uuid.uuid4()),
      "files": {}
  }
  ```
- Note: If the user has already initialized `vibe-sync.ps1` on an empty folder and provides `VibeBridge: snapshot <ID>` (or uploads the empty folder's `repo-context.txt`), use that exact `project` name and `snapshotId` so the watcher accepts `apply-changes.txt` without a snapshot ID mismatch. Otherwise, remind the user that if they use `vibe-sync.ps1` to apply the initial `apply-changes.txt`, the watcher checks that `project` and `snapshotId` match the folder's active `.vibebridge-state`.

## Deliver the change as `apply-changes.txt` in the same turn

1. Create, edit, and test the files in the isolated workspace inside the Python code interpreter.
2. Run `pack_delta()` against the in-memory snapshot baseline and the final tested files in your isolated workspace, passing the explicit changed path lists (`edit`, `create`, `delete`).
   - `edit` emits exact contextual `edits` for modified UTF-8 text files present in the baseline snapshot.
   - `create` emits a UTF-8 `text` string for new files (including all files when starting a new project).
   - `delete` emits `confirmDelete: true` for user-authorized file deletions (after removing the file from the tested workspace).
3. Validate the generated delta string by calling `validate_delta_envelope(content, snapshot["project"])`.
   - Ensure the package is a strict two-line ASCII string: line 1 is `# VibeBridge Delta v2` and line 2 is a single-line JSON string with escaped `
` sequences and zero literal line breaks inside the JSON body.
4. Write the validated delta string directly to `apply-changes.txt` in the current working directory of the code interpreter:
   ```python
   from pathlib import Path
   Path("apply-changes.txt").write_bytes(content.encode("ascii"))
   ```
5. Reply with a concise summary of the changes, verification/tests run, project name, snapshot ID, patch ID, byte count, and confirm that `apply-changes.txt` is ready to be dragged into the local project folder. Keep full source and raw delta JSON out of the visible chat text so the response stays clean.

## Python packer

Load the bundled `scripts/pack_delta.py` from the skill directory when mounted, or via `load_skill_resource(skill_name="vibecode", file_path="scripts/pack_delta.py")`, or directly from the workspace if uploaded:

```python
import runpy
from pathlib import Path

namespace = runpy.run_path(str(skill_directory / "scripts" / "pack_delta.py"))
snapshot_bytes = namespace["snapshot_bytes"]
pack_delta = namespace["pack_delta"]
validate_delta_envelope = namespace["validate_delta_envelope"]
```

- Call `snapshot_bytes(entry)` to reconstruct editable UTF-8 snapshot files into the isolated workspace.
- Call `pack_delta(snapshot, workspace, edit=[...], create=[...], delete=[...], expected_snapshot_id=...)` with the retained snapshot, the tested workspace path, and explicit `edit`, `create`, or `delete` path lists. Use `delete` only for user-authorized deletions.
- Call `validate_delta_envelope(content, snapshot["project"])` before writing `apply-changes.txt`.
- Write the exact ASCII bytes to `Path("apply-changes.txt")` so the runtime provides it as a downloadable file in the chat.
