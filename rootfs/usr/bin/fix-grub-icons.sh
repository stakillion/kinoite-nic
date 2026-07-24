#!/bin/bash
DIRECTORY="/boot/loader/entries/"
for entry in "${DIRECTORY}"ostree-*.conf; do
    if [ -f "$entry" ]; then
        if ! grep -q "grub_class" "$entry"; then
            echo "grub_class fedora" >> "$entry"
        fi
    fi
done
