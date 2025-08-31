# Epoch Uploader — Build & Run (Windows)

A tiny background app that watches your **SavedVariables** folder for `epochhead.lua`, uploads new data to your server, and (on success) renames the file to `epochhead_uploadYYYYmmdd-HHMMSS.lua`.  
Single-instance, no tray dependencies, no Python required for end users once you build the `.exe`.

## 1) Prerequisites (build machine)

- **Windows 10/11 (64-bit)**
- **Python 3.9+ (64-bit)** installed and on PATH  
  Verify:
  ```bash
  python --version
  ```
- **PyInstaller**:
  ```bash
  python -m pip install --upgrade pip
  python -m pip install pyinstaller
  ```

> End users **do not** need Python—only the built `.exe`.

## 2) Project files

Make sure this file is present:
- `epoch_uploader.py`  ← the single-file app (GUI + watcher + uploader)

The server address/token are **hard-coded** near the top of the file:
```python
SERVER = "http://193.233.161.214:5001"
TOKEN  = "devtoken"
```
Change these if needed, then rebuild.

## 3) Build the EXE

From the folder containing `epoch_uploader.py`:

```bash
python -m PyInstaller --onefile --windowed --name epoch_uploader epoch_uploader_gui.py
```

Optional:
- Use a custom icon: add `--icon path\to\icon.ico`
- Rebuild without prompts: add `--noconfirm`
- Debug (console visible): drop `--windowed`

**Output:** `dist/epoch_uploader.exe`  
You can copy that single file anywhere and run it.

## 4) First run & usage

1. **Double-click** `epoch_uploader.exe`.
2. On first launch you’ll be asked to **select a folder**.  
   Pick your **SavedVariables** folder, e.g.:
   ```
   GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables
   ```
3. The app will:
   - Watch `epochhead.lua` for changes (polling, debounced).
   - Upload on change.
   - On successful upload, **rename** the file to `epochhead_uploadYYYYmmdd-HHMMSS.lua`.
4. **Close** the window to keep it **running in the background**.  
   Launching the app again will bring the window back (single-instance).

**Config location:** `%APPDATA%\EpochUploader\config.json`  
(Stores only the chosen folder path; server/token are hard-coded in the exe.)
