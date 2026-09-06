import json
import queue
import threading
import time
from pathlib import Path
import tkinter as tk
from tkinter import messagebox, simpledialog

import keyring
import pyautogui
from pynput import keyboard

APP_NAME = "Mac Password Autofill"
HOTKEY = "<cmd>+<shift>+u"
CONFIG_PATH = Path.home() / ".mac_password_autofill.json"
KEYRING_SERVICE_PREFIX = "mac_password_autofill"


class AccountStore:
    def __init__(self, config_path: Path):
        self.config_path = config_path
        self.data = {"accounts": []}
        self.load()

    def load(self):
        if self.config_path.exists():
            self.data = json.loads(self.config_path.read_text(encoding="utf-8"))
        else:
            self.save()

    def save(self):
        self.config_path.write_text(
            json.dumps(self.data, ensure_ascii=False, indent=2), encoding="utf-8"
        )

    def list_accounts(self):
        return self.data.get("accounts", [])

    def upsert(self, label: str, username: str, password: str):
        accounts = self.data.setdefault("accounts", [])
        found = next((a for a in accounts if a["label"] == label), None)
        if found:
            found["username"] = username
        else:
            accounts.append({"label": label, "username": username})
        keyring.set_password(self._service_name(label), username, password)
        self.save()

    def delete(self, label: str):
        accounts = self.data.setdefault("accounts", [])
        target = next((a for a in accounts if a["label"] == label), None)
        if not target:
            return
        keyring.delete_password(self._service_name(label), target["username"])
        self.data["accounts"] = [a for a in accounts if a["label"] != label]
        self.save()

    def get_credentials(self, label: str):
        account = next((a for a in self.list_accounts() if a["label"] == label), None)
        if not account:
            return None
        password = keyring.get_password(self._service_name(label), account["username"])
        if password is None:
            return None
        return account["username"], password

    @staticmethod
    def _service_name(label: str):
        return f"{KEYRING_SERVICE_PREFIX}:{label}"


class AutofillApp:
    def __init__(self):
        self.store = AccountStore(CONFIG_PATH)
        self.hotkey_events = queue.Queue()
        self.root = tk.Tk()
        self.root.title(APP_NAME)
        self.root.geometry("480x360")

        self.accounts_var = tk.StringVar(value=self._account_labels())
        self._build_ui()

        self.listener_thread = threading.Thread(target=self._start_hotkey_listener, daemon=True)
        self.listener_thread.start()
        self.root.after(200, self._poll_hotkey_events)

    def _build_ui(self):
        top = tk.Frame(self.root)
        top.pack(fill=tk.X, padx=12, pady=12)

        tk.Label(top, text=f"Hotkey: {HOTKEY}").pack(anchor="w")
        tk.Label(top, text="Select account and use Add/Update/Delete.").pack(anchor="w")

        self.listbox = tk.Listbox(self.root, listvariable=self.accounts_var, height=10)
        self.listbox.pack(fill=tk.BOTH, expand=True, padx=12, pady=8)

        buttons = tk.Frame(self.root)
        buttons.pack(fill=tk.X, padx=12, pady=8)

        tk.Button(buttons, text="Add/Update", command=self.add_or_update).pack(side=tk.LEFT)
        tk.Button(buttons, text="Delete", command=self.delete).pack(side=tk.LEFT, padx=8)
        tk.Button(buttons, text="Test Autofill", command=self.manual_autofill).pack(side=tk.LEFT)

        note = (
            "Before first use: grant Accessibility and Input Monitoring permission "
            "to your Python host app (Terminal/VS Code)."
        )
        tk.Label(self.root, text=note, wraplength=450, justify="left").pack(
            fill=tk.X, padx=12, pady=12
        )

    def _account_labels(self):
        return [a["label"] for a in self.store.list_accounts()]

    def refresh(self):
        self.accounts_var.set(self._account_labels())

    def selected_label(self):
        selected = self.listbox.curselection()
        if not selected:
            return None
        return self.listbox.get(selected[0])

    def add_or_update(self):
        label = simpledialog.askstring(APP_NAME, "Account label (e.g. GitHub):", parent=self.root)
        if not label:
            return

        username = simpledialog.askstring(APP_NAME, "Username:", parent=self.root)
        if not username:
            return

        password = simpledialog.askstring(APP_NAME, "Password:", show="*", parent=self.root)
        if password is None or password == "":
            return

        self.store.upsert(label.strip(), username.strip(), password)
        self.refresh()

    def delete(self):
        label = self.selected_label()
        if not label:
            messagebox.showinfo(APP_NAME, "Select an account to delete.")
            return
        if not messagebox.askyesno(APP_NAME, f"Delete {label}?"):
            return

        try:
            self.store.delete(label)
        except keyring.errors.PasswordDeleteError:
            pass
        self.refresh()

    def manual_autofill(self):
        label = self.selected_label()
        if not label:
            messagebox.showinfo(APP_NAME, "Select an account first.")
            return
        self.perform_autofill(label)

    def _start_hotkey_listener(self):
        with keyboard.GlobalHotKeys({HOTKEY: self._on_hotkey_pressed}) as listener:
            listener.join()

    def _on_hotkey_pressed(self):
        self.hotkey_events.put("show_picker")

    def _poll_hotkey_events(self):
        while not self.hotkey_events.empty():
            event = self.hotkey_events.get()
            if event == "show_picker":
                self.show_hotkey_picker()
        self.root.after(200, self._poll_hotkey_events)

    def show_hotkey_picker(self):
        labels = self._account_labels()
        if not labels:
            messagebox.showinfo(APP_NAME, "No account registered yet.")
            return

        picker = tk.Toplevel(self.root)
        picker.title("Pick account")
        picker.attributes("-topmost", True)
        picker.geometry("340x260")

        tk.Label(picker, text="Choose account for autofill").pack(anchor="w", padx=10, pady=8)
        lb = tk.Listbox(picker, height=8)
        lb.pack(fill=tk.BOTH, expand=True, padx=10, pady=8)

        for label in labels:
            lb.insert(tk.END, label)

        def choose():
            selected = lb.curselection()
            if not selected:
                return
            label = lb.get(selected[0])
            picker.destroy()
            self.perform_autofill(label)

        tk.Button(picker, text="Autofill", command=choose).pack(pady=8)
        lb.bind("<Double-Button-1>", lambda _e: choose())

    def perform_autofill(self, label: str):
        creds = self.store.get_credentials(label)
        if creds is None:
            messagebox.showerror(
                APP_NAME,
                "Credential not found in Keychain. Please re-save this account.",
            )
            return

        username, password = creds

        # Give focus back to target application before typing.
        threading.Thread(
            target=self._type_credentials, args=(username, password), daemon=True
        ).start()

    @staticmethod
    def _type_credentials(username: str, password: str):
        time.sleep(1.0)
        pyautogui.write(username, interval=0.01)
        pyautogui.press("tab")
        pyautogui.write(password, interval=0.01)

    def run(self):
        self.root.mainloop()


if __name__ == "__main__":
    AutofillApp().run()
