#!/bin/bash
# ============================================
# Uninstall Prewarm CLI
# ============================================

set -e

INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/prewarm"
PID_FILE="$DATA_DIR/daemon.pid"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Uninstalling Prewarm CLI...${NC}"
echo ""

# Stop daemon if running
if [ -f "$PID_FILE" ]; then
    pid=$(cat "$PID_FILE")
    if ps -p "$pid" > /dev/null 2>&1; then
        echo "Stopping daemon..."
        kill "$pid" 2>/dev/null || true
        sleep 1
    fi
fi

# Ask about data
echo -e "${YELLOW}Do you want to remove all data (jobs, logs, config)?${NC}"
echo -n "[y/N] "
read -r remove_data

# Remove scripts
echo "Removing scripts..."
rm -f "$INSTALL_DIR/prewarm"
rm -f "$INSTALL_DIR/prewarm-daemon"
rm -f "$INSTALL_DIR/prewarm-worker.sh"

# Remove data if requested
if [ "$remove_data" = "y" ] || [ "$remove_data" = "Y" ]; then
    echo "Removing data directory..."
    rm -rf "$DATA_DIR"
    echo -e "${GREEN}✓ All data removed${NC}"
else
    echo -e "${YELLOW}Data directory preserved: $DATA_DIR${NC}"
fi

echo ""
echo -e "${GREEN}✓ Prewarm CLI uninstalled!${NC}"
