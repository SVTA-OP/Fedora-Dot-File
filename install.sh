#!/bin/bash
set -e

echo "=== Fedora 42 Post-install Script ==="
echo "NOTE: This script requires sudo privileges. Run with 'sudo ./post-install.sh' or as root."
ERROR_LOG="errors.txt"
: > "$ERROR_LOG"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$ERROR_LOG"
}

# Input Validation
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check for sudo/root privileges
    if [ "$(id -u)" -ne 0 ] && ! groups | grep -q sudo; then
        log_error "This script requires sudo or root privileges."
        log_error "Please run the script with 'sudo ./post-install.sh' or as root user."
        exit 1
    fi
    
    # Check for Fedora (more flexible version checking)
    if [ ! -f /etc/fedora-release ] || ! grep -q "Fedora" /etc/fedora-release; then
        log_error "This script is designed for Fedora systems only"
        exit 1
    fi
    
    # Check internet connectivity
    if ! ping -c 1 google.com &>/dev/null; then
        log_warn "Internet connectivity check failed. Some operations may fail."
    fi
    
    log_info "Prerequisites verified."
}

# Add Copr for scrcpy
enable_copr_scrcpy() {
    log_info "Enabling Copr for scrcpy..."
    
    if ! sudo dnf install -y dnf-plugins-core; then
        log_error "Failed to install dnf-plugins-core"
        return 1
    fi
    
    if ! sudo dnf copr enable -y zeno/scrcpy; then
        log_error "Failed to enable Copr for scrcpy"
        return 1
    fi
    
    log_info "Copr for scrcpy enabled."
}

# 1. Configure DNF
configure_dnf() {
    log_info "Configuring DNF..."
    
    local dnf_conf="/etc/dnf/dnf.conf"
    if [ ! -f "$dnf_conf" ]; then
        log_error "/etc/dnf/dnf.conf not found"
        return 1
    fi
    
    # Create backup
    sudo cp "$dnf_conf" "${dnf_conf}.backup.$(date +%Y%m%d_%H%M%S)" || {
        log_error "Failed to create backup of dnf.conf"
        return 1
    }
    
    # Remove existing entries and add new ones
    if ! grep -q "max_parallel_downloads=10" "$dnf_conf" || ! grep -q "fastestmirror=1" "$dnf_conf"; then
        sudo sed -i -e '/^max_parallel_downloads/d' -e '/^fastestmirror/d' "$dnf_conf" || {
            log_error "Failed to configure DNF settings"
            return 1
        }
        echo -e "max_parallel_downloads=10\nfastestmirror=1" | sudo tee -a "$dnf_conf" >/dev/null || {
            log_error "Failed to append DNF settings"
            return 1
        }
    fi
    
    log_info "DNF configured."
}

# 2. RPM Fusion
install_rpm_fusion() {
    log_info "Installing RPM Fusion..."
    
    if ! rpm -q rpmfusion-free-release &>/dev/null || ! rpm -q rpmfusion-nonfree-release &>/dev/null; then
        local fedora_version=$(rpm -E %fedora)
        if ! sudo dnf install -y \
            "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm" \
            "https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"; then
            log_error "Failed to install RPM Fusion"
            return 1
        fi
    fi
    
    log_info "RPM Fusion installed."
}

# 3. AppStream & Core
upgrade_core() {
    log_info "Upgrading core packages..."
    
    if ! sudo dnf group upgrade -y core; then
        log_error "Failed to upgrade core group"
    fi
    
    if ! sudo dnf group install -y core; then
        log_error "Failed to install core group"
    fi
    
    log_info "Core packages upgraded."
}

