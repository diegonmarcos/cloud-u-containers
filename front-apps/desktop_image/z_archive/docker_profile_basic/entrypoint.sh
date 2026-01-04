#!/bin/bash

# Start VNC server
vncserver :1 -geometry 1920x1080 -depth 24

# Keep container running
tail -f /dev/null
