{
  description = "OS-level bubblewrap sandbox for AI coding agents via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-bwrapper.url = "github:Naxdy/nix-bwrapper";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, nix-bwrapper, llm-agents }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [
          nix-bwrapper.overlays.default
          llm-agents.overlays.default
          self.overlays.default
        ];
      };

      # Default GitHub token path (agenix convention on NixOS).
      # Override per-agent via the githubTokenPath parameter.
      defaultGithubTokenPath = "/run/agenix/github-agents-token";

      # ── Shared sandbox config ──────────────────────────────────
      # Headless CLI defaults: no desktop, no audio, no display.
      # Agent-agnostic — works for any CLI tool.
      mkCliSandboxConfig = pkgs: {
        extraReadPaths ? [],
        extraReadWritePaths ? [],
        githubTokenPath ? defaultGithubTokenPath,
      }: {
        mounts = {
          # Override desktop-oriented defaults (fonts, icons, themes).
          # /etc/ssl/certs, /etc/resolv.conf, /etc/hosts are provided
          # by the FHS rootfs via /.host-etc symlinks.
          read = pkgs.lib.mkForce ([
            "/nix/store"                  # Nix store (for symlink resolution, e.g. Home Manager configs)
            "$HOME/.gitconfig"            # git user config (name, email, aliases)
            "$HOME/.ssh"                  # SSH keys for git operations
          ]
            ++ extraReadPaths
            ++ pkgs.lib.optional (githubTokenPath != null) githubTokenPath
          );

          readWrite = pkgs.lib.mkForce ([
            "$PWD"                          # current project directory
            "$HOME/.claude"                 # claude auth + config
            "$HOME/.config/claude-code"     # claude additional config
            "$HOME/.config/git"             # git XDG config (needs write for credential helpers)
            "$HOME/.gemini"                 # gemini auth + config
            "$HOME/.codex"                  # codex auth + config
            "$HOME/.local/share/pnpm/store" # pnpm content-addressable store
            "$HOME/.npm"                    # npm cache
          ] ++ extraReadWritePaths);

          sandbox = pkgs.lib.mkForce [];
        };

        fhsenv.skipExtraInstallCmds = true;
        # mkBwrapper names the output bin/<pname> (e.g. bin/claude-code)
        # but agents often expect the short name (e.g. bin/claude).
        # Create a symlink so both names work and nix run finds mainProgram.
        fhsenv.extraInstallCmds = ''
          for bin in $out/bin/*; do
            name="$(basename "$bin")"
            # If pname has a hyphenated suffix, symlink the short form
            short="''${name%%-*}"
            if [ "$short" != "$name" ] && [ ! -e "$out/bin/$short" ]; then
              ln -s "$bin" "$out/bin/$short"
            fi
          done
        '';

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
        ''
        + pkgs.lib.optionalString (githubTokenPath != null) ''
          # Read GitHub token at runtime (before bwrap clears the env).
          # Passed into the sandbox via --setenv in additionalArgs below.
          _GH_TOKEN=""
          if [ -r "${githubTokenPath}" ]; then
            _GH_TOKEN=$(cat "${githubTokenPath}")
          fi
        ''
        + ''
          # ── Git worktree support ──────────────────────────────────
          # In a worktree, $PWD/.git is a file pointing to the parent
          # repo's .git/worktrees/<name>/ directory. Detect this and
          # expose the parent .git/ so git operations work inside bwrap.
          _GIT_PARENT_DIR=""
          if [ -f "$PWD/.git" ]; then
            _gitdir_line=$(head -1 "$PWD/.git")
            _gitdir_path="''${_gitdir_line#gitdir: }"
            if [ "$_gitdir_path" != "$_gitdir_line" ] && [ -n "$_gitdir_path" ]; then
              # Handle relative gitdir paths
              if [ "''${_gitdir_path#/}" = "$_gitdir_path" ]; then
                _gitdir_path="$(cd "$PWD" && cd "$_gitdir_path" && pwd)"
              fi
              # Resolve parent .git/ via commondir (canonical) or fallback
              if [ -f "$_gitdir_path/commondir" ]; then
                _commondir=$(cat "$_gitdir_path/commondir")
                _GIT_PARENT_DIR="$(cd "$_gitdir_path" && cd "$_commondir" && pwd)"
              else
                _GIT_PARENT_DIR="$(cd "$_gitdir_path/../.." && pwd)"
              fi
              # Security: verify it looks like a .git directory
              if [ ! -f "$_GIT_PARENT_DIR/HEAD" ] || [ ! -d "$_GIT_PARENT_DIR/objects" ]; then
                _GIT_PARENT_DIR=""
              fi
            fi
          fi
        '';
        fhsenv.bwrap.additionalArgs = [
          ''--ro-bind "$_RESOLV_CONF_REAL" /etc/resolv.conf''
          # ~/.claude.json is a file, not a directory — bind-try avoids
          # mkdir errors from the FHS wrapper's readWrite mount handler.
          ''--bind-try "$HOME/.claude.json" "$HOME/.claude.json"''
          # Git worktree: mount parent .git/ directory (read-write for commits).
          # --bind-try is a no-op when _GIT_PARENT_DIR is empty (non-worktree case).
          ''--bind-try "$_GIT_PARENT_DIR" "$_GIT_PARENT_DIR"''
        ]
        # Inject GH_TOKEN/GITHUB_TOKEN into the sandbox via --setenv
        # (bwrap uses --clearenv, so host env vars don't survive).
        ++ pkgs.lib.optionals (githubTokenPath != null) [
          ''--setenv GH_TOKEN "$_GH_TOKEN"''
          ''--setenv GITHUB_TOKEN "$_GH_TOKEN"''
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
        openssh
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
        githubTokenPath ? defaultGithubTokenPath,
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
      # Each agent runs in yolo mode since the sandbox provides OS-level isolation.
      overlays.default = final: prev: {
        claude-code-sandbox = self.lib.mkAgentSandbox {
          pkgs = final;
          package = final.llm-agents.claude-code;
          runScript = "claude --dangerously-skip-permissions";
          addPkgs = defaultAddPkgs final;
        };

        gemini-cli-sandbox = self.lib.mkAgentSandbox {
          pkgs = final;
          package = final.llm-agents.gemini-cli;
          runScript = "gemini --yolo";
          addPkgs = defaultAddPkgs final;
        };

        codex-sandbox = self.lib.mkAgentSandbox {
          pkgs = final;
          package = final.llm-agents.codex;
          runScript = "codex --yolo";
          addPkgs = defaultAddPkgs final;
        };
      };

      # ── Pre-built packages ────────────────────────────────────
      packages = forAllSystems (system:
        let pkgs = mkPkgs system;
        in {
          # ── Claude Code ────────────────────────────────────────
          # Sandboxed Claude Code (bubblewrap-wrapped)
          claude-code = pkgs.claude-code-sandbox;
          # Unwrapped Claude Code (no sandbox, direct binary)
          claude-code-unwrapped = pkgs.llm-agents.claude-code;

          # ── Gemini CLI ─────────────────────────────────────────
          # Sandboxed Gemini CLI (bubblewrap-wrapped)
          gemini-cli = pkgs.gemini-cli-sandbox;
          gemini = pkgs.gemini-cli-sandbox;  # alias
          # Unwrapped Gemini CLI (no sandbox, direct binary)
          gemini-cli-unwrapped = pkgs.llm-agents.gemini-cli;

          # ── OpenAI Codex ───────────────────────────────────────
          # Sandboxed Codex (bubblewrap-wrapped)
          codex = pkgs.codex-sandbox;
          # Unwrapped Codex (no sandbox, direct binary)
          codex-unwrapped = pkgs.llm-agents.codex;

          # Default package is the sandboxed Claude Code
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
          # All agents sandboxed
          default = pkgs.mkShell {
            packages = [
              pkgs.claude-code-sandbox
              pkgs.gemini-cli-sandbox
              pkgs.codex-sandbox
            ];
          };

          # All agents unwrapped (no sandbox)
          unwrapped = pkgs.mkShell {
            packages = [
              pkgs.llm-agents.claude-code
              pkgs.llm-agents.gemini-cli
              pkgs.llm-agents.codex
            ];
          };

          # Individual agent shells
          claude = pkgs.mkShell { packages = [ pkgs.claude-code-sandbox ]; };
          gemini = pkgs.mkShell { packages = [ pkgs.gemini-cli-sandbox ]; };
          codex = pkgs.mkShell { packages = [ pkgs.codex-sandbox ]; };
        }
      );
    };
}
