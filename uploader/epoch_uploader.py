#!/usr/bin/env python3
# EpochHead Uploader (Windows/Tk) — with controls & AV-friendly behavior
# - Watches SavedVariables\epochhead.lua and uploads changes
# - Top row controls: [Upload now] [Auto-upload] [Start with Windows] [Pause watching] [Open SV Folder] [Open Log]
# - Status strip shows last upload + server stats; optional addon version warning banner
# - Exponential backoff + min-interval between uploads
# - Single instance (best-effort), no external deps

import os, sys, json, time, threading, queue, re, socket, logging, logging.handlers, glob
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

try:
    import pystray
    from PIL import Image, ImageDraw
except Exception:
    pystray = None
    Image = None

# ------------------ FIXED SETTINGS ------------------
APP_NAME           = "Epoch Uploader"
APP_VERSION        = "1.5.0"
SERVER             = "http://85.137.248.214:5001"
TOKEN              = "devtoken"
VAR_NAME           = "epochheadDB"
AUTO_RENAME        = True
POLL_INTERVAL_SEC  = 0.75
DEBOUNCE_SEC       = 0.75
RETRY_ON_PARSE_SEC = 1.25
UPLOAD_ENDPOINT    = "/upload"
LOG_MAX_LINES      = 500
MIN_SUCCESS_SPACING= 5.0  # seconds between successful uploads
PRIMARY_SV_FILE    = "epochhead.lua"
TARGET_SV_FILES    = ("aux-addon.lua", "epochhead.lua", "Auctionator.lua", "EpochCensus.lua")

# Single-instance (best effort) + activation ping
MUTEX_NAME   = r"Global\EpochUploaderMutex_v2"
ACTIVATE_PORT = 52931

# Config/Logs
APPDATA_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "EpochUploader")
CONFIG_PATH = os.path.join(APPDATA_DIR, "config.json")
LOG_PATH    = os.path.join(APPDATA_DIR, "uploader.log")

# Defaults for toggles
DEFAULT_AUTO_UPLOAD      = True
DEFAULT_START_WITH_WIN   = False
DEFAULT_PAUSE_WATCHING   = False
DEFAULT_START_MINIMIZED  = False
DEFAULT_START_SILENT     = False
DEFAULT_CLEANUP_KEEP_FILES = 30

# --------------- Logging (rotating) ---------------
def _ensure_appdata():
    try: os.makedirs(APPDATA_DIR, exist_ok=True)
    except Exception: pass

def _init_file_log():
    _ensure_appdata()
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(logging.INFO)
    h = logging.handlers.RotatingFileHandler(LOG_PATH, maxBytes=512*1024, backupCount=3, encoding="utf-8")
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    h.setFormatter(fmt)
    root.addHandler(h)
    root.info("%s %s starting", APP_NAME, APP_VERSION)

_init_file_log()

# --------------- Single-instance helpers ---------------
def _windows_mutex_singleton():
    try:
        import ctypes
        from ctypes import wintypes
        kernel32 = ctypes.windll.kernel32
        CreateMutexW = kernel32.CreateMutexW
        CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
        CreateMutexW.restype = wintypes.HANDLE
        GetLastError = kernel32.GetLastError
        ERROR_ALREADY_EXISTS = 183
        h = CreateMutexW(None, False, MUTEX_NAME)
        already = (GetLastError() == ERROR_ALREADY_EXISTS) or (h == 0)
        return h, already
    except Exception:
        return None, False

def _send_activation_ping():
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
            s.settimeout(0.25)
            s.sendto(b"SHOW", ("127.0.0.1", ACTIVATE_PORT))
    except Exception:
        pass

def _start_activation_listener(on_show_callback):
    def _loop():
        try:
            with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
                s.bind(("127.0.0.1", ACTIVATE_PORT))
                while True:
                    data, _ = s.recvfrom(64)
                    if data:
                        try: on_show_callback()
                        except Exception: pass
        except Exception:
            pass
    threading.Thread(target=_loop, daemon=True).start()

# --------------- Config helpers ---------------
def load_config():
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}

def save_config(cfg: dict):
    _ensure_appdata()
    try:
        with open(CONFIG_PATH, "w", encoding="utf-8") as f:
            json.dump(cfg, f, indent=2)
    except Exception:
        pass

# --------------- Windows autostart ---------------
def get_autostart_enabled():
    try:
        import winreg, os
        name = "EpochUploader"
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_READ) as key:
            v, _ = winreg.QueryValueEx(key, name)
            exe  = os.path.abspath(sys.argv[0])
            return isinstance(v, str) and (os.path.basename(exe) in v or exe in v)
    except Exception:
        return False

def set_autostart(enabled: bool):
    try:
        import winreg, os
        name = "EpochUploader"
        exe  = os.path.abspath(sys.argv[0])
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Run", 0, winreg.KEY_ALL_ACCESS) as key:
            if enabled:
                winreg.SetValueEx(key, name, 0, winreg.REG_SZ, f'"{exe}"')
            else:
                try: winreg.DeleteValue(key, name)
                except FileNotFoundError: pass
        return True
    except Exception as e:
        logging.warning("set_autostart failed: %s", e)
        return False