# 4. Media Codecs & HW Video Accel
install_media_codecs() {
    log_info "Installing media codecs and hardware acceleration..."
    
    sudo dnf group install -y multimedia || log_error "Failed to install multimedia group"
    sudo dnf swap -y 'ffmpeg-free' 'ffmpeg' --allowerasing || log_error "Failed to swap ffmpeg"
    sudo dnf upgrade -y @multimedia --setopt="install_weak_deps=False" --exclude=PackageKit-gstreamer-plugin || log_error "Failed to upgrade multimedia"
    sudo dnf group install -y sound-and-video || log_error "Failed to install sound-and-video group"
    sudo dnf install -y ffmpeg-libs libva libva-utils || log_error "Failed to install media libraries"
    
    # Detect CPU vendor for hardware acceleration
    local cpu_vendor
    cpu_vendor=$(lscpu | grep 'Vendor ID' | awk '{print $3}')
    
    case "$cpu_vendor" in
        "GenuineIntel")
            log_info "Detected Intel CPU, installing Intel drivers..."
            sudo dnf swap -y libva-intel-media-driver intel-media-driver --allowerasing || log_error "Failed to install Intel drivers"
            sudo dnf install -y libva-intel-driver || log_error "Failed to install Intel legacy driver"
            ;;
        "AuthenticAMD")
            log_info "Detected AMD CPU, installing AMD drivers..."
            sudo dnf swap -y mesa-va-drivers mesa-va-drivers-freeworld || log_error "Failed to swap AMD VA drivers"
            sudo dnf swap -y mesa-vdpau-drivers mesa-vdpau-drivers-freeworld || log_error "Failed to swap AMD VDPAU drivers"
            # Only install i686 versions if they exist
            sudo dnf swap -y mesa-va-drivers.i686 mesa-va-drivers-freeworld.i686 2>/dev/null || true
            sudo dnf swap -y mesa-vdpau-drivers.i686 mesa-vdpau-drivers-freeworld.i686 2>/dev/null || true
            ;;
        *)
            log_warn "Unknown CPU vendor: $cpu_vendor. Skipping hardware-specific drivers."
            ;;
    esac
    
    log_info "Media codecs and hardware acceleration installed."
}

# 5. OpenH264
install_openh264() {
    log_info "Installing OpenH264..."
    
    local repo_file="/etc/yum.repos.d/fedora-cisco-openh264.repo"
    if [ ! -f "$repo_file" ]; then
        log_info "Adding fedora-cisco-openh264 repo..."
        sudo tee "$repo_file" > /dev/null <<EOF
[fedora-cisco-openh264]
name=Fedora \$releasever openh264 (From Cisco)
baseurl=https://codecs.fedoraproject.org/openh264/\$releasever/\$basearch/
enabled=1
metadata_expire=14
type=rpm
skip_if_unavailable=False
gpgcheck=1
repo_gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-fedora-\$releasever-\$basearch
enabled_metadata=1
EOF
    else
        sudo dnf config-manager --set-enabled fedora-cisco-openh264 || log_error "Failed to enable OpenH264 repo"
    fi
    
    sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264 || log_error "Failed to install OpenH264 packages"
    
    log_info "OpenH264 installed."
}

# 6. Hostname, services, update
configure_system() {
    log_info "Configuring system settings..."
    
    sudo hostnamectl set-hostname vivobook-s14-m5406w || log_error "Failed to set hostname"
    sudo systemctl disable NetworkManager-wait-online.service || log_error "Failed to disable NetworkManager-wait-online"
    sudo rm -f /etc/xdg/autostart/org.gnome.Software.desktop || log_error "Failed to remove GNOME Software autostart"
    
    log_info "Performing system update..."
    sudo dnf -y update || log_error "Failed to update system"
    
    log_info "System settings configured."
}

# 7. Flathub
setup_flathub() {
    log_info "Setting up Flathub..."
    
    if ! flatpak remote-list | grep -q flathub; then
        flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || log_error "Failed to add Flathub"
    fi
    
    log_info "Flathub set up."
}

# 8. Firefox removal
remove_firefox() {
    log_info "Checking for default Firefox..."
    
    if rpm -q firefox &>/dev/null; then
        log_info "Removing default Firefox..."
        sudo dnf -y remove firefox || log_error "Failed to remove Firefox"
    else
        log_info "Firefox not present or already removed."
    fi
}

# 9. VS Code (Microsoft repo)
install_vscode() {
    log_info "Installing Visual Studio Code..."
    
    if command -v code &>/dev/null; then
        log_info "VS Code already installed."
        return 0
    fi
    
    sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc || {
        log_error "Failed to import Microsoft key"
        return 1
    }
    
    sudo tee /etc/yum.repos.d/vscode.repo > /dev/null <<EOF
[code]
name=Visual Studio Code
baseurl=https://packages.microsoft.com/yumrepos/vscode
enabled=1
gpgcheck=1
gpgkey=https://packages.microsoft.com/keys/microsoft.asc
EOF

    sudo dnf install -y code || log_error "Failed to install VS Code"
    
    log_info "VS Code installed."
}

# 10. Brave browser
install_brave() {
    log_info "Installing Brave browser..."
    
    if command -v brave-browser &>/dev/null; then
        log_info "Brave already installed."
        return 0
    fi
    
    curl -fsS https://dl.brave.com/install.sh | sh || log_error "Failed to install Brave"
    
    log_info "Brave installed."
}

