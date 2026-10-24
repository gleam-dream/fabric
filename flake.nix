{
  description = "Development environment for fabric";

  inputs = {
    design-layer.url = "github:lostbean/design-layer/main";
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      design-layer,
      nixpkgs,
      flake-utils,
      treefmt-nix,
      ...
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        treefmtEval = treefmt-nix.lib.evalModule pkgs {
          projectRootFile = "flake.nix";
          settings.global.excludes = [
            "**/*.pdf"
            ".render/**"
            "**/.render/**"
            "build/**"
            ".artifacts/**"
            # Captured upstream/legacy bytes and frozen datasets are evidence.
            "test/oracle/**"
            "test/fixtures/records/**"
            "test/fixtures/llm/**"
            "docs/evidence/**"
            "consumers/writing/fixtures/**"
          ];
          programs.gleam.enable = true;
          programs.nixfmt.enable = true;
          programs.prettier.enable = true;
          # Authored Python and shell tooling shares the local/CI formatter.
          programs.ruff.format = true;
          programs.shfmt.enable = true;
          settings.formatter.shfmt.options = [
            "-i"
            "2"
          ];
        };
      in
      {
        apps.snips = design-layer.apps.${system}.snips;
        apps.design-gate-check = design-layer.apps.${system}.check;
        apps.design-gate-render = design-layer.apps.${system}.render;
        apps.design-gate-context = design-layer.apps.${system}.context;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            git
            lefthook
            gleam
            beam29Packages.erlang
            beam29Packages.rebar3
            # Reproducible external-consumer and compiler-negative graph checks.
            python3
            ruff
            # integrations/fabric_postgres/scripts/test-postgres.sh starts a
            # throwaway cluster with these binaries.
            postgresql_16
          ];
        };

        formatter = treefmtEval.config.build.wrapper;

        checks.formatting = treefmtEval.config.build.check ./.;
      }
    );
}