# --------------- Lua minimal parse ---------------
MOB_PREFIX_RE = re.compile(r'^mob:', re.I)

def _strip_lua_comments(s: str) -> str:
    out = []; i=0; n=len(s); in_str=False; q=''; in_line=False; in_block=False
    while i<n:
        ch=s[i]
        if in_line:
            if ch=='\n': in_line=False; out.append(ch)
            i+=1; continue
        if in_block:
            if i+1<n and s[i:i+2]==']]': in_block=False; i+=2; continue
            i+=1; continue
        if not in_str and ch=='-' and i+1<n and s[i+1]=='-':
            if i+3<n and s[i+2]=='[' and s[i+3]=='[':
                in_block=True; i+=4; continue
            else:
                in_line=True; i+=2; continue
        if in_str:
            out.append(ch)
            if ch=='\\' and i+1<n: out.append(s[i+1]); i+=2; continue
            if ch==q: in_str=False
            i+=1; continue
        else:
            if ch in ("'", '"'):
                in_str=True; q=ch; out.append(ch); i+=1; continue
        out.append(ch); i+=1
    return ''.join(out)

def _find_var_table(src: str, varname: str) -> str:
    m=re.search(rf'{re.escape(varname)}\s*=\s*{{', src)
    if not m: raise ValueError(f"Could not find '{varname} = {{' in file.")
    start=m.end()-1; i=start; n=len(src); depth=0; in_str=False; q=''; in_line=False; in_block=False
    while i<n:
        ch=src[i]
        if in_line:
            if ch=='\n': in_line=False
            i+=1; continue
        if in_block:
            if i+1<n and src[i:i+2]==']]': in_block=False; i+=2; continue
            i+=1; continue
        if not in_str and ch=='-' and i+1<n and src[i+1]=='-':
            if i+3<n and src[i+2]=='[' and src[i+3]=='[':
                in_block=True; i+=4; continue
            else:
                in_line=True; i+=2; continue
        if in_str:
            if ch=='\\' and i+1<n: i+=2; continue
            if ch==q: in_str=False; i+=1; continue
            i+=1; continue
        else:
            if ch in ('"', "'"): in_str=True; q=ch; i+=1; continue
        if ch=='{': depth+=1
        elif ch=='}':
            depth-=1
            if depth==0: return src[start:i+1]
        i+=1
    raise ValueError("Unbalanced braces while extracting table")

def _auto_table(src: str, preferred: str):
    candidates=[preferred,"epochheadDB","EpochHeadDB","EPOCHHEAD_DB","EpochHead","EPOCHHEAD"]
    tried=set()
    for name in candidates:
        if name in tried: continue
        tried.add(name)
        try: return name,_find_var_table(src,name)
        except Exception: pass
    for m in re.finditer(r'([A-Za-z_][A-Za-z0-9_]*)\s*=\s*{', src):
        nm=m.group(1)
        if nm in tried: continue
        try: return nm,_find_var_table(src,nm)
        except Exception: pass
    raise ValueError("Could not detect a SavedVariables table")

class Tok:
    def __init__(self,k,v,p): self.kind,self.val,self.pos=k,v,p

def _tokenize(s: str):
    toks=[]; i=0; n=len(s)
    while i<n:
        c=s[i]
        if c.isspace(): i+=1; continue
        if c in '{}[](),=': toks.append(Tok(c,c,i)); i+=1; continue
        if c in ('"',"'"):
            q=c; j=i+1; buf=[]
            while j<n:
                ch=s[j]
                if ch=='\\' and j+1<n: buf.append(s[j+1]); j+=2; continue
                if ch==q: j+=1; break
                buf.append(ch); j+=1
            toks.append(Tok('string',''.join(buf),i)); i=j; continue
        if c.isdigit() or (c=='-' and i+1<n and s[i+1].isdigit()):
            j=i+1; has_dot=False
            while j<n and (s[j].isdigit() or (s[j]=='.' and not has_dot) or s[j] in 'eE+-'):
                if s[j]=='.': has_dot=True
                j+=1
            lit=s[i:j]
            try: val=float(lit) if ('.' in lit or 'e' in lit.lower()) else int(lit)
            except: val=0
            toks.append(Tok('number',val,i)); i=j; continue
        if c.isalpha() or c=='_':
            j=i+1
            while j<n and (s[j].isalnum() or s[j]=='_'): j+=1
            name=s[i:j]
            if name=='true': toks.append(Tok('bool',True,i))
            elif name=='false': toks.append(Tok('bool',False,i))
            elif name=='nil': toks.append(Tok('nil',None,i))
            else: toks.append(Tok('name',name,i))
            i=j; continue
        toks.append(Tok('sym',c,i)); i+=1
    return toks

