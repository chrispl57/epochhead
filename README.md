# EpochHead

Community‑powered data collection for **Project Epoch (Classic WoW 3.3.5a)** — a lightweight **in‑game addon** plus an optional **desktop uploader** that ships your collected data to the EpochHead backend for indexing and search.

- **Website:** <https://epochhead.com>
- **Releases (Windows uploader .exe):** <https://github.com/chrispl57/epochhead/releases/latest>
- **Manual upload (Linux/macOS or anyone preferring a browser):** <https://epochhead.com/upload>

* * *

> **What’s here?**
>
> - **WoW Addon (3.3.5a‑safe)** — logs kills, loot, containers, fishing, quest choices, vendors, and money events into `SavedVariables\epochhead.lua`.
> - **Windows Uploader (Recommended)** — watches your `SavedVariables` folder; when `epochhead.lua` changes, it uploads automatically and archives the file with a timestamp.
> - **Manual Upload** — a web page for Linux/macOS (or anyone) to upload `epochhead.lua` via browser.

* * *

## Repository layout

```
/EpochHead/       # The WoW addon (place into Interface/AddOns on 3.3.5a clients)
/uploader/        # The desktop uploader (Python source, optional if you don't use the .exe)
```

* * *

## How it works (end‑to‑end)

1. Install the addon and play normally.
2. The addon writes events to:  
   `GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables\epochhead.lua`
3. **Choose one upload method:**
   - **Windows (recommended):** run the uploader; it auto‑uploads on changes and renames the file to prevent re‑uploads.
   - **Linux/macOS or browser:** visit <https://epochhead.com/upload> and select your `epochhead.lua`.

* * *

## Addon installation

1. Copy the addon folder to your WoW client:

       <WoW 3.3.5a>\Interface\AddOns\EpochHead

2. Enable **EpochHead** at the character select screen → AddOns.
3. Optional in‑game commands:
   - `/eh` — ping
   - `/eh debug on` — verbose logging in chat
   - `/eh debug off` — stop verbose logging

> The addon writes to `SavedVariables\epochhead.lua` under your account folder, which the uploader (or web upload) consumes.

* * *

## Uploading your data

### ✅ Windows (Recommended) — use the prebuilt uploader

- **Get the .exe:** Download **`epoch_uploader.exe`** from the **[Releases page](https://github.com/chrispl57/epochhead/releases/latest)**.
- Run it. It watches your `SavedVariables` folder; when `epochhead.lua` changes, it uploads automatically and archives the file with a timestamp.

> If you prefer to build the uploader yourself, the Python source is in `/uploader/` and can be packaged with PyInstaller. The .exe is still the simplest path for Windows users.

### 🌐 Linux / macOS — use the web upload

- Go to **<https://epochhead.com/upload>** and select your `epochhead.lua`.
- Click **Upload**. That’s it.

**Optional CLI (any OS):**
```bash
# Replace the path with your SavedVariables location
curl -X POST "https://epochhead.com/upload" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@/path/to/WTF/Account/<ACCOUNT_NAME>/SavedVariables/epochhead.lua"
```

* * *

## Typical data locations

**SavedVariables file to upload:**
- **Windows:**  
  `C:\Program Files (x86)\World of Warcraft\WTF\Account\<ACCOUNT_NAME>\SavedVariables\epochhead.lua`  
  *(Your WoW folder may be outside Program Files on private clients; adjust accordingly.)*
- **macOS:**  
  `/Applications/World of Warcraft/WTF/Account/<ACCOUNT_NAME>/SavedVariables/epochhead.lua`  
  *(Or the path where you installed your 3.3.5a client.)*
- **Linux (Wine/Proton):**  
  `<WoW folder>/WTF/Account/<ACCOUNT_NAME>/SavedVariables/epochhead.lua`

* * *

## Troubleshooting

- **Uploader can’t find my SavedVariables folder**  
  Point it to your **client’s actual install path** (private clients often live outside `Program Files`).

- **Large or slow uploads**  
  That’s normal for first‑time uploads; subsequent uploads only send new data.

- **Addon error or blocked action**  
  Some client UIs block certain protected actions. These warnings don’t affect data capture and can be ignored unless they prevent normal gameplay. Please open an Issue with a screenshot if it’s disruptive.

- **I uploaded the wrong file**  
  Re‑upload the correct `epochhead.lua`. The backend uses de‑dupe and merging; duplicates are ignored.

- **`epochhead.lua` not found**  
  The file is written on **/reload** or **game exit**. The uploader automatically renames it after a successful upload; seeing “not found” right after an upload is expected for new users or immediately post‑upload.

* * *

## Contributing

Issues and PRs are welcome! If you’re adding new event types or improving de‑dupe/merging, please include:
- A short description of the new fields/events.
- Example snippets from `epochhead.lua`.
- Any migration or backfill logic required on the server side.

* * *

## Disclaimer

EpochHead is a community fan project. It is not affiliated with Blizzard Entertainment. Use at your own risk on private clients. Do not use for commercial purposes.