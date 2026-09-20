# Key Visualizer

A minimal, real-time floating on-screen keystroke visualizer HUD for Noctalia. Displays typed keys and modifier combinations as translucent, blurred glass keycaps directly on your screen.

## Plugin

| Field | Value |
| --- | --- |
| ID | `h-jangra/keyviz` |
| Entries | Bar widget: `widget`; panel: `overlay`; shortcut: `toggle`; service: `keylistener` |

## Requirements

- `python3` on `PATH` (used by the background event listener service).
- Linux user in the `input` group to read `/dev/input/event*` devices:
  ```sh
  sudo usermod -a -G input $USER
  ```
  *(Note: Log out and log back in for group membership to take effect).*

## Usage

### Panel

Toggle the key visualizer overlay HUD directly via IPC:

```sh
noctalia msg panel-toggle h-jangra/keyviz:overlay
```

### Bar Widget & Shortcut

- **Bar Widget (`widget`)**: Add `h-jangra/keyviz:widget` to your bar items in Noctalia settings to get a quick visual status icon and toggle button.
- **Control Center Shortcut (`toggle`)**: Add `h-jangra/keyviz:toggle` to your control center shortcuts to pause or resume key visualization.

### IPC Commands

Control the listener service dynamically:

```sh
# Toggle key visualizer on/off
noctalia msg plugin h-jangra/keyviz:keylistener all toggle

# Clear currently displayed keys
noctalia msg plugin h-jangra/keyviz:keylistener all clear
```

## Settings

Configure Keyviz in **Noctalia Settings → Plugins → Key Visualizer**:

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `enabled_by_default` | `bool` | `true` | Start visualizer automatically when Noctalia starts. |
| `padding` | `int` | `6` | Internal padding spacing inside overlay around keycaps (`0` – `30`). |
| `margin` | `int` | `6` | Spacing gap between visualized key combinations (`0` – `30`). |
| `timeout_ms` | `int` | `500` | Inactivity duration (ms) before keys disappear (`200` – `5000`). |
| `max_keys` | `int` | `4` | Maximum number of key combinations to display (`1` – `8`). |
| `font_size` | `select` | `medium` | Text size of keycaps (`small`, `medium`, `large`). |
| `badge_style` | `select` | `glass` | Visual style (`glass`, `solid`, `accent`). |
| `show_modifiers_only` | `bool` | `false` | Only visualize combinations with Ctrl, Alt, Shift, or Super. |

## License

MIT
