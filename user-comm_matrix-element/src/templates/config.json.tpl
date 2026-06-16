{
  "default_server_config": {
    "m.homeserver": {
      "base_url": "@HOMESERVER_URL@",
      "server_name": "@SERVER_NAME@"
    }
  },
  "brand": "Matrix",
  "default_country_code": "ES",
  "disable_guests": true,
  "disable_3pid_login": true,
  "default_theme": "dark",
  "room_directory": {
    "servers": ["@SERVER_NAME@"]
  },
  "setting_defaults": {
    "UIFeature.registration": false
  }
}
