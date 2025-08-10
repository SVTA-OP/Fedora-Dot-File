#!/bin/bash
set -e

echo "=== Fedora 42 Post-install Script ==="
echo "NOTE: This script requires sudo privileges. Run with 'sudo ./post-install.sh' or as root."
ERROR_LOG="errors.txt"
: > "$ERROR_LOG"

# Input Validation
check_prerequisites() {
    echo "Checking prerequisites..."
    # Check for sudo/root privileges
    if [ "$(id -u)" -ne 0 ] && ! groups | grep -q sudo; then
        echo "Error: This script requires sudo or root privileges." | tee -a "$ERROR_LOG"
        echo "Please run the script with 'sudo ./post-install.sh' or as root user." | tee -a "$ERROR_LOG"
        exit 1
    fi
    # Check for Fedora 42
    if ! grep -q "Fedora release 42" /etc/fedora-release; then
        echo "Error: This script is designed for Fedora 42 only" >>"$ERROR_LOG"
        exit 1
    fi
    echo "[OK] Prerequisites verified."
}

# Add Copr for scrcpy
enable_copr_scrcpy() {
    echo "Enabling Copr for scrcpy..."
    sudo dnf install -y dnf-plugins-core || echo "Error: Failed to install dnf-plugins-core" >>"$ERROR_LOG"
    sudo dnf copr enable -y zeno/scrcpy || echo "Error: Failed to enable Copr for scrcpy" >>"$ERROR_LOG"
    echo "[OK] Copr for scrcpy enabled."
}

# 1. Configure DNF
configure_dnf() {
    echo "Configuring DNF..."
    if ! grep -q "max_parallel_downloads=10" /etc/dnf/dnf.conf || ! grep -q "fastestmirror=1" /etc/dnf/dnf.conf; then
        if [ -f /etc/dnf/dnf.conf ]; then
            sudo sed -i -e '/^max_parallel_downloads/d' -e '/^fastestmirror/d' /etc/dnf/dnf.conf || echo "Error: Failed to configure DNF settings" >>"$ERROR_LOG"
            echo -e "max_parallel_downloads=10\nfastestmirror=1" | sudo tee -a /etc/dnf/dnf.conf >/dev/null || echo "Error: Failed to append DNF settings" >>"$ERROR_LOG"
        else
            echo "Error: /etc/dnf/dnf.conf not found" >>"$ERROR_LOG"
        fi
    fi
    echo "[OK] DNF configured."
}

# 2. RPM Fusion
install_rpm_fusion() {
    echo "Installing RPM Fusion..."
    if ! rpm -q rpmfusion-free-release &>/dev/null || ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        sudo dnf install -y \
            https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
            https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm || echo "Error: Failed to install RPM Fusion" >>"$ERROR_LOG"
    fi
    echo "[OK] RPM Fusion installed."
}

# 3. AppStream & Core
upgrade_core() {
    echo "Upgrading core packages..."
    sudo dnf group upgrade -y core || echo "Error: Failed to upgrade core group" >>"$ERROR_LOG"
    sudo dnf group install -y core || echo "Error: Failed to install core group" >>"$ERROR_LOG"
    echo "[OK] Core packages upgraded."
}

# 4. Media Codecs & HW Video Accel
install_media_codecs() {
    echo "Installing media codecs and hardware acceleration..."
    sudo dnf group install -y multimedia || echo "Error: Failed to install multimedia group" >>"$ERROR_LOG"
    sudo dnf swap -y 'ffmpeg-free' 'ffmpeg' --allowerasing || echo "Error: Failed to swap ffmpeg" >>"$ERROR_LOG"
    sudo dnf upgrade -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin || echo "Error: Failed to upgrade multimedia" >>"$ERROR_LOG"
    sudo dnf group install -y sound-and-video || echo "Error: Failed to install sound-and-video group" >>"$ERROR_LOG"
    sudo dnf install -y ffmpeg-libs libva libva-utils || echo "Error: Failed to install media libraries" >>"$ERROR_LOG"
    cpu_vendor=$(lscpu | grep 'Vendor ID' | awk '{print $3}')
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then
        sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing || echo "Error: Failed to install Intel drivers" >>"$ERROR_LOG"
        sudo dnf install -y libva-intel-driver || echo "Error: Failed to install Intel legacy driver" >>"$ERROR_LOG"
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then
        sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld || echo "Error: Failed to swap AMD VA drivers" >>"$ERROR_LOG"
        sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld || echo "Error: Failed to swap AMD VDPAU drivers" >>"$ERROR_LOG"
        sudo dnf swap -y mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686 || echo "Error: Failed to swap AMD VA drivers (i686)" >>"$ERROR_LOG"
        sudo dnf swap -y mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686 || echo "Error: Failed to swap AMD VDPAU drivers (i686)" >>"$ERROR_LOG"
    fi
    echo "[OK] Media codecs and hardware acceleration installed."
}

