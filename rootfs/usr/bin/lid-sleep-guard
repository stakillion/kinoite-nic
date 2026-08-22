#!/bin/bash

PRE_FILE="/run/pre_wol_gpe"
MODE=$1

if [ "$MODE" == "pre" ]; then
    cat /sys/class/net/eno1/operstate > /dev/null 2>&1
    cat /sys/firmware/acpi/interrupts/gpe0F > "$PRE_FILE"
    sync
    exit 0
fi

if [ "$MODE" == "post" ]; then
    if grep -q "open" /proc/acpi/button/lid/*/state; then
        exit 0
    fi

    if [ ! -f "$PRE_FILE" ]; then
        /usr/bin/systemctl suspend
        exit 0
    fi

    PRE_VAL=$(awk '{print $1}' "$PRE_FILE")
    POST_VAL=$(awk '{print $1}' /sys/firmware/acpi/interrupts/gpe0F)

    if [ "$POST_VAL" -gt "$PRE_VAL" ]; then
        echo "Lid-Guard: WoL confirmed! Staying awake!" | systemd-cat -t "lid-guard"
        rm -f "$PRE_FILE"

        /usr/bin/systemctl mask systemd-suspend.service suspend.target
        /usr/bin/systemd-run --no-block /bin/bash -c "sleep 10 && /usr/bin/systemctl unmask systemd-suspend.service suspend.target"
    else
        echo "Lid-Guard: No WoL signal. Re-suspending..." | systemd-cat -t "lid-guard"
        /usr/bin/systemctl suspend
    fi
    exit 0
fi