class Parser:
    def __init__(self,toks): self.toks=toks; self.i=0
    def peek(self): return self.toks[self.i] if self.i<len(self.toks) else None
    def eat(self,cond=None):
        t=self.peek()
        if t is None: raise ValueError("Unexpected EOF")
        if cond and not (t.kind==cond or t.val==cond):
            raise ValueError(f"Expected {cond} at {t.pos}, got {t.kind}:{t.val}")
        self.i+=1; return t
    def parse_value(self):
        t=self.peek()
        if t is None: raise ValueError("Unexpected EOF in value")
        if t.kind in ('string','number','bool','nil'): return self.eat().val
        if t.kind=='{' or t.val=='{': return self.parse_table()
        if t.kind=='name': return self.eat().val
        raise ValueError(f"Unexpected token {t.kind}:{t.val} at {t.pos}")
    def parse_table(self):
        self.eat('{')
        arr=[]; obj={}
        while True:
            t=self.peek()
            if t is None: raise ValueError("Unclosed {")
            if t.kind=='}' or t.val=='}':
                self.eat('}'); return obj if obj else arr
            if t.kind=='[' or t.val=='[':
                self.eat('['); key=self.parse_value(); self.eat(']'); self.eat('='); val=self.parse_value(); obj[key]=val
            elif t.kind=='name':
                name_tok=self.eat(); t2=self.peek()
                if t2 and (t2.kind=='=' or t2.val=='='):
                    self.eat('='); val=self.parse_value(); obj[name_tok.val]=val
                else:
                    arr.append(name_tok.val)
            else:
                val=self.parse_value(); arr.append(val)
            t=self.peek()
            if t and (t.kind==',' or t.val==','): self.eat(','); continue

def parse_savedvars(lua_text: str, preferred=VAR_NAME):
    name, table_src = _auto_table(lua_text, preferred)
    clean=_strip_lua_comments(table_src)
    toks=_tokenize(clean)
    val=Parser(toks).parse_value()
    return val if isinstance(val, dict) else {"_array": val}

def _normalize_inplace(obj):
    if isinstance(obj, dict):
        kind=obj.get("kind"); kid=obj.get("id"); is_mob=isinstance(kind,str) and kind.lower()=="mob"
        for k in list(obj.keys()):
            if k in ("sourceKey","key") and isinstance(obj[k], str):
                obj[k]=MOB_PREFIX_RE.sub("", obj[k])
        if is_mob and kid is not None:
            try:
                v2=str(int(kid))
                obj["sourceKey"]=v2; obj["key"]=v2
            except Exception: pass
        if "mob_guid" in obj: obj.pop("mob_guid", None)
        for v in obj.values(): _normalize_inplace(v)
    elif isinstance(obj, list):
        for v in obj: _normalize_inplace(v)

# --------------- Networking ---------------
def post_upload(server: str, token: str, payload: dict,
                endpoint: str = UPLOAD_ENDPOINT,
                timeout=(30, 300), chunk_size=64 * 1024):
    """POST data to the upload endpoint with generous timeouts.

    The timeout parameter accepts a tuple of ``(connect_timeout, read_timeout)``
    so the client can wait longer for the server to finish processing the
    request.  The payload is streamed in chunks to avoid buffering very large
    uploads in memory.

    Returns a ``(status_code, body)`` tuple.  On network errors, ``status_code``
    will be ``0`` and ``body`` will contain the exception string.
    """
    import json as _json
    import socket
    import http.client
    import urllib.parse

    connect_timeout, read_timeout = (
        timeout if isinstance(timeout, tuple) else (timeout, timeout)
    )

    url = server.rstrip("/") + endpoint
    parsed = urllib.parse.urlsplit(url)
    body = _json.dumps({"token": token, "payload": payload}).encode("utf-8")

    headers = {
        "Content-Type": "application/json",
        "User-Agent": f"EpochUploader/{APP_VERSION} (Windows)",
    }

    conn_cls = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    conn = conn_cls(parsed.hostname, port, timeout=connect_timeout)
    try:
        conn.connect()
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        conn.putrequest("POST", path, skip_accept_encoding=True)
        for k, v in headers.items():
            conn.putheader(k, v)
        conn.putheader("Content-Length", str(len(body)))
        conn.endheaders()
        for i in range(0, len(body), chunk_size):
            conn.send(body[i : i + chunk_size])
        conn.sock.settimeout(read_timeout)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8", "ignore")
        return resp.status, data
    except (socket.timeout, ConnectionResetError, OSError) as e:
        return 0, str(e)
    finally:
        try:
            conn.close()
        except Exception:
            pass

def get_upload_status(server: str, job_id: str, timeout=30):
    import socket, http.client, urllib.parse

    url = server.rstrip("/") + f"/upload/status/{job_id}"
    parsed = urllib.parse.urlsplit(url)

    conn_cls = http.client.HTTPSConnection if parsed.scheme == "https" else http.client.HTTPConnection
    port = parsed.port or (443 if parsed.scheme == "https" else 80)
    conn = conn_cls(parsed.hostname, port, timeout=timeout)
    try:
        conn.connect()
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query
        conn.putrequest("GET", path, skip_accept_encoding=True)
        conn.putheader("User-Agent", f"EpochUploader/{APP_VERSION} (Windows)")
        conn.endheaders()
        conn.sock.settimeout(timeout)
        resp = conn.getresponse()
        data = resp.read().decode("utf-8", "ignore")
        return resp.status, data
    except (socket.timeout, ConnectionResetError, OSError) as e:
        return 0, str(e)
    finally:
        try:
            conn.close()
        except Exception:
            pass

def _net_call_with_backoff(call):
    delay = 0.5
    last_code, last_body = None, None
    for _ in range(6):
        code, body = call()
        last_code, last_body = code, body
        try:
            if 200 <= int(code or 0) < 300:
                return code, body
        except Exception:
            pass
        time.sleep(delay)
        delay = min(delay * 2, 8.0)
    return last_code, last_body

