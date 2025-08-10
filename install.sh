#!/bin/bash
set -e

echo "=== Fedora 42 Post-install Script ==="

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
sudo dnf4 group install -y multimedia
sudo dnf swap -y 'ffmpeg-free' 'ffmpeg' --allowerasing
sudo dnf upgrade -y @multimedia --setopt="install_weak_deps=False" \
    --exclude=PackageKit-gstreamer-plugin
sudo dnf group install -y sound-and-video

## --- 5. Hardware Video Acceleration ---
sudo dnf install -y ffmpeg-libs libva libva-utils
cpu_vendor=$(lscpu | grep 'Vendor ID' | awk '{print $3}')
if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
    sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing
    sudo dnf install -y libva-intel-driver
elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
    sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld
    sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld
    sudo dnf swap -y mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686
    sudo dnf swap -y mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686
fi

## --- 6. OpenH264 for Firefox ---
sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264
sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1

## --- 7. Hostname & disable services ---
sudo hostnamectl set-hostname vivobook-s14-m5406w
sudo systemctl disable NetworkManager-wait-online.service
sudo rm -f /etc/xdg/autostart/org.gnome.Software.desktop

## --- 8. System update ---
sudo dnf -y update

## --- 9. Flathub ---
if ! flatpak remote-list | grep -q flathub; then
    flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
fi

## --- 10. Remove RPM Firefox ---
if rpm -q firefox &>/dev/null; then
    sudo dnf -y remove firefox
fi

## --- 11. Flatpak apps ---
flatpak_apps=(
    org.mozilla.firefox
    io.github.zen_browser.zen
    com.spotify.Client
)
for app in "${flatpak_apps[@]}"; do
    flatpak list --app | grep -q "$app" || flatpak install -y flathub "$app"
done

## --- 12. Install Brave browser (correct way) ---
if ! command -v brave-browser &>/dev/null; then
    sudo dnf install -y dnf-plugins-core
    # sudo dnf config-manager --addrepo=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
    sudo rpm --import https://brave-browser-rpm-release.s3.brave.com/brave-core.asc
    sudo dnf install -y brave-browser
else
    echo "Brave browser already installed."
fi

## --- 13. Packages (DNF first, then Flatpak if available) ---
dnf_or_flatpak_pkgs=(
    btop
    # cloudflare-warp
    easy-effects
    flatseal
    filelight
    virt-manager
    qemu-kvm
    gparted
    steam
    heroic-games-launcher
    libreoffice
    pinta
    scrcpy
    android-tools
    # protonvpn
    gnome-extensions-app
    git
    code
    mission-center
    zsh
    deja-dup
    gnome-tweaks
    adw-gtk3
)
for pkg in "${dnf_or_flatpak_pkgs[@]}"; do
    rpm -q "$pkg" &>/dev/null || sudo dnf -y install "$pkg" || flatpak install -y flathub "$pkg" || echo "❌ Could not install $pkg"
done

## --- 14. Flatpak GTK theme ---
flatpak list --app | grep -q org.gtk.Gtk3theme.adw-gtk3 || \
    flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3
sudo flatpak override --env=GTK_THEME=adw-gtk3
sudo flatpak override --filesystem=$HOME/.themes:ro
sudo flatpak override --filesystem=$HOME/.icons:ro
gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3"

## --- 15. WhiteSur Icons ---
if [ ! -d "$HOME/.icons/WhiteSur" ] && [ ! -d "/usr/share/icons/WhiteSur" ]; then
    git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icon-theme
    bash /tmp/WhiteSur-icon-theme/install.sh --alt
    rm -rf /tmp/WhiteSur-icon-theme
fi

## --- 16. Neofetch ---
if ! command -v neofetch &>/dev/null; then
    curl -L https://github.com/dylanaraps/neofetch/releases/latest/download/neofetch -o /tmp/neofetch
    chmod +x /tmp/neofetch
    sudo mv /tmp/neofetch /usr/bin/neofetch
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
    [[ "$current_keys" != *"$path"* ]] && \
        current_keys=$(echo "$current_keys" | sed "s/]$/, '$path']/")
    IFS="|" read -r combo cmd <<< "${keys[$k]}"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name "$k"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding "$combo"
    gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" command "$cmd"
done
gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$current_keys"

## --- 18. Spicetify for Spotify Flatpak ---
if ! command -v spicetify &>/dev/null; then
    sudo npm install -g spicetify-cli || echo "⚠ npm not installed, skipping spicetify"
fi
if command -v spicetify &>/dev/null; then
    spicetify config current_user_modify true
    spicetify config spotify_path "$HOME/.var/app/com.spotify.Client"
    spicetify apply
fi

## --- 19. Zsh + Oh My Zsh ---
if ! command -v zsh &>/dev/null; then
    sudo dnf -y install zsh
fi
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c \
        "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ] &&
    git clone https://github.com/zsh-users/zsh-autosuggestions \
        ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions
[ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ] &&
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \
        ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
sed -i 's/^ZSH_THEME=.*/ZSH_THEME="darkblood"/' ~/.zshrc
sed -i 's/^plugins=.*/plugins=(git zsh-autosuggestions zsh-syntax-highlighting)/' ~/.zshrc

echo "✅ Post-install setup complete."
