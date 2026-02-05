{
  description = "Front Suite - Self-hosted productivity applications";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};

    # Suite applications
    apps = {
      docs-etherpad = {
        name = "etherpad";
        description = "Collaborative document editor";
        port = 9001;
      };
      sheets-ethercalc = {
        name = "ethercalc";
        description = "Spreadsheet editor";
        port = 8765;
      };
      slides-revealjs = {
        name = "revealjs";
        description = "Presentation creator";
        port = 1948;
      };
      notes-affine = {
        name = "affine";
        description = "Workspace & notes";
        port = 3010;
      };
      photos-photoprism = {
        name = "photoprism";
        description = "AI-powered photo management";
        port = 2342;
      };
      files-filebrowser = {
        name = "filebrowser";
        description = "File manager";
        port = 8080;
      };
      powersheets-nocodb = {
        name = "nocodb";
        description = "Database/spreadsheet hybrid";
        port = 8080;
      };
      lgtm-grafana = {
        name = "grafana";
        description = "Observability stack";
        port = 3000;
      };
    };

    # Build package for each app
    mkAppPackage = name: cfg: pkgs.runCommand "front-suite-${name}" {} ''
      mkdir -p $out
      cp ${./${name}/docker-compose.yml} $out/docker-compose.yml
    '';

  in {
    packages.${system} = {
      # Individual app packages
      docs = mkAppPackage "docs-etherpad" apps.docs-etherpad;
      sheets = mkAppPackage "sheets-ethercalc" apps.sheets-ethercalc;
      slides = mkAppPackage "slides-revealjs" apps.slides-revealjs;
      notes = mkAppPackage "notes-affine" apps.notes-affine;
      photos = mkAppPackage "photos-photoprism" apps.photos-photoprism;
      files = mkAppPackage "files-filebrowser" apps.files-filebrowser;
      powersheets = mkAppPackage "powersheets-nocodb" apps.powersheets-nocodb;
      lgtm = mkAppPackage "lgtm-grafana" apps.lgtm-grafana;

      # All apps combined
      default = pkgs.runCommand "front-suite-all" {} ''
        mkdir -p $out
        ln -s ${self.packages.${system}.docs} $out/docs-etherpad
        ln -s ${self.packages.${system}.sheets} $out/sheets-ethercalc
        ln -s ${self.packages.${system}.slides} $out/slides-revealjs
        ln -s ${self.packages.${system}.notes} $out/notes-affine
        ln -s ${self.packages.${system}.photos} $out/photos-photoprism
        ln -s ${self.packages.${system}.files} $out/files-filebrowser
        ln -s ${self.packages.${system}.powersheets} $out/powersheets-nocodb
        ln -s ${self.packages.${system}.lgtm} $out/lgtm-grafana
      '';
    };

    devShells.${system}.default = pkgs.mkShell {
      packages = [ pkgs.docker-compose ];
    };
  };
}
