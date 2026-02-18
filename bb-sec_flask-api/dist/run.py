#!/usr/bin/env python3
"""
Cloud Dashboard Flask Server - Entry point

Exposes Flask app for gunicorn: gunicorn --bind 0.0.0.0:5000 run:app
"""
import os
import sys

# Add the script directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from app import create_app

# Create Flask app using factory (includes all blueprints)
app = create_app()

if __name__ == '__main__':
    debug = os.environ.get('FLASK_DEBUG', 'false').lower() == 'true'
    host = os.environ.get('FLASK_HOST', '0.0.0.0')
    port = int(os.environ.get('FLASK_PORT', 5000))
    app.run(host=host, port=port, debug=debug)