# 11. Essential Flatpak apps
install_flatpak_apps() {
    log_info "Installing Flatpak apps..."
    
    local flatpak_apps=(
        "org.mozilla.firefox"
        "io.github.zen_browser.zen"
        "com.spotify.Client"
    )
    
    for app in "${flatpak_apps[@]}"; do
        if ! flatpak list | grep -q "$app"; then
            flatpak install -y flathub "$app" || log_error "Failed to install $app"
        else
            log_info "$app already installed."
        fi
    done
    
    log_info "Flatpak apps installed."
}

# 12. Install helper with better error handling
install_or_fallback() {
    local pkg="$1"
    local flathub_id="$2"
    
    log_info "Installing $pkg..."
    
    # Check if already installed
    if rpm -q "$pkg" &>/dev/null; then
        log_info "$pkg already installed."
        return 0
    fi
    
    # Try DNF first
    if sudo dnf -y install "$pkg" &>/dev/null; then
        log_info "$pkg installed via DNF."
        return 0
    fi
    
    # Fallback to Flatpak if provided
    if [[ -n "$flathub_id" ]]; then
        if flatpak install -y flathub "$flathub_id" &>/dev/null; then
            log_info "$pkg installed via Flatpak ($flathub_id)."
            return 0
        fi
    fi
    
    log_error "Failed to install $pkg"
    return 1
}

