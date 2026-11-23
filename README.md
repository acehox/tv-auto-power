# tv-auto-power

Use a Hisense (VIDAA) TV as a PC monitor without touching the remote:

- **PC boots or wakes up**: the TV turns on (Wake-on-LAN if needed) and switches to the PC's HDMI input.
- **PC sleeps, shuts down or restarts**: the TV turns off, but only if it's showing the PC's input. If someone is watching something else, it stays on.

> **Windows 11 Pro only.** Turning the TV off at shutdown uses a Group Policy shutdown script, and Windows Home has no Group Policy.

Built on [vidaa-control](https://pypi.org/project/vidaa-control/).

## Requirements

- Windows 11 Pro and Python 3.9+ ([python.org](https://www.python.org/downloads/); tick "Add to PATH")
- A Hisense VIDAA TV on the same network, with a static or DHCP-reserved IP
- On the TV, enable network standby / Wake-on-LAN so it can be turned on over the network

## Setup

Leave the TV on, then run from an **administrator** PowerShell, signed in as the user who will use the PC:

```powershell
git clone https://github.com/<you>/tv-auto-power.git
cd tv-auto-power
powershell -ExecutionPolicy Bypass -File .\setup.ps1
```

The script:

1. Creates `.venv` and installs the requirements.
2. Finds the TV on your network and pairs with it (type the PIN shown on the TV).
3. Saves the TV's MAC address for Wake-on-LAN.
4. Lists the TV's inputs and asks which one the PC uses (optional).
5. Registers two scheduled tasks and a Group Policy shutdown script.

Running it again is safe: it keeps your config and replaces its own tasks and shutdown entry. Other shutdown scripts you have are left alone.

## Configuration

`.env` (created from [.env.example](.env.example)):

| Key | Default | |
|---|---|---|
| `TV_INPUT` | unset | PC input, as the id shown by `.\.venv\Scripts\tv.exe source list`. Unset: no input switching, and the TV turns off with the PC whatever it's showing |
| `TV_MAC` | from `config.yaml` | TV MAC address for Wake-on-LAN |
| `TV_WOL_RETRIES` | `12` | Wake-on-LAN attempts, 5 s apart |
| `TV_SOURCE_RETRIES` | `6` | Input-switch attempts after waking |

The TV's address and pairing tokens live in `config.yaml` and `tokens.json`, both written by vidaa-control. `.env`, `config.yaml` and `tokens.json` are git-ignored, so keep them private.

## How it works

| What | Runs as | When | Does |
|---|---|---|---|
| Task "TV On" | SYSTEM | Boot, resume from sleep | `tv_power.py on` |
| Task "TV Sleep Watch" | You | Logon | `tv_sleep_watch.py`: a hidden window that turns the TV off when the PC sleeps |
| Group Policy shutdown script | SYSTEM | Shutdown, restart | `tv_power.py off` |

The shutdown script appears in `gpedit.msc` under Computer Configuration > Windows Settings > Scripts (Startup/Shutdown) > Shutdown. Everything is logged to `tv_power.log`.

Manual use:

```powershell
.\.venv\Scripts\python.exe tv_power.py on
.\.venv\Scripts\python.exe tv_power.py off
```

## Notes

- **Turning on while the TV is already on doesn't change the input**, so it won't interrupt someone watching something else.
- `requirements.txt` pins vidaa-control, because this project uses some of its internals.

## Troubleshooting

- **TV turns on but stays on the wrong input**: the log says `Could not confirm switch`. Check `TV_INPUT` against `tv.exe source list`, or raise `TV_SOURCE_RETRIES`.
- **TV doesn't turn on from deep standby**: check Wake-on-LAN on the TV and `TV_MAC` in `.env`.
- **TV stays on after shutdown**: check that the script is listed in gpedit (see above), and look for errors in `tv_power.log`.
- **Pairing expired**: delete `tokens.json` and re-run `setup.ps1`.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\setup.ps1 -Uninstall
```

This removes the tasks and the shutdown script. Then delete the folder.
