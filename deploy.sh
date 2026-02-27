#!/bin/sh

# 1. Start message
echo "Starting deployment..."

# 2. Check env file
ENV_FILE="/opt/etc/.router.env"
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: $ENV_FILE not found."
    exit 1
fi

# 3. Source env file
. "$ENV_FILE"

# 4. Git pull (Assuming running from the repo root)
echo "Pulling latest changes..."
git pull origin main

# 4.1 Install Transmission and other dependencies
echo "Installing packages..."
/opt/bin/opkg install transmission-daemon-openssl
/opt/bin/opkg install python3 python3-pip git-http

# 4.2 Create Transmission directories
echo "Creating Transmission directories..."
mkdir -p /tmp/mnt/router_disk/media/Downloads
mkdir -p /tmp/mnt/router_disk/media/Incomplete
mkdir -p /tmp/mnt/router_disk/media/Watch

# 5. Process templates and write to system paths
# Templates are in relative paths: opt/etc/xray/config.json, etc.
# Destinations are absolute paths: /opt/etc/xray/config.json, etc.

# config.json
echo "Configuring Xray..."
sed -e "s/YOUR_SELECTEL_IP/$SELECTEL_IP/g" \
    -e "s/YOUR_SECRET_PASSWORD/$SECRET_PASS/g" \
    opt/etc/xray/config.json > /opt/etc/xray/config.json

# S98do-tunnel
echo "Configuring Tunnel..."
sed "s/YOUR_DO_DROPLET_IP/$DO_IP/g" opt/etc/init.d/S98do-tunnel > /opt/etc/init.d/S98do-tunnel

# nat-start
echo "Configuring Firewall..."
sed "s/YOUR_TARGET_IPS/$TARGETS/g" jffs/scripts/nat-start > /jffs/scripts/nat-start

# 5.1 Configure Transmission
echo "Configuring Transmission..."
TRANS_CONF_SRC="opt/etc/transmission/settings.json"
TRANS_CONF_DEST="/opt/etc/transmission/settings.json"
TRANS_INIT="/opt/etc/init.d/S88transmission"

# Ensure destination directory exists
mkdir -p /opt/etc/transmission

# Calculate hashes
if [ -f "$TRANS_CONF_DEST" ]; then
    SRC_HASH=$(md5sum "$TRANS_CONF_SRC" | awk '{print $1}')
    DEST_HASH=$(md5sum "$TRANS_CONF_DEST" | awk '{print $1}')
else
    SRC_HASH="src"
    DEST_HASH="dest"
fi

if [ "$SRC_HASH" != "$DEST_HASH" ]; then
    echo "Transmission config changed. Updating..."
    if [ -x "$TRANS_INIT" ]; then
        "$TRANS_INIT" stop
        sleep 3
    fi

    cp "$TRANS_CONF_SRC" "$TRANS_CONF_DEST"

    if [ -x "$TRANS_INIT" ]; then
        "$TRANS_INIT" start
    fi
else
    echo "Transmission config unchanged, skipping restart."
fi

# 6. Copy launcher
echo "Copying Xray launcher..."
cp opt/etc/init.d/S99xray /opt/etc/init.d/S99xray

# Copy swap mounter
echo "Copying Swap mounter..."
cp opt/etc/init.d/S01swap /opt/etc/init.d/S01swap

echo "Configuring dnsmasq..."
mkdir -p /jffs/configs
cp jffs/configs/dnsmasq.conf.add /jffs/configs/dnsmasq.conf.add

echo "Copying DOK Base launcher..."
cp opt/etc/init.d/S90dokbase /opt/etc/init.d/S90dokbase
chmod +x /opt/etc/init.d/S90dokbase

# 7. chmod
echo "Setting permissions..."
chmod +x /opt/etc/init.d/S98do-tunnel
chmod +x /opt/etc/init.d/S99xray
chmod +x /opt/etc/init.d/S01swap
chmod +x /jffs/scripts/nat-start

# 8. Restart services
echo "Mounting swap..."
if [ -x /opt/etc/init.d/S01swap ]; then
    /opt/etc/init.d/S01swap start
else
    echo "Warning: /opt/etc/init.d/S01swap is not executable or found."
fi

echo "Restarting Xray and Tunnel..."
if [ -x /opt/etc/init.d/S99xray ]; then
    /opt/etc/init.d/S99xray restart
else
    echo "Warning: /opt/etc/init.d/S99xray is not executable or found."
fi

if [ -x /opt/etc/init.d/S98do-tunnel ]; then
    /opt/etc/init.d/S98do-tunnel restart
else
    echo "Warning: /opt/etc/init.d/S98do-tunnel is not executable or found."
fi

# 9. Firewall update
echo "Updating Firewall rules..."
if [ -x /jffs/scripts/nat-start ]; then
    /jffs/scripts/nat-start
else
    echo "Warning: /jffs/scripts/nat-start is not executable or found."
fi

echo "Restarting dnsmasq..."
service restart_dnsmasq

# 10. Success message
echo "Deployment completed successfully!"