# 13. Applications list
install_applications() {
    log_info "Installing applications..."
    
    local apps=(
        "btop;"
        "easy-effects;com.github.wwmm.easyeffects"
        "flatseal;com.github.tchx84.Flatseal"
        "filelight;org.kde.filelight"
        "virt-manager;"
        "qemu-kvm;"
        "gparted;"
        "steam;com.valvesoftware.Steam"
        "heroic-games-launcher;com.heroicgameslauncher.hgl"
        "libreoffice;org.libreoffice.LibreOffice"
        "pinta;com.github.PintaProject.Pinta"
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
        IFS=";" read -r pkg flathub_id <<< "$entry"
        install_or_fallback "$pkg" "$flathub_id"
    done
    
    log_info "Applications installation completed."
}

# 14. GTK Theme & WhiteSur
configure_theme() {
    log_info "Configuring GTK theme and WhiteSur..."
    
    # Install adw-gtk3 theme for Flatpak
    flatpak install -y flathub org.gtk.Gtk3theme.adw-gtk3 || log_error "Failed to install adw-gtk3 theme"
    
    # Configure Flatpak overrides
    sudo flatpak override --env=GTK_THEME=adw-gtk3 || log_error "Failed to set GTK theme for Flatpak"
    sudo flatpak override --filesystem="$HOME/.themes:ro" || log_error "Failed to set themes filesystem for Flatpak"
    sudo flatpak override --filesystem="$HOME/.icons:ro" || log_error "Failed to set icons filesystem for Flatpak"
    
    # Set GNOME theme
    gsettings set org.gnome.desktop.interface gtk-theme "adw-gtk3" || log_error "Failed to set GNOME GTK theme"
    
    # Install WhiteSur icon theme
    if [ ! -d "$HOME/.icons/WhiteSur" ] && [ ! -d "/usr/share/icons/WhiteSur" ]; then
        log_info "Installing WhiteSur icon theme..."
        local temp_dir="/tmp/WhiteSur-icon-theme"
        
        if git clone https://github.com/vinceliuice/WhiteSur-icon-theme.git "$temp_dir"; then
            bash "$temp_dir/install.sh" || log_error "Failed to install WhiteSur icon theme"
            rm -rf "$temp_dir" || log_error "Failed to clean up WhiteSur temp files"
        else
            log_error "Failed to clone WhiteSur icon theme"
        fi
    fi
    
    log_info "Theme configuration completed."
}

# 15. GNOME Extensions install (simplified and more robust)
install_gnome_extensions() {
    log_info "Installing GNOME extensions..."
    
    # Check if GNOME Shell is running
    if ! pgrep -x gnome-shell &>/dev/null; then
        log_warn "GNOME Shell is not running. Skipping extension installation."
        return 0
    fi
    
    local extensions=(
        "advanced-alt-tabi@G-dH.github.com"
        "AlphabeticalAppGrid@SofianGoudes.github.com"
        "alt-tab-current-monitor@esauvisky.github.io"
        "aromenu@arcmenu.com"
        "Battery-Health-Charging@imaniacx.github.com"
        "Bluetooth-Battery-Meter@maniacs.github.com"
        "blur-my-shell@aunetx"
        "caffeine@patapon.info"
        "dash-to-dock@micxgx.gmail.com"
        "gsconnect@andyholmes.github.io"
        "just-perfection-desktop@just-perfection"
        "tiling-assistant@leleat-on-github"
    )
    
    install_gnome_extension() {
        local uuid="$1"
        
        # Skip if already installed
        if gnome-extensions info "$uuid" &>/dev/null; then
            log_info "Extension $uuid already installed."
            return 0
        fi
        
        log_info "Installing extension: $uuid"
        
        # Extract extension name for search
        local ext_name="${uuid%%@*}"
        
        # Get extension ID
        local ext_id
        ext_id=$(curl -s "https://extensions.gnome.org/extension-query/?search=${ext_name}" | \
                 grep -o '"pk": *[0-9]*' | head -n1 | tr -dc '0-9')
        
        if [ -z "$ext_id" ]; then
            log_error "No ID found for $uuid"
            return 1
        fi
        
        # Get GNOME Shell version
        local shell_ver
        shell_ver=$(gnome-shell --version | awk '{print $3}' | cut -d. -f1,2)
        
        # Get download URL
        local dl_url
        dl_url=$(curl -s "https://extensions.gnome.org/extension-info/?pk=$ext_id&shell_version=$shell_ver" | \
                 grep -o '"download_url": *"[^"]*"' | cut -d'"' -f4)
        
        if [ -z "$dl_url" ]; then
            log_error "No download URL for $uuid (shell version: $shell_ver)"
            return 1
        fi
        
        # Download and install
        local tmpzip="/tmp/${uuid}.zip"
        if curl -sL "https://extensions.gnome.org${dl_url}" -o "$tmpzip"; then
            if gnome-extensions install "$tmpzip" --force; then
                gnome-extensions enable "$uuid" || log_error "Failed to enable $uuid"
                log_info "Successfully installed and enabled $uuid"
            else
                log_error "Failed to install $uuid"
            fi
            rm -f "$tmpzip"
        else
            log_error "Failed to download $uuid"
        fi
    }
    
    for ext in "${extensions[@]}"; do
        install_gnome_extension "$ext"
    done
    
    log_info "GNOME extensions installation completed."
}

# 16. GNOME Shortcuts
configure_shortcuts() {
    log_info "Configuring GNOME shortcuts..."
    
    # Check if GNOME is running
    if ! pgrep -x gnome-shell &>/dev/null; then
        log_warn "GNOME Shell is not running. Skipping shortcuts configuration."
        return 0
    fi
    
    local base="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
    
    declare -A keys=(
        ["custom-terminal"]="<Control><Alt>t|gnome-terminal"
        ["custom-settings"]="<Super>i|gnome-control-center"
        ["custom-monitor"]="<Control><Shift>Escape|gnome-system-monitor"
        ["custom-screenshot"]="<Super><Shift>s|gnome-screenshot --interactive"
    )
    
    local current_keys
    current_keys=$(gsettings get org.gnome.settings-daemon.plugins.media-keys custom-keybindings)
    
    for k in "${!keys[@]}"; do
        local path="$base/$k/"
        
        # Add to current keys if not present
        if [[ "$current_keys" != *"$path"* ]]; then
            if [ "$current_keys" == "[]" ]; then
                current_keys="['$path']"
            else
                current_keys="${current_keys%]} , '$path']"
            fi
        fi
        
        # Parse key combination and command
        IFS="|" read -r combo cmd <<< "${keys[$k]}"
        
        # Set the keybinding
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" name "$k" || log_error "Failed to set name for $k shortcut"
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" binding "$combo" || log_error "Failed to set binding for $k shortcut"
        gsettings set "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding:$path" command "$cmd" || log_error "Failed to set command for $k shortcut"
    done
    
    # Update the custom keybindings list
    gsettings set org.gnome.settings-daemon.plugins.media-keys custom-keybindings "$current_keys" || log_error "Failed to set custom keybindings"
    
    log_info "GNOME shortcuts configured."
}

# 17. Spicetify for Spotify Flatpak
configure_spicetify() {
    log_info "Configuring Spicetify for Spotify..."
    
    # Install Node.js
    sudo dnf install -y nodejs npm || log_error "Failed to install nodejs and npm"
    
    # Install Spicetify
    if ! command -v spicetify &>/dev/null; then
        if ! sudo npm install -g spicetify-cli; then
            log_error "Failed to install Spicetify via npm"
            
            # Try alternative installation method
            log_info "Trying alternative Spicetify installation..."
            curl -fsSL https://raw.githubusercontent.com/spicetify/spicetify-cli/master/install.sh | sh || {
                log_error "Failed to install Spicetify"
                return 1
            }
        fi
    fi
    
    # Configure Spicetify for Flatpak Spotify
    if command -v spicetify &>/dev/null; then
        spicetify config current_user_modify true || log_error "Failed to set Spicetify user modify"
        spicetify config spotify_path "$HOME/.var/app/com.spotify.Client" || log_error "Failed to set Spicetify Spotify path"
        spicetify apply || log_error "Failed to apply Spicetify"
    fi
    
    log_info "Spicetify configuration completed."
}

