{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    flake-parts.url = "github:hercules-ci/flake-parts";
    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    git-hooks.url = "github:cachix/git-hooks.nix";
  };

  outputs = {flake-parts, ...} @ inputs:
    flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [inputs.git-hooks.flakeModule];

      systems = ["x86_64-linux" "aarch64-darwin"];

      flake.nixosModules.default = {
        config,
        lib,
        pkgs,
        inputs,
        ...
      }: let
        cfg = config.services.daily-stoic;
        package = inputs.daily-stoic.packages.${pkgs.system}.default;
        setupScript = pkgs.writeShellScript "daily-stoic-setup" ''
          set -e
          ${package}/bin/migrate
        '';
      in {
        options.services.daily-stoic = {
          enable = lib.mkEnableOption "daily-stoic";
          port = lib.mkOption {
            type = lib.types.port;
            default = 3060;
          };
          baseUrl = lib.mkOption {
            type = lib.types.str;
            default = "";
            description = "Base URL. If empty, BASE_URL must be set via environmentFile.";
          };
          environmentFile = lib.mkOption {
            type = lib.types.path;
            description = "Path to file containing RESEND_API_KEY and RESEND_EMAIL";
          };
        };

        config = lib.mkIf cfg.enable {
          users = {
            users.daily-stoic = {
              isSystemUser = true;
              group = "daily-stoic";
            };
            groups.daily-stoic = {};
          };

          systemd.services.daily-stoic = {
            description = "Daily Stoic";
            wantedBy = ["multi-user.target"];
            after = ["network.target"];
            serviceConfig = {
              ExecStartPre = "${setupScript}";
              ExecStart = "${package}/bin/daily-stoic";
              EnvironmentFile = cfg.environmentFile;
              Environment =
                [
                  "ADDRESS=127.0.0.1:${toString cfg.port}"
                  "DATABASE_URL=sqlite:///var/lib/daily-stoic/stoic.db"
                  "DATABASE_JSON_PATH=/var/lib/daily-stoic/database.json"
                ]
                ++ lib.optional (cfg.baseUrl != "") "BASE_URL=${cfg.baseUrl}";
              StateDirectory = "daily-stoic";
              WorkingDirectory = "/var/lib/daily-stoic";
              User = "daily-stoic";
              Group = "daily-stoic";
              Restart = "on-failure";
              RestartSec = "5s";
            };
          };
        };
      };

      perSystem = {system, ...}: let
        pkgs = import inputs.nixpkgs {
          inherit system;
          overlays = [inputs.rust-overlay.overlays.default];
        };
        rustToolchain = pkgs.rust-bin.stable.latest.default;
        rustPlatform = pkgs.makeRustPlatform {
          cargo = rustToolchain;
          rustc = rustToolchain;
        };
      in {
        packages.default = rustPlatform.buildRustPackage {
          pname = "daily-stoic";
          version = (fromTOML (builtins.readFile ./Cargo.toml)).package.version;
          src = ./.;
          SQLX_OFFLINE = "true";
          cargoLock = {
            lockFile = ./Cargo.lock;
          };
          nativeBuildInputs = [pkgs.pkg-config];
          buildInputs = [pkgs.openssl];
          release = true;
          doCheck = false;
          postInstall = ''
            mkdir -p $out/share/daily-stoic
            cp -r $src/migrations $out/share/daily-stoic/
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            rustToolchain
            rust-analyzer
            cargo-watch
            sqlite
            sqlx-cli
            openssl.dev
            pkg-config
          ];
          RUST_BACKTRACE = 1;
          shellHook = ''
            echo "📚 Stay Stoic... and memory safe."
            echo "🦀 $(rustc --version)"
          '';
        };

        pre-commit = {
          check.enable = true;
          settings.hooks = {
            rustfmt.enable = true;
            clippy = {
              enable = true;
              settings.offline = false;
            };
          };
        };
      };
    };
}
