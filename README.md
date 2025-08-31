# EpochHead

Community-powered data collection for Project Epoch (Classic WoW): a lightweight in-game addon plus a desktop uploader that ships collected data to your backend for indexing and search.

> **What’s here?**
>
> - **WoW Addon** (3.3.5a-safe) — logs kills, loot, quests, fishing, etc. into `SavedVariables\epochhead.lua`.
> - **Windows Uploader** — watches your `SavedVariables` folder; when `epochhead.lua` changes, it uploads and then archives the file with a timestamp.

---

## Repository layout

```
/EpochHead/       # The WoW addon (place into Interface/AddOns on 3.3.5a clients)
/uploader/        # The desktop uploader (source used to build epoch_uploader.exe)
```

---

## How it works (end-to-end)

1. **Install the addon** and play normally.
2. The addon writes events to:  
   `GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables\epochhead.lua`
3. **Run the uploader app**:
   - On first launch it asks you to select the **SavedVariables folder** (not the file).  
     Example: `GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables`
   - It **watches** for changes to `epochhead.lua` and **auto-uploads**.
   - On **successful upload**, it **renames** the file to `epochhead_uploadYYYYmmdd-HHMMSS.lua` to prevent re-uploading the same data.
   - Closing the window keeps it running in the background (single-instance behavior).

---

## Addon installation

1. Copy the addon folder to your WoW client:
   ```
   <WoW 3.3.5a>\Interface\AddOns\EpochHead
   ```
2. Enable **EpochHead** at the character select screen → AddOns.
3. Optional in-game commands:
   - `/eh` — ping
   - `/eh debug on` — verbose logging in chat
   - `/eh debug off` — stop verbose logging

> The addon writes to `SavedVariables\epochhead.lua` under your account folder, which the uploader monitors.

---

## Uploader (Windows)

### Quick start

1. Download `epoch_uploader.exe` from Releases (or build it yourself; see below).
2. Double-click to run. On first launch, select your **SavedVariables folder**:
   ```
   GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables
   ```
3. Leave it running; it will upload automatically whenever `epochhead.lua` changes.  
   After a successful upload, the file is archived as `epochhead_uploadYYYYmmdd-HHMMSS.lua`.

### Build the uploader from source

1. Install **Python 3.9+** and pip.
2. Install **PyInstaller**:
   ```bash
   python -m pip install --upgrade pip
   python -m pip install pyinstaller
   ```
3. From the `/uploader` folder:
   ```bash
   python -m PyInstaller --onefile --name epoch_uploader --noconsole epoch_uploader.py
   ```
4. The binary will be in `dist/epoch_uploader.exe`.

> Tip: If Windows SmartScreen warns you, click “More info → Run anyway.”

---

## Server expectations (summary)

The uploader posts JSON to your server’s `/upload` endpoint (HTTP POST). Your server should:

- Accept a body like:
  ```json
  { "token": "<your-token>", "payload": { "events": [...], "meta": {...} } }
  ```
- Write raw uploads to disk and/or materialize **derived** JSON (e.g., `derived/mob.json`, `derived/quest.json`, etc.) for your web UI to read.

*(Server code is out of scope of this repo; configure your API base URL in your site accordingly.)*

---

## Troubleshooting

- **Nothing uploads**  
  - Make sure you selected the **folder** `…\SavedVariables`, not the Lua file itself.  
  - Confirm the game has actually written a fresh `epochhead.lua` (log out or reload UI).
- **Uploader says “file not found”**  
  - Verify you’re pointing at the correct WoW account folder (private servers often use custom account names).
- **Duplicates**  
  - Files are renamed on success. If you see re-uploads, check that the server returns HTTP 200 and allows overwriting/merging appropriately.
- **Windows blocks the EXE**  
  - Use “More info → Run anyway”, or build locally with PyInstaller (see above).

---

## Roadmap

- More event types (trainers, vendors) parity and richer tooltips.
- Optional metrics in the uploader (throughput, last response).

---

## Credits

Thanks to the Project Epoch community and contributors who gather and upload data.
