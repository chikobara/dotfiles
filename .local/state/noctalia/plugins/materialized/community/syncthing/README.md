# Syncthing

Syncthing status and control for Noctalia. Shows the sync state in the bar,
gives you a Syncthing Tray-style panel with folder and device lists, per-folder
and per-device pause/resume, rescan, sync progress, transfer rates, and desktop
notifications on sync events. A port of the v4 `syncthing-status` plugin (by
Pir0c0pter0) to the v5 Luau plugin API, talking to the Syncthing REST API
directly — no helper scripts.

## Plugin

| Field | Value |
| --- | --- |
| ID | `rylos/syncthing` |
| Entries | Bar widget: `bar`; panel: `panel`; service: `poller`; shortcut: `pause`; launcher: `folders`; desktop widget: `desktop` |
| Launcher Prefix | `/st` |

## Requirements

| Command | Needed for |
| --- | --- |
| `syncthing` | The daemon this plugin talks to over its REST API. |
| `gio` | The *Open web GUI* action (`glib2`). |
| `xdg-open` | Fallback for that action when `gio` is unavailable (`xdg-utils`). |

Install `syncthing` and have it running for this user. The plugin autodetects
the GUI URL and API key from `~/.local/state/syncthing/config.xml` (or
`~/.config/syncthing/config.xml`), so it usually works with zero configuration.
The two openers are only used by the *Open web GUI* button; everything else
goes through `noctalia.http`.

## Usage

- **Bar widget** (`bar`): add it from the Add-widget picker. The Syncthing logo
  is dimmed/badged by state (syncing, paused, error, offline, …) and shows the
  overall completion percentage while syncing. Left click opens the panel,
  right click forces a refresh. The tooltip shows devices, folders, pending
  items, transfer rates, and the last check time.
- **Panel** (`panel`): header with pause-all/resume-all, open web GUI, and
  refresh buttons; stat tiles (devices / folders / pending); **Folders |
  Devices** tabs. Folder rows show state, sync progress, and last activity,
  with per-folder pause/resume and rescan buttons. Device rows show connection
  state, address, and client version, with per-device pause/resume.

  ```sh
  noctalia msg panel-toggle rylos/syncthing:panel
  ```

- **Launcher** (`/st`): type `/st <query>` to fuzzy-search monitored folders;
  activating a result triggers a rescan of that folder.
- **Shortcut** (`pause`): add it from Settings → Control Center shortcuts. It
  toggles Syncthing's global pause (pause/resume all devices).
- **Desktop widget** (`desktop`): add it from the desktop-widgets editor. A
  compact card with state, counters, sync progress, and transfer rates.
- **Notifications**: by default the service notifies when a folder finishes
  syncing, reports an error, or a device connects/disconnects. Disable with
  the **Event notifications** setting.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `url` | `string` | `""` | Syncthing GUI base URL. Empty = autodetect from config.xml. |
| `api_key` | `string` | `""` | REST API key. Empty = autodetect from config.xml. |
| `config_path` | `file` | `""` | Explicit config.xml path for autodetection (advanced). |
| `poll_interval` | `int` | `10` | Status refresh interval in seconds (2–300). |
| `notify_events` | `bool` | `true` | Desktop notifications for folder done/error and device connect/disconnect. |
| `folders` | `string_list` | `[]` | Folder IDs to monitor. Empty = all folders (advanced). |
| `insecure_tls` | `bool` | `false` | Accept self-signed certificates on HTTPS GUI URLs (advanced). |
| `show_pending` | `bool` | `true` | Bar widget: show completion %/pending count while syncing. |

## IPC

```sh
noctalia msg plugin rylos/syncthing:poller all refresh   # force a status refresh
noctalia msg plugin rylos/syncthing:poller all pause     # pause all devices
noctalia msg plugin rylos/syncthing:poller all resume    # resume all devices
noctalia msg plugin rylos/syncthing:poller all open      # open the web GUI
noctalia msg panel-toggle rylos/syncthing:panel
```

## Notes

- Requests to the Syncthing API go through a small queue (four at a time). The
  host allows at most eight in-flight HTTP requests per plugin and refuses the
  rest outright, which used to show up as `folder status HTTP 0` on the ninth
  and later folders.

- **Network**: all requests go to the local (or configured) Syncthing REST API
  via `noctalia.http` — `/rest/noauth/health`, `/rest/system/status`,
  `/rest/config`, `/rest/system/connections`, `/rest/system/error`,
  `/rest/stats/folder`, `/rest/db/status`, and the action endpoints
  (`/rest/config/folders|devices/<id>` PATCH, `/rest/db/scan` POST,
  `/rest/system/pause|resume` POST). No other network access.
- **Processes**: the only spawned process is the *Open web GUI* action, which
  runs `gio open <url>` (fallback `xdg-open <url>`). Every REST request goes
  through `noctalia.http`, including the `insecure_tls` case, which sets
  `allow_insecure_tls` instead of shelling out to an external HTTP client.
- **Filesystem**: reads Syncthing's `config.xml` for URL/API key autodetection.
  Nothing is written.
- The API key never leaves the machine: it is only sent as the `X-API-Key`
  header to the Syncthing GUI endpoint it belongs to.

## Credits

Based on the v4 [syncthing-status](https://github.com/noctalia-dev/legacy-v4-plugins/tree/main/syncthing-status)
plugin by Pir0c0pter0. MIT license.
