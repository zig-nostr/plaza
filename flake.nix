{
  description = "Plaza";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:

      let
        pkgs = import nixpkgs {
          inherit system;
        };

        zigDeps = pkgs.callPackage ./deps.nix { };
      in
      {
        packages.default = pkgs.stdenv.mkDerivation {
          pname = "plaza";
          version = "0.2.7";

src = pkgs.fetchFromGitHub {
  owner = "zig-nostr";
  repo = "plaza";
  rev = "v0.2.7";
  hash = "sha256-J5yPmpjpagxvr3RjRQ0DimjKY5TJC3gVntTFOiYx0Gw=";
};

          nativeBuildInputs = with pkgs; [
            zig
            pkg-config
          ];

          buildInputs = with pkgs; [
            gtk4
          ];

          # <-- magic happens here
          ZIG_GLOBAL_CACHE_DIR = "${zigDeps}";

          buildPhase = ''
            runHook preBuild

            zig build \
              --system ${zigDeps}

            runHook postBuild
          '';

          installPhase = ''
            mkdir -p $out/bin
            cp zig-out/bin/plaza $out/bin/
          '';
        };

        apps.default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/plaza";
        };
      });
}
