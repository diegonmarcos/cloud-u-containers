# ╔══════════════════════════════════════════════════════════════════╗
# ║ Template index — import this to get all templates                ║
# ║ Usage: templates = import ../../_shared/templates docker;        ║
# ║                                                                  ║
# ║ Then:  templates.app { name = "foo"; image = "..."; ... }       ║
# ║        templates.appDb { name = "bar"; image = "..."; ... }     ║
# ║        templates.buildApp { name = "baz"; ... }                  ║
# ╚══════════════════════════════════════════════════════════════════╝

docker:

{
  app      = import ./app.nix docker;
  appDb    = import ./app-db.nix docker;
  buildApp = import ./build-app.nix docker;
}
