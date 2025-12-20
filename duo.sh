#!/usr/bin/env bash

# Default backlight (0-3)
DEFAULT_BACKLIGHT=3

# Default scale (1-2)
DEFAULT_SCALE=1
temp=$(mktemp -d)
DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus
WAYLAND_DISPLAY=wayland-1
DISPLAY=:0

# Constants for Asus Zenbook Duo 2024
VENDOR_ID="0B05"
USB_PRODUCT_ID="1B2C"
BT_PRODUCT_ID="1B2D"

# Wait for Hyprland to start
echo "Waiting for Hyprland to initialize..."
for i in {1..60}; do
    HYPR_DIR="/run/user/1000/hypr"
    if [ -d "$HYPR_DIR" ] && [ -n "$(ls -A "$HYPR_DIR")" ]; then
        HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art "$HYPR_DIR" | tail -n 1)
        export HYPRLAND_INSTANCE_SIGNATURE
        echo "Hyprland is ready. Using instance: $HYPRLAND_INSTANCE_SIGNATURE"
        break
    fi
    sleep 1
done

if [ -z "$HYPRLAND_INSTANCE_SIGNATURE" ]; then
    echo "Hyprland did not start within 30 seconds — continuing anyway."
else
    echo "$(date) - INIT - Forcing single monitor (eDP-1 only)"
    sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1
    sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,disabled
fi


# Capture Ctrl+C and close any subprocesses such as duo-watch-monitor
trap 'echo "Ctrl+C captured. Exiting..."; pkill -P $$; exit 1' INT
HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art /run/user/1000/hypr | tail -n 1)
echo "test1 $(ls -Art /run/user/1000/hypr | tail -n 1)"
echo "test2 $(ls -Art /run/user/1000/hypr)"
echo "test3 $(ls /run/user)"
echo $temp

SCALE=${DEFAULT_SCALE}

# Python embed
PYTHON3=$(which python3)

if [ ! -f "$temp/backlight.py" ]; then
    echo "#!/usr/bin/env python3

import sys
import os
import time
import usb.core
import usb.util
import fcntl

# USB Parameters
USB_VENDOR_ID = 0x${VENDOR_ID}
USB_PRODUCT_ID = 0x${USB_PRODUCT_ID}
REPORT_ID = 0x5A
WVALUE = 0x035A
WINDEX = 4
WLENGTH = 16

# Bluetooth/HID Parameters
BT_VENDOR_ID = \"${VENDOR_ID}\"
BT_PRODUCT_ID = \"${BT_PRODUCT_ID}\"
TARGET_DRIVER = \"hid-generic\"

