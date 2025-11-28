#!/bin/bash
# ============================================
# Install Prewarm CLI
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/prewarm"

echo "Installing Prewarm CLI..."

# Create data directories
echo "Creating directories..."
mkdir -p "$DATA_DIR"/{queue,running,completed,logs}

# Copy scripts
echo "Installing scripts..."
cp "$SCRIPT_DIR/prewarm" "$INSTALL_DIR/prewarm"
cp "$SCRIPT_DIR/prewarm-daemon" "$INSTALL_DIR/prewarm-daemon"
cp "$SCRIPT_DIR/prewarm-worker.sh" "$INSTALL_DIR/prewarm-worker.sh"

# Fix line endings (Windows CRLF to Unix LF)
sed -i 's/\r$//' "$INSTALL_DIR/prewarm"
sed -i 's/\r$//' "$INSTALL_DIR/prewarm-daemon"
sed -i 's/\r$//' "$INSTALL_DIR/prewarm-worker.sh"

# Make executable
chmod +x "$INSTALL_DIR/prewarm"
chmod +x "$INSTALL_DIR/prewarm-daemon"
chmod +x "$INSTALL_DIR/prewarm-worker.sh"

# Create default config
if [ ! -f "$DATA_DIR/config" ]; then
    echo "Creating default config..."
    cat > "$DATA_DIR/config" << EOF
# Prewarm Configuration

# จำนวน job ที่รันพร้อมกันได้
MAX_CONCURRENT=2

# Default parallel requests per job
DEFAULT_PARALLEL=20
EOF
fi

echo ""
echo "✓ Installation complete!"
echo ""
echo "Usage:"
echo "  prewarm add <url>     Add URL to queue"
echo "  prewarm list          List all jobs"
echo "  prewarm status        Show running jobs"
echo "  prewarm remove <id>   Remove a job"
echo "  prewarm config        Show/set configuration"
echo ""
echo "Configuration:"
echo "  prewarm config MAX_CONCURRENT 3    # รัน 3 jobs พร้อมกัน"
echo "  prewarm config DEFAULT_PARALLEL 50 # 50 parallel per job"
echo ""
echo "Start daemon:"
echo "  prewarm start"
echo ""
echo "Uninstall:"
echo "  sudo ./uninstall.sh"
