#!/bin/sh
set -eu
if [ -s /data/CoreADI.x86_64 ]; then
    echo "CoreADI already exists in the private volume."
    exit 0
fi
python3 tools/fetch_mac_coreadi.py --dest /tmp/coreadi
cp /tmp/coreadi/coreadi-pkg/rootfs/System/Library/PrivateFrameworks/CoreADI.framework/Versions/A/CoreADI.x86_64 /data/CoreADI.x86_64
chmod 644 /data/CoreADI.x86_64
echo "Mac CoreADI extracted into the private data volume."
