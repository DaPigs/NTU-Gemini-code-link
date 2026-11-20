# Vibe Bridge prompts for Gemini

Use [Message to paste](#message-to-paste) to start vibe coding in a new Gemini chat when you are not using the imported `/vibecode` skill from `vibecode.zip`.

## Message to paste

Start the local watcher (`vibe-sync.ps1` or `start-vibe-bridge.cmd`) and wait for **[READY] repo-context.txt generated in project folder**. Upload `repo-context.txt` from your project folder into a new Gemini chat (or omit it if starting a brand-new project), paste the block below, and add your coding task at the bottom.

````text
Use the Local Vibe Bridge workflow in this chat:

- **Existing project (`repo-context.txt` uploaded):** Read the project name (`project`) and `snapshotId` directly from the uploaded `repo-context.txt`. If this message only uploads `repo-context.txt` without a task, parse the snapshot in Python and confirm what you found.
- **New project (no `repo-context.txt` uploaded):** Treat this as starting a brand-new project from an empty baseline workspace (`files: {}`). Ask for the target project folder name only if none was provided in the prompt.

An explicit change or project-creation request includes generating and outputting `apply-changes.txt` as a downloadable file in the same turn. Questions, reviews, and drafts are read-only.

## Recommended Workflow (Zero-Hallucination & Single-Read Execution)

1. **Zero-hallucination handoffs & execution:**
   - Execute inside the Python code interpreter (`file_and_coding_agent` or `tool_code_executor`) to read the uploaded `repo-context.txt` (or initialize an empty project snapshot), reconstruct and test the workspace, and write `apply-changes.txt` to disk as a downloadable attachment.
   - **Never hallucinate, fabricate, summarize away, or alter file paths, snapshot IDs, file contents, or task requirements** when transferring context between agents. Always parse `repo-context.txt` directly from the actual uploaded file in the Python runtime.
2. **Read `repo-context.txt` ONLY ONCE per uploaded snapshot:**
   - Parse the uploaded `repo-context.txt` once at the start of the session (or when a fresh `repo-context.txt` is uploaded).
   - For follow-up tasks in the same conversation where no new `repo-context.txt` is uploaded, treat your isolated Python workspace / updated in-memory snapshot baseline as the authoritative state on the user's computer.
3. **Keep all code in UTF-8 format:**
   - All file operations (`edit`, `create`, `delete`) operate strictly on UTF-8 text files. Binary Base64 packaging is not supported.
4. **Output `apply-changes.txt` as a downloadable file:**
   - Write the validated two-line ASCII delta directly to `Path("apply-changes.txt")` in the current working directory so the user can download it and drag it into their local project folder.

## Read the initial snapshot or initialize a new project

### Case A: `repo-context.txt` is uploaded (Existing Project)
The snapshot is JSON with format `vibebridge-snapshot-v2`. In Python:
- Parse the uploaded file as JSON and verify `snapshot["format"] == "vibebridge-snapshot-v2"`.
- Copy `snapshot["project"]` and `snapshot["snapshotId"]` from the parsed object.
- If the user includes `VibeBridge: snapshot <ID>`, compare it with `snapshot["snapshotId"]` before editing and pass that ID to `pack_delta` as `expected_snapshot_id`.
- Reconstruct editable text files with `snapshot_bytes(entry)` into an isolated workspace directory before editing, preserving each file's UTF-8 BOM, line endings (`lf` vs `crlf`), and final newline.

### Case B: No `repo-context.txt` is uploaded (Starting a New Project)
- Create a clean isolated workspace directory.
- Initialize an in-memory `vibebridge-snapshot-v2` dictionary:
  ```python
  import uuid
  snapshot = {
      "format": "vibebridge-snapshot-v2",
      "project": project_name,
      "snapshotId": expected_snapshot_id or str(uuid.uuid4()),
      "files": {}
  }
  ```

## Deliver the change as `apply-changes.txt` in the same turn

1. Create, edit, and test the files in the isolated workspace inside Python.
2. Run `pack_delta()` below against the in-memory snapshot baseline and the final tested files, passing explicit changed path lists (`edit`, `create`, `delete`).
3. Validate the output with `validate_delta_envelope(content, snapshot["project"])`.
4. Write the exact ASCII bytes to `apply-changes.txt` in the current working directory:
   ```python
   from pathlib import Path
   Path("apply-changes.txt").write_bytes(content.encode("ascii"))
   ```
5. Reply with a short summary of changes, verification checks, project name, snapshot ID, patch ID, and byte count, and let the user know `apply-changes.txt` is ready to download and drag into their project folder. Keep full source and raw delta JSON out of the visible reply.

## Python packer

```python
import json
import uuid
from difflib import SequenceMatcher
from pathlib import Path

DELTA_HEADER = "# VibeBridge Delta v2"
PATCH_LIMIT = 7_000_000


def validate_delta_envelope(content, project):
    """Read delta metadata without rewriting the text used for output."""
    if not isinstance(content, str) or not content.isascii() or len(content) > PATCH_LIMIT:
        raise ValueError("Expected an ASCII delta within the bridge size limit")
    header, newline, body = content.partition("\n")
    if not newline or header not in (DELTA_HEADER, DELTA_HEADER + "\r"):
        raise ValueError("Expected the VibeBridge Delta v2 header")

    def reject_constant(value):
        raise ValueError(f"Invalid JSON constant in delta: {value}")

    package = json.loads(body, parse_constant=reject_constant)
    if not isinstance(package, dict) or package.get("version") != 2:
        raise ValueError("Expected a Delta v2 JSON object")
    if package.get("project") != project:
        raise ValueError("Delta project does not match the destination")
    for key in ("snapshotId", "patchId"):
        value = package.get(key)
        if not isinstance(value, str) or str(uuid.UUID(value)) != value:
            raise ValueError(f"Expected a canonical delta {key}")
    operations = package.get("operations")
    if not isinstance(operations, list) or not 1 <= len(operations) <= 200:
        raise ValueError("Expected 1 to 200 delta operations")
    return package


def exact_bytes(text, entry):
    if entry["eol"] == "crlf":
        text = text.replace("\n", "\r\n")
    return (("\ufeff" if entry["bom"] else "") + text).encode("utf-8")


def snapshot_bytes(entry):
    if entry.get("eol") not in ("lf", "crlf"):
        raise ValueError("No exact text bytes in snapshot")
    return exact_bytes(entry["text"], entry)


def text_edits(old, new):
    before, after = old.splitlines(keepends=True), new.splitlines(keepends=True)
    matcher = SequenceMatcher(None, before, after)
    for context in (1, 3, 8, 24):
        pairs = []
        for group in matcher.get_grouped_opcodes(context):
            start, end = group[0], group[-1]
            a = "".join(before[start[1]:end[2]])
            b = "".join(after[start[3]:end[4]])
            pairs.append((a, b))
        if all(a and old.find(a, old.index(a) + 1) == -1 for a, _ in pairs):
            break
    else:
        pairs = [(old, new)]
    cursor, rebuilt = 0, []
    for a, b in pairs:
        start = old.index(a)
        if start < cursor:
            raise ValueError("Overlapping edits")
        rebuilt.extend((old[cursor:start], b))
        cursor = start + len(a)
    if "".join(rebuilt) + old[cursor:] != new:
        raise ValueError("Edits do not reproduce the tested text")
    return [{"before": a, "after": b} for a, b in pairs]


def project_file(root, name):
    if root is None or "\\" in name or ":" in name or any(
        part in ("", ".", "..") for part in name.split("/")
    ):
        raise ValueError(f"Expected a project-relative file path: {name}")
    root = Path(root).resolve()
    file = (root / name).resolve()
    if not file.is_relative_to(root):
        raise ValueError(f"File escapes the workspace: {name}")
    return file


def pack_delta(snapshot, workspace, *, edit=(), create=(), delete=(),
               expected_snapshot_id=None):
    if snapshot["format"] != "vibebridge-snapshot-v2":
        raise ValueError("Expected a v2 snapshot")
    snapshot_id = snapshot["snapshotId"]
    if expected_snapshot_id is not None and snapshot_id != expected_snapshot_id:
        raise ValueError(f"Snapshot {snapshot_id} differs from expected {expected_snapshot_id}")
    operations, seen = [], set()
    for kind, paths in (("edit", edit), ("create", create), ("delete", delete)):
        for name in paths:
            if name.lower() in seen:
                raise ValueError(f"Duplicate operation: {name}")
            seen.add(name.lower())
            entry = snapshot["files"].get(name, {})
            exact = entry.get("eol") in ("lf", "crlf")
            file = project_file(workspace, name)
            op = {"op": kind, "path": name}
            if kind == "create" and entry:
                raise ValueError(f"Create would overwrite a snapshot file: {name}")
            if kind == "edit" and not exact:
                raise ValueError(f"Missing exact snapshot text: {name}")
            if kind == "delete":
                if file.exists():
                    raise ValueError(f"Remove the file from the tested workspace: {name}")
                op["confirmDelete"] = True
            else:
                data = file.read_bytes()
                if b"\0" in data:
                    raise ValueError(f"Binary files are not supported (expected UTF-8 text): {name}")
                if kind == "edit":
                    if data == snapshot_bytes(entry):
                        continue
                    try:
                        text = data.decode("utf-8-sig").replace("\r\n", "\n")
                    except UnicodeDecodeError as exc:
                        raise ValueError(f"Expected valid UTF-8 text: {name}") from exc
                    if "\r" in text or exact_bytes(text, entry) != data:
                        raise ValueError(f"Restore the original BOM and line endings: {name}")
                    op["edits"] = text_edits(entry["text"], text)
                else:
                    try:
                        op["text"] = data.decode("utf-8")
                    except UnicodeDecodeError as exc:
                        raise ValueError(f"Expected valid UTF-8 text for created file: {name}") from exc
            operations.append(op)
    if not 1 <= len(operations) <= 200:
        raise ValueError("Expected 1 to 200 changed files")
    package = {"version": 2, "project": snapshot["project"],
               "snapshotId": snapshot_id, "patchId": str(uuid.uuid4()),
               "operations": operations}
    content = DELTA_HEADER + "\n" + json.dumps(package, ensure_ascii=True, separators=(",", ":"))
    if len(content) > PATCH_LIMIT:
        raise ValueError("Delta exceeds the 7,000,000-byte bridge budget")
    return content
```
````