def set_brightness_usb(level):
    # Find the device
    dev = usb.core.find(idVendor=USB_VENDOR_ID, idProduct=USB_PRODUCT_ID)
    if dev is None:
        return False

    print(f\"USB Device found (Vendor ID: 0x{USB_VENDOR_ID:04X}, Product ID: 0x{USB_PRODUCT_ID:04X})\")

    # Prepare the data packet
    data = [0] * WLENGTH
    data[0] = REPORT_ID
    data[1] = 0xBA
    data[2] = 0xC5
    data[3] = 0xC4
    data[4] = level

    # Detach kernel driver if necessary
    if dev.is_kernel_driver_active(WINDEX):
        try:
            dev.detach_kernel_driver(WINDEX)
        except usb.core.USBError as e:
            print(f\"Could not detach kernel driver: {str(e)}\")
            return False

    # Send the control transfer
    try:
        bmRequestType = 0x21  # Host to Device | Class | Interface
        bRequest = 0x09       # SET_REPORT
        wValue = WVALUE       # 0x035A
        wIndex = WINDEX       # Interface number
        ret = dev.ctrl_transfer(bmRequestType, bRequest, wValue, wIndex, data, timeout=1000)
        if ret != WLENGTH:
            print(f\"Warning: Only {ret} bytes sent out of {WLENGTH}.\")
        else:
            print(\"Data packet sent successfully via USB.\")
    except usb.core.USBError as e:
        print(f\"Control transfer failed: {str(e)}\")
        usb.util.release_interface(dev, WINDEX)
        return False

    # Release the interface
    usb.util.release_interface(dev, WINDEX)
    # Reattach the kernel driver if necessary
    try:
        dev.attach_kernel_driver(WINDEX)
    except usb.core.USBError:
        pass
    
    return True

def find_bt_device_path():
    base_path = \"/sys/class/hidraw\"
    if not os.path.exists(base_path):
        return None
        
    for entry in os.listdir(base_path):
        uevent_path = os.path.join(base_path, entry, \"device\", \"uevent\")
        if not os.path.exists(uevent_path):
            continue
            
        try:
            with open(uevent_path, \"r\") as f:
                content = f.read()
            
            props = {}
            for line in content.splitlines():
                if \"=\" in line:
                    k, v = line.split(\"=\", 1)
                    props[k] = v
            
            hid_id = props.get(\"HID_ID\", \"\")
            driver = props.get(\"DRIVER\", \"\")
            
            parts = hid_id.split(\":\")
            if len(parts) == 3:
                # HID_ID is BUS:VENDOR:PRODUCT.
                vid_str = parts[1].upper()
                pid_str = parts[2].upper()
                
                target_vid = BT_VENDOR_ID.upper()
                target_pid = BT_PRODUCT_ID.upper()
                
                if target_vid in vid_str and target_pid in pid_str and driver == TARGET_DRIVER:
                    return f\"/dev/{entry}\"
        except Exception:
            continue
    return None

def set_brightness_bt(level):
    device_path = find_bt_device_path()
    if not device_path:
        return False
        
    print(f\"Bluetooth Device found at {device_path}\")
    
    data = [0xBA, 0xC5, 0xC4, level] + [0] * 11
    buf = bytearray([0x5A]) + bytearray(data)
    
    try:
        fd = os.open(device_path, os.O_RDWR)
        op = 0xC0004806 | (len(buf) << 16)
        fcntl.ioctl(fd, op, buf)
        print(\"Data packet sent successfully via Bluetooth.\")
        os.close(fd)
        return True
    except Exception as e:
        print(f\"Error sending via Bluetooth: {e}\")
        return False

if __name__ == \"__main__\":
    if len(sys.argv) < 2:
        print(f\"Usage: {sys.argv[0]} <level> [wait_for_bt]\")
        sys.exit(1)

    try:
        level = int(sys.argv[1])
        level = max(0, min(3, level))
    except ValueError:
        print(\"Invalid level.\")
        sys.exit(1)
        
    wait_for_bt = False
    if len(sys.argv) > 2 and sys.argv[2] == \"wait\":
        wait_for_bt = True

    # Try USB first
    if set_brightness_usb(level):
        sys.exit(0)
        
    # If USB failed, try Bluetooth
    if set_brightness_bt(level):
        sys.exit(0)
        
    # If both failed and we are asked to wait for Bluetooth
    if wait_for_bt:
        print(\"Waiting for Bluetooth device...\")
        # Wait up to 30 seconds
        for i in range(30):
            time.sleep(1)
            if set_brightness_bt(level):
                sys.exit(0)
        print(\"Timed out waiting for Bluetooth device.\")
        sys.exit(1)
    
    print(\"No compatible device found.\")
    sys.exit(1)
" > "$temp/backlight.py"
fi

WIFI_BEFORE=$(nmcli radio wifi)
BLUETOOTH_BEFORE=$(rfkill -n -o SOFT list bluetooth |head -n1)
KEYBOARD_ATTACHED=false
# Check for USB device with specific ID
if lsusb -d ${VENDOR_ID}:${USB_PRODUCT_ID} >/dev/null 2>&1; then
    KEYBOARD_ATTACHED=true
fi
MONITOR_COUNT=$(gdctl show | grep 'Logical monitor #' | wc -l)
function duo-set-status() {
    echo "
        BLUETOOTH_BEFORE=${BLUETOOTH_BEFORE}
        WIFI_BEFORE=${WIFI_BEFORE}
        KEYBOARD_ATTACHED=${KEYBOARD_ATTACHED}
        MONITOR_COUNT=${MONITOR_COUNT}
    " > "$temp/status"
}
duo-set-status

function duo-set-kb-backlight() {
    # $1: level, $2: optional "wait"
    ${PYTHON3} "$temp/backlight.py" ${1} ${2} >/dev/null &
}

BRIGHTNESS=0
function duo-sync-display-backlight() {
    . "$temp/status"
    if [ "${KEYBOARD_ATTACHED}" = false ]; then
        CUR_BRIGHTNESS=$(cat /sys/class/backlight/intel_backlight/brightness)
        if [ "${CUR_BRIGHTNESS}" != "${BRIGHTNESS}" ]; then
            BRIGHTNESS=${CUR_BRIGHTNESS}
            echo "$(date) - DISPLAY - Setting brightness to $(echo ${BRIGHTNESS} | tee /sys/class/backlight/card1-eDP-2-backlight/brightness)"
        fi
    fi
}

function duo-watch-display-backlight() {
    while true; do
        inotifywait -e modify /sys/class/backlight/intel_backlight/brightness >/dev/null 2>&1
        duo-sync-display-backlight
    done
}

function duo-watch-wifi() {
    while read -r LINE; do
        sleep 1
        . "$temp/status"
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                WIFI_BEFORE=enabled
            else
                WIFI_BEFORE=disabled
            fi
            echo "$(date) - NETWORK - WIFI: ${WIFI_BEFORE}"
            duo-set-status
        fi
    done < <(gdbus monitor -y -d org.freedesktop.NetworkManager | grep --line-buffered WirelessEnabled)
}

function duo-watch-bluetooth() {
    while read -r LINE; do
        sleep 1
        . "$temp/status"
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                BLUETOOTH_BEFORE=unblocked
            else
                BLUETOOTH_BEFORE=blocked
            fi
            echo "$(date) - NETWORK - Bluetooth: ${BLUETOOTH_BEFORE}"
            duo-set-status
        fi
    done < <(gdbus monitor -y -d org.bluez | grep --line-buffered "'Powered':")
}

function duo-watch-lock() {
    while read -r LINE; do
        sleep 1
        echo "$(date) - DEBUG - ${LINE}"
        . "$temp/status"
        if [ "${KEYBOARD_ATTACHED}" = true ]; then
            if [[ "${LINE}" = *"<true>"* ]]; then
                BLUETOOTH_BEFORE=unblocked
            else
                BLUETOOTH_BEFORE=blocked
            fi
            echo "$(date) - NETWORK - Bluetooth: ${BLUETOOTH_BEFORE}"
            duo-set-status
            duo-check-monitor
        fi
    done < <(gdbus monitor -y -d org.freedesktop.login1 | grep --line-buffered "LockedHint")
}

function duo-check-monitor() {
    . "$temp/status"
    KEYBOARD_ATTACHED=false
    if lsusb -d ${VENDOR_ID}:${USB_PRODUCT_ID} >/dev/null 2>&1; then
        KEYBOARD_ATTACHED=true
    fi
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art /run/user/1000/hypr | tail -n 1)
    MONITOR_COUNT=$(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors | grep Monitor --color=none | wc -l)
    echo "OUTPUT $(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors)"
    duo-set-status
    echo "$(date) - MONITOR - WIFI before: ${WIFI_BEFORE}, Bluetooth before: ${BLUETOOTH_BEFORE}"
    echo "$(date) - MONITOR - Keyboard attached: ${KEYBOARD_ATTACHED}, Monitor count: ${MONITOR_COUNT}"
    if [ ${KEYBOARD_ATTACHED} = true ]; then
        echo "$(date) - MONITOR - Keyboard attached"
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
        if [ "${WIFI_BEFORE}" = enabled ]; then
            echo "$(date) - MONITOR - Turning on WIFI"
            nmcli radio wifi on
        fi
        if [ "${BLUETOOTH_BEFORE}" = unblocked ]; then
            echo "$(date) - MONITOR - Turning on Bluetooth"
            rfkill unblock bluetooth
        else
            echo "$(date) - MONITOR - Turning off Bluetooth"
            rfkill block bluetooth
        fi
        if ((${MONITOR_COUNT} > 1)); then
            echo "$(date) - MONITOR - Disabling bottom monitor"
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,disabled
            NEW_MONITOR_COUNT=$(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors | grep Monitor --color=none | wc -l)
            if ((${NEW_MONITOR_COUNT} == 1)); then
                MESSAGE="Disabled bottom display"
            else
                MESSAGE="ERROR: Bottom display still on"
            fi
            sudo -E -u nick notify-send -a "Zenbook Duo" -t 1000 --hint=int:transient:1 -i "preferences-desktop-display" "${MESSAGE}"
        fi
    else
        echo "$(date) - MONITOR - Keyboard detached"
        
        # Trigger backlight set with wait for Bluetooth
        echo "$(date) - MONITOR - Waiting for Bluetooth keyboard to connect..."
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT} "wait"
        
        if [ "${WIFI_BEFORE}" = enabled ]; then
            echo "$(date) - MONITOR - Turning on WIFI"
            nmcli radio wifi on
        fi
        echo "$(date) - MONITOR - Turning on Bluetooth"
        rfkill unblock bluetooth
        if ((${MONITOR_COUNT} < 2)); then
            echo "$(date) - MONITOR - Enabling bottom monitor"
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x1200,1
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl dispatch workspace 11
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl dispatch movecurrentworkspacetomonitor eDP-2
            NEW_MONITOR_COUNT=$(sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl monitors | grep Monitor --color=none | wc -l)
            if ((${NEW_MONITOR_COUNT} == 2)); then
                MESSAGE="Enabled bottom display"
            else
                MESSAGE="ERROR: Bottom display still off"
            fi
            sudo -E -u nick notify-send -a "Zenbook Duo" -t 1000 --hint=int:transient:1 -i "preferences-desktop-display" "${MESSAGE}"
        fi
    fi
}

function duo-watch-monitor() {
    while true; do
        echo "$(date) - MONITOR - Waiting for USB event"
        inotifywait -e attrib /dev/bus/usb/*/ >/dev/null 2>&1
        duo-check-monitor
    done
}

function duo-cli() {
    . "$temp/status"
    HYPRLAND_INSTANCE_SIGNATURE=$(ls -Art /run/user/1000/hypr | tail -n 1)
    case "${1}" in
    pre|hibernate|shutdown)
        echo "$(date) - ACPI - $@"
        duo-set-kb-backlight 0
    ;;
    post|thaw|boot)
        echo "$(date) - ACPI - $@"
        duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
        duo-check-monitor
    ;;
    kbb)
        echo "$(date) - KEYBOARD - Backlight = ${2}"
        duo-set-kb-backlight ${2}
    ;;
    left-up)
        echo "$(date) - ROTATE - Left-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,1
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,1200x0,1,transform,1
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x0,1,transform,1
        fi

        ;;
    right-up)
        echo "$(date) - ROTATE - Right-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,3
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,3
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,1200x0,1,transform,3
        fi
        ;;
    bottom-up)
        echo "$(date) - ROTATE - Bottom-up"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1,transform,2
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x1200,1,transform,3
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,0x0,1,transform,3
        fi
        ;;
    normal)
        echo "$(date) - ROTATE - Normal"
        if [ ${KEYBOARD_ATTACHED} = true ]; then
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1
        else
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-1,1920x1200@60,0x0,1
            sudo -u nick HYPRLAND_INSTANCE_SIGNATURE=$HYPRLAND_INSTANCE_SIGNATURE hyprctl keyword monitor eDP-2,1920x1200@60,1200x0,1
        fi
        ;;
    *)
        echo "$(date) - UNKNOWN - $@"
        ;;
    esac
}

function duo-watch-rotate() {
    echo "$(date) - ROTATE - Watching"
    monitor-sensor --accel |
        stdbuf -oL grep "Accelerometer orientation changed:" |
        stdbuf -oL awk '{print $4}' |
        xargs -I '{}' stdbuf -oL "$0" '{}' 2>/dev/null
}

function main() {
    duo-set-kb-backlight ${DEFAULT_BACKLIGHT}
    duo-check-monitor
    duo-watch-monitor &
    duo-watch-rotate &
    duo-watch-display-backlight &
    duo-watch-wifi &
    duo-watch-bluetooth
}

if [ -z "${1}" ]; then
    main | tee -a "$temp/duo.log"
else
    duo-cli $@ | tee -a "$temp/duo.log"
    if [ "${USER}" = root ]; then
        chmod a+w "$temp" "$temp/duo.log" "$temp/status"
    fi
fi