# 18. Zsh + Oh My Zsh
configure_zsh() {
    log_info "Configuring Zsh and Oh My Zsh..."
    
    # Install Zsh if not present
    if ! command -v zsh &>/dev/null; then
        sudo dnf -y install zsh || {
            log_error "Failed to install Zsh"
            return 1
        }
    fi
    
    # Install Oh My Zsh
    if [ ! -d "$HOME/.oh-my-zsh" ]; then
        log_info "Installing Oh My Zsh..."
        RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" || {
            log_error "Failed to install Oh My Zsh"
            return 1
        }
    fi
    
    # Install plugins
    local zsh_custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    
    if [ ! -d "$zsh_custom/plugins/zsh-autosuggestions" ]; then
        log_info "Installing zsh-autosuggestions..."
        git clone https://github.com/zsh-users/zsh-autosuggestions "$zsh_custom/plugins/zsh-autosuggestions" || log_error "Failed to install zsh-autosuggestions"
    fi
    
    if [ ! -d "$zsh_custom/plugins/zsh-syntax-highlighting" ]; then
        log_info "Installing zsh-syntax-highlighting..."
        git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$zsh_custom/plugins/zsh-syntax-highlighting" || log_error "Failed to install zsh-syntax-highlighting"
    fi
    
    # Configure .zshrc
    local zshrc="$HOME/.zshrc"
    if [ -f "$zshrc" ]; then
        # Update existing .zshrc
        sed -i "s#^ZSH_THEME=.*#ZSH_THEME=\"darkblood\"#" "$zshrc" || log_error "Failed to set Zsh theme"
        sed -i "s#^plugins=.*#plugins=(git zsh-autosuggestions zsh-syntax-highlighting)#" "$zshrc" || log_error "Failed to set Zsh plugins"
    else
        # Create new .zshrc
        cat > "$zshrc" <<EOF
export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="darkblood"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source \$ZSH/oh-my-zsh.sh
EOF
    fi
    
    # Offer to change default shell
    if [ "$SHELL" != "$(which zsh)" ]; then
        log_info "To make Zsh your default shell, run: chsh -s \$(which zsh)"
    fi
    
    log_info "Zsh and Oh My Zsh configuration completed."
}

# 19. Display Error Summary
display_error_summary() {
    echo ""
    echo "=== Setup Summary ==="
    
    if [ -s "$ERROR_LOG" ]; then
        log_warn "Some errors occurred during setup. See details below:"
        echo ""
        while IFS= read -r line; do
            echo "  ❌ $line"
        done < "$ERROR_LOG"
        echo ""
        log_info "Setup completed with warnings. Check the error log for details."
    else
        log_info "Setup completed successfully with no errors!"
    fi
    
    echo ""
    log_info "You may need to:"
    echo "  - Restart your session to apply all changes"
    echo "  - Log out and log back in for theme changes"
    echo "  - Run 'chsh -s \$(which zsh)' to make Zsh your default shell"
    echo "  - Restart GNOME Shell (Alt+F2, type 'r', press Enter) to load extensions"
}

# Main execution with error handling
main() {
    local start_time=$(date +%s)
    
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
    
    # Calculate execution time
    local end_time=$(date +%s)
    local duration=$((end_time - start_time))
    local minutes=$((duration / 60))
    local seconds=$((duration % 60))
    
    echo ""
    log_info "Post-install setup completed in ${minutes}m ${seconds}s"
    display_error_summary
}

# Run main function
main "$@"
