# shellcheck shell=bash
# The ubuntu step's services a desktop install doesn't use: cloud-init, which only sets up a fresh
# install or a cloud image, and cups-browsed, which adds network printers by itself.

cloud_init_off() {
    ! apt_installed cloud-init || [ -e "$CLOUD_INIT_DISABLED" ]
}

# Printing to local, USB, and added printers goes through cups, which stays on
cups_browsed_off() {
    ! apt_installed cups-browsed || [ "$(systemctl is-enabled "$CUPS_BROWSED_UNIT" 2> /dev/null)" == masked ]
}

mask_cups_browsed() {
    sudo systemctl mask --now "$CUPS_BROWSED_UNIT"
}
