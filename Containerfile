ARG FEDORA_VER=44
FROM quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VER}

# Copy MOK key pair into build environment for Secure Boot kernel & module signing
COPY MOK.priv MOK.der /tmp/

# Enable RPM Fusion (Free & Non-Free)
RUN dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Enable COPR Repositories
RUN dnf copr enable -y bazzite-org/obs-vkcapture && \
    dnf copr enable -y bieszczaders/kernel-cachyos && \
    dnf copr enable -y errornointernet/klassy && \
    dnf copr enable -y hikariknight/looking-glass-kvmfr && \
    dnf copr enable -y matinlotfali/KDE-Rounded-Corners

# Add Brave's official repository
RUN curl -fsSLo /etc/yum.repos.d/brave-browser.repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

# Mask 05-rpmostree.install on disk so RPM scriptlets CANNOT trigger dracut mid-transaction
RUN mkdir -p /etc/kernel/install.d && \
    ln -s /dev/null /etc/kernel/install.d/05-rpmostree.install

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
        kwin-effect-roundcorners \
        libratbag-ratbagd \
        libvirt \
        neovim \
        obs-vkcapture \
        qemu \
        sbsigntools \
        steam-devices \
        waydroid

# Configure kvmfr modprobe & explicitly tell dracut to bundle it in initramfs
RUN mkdir -p /etc/modprobe.d /etc/dracut.conf.d && \
    echo "options kvmfr static_size_mb=128" > /etc/modprobe.d/kvmfr.conf && \
    echo 'install_items+=" /etc/modprobe.d/kvmfr.conf "' > /etc/dracut.conf.d/kvmfr.conf

# Unmask hook, build drivers, run depmod, sign kernel/modules, and trigger initramfs generation
RUN rm -f /etc/kernel/install.d/05-rpmostree.install && \
    KVER=$(ls /usr/lib/modules | grep cachyos | tail -n 1) && \
    # Build out-of-tree Nvidia & KVMFR modules
    akmods --force --kernels "${KVER}" && \
    # Generate module dependency maps
    depmod -a "${KVER}" && \
    # Convert MOK DER to PEM for sbsign
    openssl x509 -in /tmp/MOK.der -inform DER -out /tmp/MOK.pem && \
    # Sign the main CachyOS kernel binary (vmlinuz)
    sbsign --key /tmp/MOK.priv --cert /tmp/MOK.pem \
           --output "/usr/lib/modules/${KVER}/vmlinuz" \
           "/usr/lib/modules/${KVER}/vmlinuz" && \
    # Sign out-of-tree kernel modules safely (handling compressed .ko.xz files)
    find "/usr/lib/modules/${KVER}/extra/" -type f \( -name "*.ko" -o -name "*.ko.xz" \) | while read -r mod; do \
        if [[ "$mod" == *.xz ]]; then \
            unxz "$mod" && \
            uncompressed="${mod%.xz}" && \
            /usr/src/kernels/${KVER}/scripts/sign-file sha256 /tmp/MOK.priv /tmp/MOK.der "$uncompressed" && \
            xz -z "$uncompressed"; \
        else \
            /usr/src/kernels/${KVER}/scripts/sign-file sha256 /tmp/MOK.priv /tmp/MOK.der "$mod"; \
        fi; \
    done && \
    # Generate the bootc initramfs
    kernel-install add "${KVER}" "/usr/lib/modules/${KVER}/vmlinuz" && \
    # DNF & transient file cleanup (wipes MOK keys in /tmp, build logs, and caches)
    dnf clean all && \
    rm -rf /run/akmods /run/dnf /tmp/* /var/log/* /var/cache/*

# Lint the final image for bootc compliance
RUN bootc container lint
