{
  description = "cloud-infra MCP server for Claude Code — containerized with debian-slim";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-24.11";
  };

  outputs = { self, nixpkgs }: let
    forAllSystems = nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ];

    config = {
      container_name = "cloud-infra-mcp";
      image = "cloud-infra-mcp:latest";
    };

    # podman-compose.yml — stdio MCP server with host volume mounts (runs in Podman on Termux)
    mkDockerCompose = pkgs: pkgs.writeText "podman-compose.yml" ''
      services:
        mcp-server:
          build: .
          container_name: ${config.container_name}
          image: ${config.image}
          stdin_open: true
          environment:
            - HOME=''${HOME}
          volumes:
            - ''${HOME}/git:''${HOME}/git:ro
            - ''${HOME}/.ssh:''${HOME}/.ssh:ro
    '';

  in {
    packages = forAllSystems (system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      default = pkgs.runCommand "mcp-server-skills" {} ''
        mkdir -p $out/src/tools $out/src/utils $out/src/resources $out/src/prompts
        mkdir -p $out/skills/official $out/skills/community

        # Container files (Podman on Termux)
        cp ${mkDockerCompose pkgs} $out/podman-compose.yml
        cp ${./Dockerfile} $out/Dockerfile

        # TypeScript source — root files
        cp ${./index.ts} $out/src/index.ts
        cp ${./types.ts} $out/src/types.ts
        cp ${./config.ts} $out/src/config.ts

        # TypeScript source — tools/
        for f in ${./tools}/*.ts; do
          cp "$f" "$out/src/tools/$(basename "$f")"
        done

        # TypeScript source — utils/
        for f in ${./utils}/*.ts; do
          cp "$f" "$out/src/utils/$(basename "$f")"
        done

        # TypeScript source — resources/ and prompts/
        cp ${./resources/index.ts} $out/src/resources/index.ts
        cp ${./prompts/index.ts} $out/src/prompts/index.ts

        # Skill files — reference docs only (SKILL.md content migrated to MCP prompts)
        cp ${./skills/skills.md} $out/skills/skills.md
        cp ${./skills/skills_claude.md} $out/skills/skills_claude.md
        cp ${./skills/skills_front.md} $out/skills/skills_front.md
        cp ${./skills/skills_claude_front.md} $out/skills/skills_claude_front.md

        # Skill files — community + official templates (senior/junior removed — migrated to MCP prompts)
        for f in ${./skills/official}/*; do
          cp "$f" "$out/skills/official/$(basename "$f")"
        done
        for f in ${./skills/community}/*; do
          cp "$f" "$out/skills/community/$(basename "$f")"
        done
      '';
    });
  };
}
