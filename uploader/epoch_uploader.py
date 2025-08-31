#!/usr/bin/env python3
# EpochHead Uploader GUI — select SavedVariables folder (not file)
# - First run: prompts for GAMEDIR\WTF\Account\ACCOUNTNAME\SavedVariables
# - Watches <folder>\epochhead.lua, uploads on changes, renames after success
# - Close hides window (keeps running); re-launch brings window to front; Quit exits
# - Single instance (no deps), standard library only

import os, sys, json, time, threading, queue, re, socket
import tkinter as tk
from tkinter import ttk, messagebox, filedialog

# ------------------ FIXED SETTINGS (not shown in UI) ------------------
SERVER        = "http://193.233.161.214:5001"
TOKEN         = "devtoken"
VAR_NAME      = "epochheadDB"
AUTO_RENAME   = True
POLL_INTERVAL_SEC = 1.0
DEBOUNCE_SEC      = 1.0
UPLOAD_ENDPOINT   = "/upload"
LOG_MAX_LINES     = 500

# Single-instance + activation
MUTEX_NAME   = r"Global\EpochUploaderMutex_v1"
ACTIVATE_PORT = 52931

# Config
APPDATA_DIR = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "EpochUploader")
CONFIG_PATH = os.path.join(APPDATA_DIR, "config.json")

# ---------------------------------------------------------------------
# Single instance (Windows)
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

# Config helpers
def _ensure_appdata():
    try: os.makedirs(APPDATA_DIR, exist_ok=True)
    except Exception: pass

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

# ------------------ Lua parse/normalize ------------------
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
            if i+3<n and src[i+2]=='[' and src[i+3]==']':
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

