ARG FEDORA_VER=44
ARG KERNEL_FLAVOR=ogc

FROM ghcr.io/ublue-os/akmods-nvidia-open:${KERNEL_FLAVOR}-${FEDORA_VER} AS akmods
FROM quay.io/fedora/fedora-kinoite:${FEDORA_VER} AS rootfs

# Enable COPR Repositories
RUN dnf copr enable -y bazzite-org/obs-vkcapture && \
    dnf copr enable -y errornointernet/klassy && \
    dnf copr enable -y deltacopy/darkly

# Enable Negativo17 repository for Nvidia SELinux support
RUN curl -fsSLo /etc/yum.repos.d/fedora-nvidia.repo https://negativo17.org/repos/fedora-nvidia.repo

# Add Brave's official repository
RUN curl -fsSLo /etc/yum.repos.d/brave-browser.repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

# Add Tailscale's official repository
RUN curl -fsSLo /etc/yum.repos.d/tailscale.repo https://pkgs.tailscale.com/stable/fedora/tailscale.repo

# Ensure /opt exists w/o symlink
RUN rm -rf /opt && \
    mkdir /opt

# Remove stock kernel & Firefox, then install OGC kernel and system packages
RUN --mount=type=bind,from=akmods,src=/kernel-rpms,dst=/tmp/kernel-rpms \
    --mount=type=bind,from=akmods,src=/rpms,dst=/tmp/nvidia-rpms \
    dnf remove -y \
        kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra \
        rpm-ostree rpm-ostree-libs plasma-discover-rpm-ostree \
        firefox firefox-langpacks \
        toolbox && \
    dnf install -y --setopt=tsflags=noscripts --allowerasing \
        /tmp/kernel-rpms/*.rpm \
        /tmp/nvidia-rpms/kmods/*.rpm \
        /tmp/nvidia-rpms/nvidia/*x86_64.rpm \
        /tmp/nvidia-rpms/nvidia/*noarch.rpm \
        /tmp/nvidia-rpms/ublue-os/*.rpm \
        libratbag-ratbagd steam-devices obs-vkcapture \
        libvirt qemu dnscrypt-proxy tailscale \
        brave-origin waydroid distrobox \
        neovim htop hyfetch yt-dlp \
        gamescope mangohud \
        klassy darkly && \
    dnf swap -y ffmpeg-free ffmpeg --allowerasing

# Symlink Brave icons
RUN for res in 16 24 32 48 64 128 256; do \
        mkdir -p /usr/share/icons/hicolor/${res}x${res}/apps && \
        ln -sf /opt/brave.com/brave-origin/product_logo_${res}.png /usr/share/icons/hicolor/${res}x${res}/apps/brave-origin.png; \
    done

# Copy custom system configurations and local binaries into the image
COPY rootfs/usr/ /usr/
COPY rootfs/etc/ /etc/

# Configure dnscrypt
RUN sed -i -E "s/^#[[:space:]]*server_names[[:space:]]*=.*/server_names = ['quad9-dnscrypt-ip4-filter-pri']/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml && \
    sed -i -E "s/^[[:space:]]*require_nofilter[[:space:]]*=.*/require_nofilter = false/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml && \
    sed -i -E "s/^#[[:space:]]*forwarding_rules[[:space:]]*=.*/forwarding_rules = '\/etc\/dnscrypt-proxy\/forwarding-rules.txt'/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml

# Enable services
RUN systemctl enable libvirtd.service dnscrypt-proxy.service lid-guard.service lid-guard-pre.service tailscaled.service

# Generate module dependency map and initramfs
RUN KVER=$(ls /usr/lib/modules | grep ogc | tail -n 1) && \
    depmod -a "${KVER}" && \
    mkdir -p /var/roothome && \
    env DRACUT_NO_XATTR=1 dracut --force --kver "${KVER}" "/usr/lib/modules/${KVER}/initramfs.img"

# Clean up
RUN dnf clean all && \
    rm -rf /var/lib/libvirt/* /var/lib/dnf/* /var/lib/iscsi /run/akmods /run/dnf /tmp/* /var/tmp/* /var/cache/* /var/log/*

# Label & lint rootfs
LABEL containers.bootc=1
RUN bootc container lint