# 5. OpenH264
install_openh264() {
    echo "Installing OpenH264..."
    repo_file="/etc/yum.repos.d/fedora-cisco-openh264.repo"
    if [ ! -f "$repo_file" ]; then
        echo "Adding fedora-cisco-openh264 repo..."
        sudo sh -c "echo '[fedora-cisco-openh264]' > $repo_file" || echo "Error: Failed to create OpenH264 repo file" >>"$ERROR_LOG"
        sudo sh -c "echo 'name=Fedora \$releasever openh264 (From Cisco)' >> $repo_file" || echo "Error: Failed to add name to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'baseurl=https://codecs.fedoraproject.org/openh264/\$releasever/\$basearch/' >> $repo_file" || echo "Error: Failed to add baseurl to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'enabled=1' >> $repo_file" || echo "Error: Failed to enable OpenH264 repo in file" >>"$ERROR_LOG"
        sudo sh -c "echo 'metadata_expire=14' >> $repo_file" || echo "Error: Failed to add metadata_expire to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'type=rpm' >> $repo_file" || echo "Error: Failed to add type to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'skip_if_unavailable=False' >> $repo_file" || echo "Error: Failed to add skip_if_unavailable to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'gpgcheck=1' >> $repo_file" || echo "Error: Failed to add gpgcheck to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'repo_gpgcheck=0' >> $repo_file" || echo "Error: Failed to add repo_gpgcheck to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch' >> $repo_file" || echo "Error: Failed to add gpgkey to OpenH264 repo" >>"$ERROR_LOG"
        sudo sh -c "echo 'enabled_metadata=1' >> $repo_file" || echo "Error: Failed to add enabled_metadata to OpenH264 repo" >>"$ERROR_LOG"
    else
        sudo dnf config-manager --set-enabled fedora-cisco-openh264 || echo "Error: Failed to enable OpenH264 repo" >>"$ERROR_LOG"
    fi
    sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264 || echo "Error: Failed to install OpenH264 packages" >>"$ERROR_LOG"
    echo "[OK] OpenH264 installed."
}

# 6. Hostname, services, update
configure_system() {
    echo "Configuring system settings..."
    sudo hostnamectl set-hostname vivobook-s14-m5406w || echo "Error: Failed to set hostname" >>"$ERROR_LOG"
    sudo systemctl disable NetworkManager-wait-online.service || echo "Error: Failed to disable NetworkManager-wait-online" >>"$ERROR_LOG"
    sudo rm -f /etc/xdg/autostart/org.gnome.Software.desktop || echo "Error: Failed to remove GNOME Software autostart" >>"$ERROR_LOG"
    sudo dnf -y update || echo "Error: Failed to update system" >>"$ERROR_LOG"
    echo "[OK] System settings configured."
}

# 7. Flathub
setup_flathub() {
    echo "Setting up Flathub..."
    if ! flatpak remote-list | grep -q flathub; then
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || echo "Error: Failed to add Flathub" >>"$ERROR_LOG"
    fi
    echo "[OK] Flathub set up."
}

# 8. Firefox removal
remove_firefox() {
    echo "Removing default Firefox..."
    if rpm -q firefox &>/dev/null; then
        sudo dnf -y remove firefox || echo "Error: Failed to remove Firefox" >>"$ERROR_LOG"
    fi
    echo "[OK] Firefox removed or not present."
}

