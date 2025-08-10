#!/bin/bash
set -e

echo "=== Fedora 42 Post-install Script ==="

# Initialize error logging
ERROR_LOG="errors.txt"
: > "$ERROR_LOG"

## --- 1. Modify /etc/dnf/dnf.conf ---
if ! grep -q "max_parallel_downloads=10" /etc/dnf/dnf.conf || ! grep -q "fastestmirror=1" /etc/dnf/dnf.conf; then
    echo "Updating /etc/dnf/dnf.conf..."
    sudo sed -i -e '/^max_parallel_downloads/d' -e '/^fastestmirror/d' /etc/dnf/dnf.conf
    echo -e "max_parallel_downloads=10\nfastestmirror=1" | sudo tee -a /etc/dnf/dnf.conf > /dev/null
else
    echo "dnf.conf already configured."
fi

## --- 2. Enable RPM Fusion Free & Nonfree ---
if ! rpm -q rpmfusion-free-release &>/dev/null || ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
    sudo dnf install -y \
        https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
        https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
fi

## --- 3. AppStream & Core Group ---
sudo dnf group upgrade -y core
sudo dnf4 group install -y core

## --- 4. Media Codecs ---
sudo dnf4 group install -y multimedia || echo "Error installing multimedia group" >> "$ERROR_LOG"
sudo dnf swap -y 'ffmpeg-free' 'ffmpeg' --allowerasing || echo "Error swapping ffmpeg-free to ffmpeg" >> "$ERROR_LOG"
sudo dnf upgrade -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin || echo "Error upgrading multimedia group" >> "$ERROR_LOG"
sudo dnf group install -y sound-and-video || echo "Error installing sound-and-video group" >> "$ERROR_LOG"

## --- 5. Hardware Video Acceleration ---
sudo dnf install -y ffmpeg-libs libva libva-utils || echo "Error installing video acceleration libs" >> "$ERROR_LOG"
cpu_vendor=$(lscpu | grep 'Vendor ID' | awk '{print $3}')
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing || echo "Error swapping Intel media driver" >> "$ERROR_LOG"
    sudo dnf install -y libva-intel-driver || echo "Error installing libva-intel-driver" >> "$ERROR_LOG"
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
    sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld || echo "Error swapping mesa-va-drivers" >> "$ERROR_LOG"
    sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld || echo "Error swapping mesa-vdpau-drivers" >> "$ERROR_LOG"
    sudo dnf swap -y mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686 || echo "Error swapping mesa-va-drivers.i686" >> "$ERROR_LOG"
    sudo dnf swap -y mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686 || echo "Error swapping mesa-vdpau-drivers.i686" >> "$ERROR_LOG"
fi

## --- 6. OpenH264 for Firefox ---
sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264 || echo "Error installing openh264 codecs" >> "$ERROR_LOG"
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 || echo "Error enabling openh264 repo" >> "$ERROR_LOG"

## --- 7. Hostname & disable services ---
sudo hostnamectl set-hostname vivobook-s14-m5406w || echo "Error setting hostname" >> "$ERROR_LOG"
sudo systemctl disable NetworkManager-wait-online.service || echo "Error disabling NetworkManager-wait-online" >> "$ERROR_LOG"
sudo rm -f /etc/xdg/autostart/org.gnome.Software.desktop || echo "Error removing gnome software autostart" >> "$ERROR_LOG"

## --- 8. System update ---
sudo dnf -y update || echo "Error updating system" >> "$ERROR_LOG"

## --- 9. Flathub ---
if ! flatpak remote-list | grep -q flathub; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || echo "Error adding Flathub" >> "$ERROR_LOG"
fi

## --- 10. Remove RPM Firefox ---
if rpm -q firefox &>/dev/null; then
    sudo dnf -y remove firefox || echo "Error removing rpm firefox" >> "$ERROR_LOG"
fi

