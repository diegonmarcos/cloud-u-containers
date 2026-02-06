"""
GitHub OAuth 2.0 Authentication for Cloud Dashboard
"""
import os
import secrets
import jwt
from datetime import datetime, timedelta, timezone
from functools import wraps
from flask import Blueprint, jsonify, request, redirect, current_app
import requests

auth_bp = Blueprint('auth', __name__)

# OAuth Configuration
GITHUB_CLIENT_ID = os.environ.get('GITHUB_CLIENT_ID')
GITHUB_CLIENT_SECRET = os.environ.get('GITHUB_CLIENT_SECRET')
JWT_SECRET_KEY = os.environ.get('JWT_SECRET_KEY', 'change-me-in-production')
JWT_EXPIRATION_HOURS = int(os.environ.get('JWT_EXPIRATION_HOURS', 24))
ALLOWED_GITHUB_USERS = os.environ.get('ALLOWED_GITHUB_USERS', '').split(',')
FRONTEND_URL = os.environ.get('FRONTEND_URL', 'https://cloud.diegonmarcos.com')

# GitHub OAuth URLs
GITHUB_AUTHORIZE_URL = 'https://github.com/login/oauth/authorize'
GITHUB_TOKEN_URL = 'https://github.com/login/oauth/access_token'
GITHUB_USER_URL = 'https://api.github.com/user'

# Store for OAuth state tokens (in production, use Redis)
_oauth_states = {}


def create_jwt_token(username: str) -> str:
    """Create a JWT token for an authenticated user."""
    payload = {
        'sub': username,
        'iat': datetime.now(timezone.utc),
        'exp': datetime.now(timezone.utc) + timedelta(hours=JWT_EXPIRATION_HOURS)
    }
    return jwt.encode(payload, JWT_SECRET_KEY, algorithm='HS256')


def decode_jwt_token(token: str) -> dict | None:
    """Decode and validate a JWT token."""
    try:
        payload = jwt.decode(token, JWT_SECRET_KEY, algorithms=['HS256'])
        return payload
    except jwt.ExpiredSignatureError:
        return None
    except jwt.InvalidTokenError:
        return None


def require_auth(f):
    """Decorator to require authentication for admin endpoints."""
    @wraps(f)
    def decorated(*args, **kwargs):
        auth_header = request.headers.get('Authorization')

        if not auth_header or not auth_header.startswith('Bearer '):
            return jsonify({'error': 'Missing or invalid authorization header'}), 401

        token = auth_header.split(' ')[1]
        payload = decode_jwt_token(token)

        if not payload:
            return jsonify({'error': 'Invalid or expired token'}), 401

        username = payload.get('sub')
        if username not in ALLOWED_GITHUB_USERS:
            return jsonify({'error': 'User not authorized for admin access'}), 403

        # Add user info to request context
        request.current_user = username
        return f(*args, **kwargs)

    return decorated


# =============================================================================
# OAuth Endpoints
# =============================================================================

@auth_bp.route('/github', methods=['GET'])
def github_login():
    """Initiate GitHub OAuth flow."""
    if not GITHUB_CLIENT_ID:
        return jsonify({'error': 'GitHub OAuth not configured'}), 500

    # Generate state token for CSRF protection
    state = secrets.token_urlsafe(32)
    _oauth_states[state] = datetime.now(timezone.utc)

    # Clean old states (older than 10 minutes)
    cutoff = datetime.now(timezone.utc) - timedelta(minutes=10)
    expired = [s for s, t in _oauth_states.items() if t < cutoff]
    for s in expired:
        del _oauth_states[s]

    # Build authorization URL
    params = {
        'client_id': GITHUB_CLIENT_ID,
        'redirect_uri': f'{FRONTEND_URL}/api/auth/callback',
        'scope': 'read:user',
        'state': state
    }
    auth_url = f"{GITHUB_AUTHORIZE_URL}?{'&'.join(f'{k}={v}' for k, v in params.items())}"

    return jsonify({'auth_url': auth_url, 'state': state})


