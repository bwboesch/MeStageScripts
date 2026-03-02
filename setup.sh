#!/bin/bash
#
# Setup script for MEwebserverMGTscripts
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Setting up MEwebserverMGTscripts..."
echo "=================================="

# Create virtual environment if it doesn't exist
if [ ! -d "venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv venv
else
    echo "Virtual environment already exists."
fi

# Activate and install dependencies
echo "Installing dependencies..."
source venv/bin/activate
pip install -q --upgrade pip
pip install -q -r requirements.txt

# Make scripts executable
chmod +x *.py 2>/dev/null || true

# Check for config.json
if [ ! -f "config.json" ]; then
    if [ -f "config.json.example" ]; then
        echo ""
        echo "NOTE: config.json not found."
        echo "Copy config.json.example to config.json and add your credentials:"
        echo "  cp config.json.example config.json"
        echo "  nano config.json"
    fi
else
    echo "config.json found."
fi

echo ""
echo "Setup complete!"
echo ""
echo "Usage:"
echo "  source venv/bin/activate"
echo "  ./get_web_aliases.py"
echo "  ./switch_to_fallback.py"
echo "  ./switch_to_live.py"
