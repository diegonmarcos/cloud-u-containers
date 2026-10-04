{
  description = "Unified Cloud Documentation Portal — dist layout v2 (flake as orchestrator)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    # ── Data sources (declarative JSON) ────────────────────────────
    buildJson = builtins.fromJSON (builtins.readFile ../build.json);
    container = builtins.fromJSON (builtins.readFile ./build-cloud-spec.json);

    engine = import ../../_shared/engine.nix;

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};

      # Build the mdbook documentation site.
      # Pages are auto-generated from _cloud-data-consolidated.json (symlinked as
      # cloud-data.json). One page per enabled service, grouped in SUMMARY.md.
      # The hand-written docs/SUMMARY.md is replaced entirely; docs/overview.md kept.
      site = pkgs.runCommand "cloud-spec-site" {
        nativeBuildInputs = [ pkgs.mdbook pkgs.jq pkgs.coreutils pkgs.bash ];
      } ''
        DATA=${./cloud-data.json}
        mkdir -p build/src/services

        # Static docs (overview prose, probe widget, config)
        cp ${./docs/overview.md} build/src/overview.md
        # mdbook additional-js paths resolve relative to the BOOK ROOT (the dir
        # holding book.toml = build/), not src/ — probe.js must sit beside
        # book.toml or mdbook aborts "Unable to copy /build/build/probe.js".
        cp ${./probe.js} build/probe.js
        cp ${./book.toml} build/book.toml

        # ── Generate per-service pages ─────────────────────────────
        while IFS= read -r entry; do
          key=$(printf '%s' "$entry" | jq -r '.key')
          desc=$(printf '%s' "$entry" | jq -r '.value.description // .key')
          vm=$(printf '%s' "$entry" | jq -r '.value.vm // "local"')
          cat=$(printf '%s' "$entry" | jq -r '.value.category // "-"')
          domain=$(printf '%s' "$entry" | jq -r '.value.dns // ""')
          upstream=$(printf '%s' "$entry" | jq -r '.value.upstream // ""')
          image=$(printf '%s' "$entry" | jq -r '.value.containers.app.image // ""')
          port=$(printf '%s' "$entry" | jq -r 'if .value.containers.app.port != null then (.value.containers.app.port | tostring) else "" end')
          hc=$(printf '%s' "$entry" | jq -r '.value.containers.app.healthcheck // ""')

          {
            printf '# %s\n\n' "$desc"
            printf '| Field | Value |\n'
            printf '|-------|-------|\n'
            printf '| **Key** | `%s` |\n' "$key"
            printf '| **VM** | `%s` |\n' "$vm"
            printf '| **Category** | `%s` |\n' "$cat"
            [ -n "$domain" ]   && printf '| **Domain** | `%s` |\n' "$domain"
            [ -n "$upstream" ] && printf '| **Upstream** | `%s` |\n' "$upstream"
            [ -n "$image" ]    && printf '| **Image** | `%s` |\n' "$image"
            [ -n "$port" ]     && printf '| **Port** | `%s` |\n' "$port"
            [ -n "$hc" ]       && printf '| **Healthcheck** | `%s` |\n' "$hc"
            printf '\n'
            if [ -n "$hc" ]; then
              printf '<div class="probe" data-svc="%s">Live probe: <span class="probe-status" id="probe-%s">checking…</span></div>\n\n' "$key" "$key"
            fi
          } > "build/src/services/$key.md"
        done < <(jq -c '.services | to_entries[] | select(.value.enabled != false)' "$DATA")

        # ── Generate SUMMARY.md grouped by category ────────────────
        {
          printf '# Summary\n\n'
          printf -- '- [Overview](./overview.md)\n\n'
          printf -- '---\n\n'

          for cat_pair in \
            "app:Applications" \
            "mic:Microservices" \
            "fin:Financial" \
            "agi:AI / AGI" \
            "cloud:Cloud Providers" \
            "sec:Security" \
            "obs:Observability" \
            "data:Data"; do
            cat_key=''${cat_pair%%:*}
            cat_label=''${cat_pair#*:}
            entries=$(jq -r --arg c "$cat_key" '
              .services | to_entries[] |
              select(.value.enabled != false and .value.category == $c) |
              "- [" + (.value.description // .key) + "](./services/" + .key + ".md)"
            ' "$DATA")
            if [ -n "$entries" ]; then
              printf '# %s\n\n%s\n\n' "$cat_label" "$entries"
            fi
          done
        } > build/src/SUMMARY.md

        cd build && mdbook build -d $out
      '';

      # Engine output (manifest.json, compose/, code/, configs/, assets/).
      baseDist = engine {
        inherit pkgs buildJson container;
        srcDir = ./.;
        templates = [];
        composeSpec = import ./compose.nix { inherit buildJson container; };
        title = buildJson.description;
      };

    in {
      # Wrap engine output, overlaying the built mdbook site at assets/site/
      # so compose.nix can mount ./assets/site:/srv:ro.
      default = pkgs.runCommand "${buildJson.name}-dist-v2" {
        passthru = { inherit (baseDist.passthru) manifest declaredArchs; };
      } ''
        mkdir -p $out
        cp -r ${baseDist}/. $out/
        chmod -R u+w $out
        mkdir -p $out/assets/site
        if [ -d ${site}/html ]; then
          cp -r ${site}/html/. $out/assets/site/
        else
          cp -r ${site}/. $out/assets/site/
        fi
      '';
    });
  };
}