@auth_bp.route('/github/redirect', methods=['GET'])
def github_redirect():
    """Redirect to GitHub OAuth (for browser-based flow)."""
    if not GITHUB_CLIENT_ID:
        return jsonify({'error': 'GitHub OAuth not configured'}), 500

    state = secrets.token_urlsafe(32)
    _oauth_states[state] = datetime.now(timezone.utc)

    params = {
        'client_id': GITHUB_CLIENT_ID,
        'redirect_uri': f'{FRONTEND_URL}/api/auth/callback',
        'scope': 'read:user',
        'state': state
    }
    auth_url = f"{GITHUB_AUTHORIZE_URL}?{'&'.join(f'{k}={v}' for k, v in params.items())}"

    return redirect(auth_url)


@auth_bp.route('/callback', methods=['GET'])
def github_callback():
    """Handle GitHub OAuth callback."""
    code = request.args.get('code')
    state = request.args.get('state')
    error = request.args.get('error')

    if error:
        return redirect(f'{FRONTEND_URL}?auth_error={error}')

    if not code or not state:
        return redirect(f'{FRONTEND_URL}?auth_error=missing_params')

    # Verify state token
    if state not in _oauth_states:
        return redirect(f'{FRONTEND_URL}?auth_error=invalid_state')

    del _oauth_states[state]

    # Exchange code for access token
    token_response = requests.post(
        GITHUB_TOKEN_URL,
        data={
            'client_id': GITHUB_CLIENT_ID,
            'client_secret': GITHUB_CLIENT_SECRET,
            'code': code,
            'redirect_uri': f'{FRONTEND_URL}/api/auth/callback'
        },
        headers={'Accept': 'application/json'}
    )

    if token_response.status_code != 200:
        return redirect(f'{FRONTEND_URL}?auth_error=token_exchange_failed')

    token_data = token_response.json()
    access_token = token_data.get('access_token')

    if not access_token:
        return redirect(f'{FRONTEND_URL}?auth_error=no_access_token')

    # Get user info from GitHub
    user_response = requests.get(
        GITHUB_USER_URL,
        headers={
            'Authorization': f'Bearer {access_token}',
            'Accept': 'application/json'
        }
    )

    if user_response.status_code != 200:
        return redirect(f'{FRONTEND_URL}?auth_error=user_fetch_failed')

    user_data = user_response.json()
    username = user_data.get('login')

    if not username:
        return redirect(f'{FRONTEND_URL}?auth_error=no_username')

    # Check if user is allowed
    if username not in ALLOWED_GITHUB_USERS:
        return redirect(f'{FRONTEND_URL}?auth_error=user_not_allowed')

    # Create JWT token
    jwt_token = create_jwt_token(username)

    # Redirect to frontend with token
    return redirect(f'{FRONTEND_URL}?token={jwt_token}&user={username}')


@auth_bp.route('/me', methods=['GET'])
@require_auth
def get_current_user():
    """Get current authenticated user info."""
    return jsonify({
        'username': request.current_user,
        'authorized': True
    })


@auth_bp.route('/logout', methods=['POST'])
@require_auth
def logout():
    """Logout (client should discard token)."""
    return jsonify({
        'status': 'ok',
        'message': 'Logged out successfully'
    })


@auth_bp.route('/verify', methods=['POST'])
def verify_token():
    """Verify if a token is valid."""
    data = request.get_json() or {}
    token = data.get('token')

    if not token:
        return jsonify({'valid': False, 'error': 'No token provided'}), 400

    payload = decode_jwt_token(token)

    if not payload:
        return jsonify({'valid': False, 'error': 'Invalid or expired token'})

    username = payload.get('sub')
    if username not in ALLOWED_GITHUB_USERS:
        return jsonify({'valid': False, 'error': 'User not authorized'})

    return jsonify({
        'valid': True,
        'username': username,
        'exp': payload.get('exp')
    })
