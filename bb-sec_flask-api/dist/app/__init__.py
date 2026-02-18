"""
Cloud Dashboard Flask Server
API backend for cloud infrastructure monitoring and management
"""
import os
import re
from flask import Flask
from flask_cors import CORS
from flasgger import Swagger


def create_app():
    """Application factory."""
    app = Flask(__name__, template_folder='../templates')
    raw_origins = os.environ.get('CORS_ORIGINS', '*').split(',')
    # Convert wildcard patterns (e.g. http://localhost:*) to compiled regex
    allowed_origins = []
    for o in raw_origins:
        if '*' in o and o != '*':
            allowed_origins.append(re.compile(o.replace('.', r'\.').replace('*', '.*')))
        else:
            allowed_origins.append(o)
    CORS(app, origins=allowed_origins, supports_credentials=True)

    # Load config
    app.config.from_mapping(
        SECRET_KEY=os.environ.get('JWT_SECRET_KEY', 'dev-key-change-in-production'),
        JSON_CONFIG_PATH=os.environ.get('CLOUD_CONFIG_PATH', '/opt/cloud-dashboard/cloud-infrastructure.json'),
    )

    # Register blueprints
    from app.api.routes import api_bp
    from app.api.web import web_bp
    from app.api.auth import auth_bp
    from app.api.admin import admin_bp
    from app.api.c3 import c3_bp
    from app.api.alerts import alerts_bp
    from app.api.cloudflare import cloudflare_bp

    app.register_blueprint(api_bp, url_prefix='/api')
    app.register_blueprint(auth_bp, url_prefix='/api/auth')
    app.register_blueprint(admin_bp, url_prefix='/api/admin')
    app.register_blueprint(c3_bp, url_prefix='/api/c3')
    app.register_blueprint(alerts_bp, url_prefix='/api/alerts')
    app.register_blueprint(cloudflare_bp, url_prefix='/api/cloudflare')
    app.register_blueprint(web_bp)  # Serves at / for HTML dashboard

    # Initialize Swagger (auto-generates OpenAPI spec from docstrings)
    swagger_template = {
        "info": {
            "title": "Cloud Dashboard API",
            "version": "1.0.0",
            "description": "REST API for cloud infrastructure monitoring & management"
        },
        "securityDefinitions": {
            "Bearer": {"type": "apiKey", "name": "Authorization", "in": "header"}
        }
    }
    swagger_config = {
        "specs_route": "/apidocs/",
        "swagger_ui": False,
        "specs": [{"endpoint": "apispec", "route": "/apispec.json"}],
        "headers": []
    }
    Swagger(app, template=swagger_template, config=swagger_config)

    return app
