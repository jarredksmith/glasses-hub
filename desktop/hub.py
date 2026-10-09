"""Glasses Hub for Windows: sends sports scores, trivia and odd facts to your phone, and from there to
your smart glasses, as notifications. Start it with "Glasses Hub.bat".
"""
import json
import logging
import logging.handlers
import os
import queue
import subprocess
import sys
import threading
import time
import tkinter as tk
import webbrowser
from datetime import datetime
from tkinter import font as tkfont
from tkinter import messagebox, ttk

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import core  # noqa: E402
from core import Hub, data_dir, get_api_key, save_api_key  # noqa: E402
from plugins.facts import Facts  # noqa: E402
from plugins.nfl import NFL  # noqa: E402
from plugins.trivia import Trivia  # noqa: E402

VERSION = "1.0.0"
APP_TITLE = "Glasses Hub"


def setup_logging():
    log_file = data_dir() / "glasses-hub.log"
    h = logging.handlers.RotatingFileHandler(log_file, maxBytes=1_000_000, backupCount=2, encoding="utf-8")
    h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    root = logging.getLogger()
    root.setLevel(logging.INFO)
    root.addHandler(h)


def startup_shortcut():
    appdata = os.environ.get("APPDATA", "")
    return os.path.join(appdata, "Microsoft", "Windows", "Start Menu", "Programs", "Startup", "Glasses Hub.lnk")


def set_startup(on: bool):
    path = startup_shortcut()
    if not on:
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
        return
    here = os.path.dirname(os.path.abspath(__file__))
    target = os.path.join(here, "Glasses Hub.bat")
    ps = ("$s=(New-Object -ComObject WScript.Shell).CreateShortcut('{0}'); $s.TargetPath='{1}'; "
          "$s.Arguments='--minimized'; $s.WorkingDirectory='{2}'; $s.WindowStyle=7; $s.Save()").format(
        path.replace("'", "''"), target.replace("'", "''"), here.replace("'", "''"))
    subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ps],
                   capture_output=True, timeout=30, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))


