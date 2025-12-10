#!/bin/bash

FRONTEND_PATH="/home/jetson/Documents/media-mtx-camera/frontend/dashboard.html"
BACKEND_PATH="/home/jetson/Documents/media-mtx-camera/backend/main.go"

echo "=== Checking required services ==="

check_service() {
    SERVICE=$1
    systemctl is-active --quiet "$SERVICE"
    if [ $? -ne 0 ]; then
        echo "Service $SERVICE is NOT running. Starting it..."
        sudo systemctl start "$SERVICE"
        if [ $? -ne 0 ]; then
            echo "❌ Failed to start $SERVICE"
            exit 1
        fi
        echo "✅ $SERVICE started."
    else
        echo "✅ $SERVICE is already running."
    fi
}

check_service "mosquitto"
check_service "mediamtx"

echo ""
echo "=== Starting Go backend ==="

# Start backend in background
go run "$BACKEND_PATH" &
BACKEND_PID=$!

echo "Backend started with PID $BACKEND_PID"
echo ""

echo "=== Waiting 30 seconds before opening dashboard ==="

for i in {30..1}
do
    echo "Opening dashboard in $i seconds..."
    sleep 1
done

echo ""
echo "=== Opening frontend dashboard ==="
xdg-open "file://$FRONTEND_PATH" >/dev/null 2>&1 &

echo "Dashboard opened successfully."
echo ""
echo "=== All systems running ==="

wait $BACKEND_PID

