# Mango Layouts

A clean, minimalist layout switcher plugin for MangoWC. It provides a bar widget and a fast popup panel to switch workspace layouts on the fly, directly from your desktop.

## Plugin

| Field | Value |
| --- | --- |
| ID | `ezequiel/mango_layouts` |
| Entries | Bar widget: `btn`; panel: `panel` |

## Requirements

Install `jq` and `mmsg` (MangoWC CLI) on `PATH`.
Requires MangoWC as the compositor.

## Usage

Add the widget to your Noctalia bar in Settings. Click the widget to open the layout switcher panel and change the current workspace layout. 

Alternatively, toggle the panel directly via command line or keybinding:

```sh
noctalia msg panel-toggle ezequiel/mango_layouts:panel
```

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `list_mode` | `bool` | `false` | Display layouts in a vertical list instead of a grid. |
| `show_tile` | `bool` | `true` | Show Tile layout. |
| `show_scroller` | `bool` | `true` | Show Scroller layout. |
| `show_monocle` | `bool` | `true` | Show Monocle layout. |
| `show_grid` | `bool` | `true` | Show Grid layout. |
| `show_fair` | `bool` | `true` | Show Fair layout. |
| `show_deck` | `bool` | `true` | Show Deck layout. |
| `show_dwindle` | `bool` | `true` | Show Dwindle layout. |
| `show_center_tile` | `bool` | `true` | Show Center Tile layout. |
| `show_vertical_tile` | `bool` | `true` | Show Vertical Tile layout. |
| `show_right_tile` | `bool` | `true` | Show Right Tile layout. |
| `show_vertical_scroller` | `bool` | `true` | Show Vertical Scroller layout. |
| `show_vertical_grid` | `bool` | `true` | Show Vertical Grid layout. |
| `show_vertical_deck` | `bool` | `true` | Show Vertical Deck layout. |
| `show_vertical_fair` | `bool` | `true` | Show Vertical Fair layout. |

Widget Specific Settings:
| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `show_glyph` | `bool` | `true` | Show the widget icon. |
| `show_text` | `bool` | `false` | Show the active layout name as text. |
| `custom_color` | `string` | `""` | Custom icon/text color (e.g. primary, on_surface). |

## Notes

The plugin uses `mmsg` to communicate with MangoWC for reading the active monitor state and applying the selected layout. Make sure you don't use this plugin on compositors other than MangoWC.
