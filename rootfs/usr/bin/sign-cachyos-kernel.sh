#!/bin/bash

export PATH=/usr/bin:/usr/sbin:/bin:/sbin

# We watch the ostree boot directory for the CachyOS kernels
for kernel in /boot/ostree/fedora-*/vmlinuz-*cachyos*; do
    # Check if it even exists to prevent globbing errors
    [ -e "$kernel" ] || continue

    # If the kernel is NOT already signed by our key, sign it
    if ! sbverify --cert /etc/secureboot/MOK.pem "$kernel" > /dev/null 2>&1; then
        echo "Unsigned CachyOS kernel detected. Signing $kernel..."
        
        # Output to a temporary file first, then move it. 
        # This breaks the ostree hardlink so we don't corrupt the local repo!
        sbsign --key /etc/secureboot/MOK.priv --cert /etc/secureboot/MOK.pem --output "$kernel.signed" "$kernel"
        mv "$kernel.signed" "$kernel"
        
        echo "Successfully signed $kernel"
    fi
done