# 9. VS Code (Microsoft repo)
install_vscode() {
    echo "Installing Visual Studio Code..."
    if ! command -v code &>/dev/null; then
        sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || echo "Error: Failed to import Microsoft key" >>"$ERROR_LOG"
        sudo sh -c 'echo -e "[code]\nname=Visual Studio Code\nbaseurl=https://packages.microsoft.com/yumrepos/vscode\nenabled=1\ngpgcheck=1\ngpgkey=https://packages.microsoft.com/keys/microsoft.asc" > /etc/yum.repos.d/vscode.repo' || echo "Error: Failed to add VS Code repo" >>"$ERROR_LOG"
        sudo dnf install -y code || echo "Error: Failed to install VS Code" >>"$ERROR_LOG"
    fi
    echo "[OK] VS Code installed."
}

# 10. Brave browser
install_brave() {
    echo "Installing Brave browser..."
    curl -fsS https://dl.brave.com/install.sh | sh || echo "Error: Failed to install Brave" >>"$ERROR_LOG"
    echo "[OK] Brave installed."
}

# 11. Essential Flatpak apps
install_flatpak_apps() {
    echo "Installing Flatpak apps..."
    flatpak_apps=(org.mozilla.firefox io.github.zen_browser.zen com.spotify.Client)
    flatpak install -y flathub "${flatpak_apps[@]}" || echo "Error: Failed to install Flatpak apps" >>"$ERROR_LOG"
    echo "[OK] Flatpak apps installed."
}

# 12. Install helper
install_or_fallback() {
    local pkg="$1"
    local flathub_id="$2"
    echo "Installing $pkg..."
    if rpm -q "$pkg" &>/dev/null; then
        echo "[OK] $pkg already installed."
        return
    fi
    if sudo dnf -y install "$pkg"; then
        echo "[OK] $pkg installed via DNF."
    elif [[ -n "$flathub_id" ]] && ! sudo dnf info "$pkg" &>/dev/null; then
        flatpak install -y flathub "$flathub_id" || echo "Error: Failed to install $pkg/$flathub_id" >>"$ERROR_LOG"
    else
        echo "Error: Failed to install $pkg" >>"$ERROR_LOG"
    fi
}

# 13. Applications list
install_applications() {
    echo "Installing applications..."
    apps=(
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
        "scrcpy;"
        "android-tools;"
        "gnome-extensions-app;"
        "git;"
        "mission-center;io.missioncenter.MissionCenter"
        "zsh;"
        "deja-dup;org.gnome.DejaDup"
        "gnome-tweaks;"
        "adw-gtk3-theme;"
    )
    for entry in "${apps[@]}"; do
        IFS=";" read -r pkg flathub_id <<<"$entry"
        install_or_fallback "$pkg" "$flathub_id"
    done
    echo "[OK] Applications installed."
}

# 14. GTK Theme & WhiteSur
configure_theme() {
    echo "Configuring GTK theme and WhiteSur..."
    flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3 || echo "Error: Failed to install adw-gtk3 theme" >>"$ERROR_LOG"
    sudo flatpak override --env=GTK_THEME=adw-gtk3 || echo "Error: Failed to set GTK theme for Flatpak" >>"$ERROR_LOG"
    sudo flatpak override --filesystem=$HOME/.themes:ro || echo "Error: Failed to set themes filesystem for Flatpak" >>"$ERROR_LOG"
    sudo flatpak override --filesystem=$HOME/.icons:ro || echo "Error: Failed to set icons filesystem for Flatpak" >>"$ERROR_LOG"
    gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3" || echo "Error: Failed to set GNOME GTK theme" >>"$ERROR_LOG"
    if [ ! -d "$HOME/.icons/WhiteSur" ] && [ ! -d "/usr/share/icons/WhiteSur" ]; then
        git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git /tmp/WhiteSur-icon-theme || echo "Error: Failed to clone WhiteSur icon theme" >>"$ERROR_LOG"
        bash /tmp/WhiteSur-icon-theme/install.sh || echo "Error: Failed to install WhiteSur icon theme" >>"$ERROR_LOG"
        rm -rf /tmp/WhiteSur-icon-theme || echo "Error: Failed to clean up WhiteSur temp files" >>"$ERROR_LOG"
    fi
    echo "[OK] Theme configured."
}

