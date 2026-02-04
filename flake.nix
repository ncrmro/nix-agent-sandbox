{
  description = "OS-level bubblewrap sandbox for AI coding agents via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-bwrapper.url = "github:Naxdy/nix-bwrapper";
    claude-code.url = "github:sadjow/claude-code-nix";
  };

  outputs = { self, nixpkgs, nix-bwrapper, claude-code }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [
          nix-bwrapper.overlays.default
          claude-code.overlays.default
          self.overlays.default
        ];
      };

      # ── Shared sandbox config ──────────────────────────────────
      # Headless CLI defaults: no desktop, no audio, no display.
      # Agent-agnostic — works for any CLI tool.
      mkCliSandboxConfig = pkgs: {
        extraReadPaths ? [],
        extraReadWritePaths ? [],
        githubTokenPath ? null,
      }: {
        mounts = {
          # Override desktop-oriented defaults (fonts, icons, themes).
          # /etc/ssl/certs, /etc/resolv.conf, /etc/hosts are provided
          # by the FHS rootfs via /.host-etc symlinks.
          read = pkgs.lib.mkForce (
            extraReadPaths
            ++ pkgs.lib.optional (githubTokenPath != null) githubTokenPath
          );

          readWrite = pkgs.lib.mkForce ([
            "$PWD"                          # current project directory
            "$HOME/.claude"                 # claude auth + config
            "$HOME/.config/claude-code"     # claude additional config
            "$HOME/.gemini"                 # gemini auth + config
            "$HOME/.codex"                  # codex auth + config
          ] ++ extraReadWritePaths);

          sandbox = pkgs.lib.mkForce [];
        };

        fhsenv.skipExtraInstallCmds = true;

        sockets = {
          x11 = false;
          wayland = false;
          pulseaudio = false;
          pipewire = false;
          cups = false;
        };

        # ── NixOS DNS fix ─────────────────────────────────────
        # NixOS manages /etc/resolv.conf as a symlink chain that breaks
        # inside bwrap's --tmpfs /etc. Fix: resolve on the host side and
        # bind-mount the real file directly, skipping the FHS wrapper's
        # broken symlink.
        script.preCmds.stage3 = ''
          _RESOLV_CONF_REAL=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)
          etc_ignored+=("/etc/resolv.conf")
        '';
        fhsenv.bwrap.additionalArgs = [
          ''--ro-bind "$_RESOLV_CONF_REAL" /etc/resolv.conf''
          # ~/.claude.json is a file, not a directory — bind-try avoids
          # mkdir errors from the FHS wrapper's readWrite mount handler.
          ''--bind-try "$HOME/.claude.json" "$HOME/.claude.json"''
        ];
      };

      # ── Default toolchain for agents ──────────────────────────
      defaultAddPkgs = pkgs: with pkgs; [
        git
        ripgrep
        fd
        coreutils
        bash
        gnugrep
        gnused
        findutils
        curl
        gh
        nodejs_22
      ];
    in {

      # ── Library function ──────────────────────────────────────
      # Wrap any package in the agent sandbox. Use this to sandbox
      # agents that aren't pre-packaged below.
      lib.mkAgentSandbox = {
        pkgs,
        package,
        runScript,
        addPkgs ? defaultAddPkgs pkgs,
        env ? {},
        extraReadPaths ? [],
        extraReadWritePaths ? [],
        githubTokenPath ? null,
      }:
        let
          sandboxConfig = mkCliSandboxConfig pkgs {
            inherit extraReadPaths extraReadWritePaths githubTokenPath;
          };
        in pkgs.mkBwrapper (sandboxConfig // {
          app = {
            inherit package runScript addPkgs env;
          };
        });

      # ── Overlay ───────────────────────────────────────────────
      # Adds sandboxed agent packages to pkgs.
      overlays.default = final: prev: {
        claude-code-sandbox = self.lib.mkAgentSandbox {
          pkgs = final;
          package = final.claude-code;
          runScript = "claude";
          addPkgs = defaultAddPkgs final;
        };
      };

      # ── Pre-built packages ────────────────────────────────────
      packages = forAllSystems (system:
        let pkgs = mkPkgs system;
        in {
          # Sandboxed Claude Code (bubblewrap-wrapped)
          claude-code = pkgs.claude-code-sandbox;

          # Unwrapped Claude Code (no sandbox, direct binary)
          claude-code-unwrapped = pkgs.claude-code;

          # Default package is the sandboxed version
          default = pkgs.claude-code-sandbox;

          # Security test runner — validates sandbox isolation
          security-test = let
            testScript = pkgs.writeShellScriptBin "security-test" (builtins.readFile ./security-test.sh);
            testPkg = testScript // {
              pname = "security-test";
              version = "0.1.0";
              meta = testScript.meta or {} // { mainProgram = "security-test"; };
            };
            sandboxConfig = mkCliSandboxConfig pkgs {};
          in pkgs.mkBwrapper (sandboxConfig // {
            app = {
              package = testPkg;
              runScript = "security-test";
              addPkgs = with pkgs; [ coreutils bash curl gh git ];
            };
          });
        }
      );

      # ── Dev shell (example) ───────────────────────────────────
      devShells = forAllSystems (system:
        let pkgs = mkPkgs system;
        in {
          default = pkgs.mkShell {
            packages = [
              pkgs.claude-code-sandbox    # sandboxed
            ];
          };

          unwrapped = pkgs.mkShell {
            packages = [
              pkgs.claude-code            # unwrapped (no sandbox)
            ];
          };
        }
      );
    };
}
