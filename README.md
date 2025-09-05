# EpochHead

> **📥 WINDOWS USERS — NO PYTHON REQUIRED**  
> **Download the ready-made uploader here:**  
> 👉 **[epoch_uploader.exe (Latest Releases)](../../releases/latest/download/epoch_uploader.exe)**  
> *(If that direct link doesn’t work in your viewer, open the Releases page: [See all releases →](../../releases))*

Community-powered data collection for Project Epoch (Classic WoW): a lightweight in-game addon plus a desktop uploader that ships collected data to your backend for indexing and search.

> **What’s here?**
>
> - **WoW Addon** (3.3.5a-safe) — logs kills, loot, quests, fishing, etc. into `SavedVariables\epochhead.lua`.
> - **Windows Uploader** — watches your `SavedVariables` folder; when `epochhead.lua` changes, it uploads and then archives the file with a timestamp.

---

## 🚀 Quick Start (Windows – recommended)

1. **Download:** 👉 **[epoch_uploader.exe](../../releases/latest/download/epoch_uploader.exe)**  
   *(Or open [Releases](../../releases) and grab `epoch_uploader.exe` from the latest tag.)*
2. **Run it.** On first launch, **select your SavedVariables folder** (the folder, not the file), e.g.:  
   ```
   <WoW 3.3.5a>\WTF\Account\<ACCOUNTNAME>\SavedVariables
   ```
3. Play normally. Whenever `epochhead.lua` updates, the uploader **auto-uploads** it and then **archives** it as:  
   `epochhead_uploadYYYYmmdd-HHMMSS.lua`

> 🧰 SmartScreen note: Windows may warn about unrecognized apps. Click **More info → Run anyway**, or build from source (below).

---

## Repository Layout

```
/EpochHead/       # The WoW addon (place into Interface/AddOns on 3.3.5a clients)
/uploader/        # The desktop uploader (source used to build epoch_uploader.exe)
```

---

## How It Works (end-to-end)

1. **Install the addon** and play normally.
2. The addon writes events to:  
   `GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables\epochhead.lua`
3. **Run the uploader app**:
   - On first launch it asks for the **SavedVariables folder** (not the file).  
     Example: `GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables`
   - It **watches** for changes to `epochhead.lua` and **auto-uploads**.
   - On **success**, it **renames** the file to `epochhead_uploadYYYYmmdd-HHMMSS.lua` to prevent re-uploads.
   - Closing the window keeps it running in the background (single-instance behavior).

---

## Addon Installation

1. Copy the addon folder to your WoW client:
   ```
   <WoW 3.3.5a>\Interface\AddOns\EpochHead
   ```
2. Enable **EpochHead** at the character select screen → AddOns.
3. Optional in-game commands:
   - `/eh` — ping
   - `/eh debug on` — verbose logging in chat
   - `/eh debug off` — stop verbose logging

> The addon writes to `SavedVariables\epochhead.lua`, which the uploader monitors.

---

## 🐍 Prefer to Build the Uploader Yourself?

> You don’t need Python if you use the EXE above. This section is only for folks who want to build locally.

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
4. The binary will be in: `dist/epoch_uploader.exe`

---

## Troubleshooting

- **Nothing uploads**
  - Make sure you selected the **folder** `…\SavedVariables`, not the Lua file itself.
  - Confirm the game actually wrote a fresh `epochhead.lua` (log out or `/reload`).
- **Uploader says “file not found”**
  - Verify you’re pointing at the correct WoW account folder (private servers often use custom account names).
- **Duplicates**
  - Files are renamed on success. If you see re-uploads, check the server returns HTTP 200 and merges correctly.
- **Windows blocks the EXE**
  - Use “More info → Run anyway”, or build locally with PyInstaller.

---

## Roadmap

- More event types (trainers, vendors) parity and richer tooltips.
- Optional metrics in the uploader (throughput, last response).

---

## Credits

Thanks to the Project Epoch community and contributors who gather and upload data.

Issues with uploader/addon? Open an issue or contact on Discord: **_macetotheface_**.
