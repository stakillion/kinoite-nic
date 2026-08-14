ARG FEDORA_VER=44

# ==============================================================================
# Stage 1: Build rootfs with all packages, kernel modules, and configuration
# ==============================================================================
FROM quay.io/fedora-ostree-desktops/kinoite:${FEDORA_VER} AS rootfs

# Enable RPM Fusion (Free & Non-Free)
RUN dnf install -y \
    https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm \
    https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-$(rpm -E %fedora).noarch.rpm

# Enable COPR Repositories
RUN dnf copr enable -y bazzite-org/obs-vkcapture && \
    dnf copr enable -y bieszczaders/kernel-cachyos && \
    dnf copr enable -y errornointernet/klassy && \
    dnf copr enable -y deltacopy/darkly && \
    dnf copr enable -y hikariknight/looking-glass-kvmfr

# Add Brave's official repository
RUN curl -fsSLo /etc/yum.repos.d/brave-browser.repo https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo

# Ensure /var/opt exists
RUN mkdir -p /var/opt

# Remove stock kernel & Firefox, then install CachyOS kernel and system packages
RUN rm -f /etc/dnf/protected.d/grub* /etc/dnf/protected.d/shim* && \
    dnf remove -y \
        kernel kernel-core kernel-modules kernel-modules-core kernel-modules-extra \
        rpm-ostree rpm-ostree-libs plasma-discover-rpm-ostree \
        shim-* grub2-* bootupd \
        firefox firefox-langpacks \
        toolbox && \
    dnf install -y --setopt=tsflags=noscripts \
        kernel-cachyos kernel-cachyos-devel-matched systemd-boot-unsigned \
        akmod-nvidia xorg-x11-drv-nvidia xorg-x11-drv-nvidia-cuda \
        libratbag-ratbagd steam-devices obs-vkcapture \
        libvirt qemu kvmfr-kmod dnscrypt-proxy \
        brave-origin waydroid distrobox \
        neovim htop hyfetch yt-dlp \
        klassy darkly \
        webkit2gtk4.1 && \
    dnf swap -y ffmpeg-free ffmpeg --allowerasing

# Symlink Brave icons
RUN for res in 16 24 32 48 64 128 256; do \
        mkdir -p /usr/share/icons/hicolor/${res}x${res}/apps && \
        ln -sf /opt/brave.com/brave-origin/product_logo_${res}.png /usr/share/icons/hicolor/${res}x${res}/apps/brave-origin.png; \
    done

# Copy custom system configurations and local binaries into the image
COPY rootfs/usr/ /usr/

# Configure dnscrypt
RUN sed -i -E "s/^#[[:space:]]*server_names[[:space:]]*=.*/server_names = ['quad9-dnscrypt-ip4-filter-pri']/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml && \
    sed -i -E "s/^[[:space:]]*require_nofilter[[:space:]]*=.*/require_nofilter = false/" /etc/dnscrypt-proxy/dnscrypt-proxy.toml

# Configure altfiles in nsswitch.conf
RUN sed -i 's/^passwd:.*/passwd:     files altfiles/' /etc/nsswitch.conf && \
    sed -i 's/^group:.*/group:      files altfiles/' /etc/nsswitch.conf

# Enable services
RUN systemctl enable libvirtd.service dnscrypt-proxy.service lid-guard.service lid-guard-pre.service

# Build and sign kernel modules and trigger initramfs generation
RUN --mount=type=secret,id=mok_key \
    --mount=type=secret,id=mok_der \
    KVER=$(ls /usr/lib/modules | grep cachyos | tail -n 1) && \
    akmods --force --kernels "${KVER}" && \
    find "/usr/lib/modules/${KVER}/extra/" -type f \( -name "*.ko" -o -name "*.ko.xz" \) | while read -r mod; do \
        if [[ "$mod" == *.xz ]]; then \
            unxz "$mod" && \
            uncompressed="${mod%.xz}" && \
            /usr/src/kernels/${KVER}/scripts/sign-file sha256 /run/secrets/mok_key /run/secrets/mok_der "$uncompressed" && \
            xz -z "$uncompressed"; \
        else \
            /usr/src/kernels/${KVER}/scripts/sign-file sha256 /run/secrets/mok_key /run/secrets/mok_der "$mod"; \
        fi; \
    done && \
    depmod -a "${KVER}" && \
    mkdir -p /var/roothome && \
    env DRACUT_NO_XATTR=1 dracut --force --kver "${KVER}" "/usr/lib/modules/${KVER}/initramfs.img"

# clean up
RUN dnf clean all && \
    rm -rf /var/lib/libvirt/* /var/lib/dnf/* /var/lib/iscsi /run/akmods /run/dnf /tmp/* /var/tmp/* /var/cache/* /var/log/*

# Freeze timestamps across /usr, /etc, and /var/opt for chunkah
RUN find /usr /etc /var/opt -exec touch -h -d "2026-01-01T00:00:00Z" {} +

# Lint complete rootfs before splitting kernel or chunking
RUN bootc container lint

# ==============================================================================
# Stage 2: Split raw kernel/initramfs out of rootfs using bootc
# ==============================================================================
FROM rootfs AS split
RUN mkdir -p /kernel && \
    bootc container split-kernel-and-rootfs \
      --rootfs / \
      --output /kernel

# ==============================================================================
# Stage 3: Rechunk stripped base OS via chunkah
# ==============================================================================
FROM quay.io/coreos/chunkah AS chunkah
RUN --mount=from=split,src=/,target=/chunkah,ro \
    chunkah build \
        --max-layers 256 \
        --prune /ostree \
        --prune /sysroot/ostree \
        --output oci:/run/src/out

# ==============================================================================
# Stage 4: Load chunked base image
# ==============================================================================
FROM oci:out AS rootfs-chunked
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# ==============================================================================
# Stage 5: Build UKI using extracted kernel directory from Stage 2
# ==============================================================================
FROM quay.io/fedora/fedora-bootc:latest AS sealed-uki
RUN dnf install -y systemd-ukify sbsigntools && dnf clean all

RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=secret,id=mok_key \
    --mount=type=secret,id=mok_crt \
    --mount=type=bind,from=rootfs-chunked,target=/run/target,ro \
    --mount=type=bind,from=split,src=/kernel,target=/kernel,ro \
    set -euo pipefail && \
    KVER=$(ls /kernel) && \
    mkdir -p /out && \
    bootc container ukify \
      --rootfs /run/target \
      --kernel-dir "/kernel/${KVER}" \
      -- \
      --output "/out/${KVER}.efi" \
      --signtool sbsign \
      --secureboot-private-key /run/secrets/mok_key \
      --secureboot-certificate /run/secrets/mok_crt

# ==============================================================================
# Stage 6: Final Image (Chunked Base + UKI top layer)
# ==============================================================================
FROM rootfs-chunked AS final
COPY --from=sealed-uki /out/*.efi /boot/EFI/Linux/