# 15. GNOME Extensions install
install_gnome_extensions() {
    echo "Installing GNOME extensions..."
    GNOME_EXTENSIONS=(
        "advanced-alt-tabi@G-dH.github.com"
        "AlphabeticalAppGrid@SofianGoudes.github.com"
        "alt-tab-current-monitor@esauvisky.github.io"
        "arch-update@RaphaelRochet"
        "aromenu@arcmenu.com"
        "Battery-Health-Charging@imaniacx.github.com"
        "Bluetooth-Battery-Meter@maniacs.github.com"
        "blur-my-shell@aunetx"
        "caffeine@patapon.info"
        "cloudflare-warp-toggle@khaled.is-a.dev"
        "monitor-brightness-volume@allin.nemul"
        "dash-to-dock@micxgx.gmail.com"
        "fullscreen-avoider@noobsai.github.com"
        "gsconnect@andyholmes.github.io"
        "gtk4-ding@smedius.gitlab.com"
        "just-perfection-desktop@just-perfection"
        "legacyschemeautoswitcher@joshimukul29.gmail.com"
        "mediacontrols@cliffniff.github.com"
        "notification-banner-reloaded@marcinjakubowski.github.com"
        "quick-settings-tweaks@qwreey"
        "rounded-window-corners@fxgn"
        "tiling-assistant@leleat-on-github"
        "window-title-is-back@fthx"
        "xwayland-indicator@swsnr.de"
    )
    install_gnome_extension() {
        local uuid="$1"
        if [ "$uuid" == "appindicatorsupport@rgcjonas.gmail.com" ]; then
            # Special case for appindicator - install from GitHub
            if ! gnome-extensions info "$uuid" &>/dev/null; then
                git clone https://github.com/ubuntu/gnome-shell-extension-appindicator.git /tmp/appindicator || echo "Error: Failed to clone appindicator extension" >>"$ERROR_LOG"
                cd /tmp/appindicator
                make install || echo "Error: Failed to make install appindicator extension" >>"$ERROR_LOG"
                cd -
                rm -rf /tmp/appindicator || echo "Error: Failed to clean up appindicator temp files" >>"$ERROR_LOG"
                gnome-extensions enable "$uuid" || echo "Error: Failed to enable $uuid" >>"$ERROR_LOG"
            fi
            return
        fi
        ext_id=$(curl -s "https://extensions.gnome.org/extension-query/?search=${uuid%%@*}" | grep -o "\"pk\": *[0-9]*" | head -n1 | tr -dc '0-9')
        if [ -z "$ext_id" ]; then
            echo "Error: No ID found for $uuid" >>"$ERROR_LOG"
            return
        fi
        shell_ver=$(gnome-shell --version | awk '{print $3}')
        dl_url=$(curl -s "https://extensions.gnome.org/extension-info/?pk=$ext_id&shell_version=$shell_ver" | grep -o '"download_url": *"[^"]*"' | cut -d'"' -f4)
        if [ -z "$dl_url" ]; then
            echo "Error: No download URL for $uuid" >>"$ERROR_LOG"
            return
        fi
        tmpzip="/tmp/${uuid}.zip"
        curl -sL "https://extensions.gnome.org${dl_url}" -o "$tmpzip" || echo "Error: Failed to download $uuid" >>"$ERROR_LOG"
        gnome-extensions install "$tmpzip" --force || echo "Error: Failed to install $uuid" >>"$ERROR_LOG"
        rm -f "$tmpzip" || echo "Error: Failed to clean up $uuid zip" >>"$ERROR_LOG"
        gnome-extensions enable "$uuid" || echo "Error: Failed to enable $uuid" >>"$ERROR_LOG"
    }
    for ext in "${GNOME_EXTENSIONS[@]}"; do
        gnome-extensions info "$ext" &>/dev/null || install_gnome_extension "$ext"
    done
    echo "[OK] GNOME extensions installed."
}