# --------------- Tk App ---------------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(f"{APP_NAME}")
        self.geometry("840x560")
        self.minsize(760, 500)

        self.queue = queue.Queue()
        self._debounce_until = 0.0
        self._watcher_running = True
        self._watcher_paused = False
        self._last_sig = None  # tuple of watched file signatures
        self._last_success_at = 0.0
        self._last_upload_ts = None
        self._uploading = False

        cfg = load_config()
        sv_dir = cfg.get("sv_dir")
        if not sv_dir and cfg.get("sv_path"):
            try:
                sv_dir = os.path.dirname(cfg["sv_path"])
                cfg["sv_dir"] = sv_dir
                cfg.pop("sv_path", None)
                save_config(cfg)
            except Exception:
                sv_dir = None
        self.sv_dir = sv_dir

        self.auto_upload = bool(cfg.get("auto_upload", DEFAULT_AUTO_UPLOAD))
        self.start_with_windows = bool(cfg.get("autostart", DEFAULT_START_WITH_WIN))
        self.pause_watching = bool(cfg.get("pause_watching", DEFAULT_PAUSE_WATCHING))
        self.start_minimized = bool(cfg.get("start_minimized", DEFAULT_START_MINIMIZED))
        self.start_silent = bool(cfg.get("start_silent", DEFAULT_START_SILENT))
        self.cleanup_keep_files = int(cfg.get("cleanup_keep_files", DEFAULT_CLEANUP_KEEP_FILES) or DEFAULT_CLEANUP_KEEP_FILES)

        # CLI override for silent/minimized startup (useful from task scheduler).
        if "--silent" in [a.lower() for a in sys.argv[1:]]:
            self.start_minimized = True
            self.start_silent = True

        self.created = None
        self.updated = None
        self.dropped = None
        self.duplicates = None
        self.kept = None
        self.server_ok = None

        self.warn_banner_var = tk.StringVar(value="")
        self.status_line_var = tk.StringVar(value="Idle")
        self.meta_player_var = tk.StringVar(value="")
        self._tray_icon = None
        self._tray_warned = False

        self._build_ui()

        if not self._valid_dir(self.sv_dir):
            self.after(250, lambda: self._choose_sv_dir(initial=True))

        self.protocol("WM_DELETE_WINDOW", self._on_close_hide)
        self.after(200, self._pump_queue)
        threading.Thread(target=self._watch_loop, daemon=True).start()
        _start_activation_listener(lambda: self.queue.put(("show", {})))
        self._ensure_tray_icon()

        if self.start_minimized:
            self.after(50, self.withdraw)

        if self.sv_dir:
            self._log(f"Watching folder: {self.sv_dir}")
            self._log_target_files()
        else:
            self._log("Select your SavedVariables folder (e.g. GAMEDIR\\WTF\\Account\\ACCOUNTNAME\\SavedVariables).")

    # ---------------- UI ----------------
    def _build_ui(self):
        root = ttk.Frame(self, padding=12)
        root.pack(fill="both", expand=True)

        # Banner (hidden until needed)
        self.banner = ttk.Frame(root)
        self.banner.pack(fill="x", side="top")
        self.banner_label = tk.Label(self.banner, textvariable=self.warn_banner_var, fg="#1a1a00",
                                     bg="#ffec99", padx=10, pady=6, anchor="w", justify="left")
        self.banner_label.pack(fill="x")
        self._hide_banner()

        # Path row
        row = ttk.Frame(root); row.pack(fill="x")
        ttk.Label(row, text="SavedVariables folder:", font=("Segoe UI", 10, "bold")).pack(side="left")
        self.path_var = tk.StringVar(value=self.sv_dir or "")
        e = ttk.Entry(row, textvariable=self.path_var, state="readonly")
        e.pack(side="left", fill="x", expand=True, padx=8)
        ttk.Button(row, text="Change…", command=self._choose_sv_dir).pack(side="left")

        # Top controls row
        bar = ttk.Frame(root); bar.pack(fill="x", pady=(10, 8))
        ttk.Button(bar, text="Upload now", command=lambda: self.queue.put(("upload", {"manual": True}))).pack(side="left")

        self.auto_upload_var = tk.BooleanVar(value=self.auto_upload)
        self.autostart_var   = tk.BooleanVar(value=self.start_with_windows)
        self.pause_var       = tk.BooleanVar(value=self.pause_watching)
        self.minimized_var   = tk.BooleanVar(value=self.start_minimized)
        self.silent_var      = tk.BooleanVar(value=self.start_silent)

        ttk.Checkbutton(bar, text="Auto-upload", variable=self.auto_upload_var,
                        command=self._toggle_auto).pack(side="left", padx=(10,0))
        ttk.Checkbutton(bar, text="Start with Windows", variable=self.autostart_var,
                        command=self._toggle_autostart).pack(side="left", padx=(10,0))
        ttk.Checkbutton(bar, text="Start minimized", variable=self.minimized_var,
                        command=self._toggle_start_minimized).pack(side="left", padx=(10,0))
        ttk.Checkbutton(bar, text="Start silently", variable=self.silent_var,
                        command=self._toggle_start_silent).pack(side="left", padx=(10,0))
        ttk.Checkbutton(bar, text="Pause watching", variable=self.pause_var,
                        command=self._toggle_pause).pack(side="left", padx=(10,0))

        ttk.Button(bar, text="Open SV Folder", command=self._open_sv_folder).pack(side="left", padx=(10,0))
        ttk.Button(bar, text="Open Log", command=self._open_log).pack(side="left", padx=(10,0))
        ttk.Button(bar, text="Clean old uploads", command=self._cleanup_old_uploads).pack(side="left", padx=(10,0))

        # Status strip
        meta = ttk.Frame(root); meta.pack(fill="x", pady=(4, 8))
        ttk.Label(meta, textvariable=self.status_line_var).pack(side="left")
        ttk.Label(meta, textvariable=self.meta_player_var, foreground="#56b1ff").pack(side="right")

        # Log area
        box = ttk.LabelFrame(root, text="Recent activity")
        box.pack(fill="both", expand=True)
        self.log = tk.Text(box, height=18, wrap="word")
        self.log.pack(fill="both", expand=True)
        self.log.configure(state="disabled")

        # Footer
        ttk.Label(root, text=f"Close window to minimize to tray (single-instance).  v{APP_VERSION}",
                  foreground="#888").pack(anchor="w", pady=(8, 0))

        try: self.tk.call("tk", "scaling", 1.15)
        except Exception: pass

    def _show_banner(self, msg: str):
        self.warn_banner_var.set(msg or "")
        self.banner_label.configure(bg="#ffec99")
        self.banner.pack(fill="x")
        self.banner_label.update_idletasks()

    def _hide_banner(self):
        self.warn_banner_var.set("")
        self.banner.forget()

    def _set_status_line(self):
        t = time.strftime("%H:%M:%S", time.localtime(self._last_upload_ts)) if self._last_upload_ts else "—"
        created = "—" if self.created is None else str(self.created)
        updated = "—" if self.updated is None else str(self.updated)
        dropped = "—" if self.dropped is None else str(self.dropped)
        dupes   = "—" if self.duplicates is None else str(self.duplicates)
        server  = "OK" if self.server_ok else ("Error" if self.server_ok is not None else "—")
        self.status_line_var.set(f"Last upload: {t} • Created: {created}  Updated: {updated}  Dropped: {dropped} • Server: {server}")

    def _log(self, s):
        logging.info(s)
        ts = time.strftime("%H:%M:%S")
        line = f"[{ts}] {s}\n"
        self.log.configure(state="normal")
        self.log.insert("end", line)
        try:
            if int(self.log.index('end-1c').split('.')[0]) > LOG_MAX_LINES:
                self.log.delete('1.0', '2.0')
        except Exception:
            pass
        self.log.see("end"); self.log.configure(state="disabled")

    def _make_tray_image(self):
        if Image is None:
            return None
        img = Image.new("RGBA", (64, 64), (35, 35, 35, 255))
        d = ImageDraw.Draw(img)
        d.ellipse((8, 8, 56, 56), fill=(43, 121, 245, 255))
        d.text((19, 21), "EH", fill=(255, 255, 255, 255))
        return img

    def _ensure_tray_icon(self):
        if self._tray_icon is not None or pystray is None:
            if pystray is None and not self._tray_warned:
                self._log("Tray support unavailable (missing pystray/Pillow in build environment).")
                self._tray_warned = True
            return
        try:
            menu = pystray.Menu(
                pystray.MenuItem("Restore", lambda: self.queue.put(("show", {}))),
                pystray.MenuItem("Close", lambda: self.queue.put(("exit", {}))),
            )
            self._tray_icon = pystray.Icon("epoch_uploader", self._make_tray_image(), APP_NAME, menu)
            self._tray_icon.run_detached()
        except Exception as e:
            self._tray_icon = None
            self._log(f"Tray icon failed to start: {e}")

    def _stop_tray_icon(self):
        if not self._tray_icon:
            return
        try:
            self._tray_icon.stop()
        except Exception:
            pass
        self._tray_icon = None

    # ---------------- Events/queue ----------------
    def _on_close_hide(self):
        # Keep app running background and show tray icon.
        self._ensure_tray_icon()
        if not self.start_silent:
            try:
                messagebox.showinfo(APP_NAME, "Uploader is still running in the system tray.")
            except Exception:
                pass
        self.withdraw()

    def _exit_app(self):
        self._watcher_running = False
        self._stop_tray_icon()
        self.destroy()

    def _pump_queue(self):
        try:
            while True:
                item = self.queue.get_nowait()
                if isinstance(item, tuple):
                    kind, payload = item
                else:
                    kind, payload = item, {}
                if kind == "upload":
                    self._do_upload(manual=bool(payload.get("manual")))
                elif kind == "upload_result":
                    self._finish_upload(payload.get("path"), payload.get("code"), payload.get("body"))
                elif kind == "show":
                    self.deiconify()
                    try: self.lift(); self.focus_force()
                    except Exception: pass
                elif kind == "exit":
                    self._exit_app()
                    return
        except queue.Empty:
            pass
        self.after(200, self._pump_queue)

    # ---------------- Toggles ----------------
    def _toggle_auto(self):
        self.auto_upload = bool(self.auto_upload_var.get())
        cfg = load_config(); cfg["auto_upload"] = self.auto_upload; save_config(cfg)
        self._log(f"Auto-upload {'enabled' if self.auto_upload else 'disabled'}.")

    def _toggle_autostart(self):
        want = bool(self.autostart_var.get())
        ok = set_autostart(want)
        if not ok:
            # revert UI checkbox if failed
            self.autostart_var.set(get_autostart_enabled())
        cfg = load_config(); cfg["autostart"] = bool(self.autostart_var.get()); save_config(cfg)
        self._log(f"Start with Windows {'enabled' if self.autostart_var.get() else 'disabled'}.")

    def _toggle_pause(self):
        self.pause_watching = bool(self.pause_var.get())
        cfg = load_config(); cfg["pause_watching"] = self.pause_watching; save_config(cfg)
        self._log(f"Watching {'paused' if self.pause_watching else 'resumed'}.")

    def _toggle_start_minimized(self):
        self.start_minimized = bool(self.minimized_var.get())
        cfg = load_config(); cfg["start_minimized"] = self.start_minimized; save_config(cfg)
        self._log(f"Start minimized {'enabled' if self.start_minimized else 'disabled'}.")

    def _toggle_start_silent(self):
        self.start_silent = bool(self.silent_var.get())
        cfg = load_config(); cfg["start_silent"] = self.start_silent; save_config(cfg)
        self._log(f"Start silently {'enabled' if self.start_silent else 'disabled'}.")

    def _open_sv_folder(self):
        try:
            if self._valid_dir(self.sv_dir):
                os.startfile(self.sv_dir)
            else:
                messagebox.showwarning(APP_NAME, "No SavedVariables folder selected yet.")
        except Exception as e:
            self._log(f"Open SV folder failed: {e}")

    def _open_log(self):
        try:
            _ensure_appdata()
            if not os.path.exists(LOG_PATH):
                with open(LOG_PATH, "a", encoding="utf-8"): pass
            os.startfile(LOG_PATH)
        except Exception as e:
            self._log(f"Open log failed: {e}")

    def _cleanup_old_uploads(self):
        if not self._valid_dir(self.sv_dir):
            self._log("Select your SavedVariables folder first.")
            return
        keep = max(1, int(self.cleanup_keep_files or DEFAULT_CLEANUP_KEEP_FILES))
        pattern = os.path.join(self.sv_dir, "epochhead_upload*.lua")
        files = sorted(glob.glob(pattern), key=lambda p: os.path.getmtime(p), reverse=True)
        old = files[keep:]
        if not old:
            self._log(f"Cleanup complete. Nothing to remove (keeping up to {keep} files).")
            return
        removed = 0
        for p in old:
            try:
                os.remove(p)
                removed += 1
            except Exception as e:
                self._log(f"Failed to remove {os.path.basename(p)}: {e}")
        self._log(f"Cleanup removed {removed} old uploaded files (kept newest {keep}).")

    # ---------------- Paths ----------------
    def _valid_dir(self, d): return bool(d) and os.path.isdir(d)

    def _sv_file_path(self):
        return os.path.join(self.sv_dir, PRIMARY_SV_FILE) if self._valid_dir(self.sv_dir) else None

    def _log_target_files(self):
        self._log("Target files: " + ", ".join(TARGET_SV_FILES))

    def _watched_file_signatures(self):
        if not self._valid_dir(self.sv_dir):
            return tuple()
        by_lower = {}
        try:
            for name in os.listdir(self.sv_dir):
                by_lower[name.lower()] = name
        except Exception:
            return tuple()
        sigs = []
        for target in TARGET_SV_FILES:
            real = by_lower.get(target.lower())
            if not real:
                continue
            p = os.path.join(self.sv_dir, real)
            try:
                st = os.stat(p)
                sigs.append((target.lower(), getattr(st, "st_mtime_ns", int(st.st_mtime * 1e9)), st.st_size))
            except FileNotFoundError:
                continue
        sigs.sort(key=lambda x: x[0])
        return tuple(sigs)

    def _choose_sv_dir(self, initial=False):
        start_dir = os.path.join(os.path.expanduser("~"), "Documents")
        title = "Select your SavedVariables folder (e.g. GAMEDIR\\WTF\\Account\\ACCOUNTNAME\\SavedVariables)"
        d = filedialog.askdirectory(
            initialdir=start_dir if os.path.isdir(start_dir) else os.path.expanduser("~"),
            title=title,
            mustexist=True,
        )
        if d:
            self.sv_dir = d
            self.path_var.set(d)
            cfg = load_config(); cfg["sv_dir"] = d; save_config(cfg)
            self._log(f"Selected folder: {d}")
            self._log_target_files()
            self._last_sig = None
        elif initial and not self.sv_dir:
            self._log("No folder selected. Use 'Change…' to pick the SavedVariables folder.")

    def _load_market_addon_data(self):
        if not self._valid_dir(self.sv_dir):
            return {}
        targets = {
            "aux": ["aux-addon.lua", "aux.lua", "auxhistory.lua", "aux_history.lua"],
            "auctionator": ["auctionator.lua", "auctionatordata.lua", "auctionatorshoppinglists.lua"],
        }
        files_by_lower = {}
        try:
            for name in os.listdir(self.sv_dir):
                files_by_lower[name.lower()] = name
        except Exception:
            return {}

        out = {}
        for source, names in targets.items():
            for lname in names:
                real = files_by_lower.get(lname)
                if not real:
                    continue
                path = os.path.join(self.sv_dir, real)
                try:
                    with open(path, "r", encoding="utf-8", errors="ignore") as f:
                        raw = f.read()
                    out[source] = {
                        "file": real,
                        "mtime": int(os.path.getmtime(path)),
                        "size": len(raw),
                        "raw_lua": raw,
                    }
                    break
                except Exception as e:
                    self._log(f"{source} read skipped ({real}): {e}")
                    break
        return out

    def _load_census_addon_data(self):
        if not self._valid_dir(self.sv_dir):
            return None
        files_by_lower = {}
        try:
            for name in os.listdir(self.sv_dir):
                files_by_lower[name.lower()] = name
        except Exception:
            return None

        real = files_by_lower.get("epochcensus.lua")
        if not real:
            return None
        path = os.path.join(self.sv_dir, real)
        try:
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                raw = f.read()
            return {
                "file": real,
                "mtime": int(os.path.getmtime(path)),
                "size": len(raw),
                "raw_lua": raw,
            }
        except Exception as e:
            self._log(f"census read skipped ({real}): {e}")
            return None

    # ---------------- Watch & upload ----------------
    def _watch_loop(self):
        """Poll target SavedVariables files and push an upload when signature changes."""
        while self._watcher_running:
            try:
                if self.pause_watching:
                    time.sleep(POLL_INTERVAL_SEC)
                    continue
                sig = self._watched_file_signatures()
                if self._last_sig is None:
                    self._last_sig = sig
                elif sig != self._last_sig:
                    self._last_sig = sig
                    now = time.time()
                    if now >= self._debounce_until:
                        self._debounce_until = now + DEBOUNCE_SEC
                        # Auto uploads only if enabled; manual bypasses this check.
                        if self.auto_upload:
                            self.queue.put(("upload", {"manual": False}))
            except Exception as e:
                logging.warning("watch loop error: %s", e)
            time.sleep(POLL_INTERVAL_SEC)

    def _requeue_soon(self, secs=RETRY_ON_PARSE_SEC):
        self._debounce_until = time.time() + secs
        threading.Timer(secs, lambda: self.queue.put(("upload", {"manual": False}))).start()

    def _do_upload(self, *, manual: bool):
        if self._uploading:
            self._log("Upload already in progress; skipping.")
            return
        p = self._sv_file_path()
        if not p:
            self._log("Select the SavedVariables folder first.")
            return
        have_epochhead = os.path.isfile(p)

        # Rate limit successful uploads
        if self._last_success_at and (time.time() - self._last_success_at) < MIN_SUCCESS_SPACING:
            wait = MIN_SUCCESS_SPACING - (time.time() - self._last_success_at)
            time.sleep(max(0.05, wait))

        events = []
        meta = {}
        if have_epochhead:
            # Read file
            try:
                with open(p, "r", encoding="utf-8", errors="ignore") as f:
                    lua = f.read()
            except Exception as e:
                self._log(f"Read error: {e}")
                self._requeue_soon()
                return

            # Parse
            try:
                sv = parse_savedvars(lua, VAR_NAME)
            except Exception as e:
                self._log(f"Parse error (likely mid-write). Retrying soon… ({e})")
                self._requeue_soon()
                return

            events = list(sv.get("events") or [])
            meta = dict(sv.get("meta") or {})
        else:
            self._log("epochhead.lua not found; continuing with market addon exports only.")

        _normalize_inplace(events); _normalize_inplace(meta)
        meta["_uploader"] = {
            "name": APP_NAME,
            "version": APP_VERSION,
            "upload_tick": int(time.time()),
        }
        if meta:
            try:
                pmeta = meta.get("player") or {}
                name = pmeta.get("name") or "Unknown"
                realm = pmeta.get("realm") or ""
                cls = pmeta.get("className") or pmeta.get("class") or ""
                lvl = pmeta.get("level") or ""
                bits = [name]
                if realm: bits.append(f"({realm})")
                if cls: bits.append(f"— {cls}")
                if lvl: bits.append(f"lvl {lvl}")
                self.meta_player_var.set(" ".join(str(b) for b in bits if b))
            except Exception:
                pass

        market_addons = self._load_market_addon_data()
        census_addon = self._load_census_addon_data()
        if not events and not meta and not market_addons and not census_addon:
            self._log("No uploadable data found (expected epochhead.lua, Auctionator.lua, aux-addon.lua, or EpochCensus.lua).")
            return
        payload = {"events": events, "meta": meta}
        if market_addons:
            payload["market_addons"] = market_addons
            self._log("Included market addon data: " + ", ".join(sorted(market_addons.keys())))
            details = []
            for addon_key in sorted(market_addons.keys()):
                info = market_addons.get(addon_key) or {}
                file_name = info.get("file") or f"{addon_key}.lua"
                size = info.get("size")
                if isinstance(size, int):
                    details.append(f"{file_name} ({size} bytes)")
                else:
                    details.append(str(file_name))
            if details:
                self._log("Included file stats: " + ", ".join(details))
        if census_addon:
            payload["census_addon"] = census_addon
            file_name = census_addon.get("file") or "EpochCensus.lua"
            size = census_addon.get("size")
            if isinstance(size, int):
                self._log(f"Included census addon data: {file_name} ({size} bytes)")
            else:
                self._log(f"Included census addon data: {file_name}")

        self._log("Uploading…")
        self._uploading = True

        def worker():
            try:
                code, body = _net_call_with_backoff(
                    lambda: post_upload(SERVER, TOKEN, payload, endpoint=UPLOAD_ENDPOINT)
                )
            except Exception as e:
                code, body = 0, str(e)

            job_id = None
            if body:
                try:
                    job_id = json.loads(body).get("job_id")
                except Exception:
                    pass

            if job_id and 200 <= int(code or 0) < 400:
                def poll():
                    while True:
                        time.sleep(1.0)
                        try:
                            scode, sbody = _net_call_with_backoff(
                                lambda: get_upload_status(SERVER, job_id)
                            )
                        except Exception as e2:
                            scode, sbody = 0, str(e2)
                        finished = False
                        if sbody:
                            try:
                                sj = json.loads(sbody)
                                finished = bool(sj.get("finished"))
                            except Exception:
                                pass
                        if finished:
                            self.queue.put(("upload_result", {"path": p, "code": scode, "body": sbody}))
                            break
                threading.Thread(target=poll, daemon=True).start()
            else:
                self.queue.put(("upload_result", {"path": p, "code": code, "body": body}))

        threading.Thread(target=worker, daemon=True).start()

    def _finish_upload(self, p, code, body):
        ok = 200 <= int(code or 0) < 300
        self.server_ok = bool(ok)

        # Parse JSON body if possible
        server = {}
        if body:
            try:
                server = json.loads(body)
            except Exception:
                pass

        result = server.get("result") if isinstance(server, dict) else None
        if result is None:
            result = server if isinstance(server, dict) else {}

        totals = ((result.get("stats") or {}).get("totals") or {}) if isinstance(result, dict) else {}
        self.created    = totals.get("created") or result.get("created")
        self.updated    = totals.get("updated") or result.get("updated")
        self.dropped    = result.get("dropped_by_realm") or result.get("dropped")
        self.duplicates = result.get("dropped_dupes") or result.get("dropped_duplicates") or result.get("duplicates")
        self.kept       = result.get("kept")

        # Addon version warning
        warn = None
        av = result.get("addonVersion") or result.get("addon_version") or {}
        if isinstance(av, dict):
            client = av.get("client") or av.get("addon") or ""
            target = av.get("target") or ""
            do_warn = bool(av.get("warn"))
            if do_warn and client and target:
                warn = f"Addon {client} is behind target {target}. Please update."
        if warn:
            self._show_banner(warn)
        else:
            self._hide_banner()

        # Update status strip
        self._last_upload_ts = int(time.time())
        self._set_status_line()

        self._log(f"Upload -> {code}")
        summary_bits = []
        if self.created is not None:
            summary_bits.append(f"{self.created} created")
        if self.updated is not None:
            summary_bits.append(f"{self.updated} updated")
        if self.dropped is not None:
            summary_bits.append(f"{self.dropped} dropped")
        if self.duplicates is not None:
            summary_bits.append(f"{self.duplicates} duplicates")
        if self.kept is not None:
            summary_bits.append(f"{self.kept} kept")
        if summary_bits:
            self._log(", ".join(summary_bits).capitalize())
        elif body:
            try:
                preview = (body[:600] + ("…" if len(body) > 600 else "")).replace("\n", " ").strip()
                self._log(preview)
            except Exception:
                pass

        market_files = result.get("marketFiles") if isinstance(result, dict) else None
        if isinstance(market_files, dict) and market_files:
            mf_bits = []
            for source in sorted(market_files.keys()):
                info = market_files.get(source) or {}
                file_name = info.get("file") or f"{source}.lua"
                events = info.get("events")
                err = info.get("error")
                if err:
                    mf_bits.append(f"{file_name}: error ({err})")
                elif isinstance(events, int):
                    mf_bits.append(f"{file_name}: {events} events")
                else:
                    mf_bits.append(str(file_name))
            if mf_bits:
                self._log("Market file upload stats: " + ", ".join(mf_bits))

        if ok and AUTO_RENAME:
            try:
                new_name = time.strftime("epochhead_upload%Y%m%d-%H%M%S.lua", time.localtime())
                new_path = os.path.join(self.sv_dir, new_name)
                os.replace(p, new_path)
                self._log(f"Renamed uploaded file -> {new_name}")
                self._last_sig = None
                self._last_success_at = time.time()
                self._cleanup_old_uploads()
            except Exception as e:
                self._log(f"Rename failed: {e}")
        elif ok:
            self._last_success_at = time.time()

        self._uploading = False

# --------------- Entrypoint ---------------
def main():
    hMutex, already = _windows_mutex_singleton()
    if already:
        _send_activation_ping()
        return
    app = App()
    app.mainloop()

if __name__ == "__main__":
    main()
