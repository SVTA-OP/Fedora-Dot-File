#!/bin/bash
set -e

echo "=== Fedora 42 Post-install Script ==="

ERROR_LOG="errors.txt"
: > "$ERROR_LOG"

############################
# 1. Configure DNF
############################
if ! grep -q "max_parallel_downloads=10" /etc/dnf/dnf.conf || ! grep -q "fastestmirror=1" /etc/dnf/dnf.conf; then
    echo "Updating /etc/dnf/dnf.conf..."
    sudo sed -i -e '/^max_parallel_downloads/d' -e '/^fastestmirror/d' /etc/dnf/dnf.conf
    echo -e "max_parallel_downloads=10\nfastestmirror=1" | sudo tee -a /etc/dnf/dnf.conf >/dev/null
fi

############################
# 2. Enable RPM Fusion
############################
if ! rpm -q rpmfusion-free-release &>/dev/null || ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
    sudo dnf install -y \
      https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
      https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm
fi

############################
# 3. AppStream & Core Group
############################
sudo dnf group upgrade -y core
sudo dnf4 group install -y core

############################
# 4. Media Codecs
############################
sudo dnf4 group install -y multimedia || echo "Error: multimedia group" >>"$ERROR_LOG"
sudo dnf swap -y 'ffmpeg-free' 'ffmpeg' --allowerasing || echo "Error: ffmpeg swap" >>"$ERROR_LOG"
sudo dnf upgrade -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin || echo "Error: multimedia upgrade" >>"$ERROR_LOG"
sudo dnf group install -y sound-and-video || echo "Error: sound-and-video" >>"$ERROR_LOG"

############################
# 5. Hardware Video Acceleration
############################
sudo dnf install -y ffmpeg-libs libva libva-utils || echo "Error: VAAPI libs" >>"$ERROR_LOG"
cpu_vendor=$(lscpu | grep 'Vendor ID' | awk '{print $3}')
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing || echo "Error: intel driver swap" >>"$ERROR_LOG"
    sudo dnf install -y libva-intel-driver || echo "Error: intel VA driver" >>"$ERROR_LOG"
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
    sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld || true
    sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld || true
    sudo dnf swap -y mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686 || true
    sudo dnf swap -y mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686 || true
fi

############################
# 6. OpenH264 for Firefox
############################
sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264 || echo "Error: openh264" >>"$ERROR_LOG"
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 || true

############################
# 7. Hostname & system tweaks
############################
sudo hostnamectl set-hostname vivobook-s14-m5406w
sudo systemctl disable NetworkManager-wait-online.service || true
sudo rm -f /etc/xdg/autostart/org.gnome.Software.desktop || true

############################
# 8. System Update
############################
sudo dnf -y update

############################
# 9. Enable Flathub
############################
if ! flatpak remote-list | grep -q flathub; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

############################
# 10. Remove RPM Firefox
############################
if rpm -q firefox &>/dev/null; then
    sudo dnf -y remove firefox
fi

############################
# 11. Install official VS Code
############################
if ! command -v code &>/dev/null; then
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
    sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo'
    sudo dnf install -y code || echo "Error: installing VS Code" >>"$ERROR_LOG"
fi

############################
# 12. Brave via official script
############################
curl -fsS https://dl.brave.com/install.sh | sh || echo "Error: Brave install" >>"$ERROR_LOG"

############################
# 13. Flatpak essentials
############################
flatpak_apps=(org.mozilla.firefox io.github.zen_browser.zen com.spotify.Client)
for app in "${flatpak_apps[@]}"; do
    flatpak list --app | grep -q "$app" || flatpak install -y flathub "$app" || echo "Error: Flatpak $app" >>"$ERROR_LOG"
done

############################
# Helper: install_or_fallback
############################
install_or_fallback() {
    local pkg=$1
    local flathub_id=$2
    if rpm -q "$pkg" &>/dev/null; then
        echo "[OK] $pkg already installed."
        return
    fi
    if sudo dnf -y install "$pkg"; then
        echo "[OK] Installed $pkg via DNF."
        return
    fi
    # Only fallback if pkg does NOT exist in DNF repos
    if [[ -n "$flathub_id" ]] && ! sudo dnf info "$pkg" &>/dev/null; then
        echo "[INFO] Trying Flatpak: $flathub_id"
        flatpak install -y flathub "$flathub_id" || echo "Error: $pkg/$flathub_id" >>"$ERROR_LOG"
    else
        echo "[ERR] $pkg exists in DNF but failed to install" >>"$ERROR_LOG"
    fi
}

############################
# 14. Applications (no Cloudflare Warp, scrcpy is DNF only)
############################
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
    "scrcpy;"   # DNF only, no Flatpak fallback
    "android-tools;"
    "gnome-extensions-app;"
    "git;"
    "mission-center;"   # no fallback
    "zsh;"
    "deja-dup;org.gnome.DejaDup"
    "gnome-tweaks;"
    "adw-gtk3;"
)

for entry in "${packages_with_fallback[@]}"; do
    IFS=";" read -r pkg flatpak_id <<< "$entry"
    install_or_fallback "$pkg" "$flatpak_id"
done

############################
# 15. Flatpak GTK theme
############################
flatpak list --app | grep -q org.gtk.Gtk3theme.adw-gtk3 || flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3
sudo flatpak override --env=GTK_THEME=adw-gtk3
sudo flatpak override --filesystem=$HOME/.themes:ro
sudo flatpak override --filesystem=$HOME/.icons:ro
gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3"

############################
# 16. WhiteSur Icons (no --alt)
############################
if [ ! -d "$HOME/.icons/WhiteSur" ] && [ ! -d "/usr/share/icons/WhiteSur" ]; then
    git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icon-theme
    bash /tmp/WhiteSur-icon-theme/install.sh
    rm -rf /tmp/WhiteSur-icon-theme
fi

############################
# 17. Neofetch
############################
if ! command -v neofetch &>/dev/null; then
    curl -L https://github.com/dylanaraps/neofetch/releases/latest/download/neofetch -o /tmp/neofetch
    chmod +x /tmp/neofetch
    sudo mv /tmp/neofetch /usr/bin/neofetch
fi

############################
# 18. GNOME Shortcuts
############################
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
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name "$k"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding "$combo"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" command "$cmd"
done
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$current_keys"

############################
# 19. Spicetify for Spotify Flatpak
############################
if ! command -v spicetify &>/dev/null; then
    sudo npm install -g spicetify-cli || echo "⚠ npm not installed" >>"$ERROR_LOG"
fi
if command -v spicetify &>/dev/null; then
    spicetify config current_user_modify true
    spicetify config spotify_path "$HOME/.var/app/com.spotify.Client"
    spicetify apply
fi

############################
# 20. Zsh + Oh My Zsh
############################
if ! command -v zsh &>/dev/null; then
    sudo dnf -y install zsh
fi
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ] &&
    git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions"
[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ] &&
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting"
sed -i "s|^ZSH_THEME=.*|ZSH_THEME=\"darkblood\"|" ~/.zshrc
sed -i "s|^plugins=.*|plugins=(git zsh-autosuggestions zsh-syntax-highlighting)|" ~/.zshrc

############################
# Done
############################
echo "✅ Post-install setup complete."
echo "Check $ERROR_LOG for any errors."