## --- 11. Flatpak apps ---
flatpak_apps=(
    org.mozilla.firefox
    io.github.zen_browser.zen
    com.spotify.Client
)
for app in "${flatpak_apps[@]}"; do
    flatpak list --app | grep -q "$app" || flatpak install -y flathub "$app" || echo "Error installing Flatpak $app" >> "$ERROR_LOG"
done

## --- Brave install via official script ---
curl -fsS https://dl.brave.com/install.sh | sh || echo "Error installing Brave browser" >> "$ERROR_LOG"

## --- 12. Install cloudflare-warp and protonvpn with error handling ---
echo 'Installing cloudflare-warp...';
if ! rpm -q cloudflare-warp &>/dev/null; then
  (sudo dnf -y install cloudflare-warp || (echo 'DNF install failed for cloudflare-warp, trying Flatpak...' && flatpak install -y flathub com.cloudflare.Cloudflare)) || echo '❌ Could not install cloudflare-warp, check errors.txt' >> "$ERROR_LOG"
else
  echo 'cloudflare-warp already installed.'
fi

echo 'Installing protonvpn via Flatpak only...';
flatpak list --app | grep -q com.protonvpn.ProtonVPN || (flatpak install -y flathub com.protonvpn.ProtonVPN || echo '❌ Could not install protonvpn, check errors.txt' >> "$ERROR_LOG")

## --- Helper function to install package via dnf, fallback to flatpak ---
install_or_fallback() {
    local pkg=$1
    local flathub_id=$2  # Optional flathub app id
    if rpm -q "$pkg" &>/dev/null; then
        echo "$pkg already installed."
        return
    fi
    if sudo dnf -y install "$pkg"; then
        echo "Installed $pkg via DNF."
    else
        if [[ -n $flathub_id ]]; then
            echo "DNF install failed for $pkg, trying Flatpak ($flathub_id)..."
            if flatpak install -y flathub "$flathub_id"; then
                echo "Installed $flathub_id via Flatpak."
            else
                echo "Failed to install $pkg and $flathub_id" >> "$ERROR_LOG"
            fi
        else
            echo "Failed to install $pkg and no Flatpak fallback defined." >> "$ERROR_LOG"
        fi
    fi
}

## --- 13. Packages list with Flatpak fallback app IDs where known ---
# Format: package_name;flatpak_app_id (empty if no fallback)
packages_with_fallback=(
    "btop;"
    "easy-effects;com.github.wwmm.easyeffects"
    "flatseal;com.github.tchx84.Flatseal"
    "filelight;"
    "virt-manager;"
    "qemu-kvm;"
    "gparted;"
    "steam;com.valvesoftware.Steam"
    "heroic-games-launcher;com.heroicgameslauncher.hgl"
    "libreoffice;org.libreoffice.LibreOffice"
    "pinta;org.pinta.Pinta"
    "scrcpy;dev.boredom.Scrcpy"
    "android-tools;"
    "gnome-extensions-app;"
    "git;"
    "code;com.visualstudio.code"
    "mission-center;"
    "zsh;"
    "deja-dup;org.gnome.DejaDup"
    "gnome-tweaks;"
    "adw-gtk3;"
)

for entry in "${packages_with_fallback[@]}"; do
    IFS=";" read -r dnf_pkg flatpak_id <<< "$entry"
    install_or_fallback "$dnf_pkg" "$flatpak_id"
done

## --- 14. Flatpak GTK theme ---
flatpak list --app | grep -q org.gtk.Gtk3theme.adw-gtk3 || flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3 || echo "Error installing GTK Flatpak theme" >> "$ERROR_LOG"
sudo flatpak override --env=GTK_THEME=adw-gtk3 || echo "Error setting flatpak GTK_THEME override" >> "$ERROR_LOG"
sudo flatpak override --filesystem=$HOME/.themes:ro || echo "Error setting flatpak themes fs override" >> "$ERROR_LOG"
sudo flatpak override --filesystem=$HOME/.icons:ro || echo "Error setting flatpak icons fs override" >> "$ERROR_LOG"
gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3" || echo "Error setting GTK theme in gsettings" >> "$ERROR_LOG"

