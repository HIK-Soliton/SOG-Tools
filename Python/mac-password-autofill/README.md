# Mac Password Autofill (MVP)

A local-only macOS autofill helper app.

## Features
- Store credentials metadata in a local JSON file.
- Store passwords in Apple Keychain via `keyring`.
- Global hotkey (`Cmd+Shift+U`) to open account picker.
- Autofill sequence: username -> Tab -> password.

## Security Model
- Password text is not saved in local JSON.
- Password is saved in Keychain only.
- No network communication.

## Setup
1. Create and activate virtual environment.
2. Install dependencies.
3. Run app.

```bash
cd /Users/hiroyukiiki/src/SOG-Tools/Python/mac-password-autofill
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
python src/app.py
```

## macOS Permissions
Grant permissions to the host process that runs Python (Terminal or VS Code):
- Privacy & Security -> Accessibility
- Privacy & Security -> Input Monitoring

Without permissions, global hotkey or typing automation may not work.

## Usage
1. Click `Add/Update` and save label, username, password.
2. Focus target login screen.
3. Press `Cmd+Shift+U`.
4. Choose account and click `Autofill`.

## Notes
- This is MVP for login forms with two fields.
- If your form order differs, customize `perform_autofill` logic in `src/app.py`.
