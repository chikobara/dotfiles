# Wallhaven

Browse [Wallhaven](https://wallhaven.cc), download a wallpaper into your Noctalia wallpaper directory, and apply it to all monitors.

## Plugin

| Field | Value |
| --- | --- |
| ID | `noctalia/wallhaven` |
| Entries | Panel: `browser`; bar widget: `wallhaven`; shortcut: `shortcut` |

## Usage

1. Enable the plugin in Settings → Plugins.
2. Add the `wallhaven` bar widget, the control center shortcut, or run:

   ```sh
   noctalia msg panel-toggle noctalia/wallhaven:browser
   ```

3. Search by tags, adjust category and purity filters, paginate results (or click the page counter, type a page number, and press Enter), then click a wallpaper to download and apply.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `api_key` | `string` | *(empty)* | Optional Wallhaven API key for higher rate limits and NSFW access. |
| `download_dir` | `folder` | *(empty)* | Optional download override; defaults to your configured wallpaper directory. |

Thumbnail previews are cached under `$XDG_STATE_HOME/noctalia/wallhaven/thumbs` (`~/.local/state/noctalia/wallhaven/thumbs` by default).

## Notes

- Requires network access (`[shell].offline_mode` must be off).
- NSFW results require a Wallhaven API key.
- Applied wallpapers use `noctalia.setWallpaper(path)` so they persist like any other wallpaper.
