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
echo
echo "Backup Hyprland config"
copy_item "$HOME/.config/hypr" "$script_dir/.config/"

# Backup wlogout config
echo
echo "Backup wlogout config"
copy_item "$HOME/.config/wlogout" "$script_dir/.config/"

# Backup fuzzel config
echo
echo "Backup fuzzel config"
copy_item "$HOME/.config/fuzzel" "$script_dir/.config/"


# Backup qt config
echo
echo "Backup qt5ct & qt6ct config"
copy_item "$HOME/.config/qt5ct" "$script_dir/.config/"
copy_item "$HOME/.config/qt6ct" "$script_dir/.config/"



# Backup AGS config
echo
echo "Backup AGS config"
copy_item "$HOME/.config/ags" "$script_dir/.config/"


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
echo "Backup fastfetch conf"
copy_item "$HOME/.fastfetch_conf.jsonc" "$script_dir/"
