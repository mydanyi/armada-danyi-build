#!/bin/bash
set -eu

# Install the personal-build update entrypoint. The script itself is already
# present in the vendored source tree; this step only places it on PATH so the
# external armada-danyi-update helper can be invoked. It must not download,
# run, or trigger an update, and must not call bootc or reboot.
install -Dpm0755 /ctx/personal-build/update.sh /usr/bin/armada-danyi-update