def post_upload(server: str, token: str, payload: dict, endpoint: str = UPLOAD_ENDPOINT, timeout=30):
    import json as _json
    from urllib.request import Request, urlopen
    from urllib.error import URLError, HTTPError
    url = server.rstrip("/") + endpoint
    body = _json.dumps({"token": token, "payload": payload}).encode("utf-8")
    req = Request(url, data=body, headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read().decode("utf-8","ignore")
    except HTTPError as e:
        return e.code, e.read().decode("utf-8","ignore")
    except URLError as e:
        return 0, str(e)

def pretty_player(meta):
    try:
        p = meta.get("player") or {}
        name = p.get("name") or "Unknown"
        realm = p.get("realm") or ""
        cls = p.get("className") or p.get("class") or ""
        lvl = p.get("level") or ""
        bits = [name]
        if realm: bits.append(f"({realm})")
        if cls: bits.append(f"— {cls}")
        if lvl: bits.append(f"lvl {lvl}")
        return " ".join(str(b) for b in bits if b)
    except Exception:
        return "Unknown"

def ts_filename():
    return time.strftime("epochhead_upload%Y%m%d-%H%M%S.lua", time.localtime())

# ------------------ Tk App ------------------
class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Epoch Uploader")
        self.geometry("760x500")
        self.minsize(680, 460)

        self.queue = queue.Queue()
        self._debounce_until = 0.0
        self._watcher_running = True
        self._last_mtime = None

        cfg = load_config()
        # Migrate old config key (sv_path) to folder if present
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

        self._build_ui()

        if not self._valid_dir(self.sv_dir):
            self.after(200, lambda: self._choose_sv_dir(initial=True))

        self.protocol("WM_DELETE_WINDOW", self._on_close_hide)
        self.after(200, self._pump_queue)
        threading.Thread(target=self._watch_loop, daemon=True).start()

        if self.sv_dir:
            self._log(f"Watching folder: {self.sv_dir}")
            self._log("Target file: epochhead.lua")
        else:
            self._log("Select your SavedVariables folder (e.g. GAMEDIR\\WTF\\Account\\ACCOUNTNAME\\SavedVariables).")

    # UI
    def _build_ui(self):
        root = ttk.Frame(self, padding=12)
        root.pack(fill="both", expand=True)

        # Row: folder path + change button
        row = ttk.Frame(root); row.pack(fill="x")
        ttk.Label(row, text="SavedVariables folder:", font=("Segoe UI", 10, "bold")).pack(side="left")
        self.path_var = tk.StringVar(value=self.sv_dir or "")
        e = ttk.Entry(row, textvariable=self.path_var, state="readonly")
        e.pack(side="left", fill="x", expand=True, padx=8)
        ttk.Button(row, text="Change folder…", command=self._choose_sv_dir).pack(side="left")

        meta = ttk.Frame(root); meta.pack(fill="x", pady=(8, 8))
        self.status_var = tk.StringVar(value="Idle")
        ttk.Label(meta, textvariable=self.status_var).pack(side="left")
        self.player_var = tk.StringVar(value="")
        ttk.Label(meta, textvariable=self.player_var, foreground="#56b1ff").pack(side="right")

        bar = ttk.Frame(root); bar.pack(fill="x", pady=(0, 8))
        ttk.Button(bar, text="Upload now", command=self._manual_upload).pack(side="left")
        ttk.Button(bar, text="Quit", command=self._quit_app).pack(side="right")

        box = ttk.LabelFrame(root, text="Recent activity")
        box.pack(fill="both", expand=True)
        self.log = tk.Text(box, height=18, wrap="word")
        self.log.pack(fill="both", expand=True)
        self.log.configure(state="disabled")

        ttk.Label(root, text="Close window to keep uploader running in the background. Re-open to bring it back.",
                  foreground="#888").pack(anchor="w", pady=(6, 0))

        try: self.tk.call("tk", "scaling", 1.15)
        except Exception: pass

    def _set_status(self, s): self.status_var.set(s)
    def _log(self, s):
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

    def _on_close_hide(self):
        try:
            messagebox.showinfo("Epoch Uploader",
                "Uploader will keep running in the background.\nRun it again to bring this window back, or click 'Quit' to exit.")
        except Exception:
            pass
        self.withdraw()

    def _quit_app(self):
        self._watcher_running = False
        try: self.destroy()
        except Exception: os._exit(0)

    def _pump_queue(self):
        try:
            while True:
                item = self.queue.get_nowait()
                if item == "upload":
                    self._do_upload()
                elif item == "show":
                    self.deiconify()
                    try: self.lift(); self.focus_force()
                    except Exception: pass
        except queue.Empty:
            pass
        self.after(200, self._pump_queue)

    # Paths
    def _valid_dir(self, d): return bool(d) and os.path.isdir(d)
    def _sv_file_path(self):
        return os.path.join(self.sv_dir, "epochhead.lua") if self._valid_dir(self.sv_dir) else None

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
            self._log("Target file: epochhead.lua")
        elif initial and not self.sv_dir:
            self._log("No folder selected. Use 'Change folder…' to pick the SavedVariables folder.")

    # Uploading
    def _manual_upload(self): self.queue.put("upload")

    def _watch_loop(self):
        while self._watcher_running:
            try:
                p = self._sv_file_path()
                if p and os.path.isfile(p):
                    m = os.path.getmtime(p)
                    if self._last_mtime is None:
                        self._last_mtime = m
                    elif m != self._last_mtime:
                        self._last_mtime = m
                        now = time.time()
                        if now >= self._debounce_until:
                            self._debounce_until = now + DEBOUNCE_SEC
                            self.queue.put("upload")
                # if file doesn't exist yet (e.g., after rename), we just wait
            except Exception:
                pass
            time.sleep(POLL_INTERVAL_SEC)

    def _do_upload(self):
        p = self._sv_file_path()
        if not p:
            self._set_status("No folder selected")
            self._log("Select the SavedVariables folder first.")
            return
        if not os.path.isfile(p):
            self._set_status("Waiting for file")
            self._log("epochhead.lua not found in the selected folder (yet).")
            return

        self._set_status("Reading file…")
        try:
            with open(p, "r", encoding="utf-8", errors="ignore") as f:
                lua = f.read()
        except Exception as e:
            self._set_status("Read error"); self._log(f"Read error: {e}"); return

        try:
            sv = parse_savedvars(lua, VAR_NAME)
        except Exception as e:
            self._set_status("Parse error"); self._log(f"Parse error: {e}"); return

        events = list(sv.get("events") or [])
        meta   = dict(sv.get("meta")   or {})
        if not events and not meta:
            self._log("No events/meta found; nothing to upload.")
            self._set_status("Nothing to upload")
            return

        _normalize_inplace(events); _normalize_inplace(meta)
        if meta:
            self.player_var.set(pretty_player(meta))

        payload = {"events": events, "meta": meta}

        self._set_status("Uploading…")
        code, body = post_upload(SERVER, TOKEN, payload, endpoint=UPLOAD_ENDPOINT)
        ok = 200 <= int(code or 0) < 300
        self._log(f"Upload -> {code}")
        if body:
            try:
                self._log((body[:600] + ("…" if len(body) > 600 else "")).replace("\n"," ").strip())
            except Exception:
                pass

        if ok and AUTO_RENAME:
            try:
                new_name = ts_filename()
                new_path = os.path.join(self.sv_dir, new_name)
                os.replace(p, new_path)
                self._log(f"Renamed uploaded file -> {new_name}")
                self._set_status("Uploaded & renamed")
                self._last_mtime = None  # wait for addon to recreate epochhead.lua
            except Exception as e:
                self._log(f"Rename failed: {e}")
                self._set_status("Uploaded (rename failed)")
        else:
            self._set_status("Uploaded" if ok else f"Upload failed ({code})")

# Entrypoint
def main():
    hMutex, already = _windows_mutex_singleton()
    if already:
        _send_activation_ping()
        return
    app = App()
    _start_activation_listener(lambda: app.queue.put("show"))
    app.mainloop()

if __name__ == "__main__":
    main()
