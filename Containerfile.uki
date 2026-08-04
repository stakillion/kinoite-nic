# ==============================================================================
# Stage 1: Load chunkah output from host disk
# ==============================================================================
FROM oci:out AS rootfs-chunked
LABEL containers.bootc=1
ENV container=oci
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]

# ==============================================================================
# Stage 2: Build and Sign UKI against chunked base
# ==============================================================================
FROM quay.io/fedora/fedora-bootc:latest AS sealed-uki
RUN dnf install -y systemd-ukify sbsigntools && dnf clean all

COPY kernel-out /kernel-out

RUN --mount=type=tmpfs,target=/run \
    --mount=type=tmpfs,target=/tmp \
    --mount=type=secret,id=mok_key \
    --mount=type=secret,id=mok_crt \
    --mount=type=bind,from=rootfs-chunked,src=/,target=/run/target,ro \
    set -euo pipefail && \
    KVER=$(cat /kernel-out/kver.txt) && \
    mkdir -p /boot/EFI/Linux && \
    bootc container ukify \
      --rootfs /run/target \
      --kernel-dir /kernel-out \
      -- \
      --output "/boot/EFI/Linux/${KVER}.efi" \
      --signtool sbsign \
      --secureboot-private-key /run/secrets/mok_key \
      --secureboot-certificate /run/secrets/mok_crt

# ==============================================================================
# Stage 3: Final image combining chunked rootfs and signed UKI
# ==============================================================================
FROM rootfs-chunked AS final
COPY --from=sealed-uki /boot/EFI/Linux /boot/EFI/Linux
