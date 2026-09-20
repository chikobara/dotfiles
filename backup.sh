#!/bin/bash

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# Function to copy files/directories, replacing if they exist


copy_item() {
    if [ -e "$1" ]; then
        mkdir -p "$2" || return 1
        if rsync -a --delete "$1" "$2"; then
            echo "Updated: $1"
        else
            echo "Failed to update: $1" >&2
            return 1
        fi
    else
        echo "Not found: $1"
    fi
}


# Backup Hyprland config
echo
echo "Backup Hyprland config"
copy_item "$HOME/.config/hypr" "$script_dir/.config/"

# Backup fuzzel config
echo
echo "Backup fuzzel config"
copy_item "$HOME/.config/fuzzel" "$script_dir/.config/"


# Backup qt config
echo
echo "Backup qt5ct & qt6ct config"
copy_item "$HOME/.config/qt5ct" "$script_dir/.config/"
copy_item "$HOME/.config/qt6ct" "$script_dir/.config/"



# Backup Noctalia config
echo
echo "Backup Noctalia config"
copy_item "$HOME/.config/noctalia" "$script_dir/.config/"

# Backup Noctalia panel state, installed plugins, and plugin data.
# Caches, logs, and clipboard history are intentionally not copied.
echo
echo "Backup Noctalia state and plugins"
copy_item "$HOME/.local/state/noctalia/settings.toml" "$script_dir/.local/state/noctalia/"
copy_item "$HOME/.local/state/noctalia/state.toml" "$script_dir/.local/state/noctalia/"
copy_item "$HOME/.local/state/noctalia/recently_used.json" "$script_dir/.local/state/noctalia/"
copy_item "$HOME/.local/state/noctalia/usage_counts.json" "$script_dir/.local/state/noctalia/"
copy_item "$HOME/.local/state/noctalia/community-palettes" "$script_dir/.local/state/noctalia/"
copy_item "$HOME/.local/state/noctalia/plugin-data" "$script_dir/.local/state/noctalia/"
copy_item "$HOME/.local/state/noctalia/plugins/materialized" "$script_dir/.local/state/noctalia/plugins/"
copy_item "$HOME/.local/state/noctalia/plugins/data" "$script_dir/.local/state/noctalia/plugins/"

# Backup Kitty config
echo
echo "Backup Kitty config"
copy_item "$HOME/.config/kitty" "$script_dir/.config/"

# Backup zsh configs
echo
echo "Backup zsh configs"
copy_item "$HOME/.zshrc" "$script_dir/"
copy_item "$HOME/.zprofile" "$script_dir/"
copy_item "$HOME/.zshenv" "$script_dir/"
copy_item "$HOME/.zsh" "$script_dir/"
copy_item "$HOME/.config/zshrc.d" "$script_dir/.config/"

# Backup fonts
echo
echo "Backup fonts"
copy_item "$HOME/.fonts" "$script_dir/"


echo
echo "Backup completed in: $script_dir"

# Backup fastfetch conf
echo
echo "Backup fastfetch conf and artwork"
copy_item "$HOME/.fastfetch_conf.jsonc" "$script_dir/"
copy_item "$HOME/Pictures/pixelparadise.jpg" "$script_dir/assets/fastfetch/"

# Backup the wallpaper currently selected by Noctalia.
echo
echo "Backup current wallpaper"
copy_item "$HOME/Pictures/randoms/DopqTgT.png" "$script_dir/assets/wallpapers/"