# 16. GNOME Shortcuts
configure_shortcuts() {
    echo "Configuring GNOME shortcuts..."
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
        if [[ "$current_keys" != *"$path"* ]]; then
            if [ "$current_keys" == "[]" ]; then
                current_keys="['$path']"
            else
                current_keys="${current_keys%]} , '$path']"
            fi
        fi
        IFS="|" read -r combo cmd <<< "${keys[$k]}"
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name "$k" || echo "Error: Failed to set name for $k shortcut" >>"$ERROR_LOG"
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding "$combo" || echo "Error: Failed to set binding for $k shortcut" >>"$ERROR_LOG"
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" command "$cmd" || echo "Error: Failed to set command for $k shortcut" >>"$ERROR_LOG"
    done
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$current_keys" || echo "Error: Failed to set custom keybindings" >>"$ERROR_LOG"
    echo "[OK] GNOME shortcuts configured."
}

# 17. Spicetify for Spotify Flatpak
configure_spicetify() {
    echo "Configuring Spicetify for Spotify..."
    sudo dnf install -y nodejs || echo "Error: Failed to install nodejs" >>"$ERROR_LOG"
    if ! command -v spicetify &>/dev/null; then
        sudo npm install -g spicetify-cli || echo "Error: Failed to install Spicetify" >>"$ERROR_LOG"
    fi
    if command -v spicetify &>/dev/null; then
        spicetify config current_user_modify true || echo "Error: Failed to set Spicetify user modify" >>"$ERROR_LOG"
        spicetify config spotify_path "$HOME/.var/app/com.spotify.Client" || echo "Error: Failed to set Spicetify Spotify path" >>"$ERROR_LOG"
        spicetify apply || echo "Error: Failed to apply Spicetify" >>"$ERROR_LOG"
    fi
    echo "[OK] Spicetify configured."
}

# 18. Zsh + Oh My Zsh
configure_zsh() {
    echo "Configuring Zsh and Oh My Zsh..."
    if ! command -v zsh &>/dev/null; then
        sudo dnf -y install zsh || echo "Error: Failed to install Zsh" >>"$ERROR_LOG"
    fi
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || echo "Error: Failed to install Oh My Zsh" >>"$ERROR_LOG"
    fi
    if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" ]; then
        git clone https://github.com/zsh-users/zsh-autosuggestions "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions" || echo "Error: Failed to install zsh-autosuggestions" >>"$ERROR_LOG"
    fi
    if [ ! -d "${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" ]; then
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting" || echo "Error: Failed to install zsh-syntax-highlighting" >>"$ERROR_LOG"
    fi
    if [ -f "$HOME/.zshrc" ]; then
        sed -i "s#^ZSH_THEME=.*#ZSH_THEME=\"darkblood\"#" "$HOME/.zshrc" || echo "Error: Failed to set Zsh theme" >>"$ERROR_LOG"
        sed -i "s#^plugins=.*#plugins=(git zsh-autosuggestions zsh-syntax-highlighting)#" "$HOME/.zshrc" || echo "Error: Failed to set Zsh plugins" >>"$ERROR_LOG"
    else
        echo "ZSH_THEME=\"darkblood\"" >> "$HOME/.zshrc" || echo "Error: Failed to create .zshrc with theme" >>"$ERROR_LOG"
        echo "plugins=(git zsh-autosuggestions zsh-syntax-highlighting)" >> "$HOME/.zshrc" || echo "Error: Failed to add plugins to .zshrc" >>"$ERROR_LOG"
    fi
    echo "[OK] Zsh and Oh My Zsh configured."
}

# 19. Display Error Summary
display_error_summary() {
    echo "Checking for errors..."
    if [ -s "$ERROR_LOG" ]; then
        echo "⚠ Errors occurred during setup. See details below:"
        cat "$ERROR_LOG"
    else
        echo "✅ No errors detected."
    fi
}

# Execute all steps
check_prerequisites
configure_dnf
install_rpm_fusion
upgrade_core
enable_copr_scrcpy
install_media_codecs
install_openh264
configure_system
setup_flathub
remove_firefox
install_vscode
install_brave
install_flatpak_apps
install_applications
configure_theme
install_gnome_extensions
configure_shortcuts
configure_spicetify
configure_zsh

# Display completion and error summary
echo "✅ Post-install setup complete."
display_error_summary