def main():
    setup_logging()
    minimized = "--minimized" in sys.argv

    C = {"bg": "#16181d", "panel": "#1e2128", "panel2": "#262a33", "line": "#323745", "fg": "#e8eaf0",
         "muted": "#9aa1b2", "accent": "#5aa7ff", "ok": "#4cc38a", "warn": "#f2b84b", "err": "#ff6b6b"}
    root = tk.Tk()
    root.title(APP_TITLE)
    root.geometry("520x760")
    root.minsize(420, 560)
    root.configure(bg=C["bg"])
    fam = set(tkfont.families())
    ui = "Segoe UI" if "Segoe UI" in fam else "TkDefaultFont"
    semi = "Segoe UI Semibold" if "Segoe UI Semibold" in fam else ui
    mono = "Consolas" if "Consolas" in fam else "TkFixedFont"
    F = {"title": (semi, 14), "head": (semi, 11), "body": (ui, 10), "small": (ui, 9), "code": (mono, 16, "bold"),
         "mono": (mono, 9)}
    style = ttk.Style(root)
    try:
        style.theme_use("clam")
    except Exception:
        pass
    style.configure("TNotebook", background=C["bg"], borderwidth=0, tabmargins=(0, 0, 0, 0))
    style.configure("TNotebook.Tab", background=C["bg"], foreground=C["muted"], padding=(12, 6), font=F["small"],
                    borderwidth=0, lightcolor=C["bg"], darkcolor=C["bg"], bordercolor=C["bg"])
    style.map("TNotebook.Tab", background=[("selected", C["panel"])], foreground=[("selected", C["fg"])])
    style.configure("TCombobox", fieldbackground=C["panel2"], background=C["panel2"], foreground=C["fg"],
                    arrowcolor=C["muted"], bordercolor=C["line"])
    style.map("TCombobox", fieldbackground=[("readonly", C["panel2"])], foreground=[("readonly", C["fg"])])
    root.option_add("*TCombobox*Listbox.background", C["panel2"])
    root.option_add("*TCombobox*Listbox.foreground", C["fg"])

    events = queue.Queue()
    hub = Hub(on_event=lambda kind, text: events.put((kind, text)))
    for P in (NFL, Trivia, Facts):
        hub.add_plugin(P(hub))

    # ------------------------------------------------------------ widget helpers
    def button(parent, text, cmd, primary=False):
        return tk.Button(parent, text=text, command=cmd, relief="flat", bd=0, cursor="hand2",
                         bg=C["accent"] if primary else C["panel2"], fg="#0b1220" if primary else C["fg"],
                         activebackground="#7cbaff" if primary else C["line"], activeforeground=C["fg"],
                         font=F["head"] if primary else F["small"], padx=10, pady=4, highlightthickness=0)

    def label(parent, text="", var=None, color="fg", font="body", **kw):
        return tk.Label(parent, text=text, textvariable=var, bg=kw.pop("bg", C["panel"]), fg=C[color],
                        font=F[font], anchor="w", justify="left", **kw)

    def entry(parent, var, width=None, show=None):
        e = tk.Entry(parent, textvariable=var, bg=C["panel2"], fg=C["fg"], insertbackground=C["fg"], relief="flat",
                     font=F["body"], highlightthickness=1, highlightbackground=C["line"], highlightcolor=C["accent"],
                     show=show)
        if width:
            e.configure(width=width)
        return e

    def check(parent, text, var, cmd=None):
        return tk.Checkbutton(parent, text=text, variable=var, command=cmd, bg=C["panel"], fg=C["fg"],
                              selectcolor=C["panel2"], activebackground=C["panel"], activeforeground=C["fg"],
                              font=F["small"], anchor="w", highlightthickness=0, bd=0)

    def card(parent, title=None):
        f = tk.Frame(parent, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
        f.pack(fill="x", padx=10, pady=(8, 0))
        if title:
            label(f, title, font="head").pack(fill="x", padx=10, pady=(8, 2))
        return f

    def in_thread(fn, *a):
        def run():
            try:
                fn(*a)
            except Exception as e:
                events.put(("log", f"Problem: {e}"))
        threading.Thread(target=run, daemon=True).start()

    # ------------------------------------------------------------ header
    top = tk.Frame(root, bg=C["bg"])
    top.pack(fill="x", padx=12, pady=(10, 0))
    tk.Label(top, text="👓  " + APP_TITLE, bg=C["bg"], fg=C["fg"], font=F["title"]).pack(side="left")
    status_var = tk.StringVar(value="Starting…")
    status_lbl = tk.Label(top, textvariable=status_var, bg=C["bg"], fg=C["muted"], font=F["small"])
    status_lbl.pack(side="right")

    # ------------------------------------------------------------ phone card
    pc = card(root, "Your phone")
    code_row = tk.Frame(pc, bg=C["panel"])
    code_row.pack(fill="x", padx=10, pady=(2, 2))
    label(code_row, "Pairing code").pack(side="left")
    code_var = tk.StringVar(value=hub.cfg["code"])
    tk.Label(code_row, textvariable=code_var, bg=C["panel"], fg=C["accent"], font=F["code"]).pack(side="left", padx=10)

    def copy_code():
        root.clipboard_clear()
        root.clipboard_append(hub.cfg["code"])
        events.put(("log", "Pairing code copied."))
    button(code_row, "Copy", copy_code).pack(side="right")
    label(pc, "On your iPhone open " + hub.cfg["app_url"].replace("https://", "") +
          ", add it to your Home Screen, open it from there and enter this code.",
          color="muted", font="small", wraplength=470).pack(fill="x", padx=10)
    dev_var = tk.StringVar()
    dev_lbl = label(pc, var=dev_var, font="small", wraplength=470)
    dev_lbl.pack(fill="x", padx=10, pady=(6, 2))
    prow = tk.Frame(pc, bg=C["panel"])
    prow.pack(fill="x", padx=10, pady=(4, 10))
    button(prow, "Send test", lambda: hub.deliver("Test from Glasses Hub",
                                                  "Sent " + datetime.now().strftime("%I:%M:%S %p").lstrip("0"),
                                                  source="hub", manual=True)).pack(side="left")

    def remove_phones():
        if not hub.cfg["devices"]:
            return
        if messagebox.askyesno(APP_TITLE, "Forget all paired phones? They'll need to pair again with the code."):
            hub.cfg["devices"] = {}
            hub.save()
            render_devices()

    def new_code():
        if messagebox.askyesno(APP_TITLE, "Make a new pairing code? Every phone will need to pair again."):
            hub.new_pairing()
            code_var.set(hub.cfg["code"])
    button(prow, "Forget phones", remove_phones).pack(side="left", padx=6)
    button(prow, "New code", new_code).pack(side="left")
    button(prow, "Open phone app", lambda: webbrowser.open(hub.cfg["app_url"])).pack(side="right")

    def render_devices():
        devs = hub.cfg["devices"]
        if not devs:
            dev_var.set("No phone paired yet.")
            dev_lbl.configure(fg=C["warn"])
            return
        lines = []
        bad = False
        for d in devs.values():
            if d.get("sub"):
                how = "notifications on (works with the app closed)"
            else:
                how = "relay only (keep the app open)"
            if d.get("last_error"):
                how += f" · last problem: {d['last_error'][:60]}"
                bad = True
            lines.append(f"📱 {d.get('name', 'Phone')}: {how}")
        dev_var.set("\n".join(lines))
        dev_lbl.configure(fg=C["warn"] if bad else C["ok"])

    # ------------------------------------------------------------ tabs
    nb = ttk.Notebook(root)
    nb.pack(fill="both", expand=True, padx=10, pady=8)

    def tab(name):
        outer = tk.Frame(nb, bg=C["bg"])
        nb.add(outer, text=name)
        canvas = tk.Canvas(outer, bg=C["bg"], highlightthickness=0)
        sb = tk.Scrollbar(outer, orient="vertical", command=canvas.yview)
        inner = tk.Frame(canvas, bg=C["bg"])
        inner.bind("<Configure>", lambda e: canvas.configure(scrollregion=canvas.bbox("all")))
        win = canvas.create_window((0, 0), window=inner, anchor="nw")
        canvas.bind("<Configure>", lambda e: canvas.itemconfigure(win, width=e.width))
        canvas.configure(yscrollcommand=sb.set)
        canvas.pack(side="left", fill="both", expand=True)
        sb.pack(side="right", fill="y")
        canvases.append(canvas)
        return inner

    canvases = []

    def wheel(e):
        for cv in canvases:
            if cv.winfo_ismapped():
                cv.yview_scroll(int(-e.delta / 120), "units")
    root.bind_all("<MouseWheel>", wheel)

    # ---- plug-ins
    ptab = tab("Plug-ins")
    plugin_state = {}

    def settings_dialog(p):
        d = tk.Toplevel(root)
        d.title(f"{p.name} settings")
        d.configure(bg=C["panel"])
        d.transient(root)
        d.grab_set()
        vars_ = {}
        for i, (key, text, kind, extra) in enumerate(p.fields):
            val = p.cfg.get(key)
            if kind == "bool":
                v = tk.BooleanVar(value=bool(val))
                check(d, text, v).grid(row=i, column=0, columnspan=2, sticky="w", padx=12, pady=3)
            else:
                label(d, text, font="small", wraplength=260).grid(row=i, column=0, sticky="w", padx=12, pady=3)
                if kind == "list":
                    v = tk.StringVar(value=", ".join(val or []))
                else:
                    v = tk.StringVar(value=str(val if val is not None else ""))
                if kind == "choice":
                    w = ttk.Combobox(d, textvariable=v, values=extra, state="readonly", width=18)
                else:
                    w = entry(d, v, width=28 if kind in ("text", "list") else 8)
                w.grid(row=i, column=1, sticky="w", padx=12, pady=3)
            vars_[key] = (kind, extra, v)

        def save():
            for key, (kind, extra, v) in vars_.items():
                try:
                    if kind == "bool":
                        p.cfg[key] = bool(v.get())
                    elif kind == "int":
                        n = int(float(v.get()))
                        if extra:
                            n = max(extra[0], min(extra[1], n))
                        p.cfg[key] = n
                    elif kind == "list":
                        p.cfg[key] = [x.strip().upper() for x in v.get().split(",") if x.strip()]
                    elif kind == "time":
                        h, m = core.parse_hhmm(v.get(), p.defaults.get(key, "09:00"))
                        p.cfg[key] = f"{h:02d}:{m:02d}"
                    else:
                        p.cfg[key] = v.get().strip()
                except ValueError:
                    pass
            hub.save()
            if hasattr(p, "pool"):
                p.pool = []                   # new topic/difficulty: fetch fresh questions/facts
            if hasattr(p, "schedule_at"):
                p.schedule_at = 0
            p.wake.set()
            d.destroy()
            events.put(("log", f"{p.name} settings saved."))
        row = tk.Frame(d, bg=C["panel"])
        row.grid(row=len(p.fields), column=0, columnspan=2, sticky="e", padx=12, pady=10)
        button(row, "Cancel", d.destroy).pack(side="right", padx=(6, 0))
        button(row, "Save", save, primary=True).pack(side="right")

    for p in hub.plugins.values():
        f = tk.Frame(ptab, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
        f.pack(fill="x", pady=(0, 8))
        head = tk.Frame(f, bg=C["panel"])
        head.pack(fill="x", padx=10, pady=(8, 0))
        on = tk.BooleanVar(value=p.enabled)
        check(head, p.name, on, lambda p=p, on=on: p.set_enabled(on.get())).pack(side="left")
        button(head, "Settings…", lambda p=p: settings_dialog(p)).pack(side="right")
        st = tk.StringVar(value=p.state_text or "")
        label(f, var=st, color="muted", font="small").pack(fill="x", padx=12)
        acts = tk.Frame(f, bg=C["panel"])
        acts.pack(fill="x", padx=10, pady=(4, 10))
        for aid, text in p.actions.items():
            button(acts, text, lambda p=p, aid=aid: in_thread(p.action, aid)).pack(side="left", padx=(0, 6))
        plugin_state[p.id] = (on, st)

    # ---- send
    stab = tab("Send")
    sc = tk.Frame(stab, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
    sc.pack(fill="x")
    label(sc, "Send anything to your glasses", font="head").pack(fill="x", padx=10, pady=(8, 2))
    label(sc, "Top line", color="muted", font="small").pack(fill="x", padx=10)
    s_title = tk.StringVar()
    entry(sc, s_title).pack(fill="x", padx=10)
    label(sc, "Second line (longer text flows into a second notification)", color="muted", font="small").pack(fill="x", padx=10, pady=(6, 0))
    s_body = tk.Text(sc, height=4, bg=C["panel2"], fg=C["fg"], insertbackground=C["fg"], relief="flat",
                     font=F["body"], wrap="word", highlightthickness=1, highlightbackground=C["line"])
    s_body.pack(fill="x", padx=10)

    def do_send():
        t, b = s_title.get().strip(), s_body.get("1.0", "end").strip()
        if hub.deliver(t, b, source="send", manual=True):
            s_title.set("")
            s_body.delete("1.0", "end")
    srow = tk.Frame(sc, bg=C["panel"])
    srow.pack(fill="x", padx=10, pady=8)
    button(srow, "Send", do_send, primary=True).pack(side="right")

    ac = tk.Frame(stab, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
    ac.pack(fill="x", pady=8)
    label(ac, "Send from scripts and other apps", font="head").pack(fill="x", padx=10, pady=(8, 2))
    label(ac, "Anything on this PC can post a note to this address (only this PC can reach it):",
          color="muted", font="small", wraplength=460).pack(fill="x", padx=10)
    url_var = tk.StringVar(value=hub.send_url() + "&title=Hello&body=From%20a%20script")
    tk.Entry(ac, textvariable=url_var, bg=C["panel2"], fg=C["fg"], relief="flat", font=F["mono"],
             readonlybackground=C["panel2"], state="readonly").pack(fill="x", padx=10, pady=4)
    ps = f"Invoke-RestMethod -Method Post -Uri '{hub.send_url()}' -Body @{{title='Build done'; body='Render finished'}}"

    def copy(text):
        root.clipboard_clear()
        root.clipboard_append(text)
        events.put(("log", "Copied."))
    arow = tk.Frame(ac, bg=C["panel"])
    arow.pack(fill="x", padx=10, pady=(0, 10))
    button(arow, "Copy address", lambda: copy(hub.send_url())).pack(side="left")
    button(arow, "Copy PowerShell example", lambda: copy(ps)).pack(side="left", padx=6)

    # ---- activity
    atab = tk.Frame(nb, bg=C["bg"])
    nb.add(atab, text="Activity")
    act = tk.Text(atab, bg=C["panel"], fg=C["fg"], relief="flat", font=F["small"], wrap="word",
                  highlightthickness=0, padx=10, pady=8, state="disabled")
    act.pack(fill="both", expand=True)
    act.tag_configure("time", foreground=C["muted"])
    act.tag_configure("src", foreground=C["accent"])
    act.tag_configure("t", foreground=C["fg"], font=F["head"])
    act.tag_configure("b", foreground="#c9cedb")
    act.tag_configure("log", foreground=C["muted"])

    def act_add(chunks):
        act.configure(state="normal")
        act.insert("1.0", "\n")
        for text, tag in reversed(chunks):
            act.insert("1.0", text, tag)
        n = int(act.index("end-1c").split(".")[0])
        if n > 600:
            act.delete("500.0", "end")
        act.configure(state="disabled")

    # ---- settings
    gtab = tab("Settings")
    qc = tk.Frame(gtab, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
    qc.pack(fill="x")
    label(qc, "Quiet hours", font="head").pack(fill="x", padx=10, pady=(8, 2))
    q_on = tk.BooleanVar(value=hub.cfg["quiet_on"])
    q_s, q_e = tk.StringVar(value=hub.cfg["quiet_start"]), tk.StringVar(value=hub.cfg["quiet_end"])
    qrow = tk.Frame(qc, bg=C["panel"])
    qrow.pack(fill="x", padx=10)
    check(qrow, "No automatic notes from", q_on).pack(side="left")
    entry(qrow, q_s, 6).pack(side="left", padx=4)
    label(qrow, "to").pack(side="left")
    entry(qrow, q_e, 6).pack(side="left", padx=4)
    label(qc, "Things you ask for (Send, Score now, Fact now, trivia) always come through. Game alerts can too "
              "(NFL settings).", color="muted", font="small", wraplength=460).pack(fill="x", padx=10, pady=(2, 6))
    lrow = tk.Frame(qc, bg=C["panel"])
    lrow.pack(fill="x", padx=10, pady=(0, 10))
    gap_v = tk.StringVar(value=str(hub.cfg["gap_seconds"]))
    cap_v = tk.StringVar(value=str(hub.cfg["max_per_hour"]))
    label(lrow, "Seconds between notes").pack(side="left")
    entry(lrow, gap_v, 4).pack(side="left", padx=(4, 12))
    label(lrow, "Max automatic notes per hour").pack(side="left")
    entry(lrow, cap_v, 4).pack(side="left", padx=4)

    kc = tk.Frame(gtab, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
    kc.pack(fill="x", pady=8)
    label(kc, "Claude (for trivia and facts on any topic)", font="head").pack(fill="x", padx=10, pady=(8, 2))
    key_state = tk.StringVar()

    def render_key():
        k = get_api_key()
        key_state.set(f"Key found (…{k[-4:]})." if k else
                      "No key yet. Without one, trivia uses Open Trivia DB and facts use Wikipedia's On this day.")
    render_key()
    label(kc, var=key_state, color="muted", font="small", wraplength=460).pack(fill="x", padx=10)
    k_var = tk.StringVar()
    krow = tk.Frame(kc, bg=C["panel"])
    krow.pack(fill="x", padx=10, pady=4)
    entry(krow, k_var, show="•").pack(side="left", fill="x", expand=True)

    def save_key():
        if k_var.get().strip():
            save_api_key(k_var.get())
            k_var.set("")
            render_key()
            events.put(("log", "Claude key saved on this PC."))
    button(krow, "Save key", save_key).pack(side="left", padx=(6, 0))
    m_var = tk.StringVar(value=hub.cfg["claude_model"])
    mrow = tk.Frame(kc, bg=C["panel"])
    mrow.pack(fill="x", padx=10, pady=(0, 10))
    label(mrow, "Model").pack(side="left")
    entry(mrow, m_var, 24).pack(side="left", padx=6)

    oc = tk.Frame(gtab, bg=C["panel"], highlightthickness=1, highlightbackground=C["line"])
    oc.pack(fill="x")
    label(oc, "This PC", font="head").pack(fill="x", padx=10, pady=(8, 2))
    boot = tk.BooleanVar(value=os.path.exists(startup_shortcut()))
    check(oc, "Start Glasses Hub when I sign in to Windows (starts minimized)", boot,
          lambda: in_thread(set_startup, boot.get())).pack(fill="x", padx=10)
    label(oc, f"Settings and keys are stored in {data_dir()}. Version {VERSION}.", color="muted", font="small",
          wraplength=460).pack(fill="x", padx=10, pady=(4, 10))

    def save_settings():
        hub.cfg["quiet_on"] = bool(q_on.get())
        for var, key, dflt in ((q_s, "quiet_start", "22:00"), (q_e, "quiet_end", "07:00")):
            h, m = core.parse_hhmm(var.get(), dflt)
            hub.cfg[key] = f"{h:02d}:{m:02d}"
            var.set(hub.cfg[key])
        try:
            hub.cfg["gap_seconds"] = max(2, min(30, float(gap_v.get())))
            hub.cfg["max_per_hour"] = max(1, min(500, int(float(cap_v.get()))))
        except ValueError:
            pass
        hub.cfg["claude_model"] = m_var.get().strip() or "claude-sonnet-5-5"
        hub.save()
        events.put(("log", "Settings saved."))
    srow2 = tk.Frame(gtab, bg=C["bg"])
    srow2.pack(fill="x", pady=8)
    button(srow2, "Save settings", save_settings, primary=True).pack(side="right")

    # ------------------------------------------------------------ events from the hub threads
    def pump():
        try:
            while True:
                kind, text = events.get_nowait()
                stamp = datetime.now().strftime("%I:%M %p").lstrip("0")
                if kind == "log":
                    act_add([(stamp + "  ", "time"), (text, "log")])
                elif kind == "sent":
                    e = json.loads(text)
                    chunks = [(stamp + "  ", "time"), (e["source"] + "\n", "src")]
                    for t, b in e["parts"]:
                        chunks += [(t + "\n", "t")] + ([(b + "\n", "b")] if b else [])
                    act_add(chunks)
                elif kind == "devices":
                    render_devices()
                render_status()
        except queue.Empty:
            pass
        root.after(250, pump)

    def render_status():
        if hub.relay_ok:
            q = " · quiet hours" if hub.quiet_now() else ""
            status_var.set("● Connected" + q)
            status_lbl.configure(fg=C["ok"])
        else:
            status_var.set("● Connecting…")
            status_lbl.configure(fg=C["warn"])

    def refresh_states():
        for pid, (on, st) in plugin_state.items():
            p = hub.plugins[pid]
            st.set(p.state_text or "")
            if on.get() != p.enabled:
                on.set(p.enabled)
        render_status()
        root.after(2000, refresh_states)

    def on_close():
        hub.stop()
        root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_close)
    render_devices()
    hub.start()
    pump()
    refresh_states()
    act_add([(datetime.now().strftime("%I:%M %p").lstrip("0") + "  ", "time"),
             ("Glasses Hub started. Notes you send show up here.", "log")])
    if minimized:
        root.iconify()
    root.mainloop()


if __name__ == "__main__":
    main()
