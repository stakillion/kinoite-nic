ARG FEDORA_VER=44
FROM quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VER}

# Enable RPM Fusion (Free & Non-Free)
RUN dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Enable COPR Repositories
RUN dnf copr enable -y bazzite-org/obs-vkcapture && \
    dnf copr enable -y bieszczaders/kernel-cachyos && \
    dnf copr enable -y errornointernet/klassy && \
    dnf copr enable -y hikariknight/looking-glass-kvmfr && \
    dnf copr enable -y chenxiaolong/sbctl

# Add Brave's official repository
RUN curl -fsSLo /etc/yum.repos.d/brave-browser.repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

# Mask 05-rpmostree.install on disk so RPM scriptlets CANNOT trigger dracut mid-transaction
RUN mkdir -p /etc/kernel/install.d && \
    ln -s /dev/null /etc/kernel/install.d/05-rpmostree.install

# Fix the /opt symlink issue so RPM/cpio can install third-party apps normally
RUN rm -rf /opt && mkdir -p /opt

# Remove stock kernel & Firefox, then install CachyOS kernel and system packages
RUN dnf remove -y \
        firefox \
        firefox-langpacks \
        kernel \
        kernel-core \
        kernel-modules \
        kernel-modules-core \
        kernel-modules-extra && \
    dnf install -y --setopt=tsflags=noscripts \
        kernel-cachyos \
        kernel-cachyos-devel-matched \
        akmod-nvidia \
        xorg-x11-drv-nvidia \
        xorg-x11-drv-nvidia-cuda \
        brave-origin \
        dnscrypt-proxy \
        fastfetch \
        htop \
        klassy \
        kvmfr-kmod \
        libratbag-ratbagd \
        libvirt \
        neovim \
        obs-vkcapture \
        qemu \
        sbsigntools \
        steam-devices \
        systemd-boot-unsigned \
        sbctl \
        waydroid

# Symlink Brave icons
RUN mkdir -p /usr/share/icons/hicolor/16x16/apps \
             /usr/share/icons/hicolor/24x24/apps \
             /usr/share/icons/hicolor/32x32/apps \
             /usr/share/icons/hicolor/48x48/apps \
             /usr/share/icons/hicolor/64x64/apps \
             /usr/share/icons/hicolor/128x128/apps \
             /usr/share/icons/hicolor/256x256/apps && \
    ln -sf /opt/brave.com/brave-origin/product_logo_16.png /usr/share/icons/hicolor/16x16/apps/brave-origin.png && \
    ln -sf /opt/brave.com/brave-origin/product_logo_24.png /usr/share/icons/hicolor/24x24/apps/brave-origin.png && \
    ln -sf /opt/brave.com/brave-origin/product_logo_32.png /usr/share/icons/hicolor/32x32/apps/brave-origin.png && \
    ln -sf /opt/brave.com/brave-origin/product_logo_48.png /usr/share/icons/hicolor/48x48/apps/brave-origin.png && \
    ln -sf /opt/brave.com/brave-origin/product_logo_64.png /usr/share/icons/hicolor/64x64/apps/brave-origin.png && \
    ln -sf /opt/brave.com/brave-origin/product_logo_128.png /usr/share/icons/hicolor/128x128/apps/brave-origin.png && \
    ln -sf /opt/brave.com/brave-origin/product_logo_256.png /usr/share/icons/hicolor/256x256/apps/brave-origin.png

# Copy custom system configurations and local binaries into the image
COPY rootfs/etc/ /etc/
COPY rootfs/usr/ /usr/

# Configure dnscrypt
RUN sed -i -E "s/^#[[:space:]]*server_names[[:space:]]*=.*/server_names = ['quad9-dnscrypt-ip4-filter-pri']/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml && \
    sed -i -E "s/^[[:space:]]*require_nofilter[[:space:]]*=.*/require_nofilter = false/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml

# Enable services
RUN systemctl enable libvirtd.service && \
    systemctl enable dnscrypt-proxy.service && \
    systemctl enable lid-guard.service && \
    systemctl enable lid-guard-pre.service && \
    systemctl enable systemd-boot-update.service

# Unmask hook, build drivers, run depmod, sign kernel/modules, and trigger initramfs generation
RUN --mount=type=secret,id=sbctl_db_key \
    --mount=type=secret,id=sbctl_db_cert \
    --mount=type=secret,id=sbctl_db_der \
    rm -f /etc/kernel/install.d/05-rpmostree.install && \
    KVER=$(ls /usr/lib/modules | grep cachyos | tail -n 1) && \
    # Build out-of-tree Nvidia & KVMFR modules
    akmods --force --kernels "${KVER}" && \
    # Generate module dependency maps
    depmod -a "${KVER}" && \
    # Sign the main CachyOS kernel binary (vmlinuz)
    sbsign --key /run/secrets/sbctl_db_key --cert /run/secrets/sbctl_db_cert \
           --output "/usr/lib/modules/${KVER}/vmlinuz" \
           "/usr/lib/modules/${KVER}/vmlinuz" && \
    # Sign systemd-boot
    sbsign --key /run/secrets/sbctl_db_key --cert /run/secrets/sbctl_db_cert \
           --output /usr/lib/systemd/boot/efi/systemd-bootx64.efi \
           /usr/lib/systemd/boot/efi/systemd-bootx64.efi && \
    # Sign out-of-tree kernel modules safely (handling compressed .ko.xz files)
    find "/usr/lib/modules/${KVER}/extra/" -type f \( -name "*.ko" -o -name "*.ko.xz" \) | while read -r mod; do \
        if [[ "$mod" == *.xz ]]; then \
            unxz "$mod" && \
            uncompressed="${mod%.xz}" && \
            /usr/src/kernels/${KVER}/scripts/sign-file sha256 /run/secrets/sbctl_db_key /run/secrets/sbctl_db_der "$uncompressed" && \
            xz -z "$uncompressed"; \
        else \
            /usr/src/kernels/${KVER}/scripts/sign-file sha256 /run/secrets/sbctl_db_key /run/secrets/sbctl_db_der "$mod"; \
        fi; \
    done && \
    # Generate the bootc initramfs
    kernel-install add "${KVER}" "/usr/lib/modules/${KVER}/vmlinuz" && \
    # DNF & transient file cleanup
    dnf clean all && \
    rm -rf /run/akmods /run/dnf /tmp/* /var/log/* /var/cache/*

# Lint the final image for bootc compliance
RUN bootc container lint
