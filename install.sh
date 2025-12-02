#!/bin/bash
# ============================================
# Install Prewarm CLI
# ============================================

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/usr/local/bin"
DATA_DIR="/var/lib/prewarm"

echo "Installing Prewarm CLI..."

# Check Node.js
if ! command -v node &> /dev/null; then
    echo "⚠️  Node.js is not installed. Installing..."
    if command -v apt-get &> /dev/null; then
        curl -fsSL https://deb.nodesource.com/setup_lts.x | bash -
        apt-get install -y nodejs
    elif command -v yum &> /dev/null; then
        curl -fsSL https://rpm.nodesource.com/setup_lts.x | bash -
        yum install -y nodejs
    else
        echo "❌ Cannot install Node.js automatically. Please install Node.js manually."
        echo "   Visit: https://nodejs.org/"
        exit 1
    fi
fi
echo "✓ Node.js version: $(node --version)"

# Create data directories
echo "Creating directories..."
mkdir -p "$DATA_DIR"/{queue,running,completed,logs}

# Install Node.js dependencies
echo "Installing dependencies..."
cd "$SCRIPT_DIR"
npm install --production
echo "✓ Dependencies installed"

# Copy scripts
echo "Installing scripts..."
cp "$SCRIPT_DIR/prewarm" "$INSTALL_DIR/prewarm"
cp "$SCRIPT_DIR/prewarm-daemon" "$INSTALL_DIR/prewarm-daemon"
cp "$SCRIPT_DIR/prewarm-worker.sh" "$INSTALL_DIR/prewarm-worker.sh"
cp "$SCRIPT_DIR/prewarm-worker.js" "$INSTALL_DIR/prewarm-worker.js"
cp "$SCRIPT_DIR/package.json" "$INSTALL_DIR/package.json"
cp -r "$SCRIPT_DIR/node_modules" "$INSTALL_DIR/" 2>/dev/null || true

# Fix line endings (Windows CRLF to Unix LF)
sed -i 's/\r$//' "$INSTALL_DIR/prewarm"
sed -i 's/\r$//' "$INSTALL_DIR/prewarm-daemon"
sed -i 's/\r$//' "$INSTALL_DIR/prewarm-worker.sh"

# Make executable
chmod +x "$INSTALL_DIR/prewarm"
chmod +x "$INSTALL_DIR/prewarm-daemon"
chmod +x "$INSTALL_DIR/prewarm-worker.sh"
chmod +x "$INSTALL_DIR/prewarm-worker.js"

# Create default config
if [ ! -f "$DATA_DIR/config" ]; then
    echo "Creating default config..."
    cat > "$DATA_DIR/config" << EOF
# Prewarm Configuration

# จำนวน job ที่รันพร้อมกันได้
MAX_CONCURRENT=5

# Default parallel requests per job
DEFAULT_PARALLEL=5

# Base domain for URL generation
BASE_DOMAIN=media.vdohls.com

# API endpoint
API_ENDPOINT=https://service.vdohide.dev/prewarm

# API token (optional)
API_TOKEN=
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

# Start or restart daemon
PID_FILE="$DATA_DIR/daemon.pid"
if [ -f "$PID_FILE" ]; then
    old_pid=$(cat "$PID_FILE")
    if ps -p "$old_pid" > /dev/null 2>&1; then
        echo "Restarting daemon..."
        kill "$old_pid" 2>/dev/null || true
        sleep 1
    fi
fi

echo "Starting daemon..."
nohup "$INSTALL_DIR/prewarm-daemon" >> "$DATA_DIR/logs/daemon.log" 2>&1 &
echo $! > "$PID_FILE"
echo "✓ Daemon started (PID: $(cat $PID_FILE))"
echo ""
echo "Uninstall:"
echo "  sudo ./uninstall.sh"
