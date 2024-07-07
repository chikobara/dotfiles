#!/bin/bash

script_dir="$(pwd)"
# Function to copy files/directories, replacing if they exist


copy_item() {
    if [ -e "$1" ]; then
        rsync -a --delete "$1" "$2"
        echo "Updated: $1"
    else
        echo "Not found: $1"
    fi
}


# Backup Hyprland config
echo "Backup Hyprland config"
copy_item "$HOME/.config/hypr" "$script_dir/"

# Backup AGS config
echo "Backup AGS config"
copy_item "$HOME/.config/ags" "$script_dir/"

# Backup themes and icons
echo "Backup themes and icons"
copy_item "$HOME/.themes" "$script_dir/"
copy_item "$HOME/.icons" "$script_dir/"

# Backup Kitty config
echo "Backup Kitty config"
copy_item "$HOME/.config/kitty" "$script_dir/"

# Backup zsh configs
echo "Backup zsh configs"
copy_item "$HOME/.zshrc" "$script_dir/"
copy_item "$HOME/.zshenv" "$script_dir/"
copy_item "$HOME/.zprofile" "$script_dir/"
copy_item "$HOME/.zsh" "$script_dir/"

# Backup fonts
echo "Backup fonts"
copy_item "$HOME/.local/share/fonts" "$script_dir/"
copy_item "$HOME/.fonts" "$script_dir/"

echo "Backup completed in: $script_dir"