## --- 15. WhiteSur Icons ---
if [ ! -d "$HOME/.icons/WhiteSur" ] && [ ! -d "/usr/share/icons/WhiteSur" ]; then
    git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icon-theme || echo "Error cloning WhiteSur repo" >> "$ERROR_LOG"
    bash /tmp/WhiteSur-icon-theme/install.sh --alt || echo "Error installing WhiteSur icons" >> "$ERROR_LOG"
    rm -rf /tmp/WhiteSur-icon-theme
fi

## --- 16. Neofetch ---
if ! command -v neofetch &>/dev/null; then
    curl -L https://github.com/dylanaraps/neofetch/releases/latest/download/neofetch -o /tmp/neofetch || echo "Error downloading neofetch" >> "$ERROR_LOG"
    chmod +x /tmp/neofetch || echo "Error setting neofetch executable" >> "$ERROR_LOG"
    sudo mv /tmp/neofetch /usr/bin/neofetch || echo "Error moving neofetch binary" >> "$ERROR_LOG"
fi

## --- 17. GNOME shortcuts ---
base="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
declare -A keys=(
    ["custom-terminal"]="<Control><Alt>t|gnome-terminal"
    ["custom-settings"]="<Super>i|gnome-control-center"
    ["custom-monitor"]="<Control><Shift>Escape|gnome-system-monitor"
    ["custom-hide"]="<Super>m|xdotool key super+d"
    ["custom-screenshot"]="<Super><Shift>s|gnome-screenshot --interactive"
)
current_keys=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)
for k in "${!keys[@]}"; do
    path="$base/$k/"
    [[ "$current_keys" != *"$path"* ]] && current_keys=$(echo "$current_keys" | sed "s/]$/, '$path']/")
    IFS="|" read -r combo cmd <<< "${keys[$k]}"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name "$k" || echo "Error setting shortcut name for $k" >> "$ERROR_LOG"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding "$combo" || echo "Error setting shortcut binding for $k" >> "$ERROR_LOG"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" command "$cmd" || echo "Error setting shortcut command for $k" >> "$ERROR_LOG"
done
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$current_keys" || echo "Error applying custom keybindings list" >> "$ERROR_LOG"

## --- 18. Spicetify for Spotify Flatpak ---
if ! command -v spicetify &>/dev/null; then
    sudo npm install -g spicetify-cli || echo "⚠ npm not installed, skipping spicetify" >> "$ERROR_LOG"
fi
if command -v spicetify &>/dev/null; then
    spicetify config current_user_modify true || echo "Error setting spicetify config" >> "$ERROR_LOG"
    spicetify config spotify_path "$HOME/.var/app/com.spotify.Client" || echo "Error setting spicetify spotify_path" >> "$ERROR_LOG"
    spicetify apply || echo "Error applying spicetify" >> "$ERROR_LOG"
fi

## --- 19. Zsh + Oh My Zsh ---
if ! command -v zsh &>/dev/null; then
    sudo dnf -y install zsh || echo "Error installing zsh" >> "$ERROR_LOG"
fi
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || echo "Error installing Oh My Zsh" >> "$ERROR_LOG"
fi
[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ] &&
    git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" || echo "Error cloning zsh-autosuggestions" >> "$ERROR_LOG"
[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ] &&
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" || echo "Error cloning zsh-syntax-highlighting" >> "$ERROR_LOG"
sed -i 's/^ZSH_THEME=.*/ZSH_THEME="darkblood"/' ~/.zshrc || echo "Error setting ZSH_THEME" >> "$ERROR_LOG"
sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc || echo "Error setting zsh plugins" >> "$ERROR_LOG"

echo "✅ Post-install setup complete."
echo "Check $ERROR_LOG for any installation errors."
