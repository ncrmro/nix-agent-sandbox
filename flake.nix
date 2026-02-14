{
  description = "OS-level bubblewrap sandbox for AI coding agents via Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    llm-agents.url = "github:numtide/llm-agents.nix";
  };

  outputs = { self, nixpkgs, llm-agents }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs supportedSystems f;

      mkPkgs = system: import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [
          llm-agents.overlays.default
          self.overlays.default
        ];
      };

      # Default GitHub token path (agenix convention on NixOS).
      # Override per-agent via the githubTokenPath parameter.
      defaultGithubTokenPath = "/run/agenix/github-agents-token";

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

      # ── Direct bubblewrap wrapper ─────────────────────────────
      # Minimal sandbox without FHS environment or ldconfig.
      # Much simpler than nix-bwrapper - just what CLI agents need.
      mkAgentWrapper = {
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
          # Build PATH from addPkgs binaries
          pathEntries = map (p: "${p}/bin") addPkgs;
          pathString = pkgs.lib.concatStringsSep ":" pathEntries;

          # The main package binary path
          mainBin = "${package}/bin";

          # Short name for symlink (e.g., "claude-code" -> "claude")
          shortName = builtins.head (pkgs.lib.splitString "-" package.pname);

          wrapperScript = pkgs.writeShellScript "agent-sandbox" ''
            set -euo pipefail

            # ── Resolve symlinks for NixOS ──────────────────────────
            # NixOS uses symlinks for /etc/resolv.conf that break inside bwrap
            _RESOLV=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)

            # NixOS SSL certs are symlinks through /etc/static to /nix/store
            # Resolve to the actual Nix store path so they work inside the sandbox
            _SSL_CERT_FILE=$(readlink -f /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo /etc/ssl/certs/ca-certificates.crt)
            _SSL_CERT_DIR=$(dirname "$_SSL_CERT_FILE")

            # ── GitHub token ────────────────────────────────────────
            _GH_TOKEN=""
            ${pkgs.lib.optionalString (githubTokenPath != null) ''
              if [ -r "${githubTokenPath}" ]; then
                _GH_TOKEN=$(cat "${githubTokenPath}")
              fi
            ''}

            # ── Git worktree support ────────────────────────────────
            # In a worktree, $PWD/.git is a file pointing to the parent
            # repo's .git/worktrees/<name>/ directory. Detect this and
            # expose the parent .git/ so git operations work inside bwrap.
            _GIT_PARENT_ARGS=""
            if [ -f "$PWD/.git" ]; then
              _gitdir_line=$(head -1 "$PWD/.git")
              _gitdir_path="''${_gitdir_line#gitdir: }"
              if [ "$_gitdir_path" != "$_gitdir_line" ] && [ -n "$_gitdir_path" ]; then
                # Handle relative gitdir paths
                if [ "''${_gitdir_path#/}" = "$_gitdir_path" ]; then
                  _gitdir_path="$(cd "$PWD" && cd "$_gitdir_path" && pwd)"
                fi
                # Resolve parent .git/ via commondir (canonical) or fallback
                _GIT_PARENT_DIR=""
                if [ -f "$_gitdir_path/commondir" ]; then
                  _commondir=$(cat "$_gitdir_path/commondir")
                  _GIT_PARENT_DIR="$(cd "$_gitdir_path" && cd "$_commondir" && pwd)"
                else
                  _GIT_PARENT_DIR="$(cd "$_gitdir_path/../.." && pwd)"
                fi
                # Security: verify it looks like a .git directory
                if [ -f "$_GIT_PARENT_DIR/HEAD" ] && [ -d "$_GIT_PARENT_DIR/objects" ]; then
                  _GIT_PARENT_ARGS="--bind $_GIT_PARENT_DIR $_GIT_PARENT_DIR"
                fi
              fi
            fi

            # ── Build optional bind mounts ──────────────────────────
            _OPTIONAL_BINDS=""

            # ~/.claude.json (file, not directory)
            if [ -f "$HOME/.claude.json" ]; then
              _OPTIONAL_BINDS="$_OPTIONAL_BINDS --bind $HOME/.claude.json $HOME/.claude.json"
            fi

            # Extra read paths
            ${pkgs.lib.concatMapStringsSep "\n" (path: ''
              _expanded="${path}"
              _expanded="''${_expanded//\$HOME/$HOME}"
              _expanded="''${_expanded//\$PWD/$PWD}"
              if [ -e "$_expanded" ]; then
                _OPTIONAL_BINDS="$_OPTIONAL_BINDS --ro-bind $_expanded $_expanded"
              fi
            '') extraReadPaths}

            # Extra read-write paths
            ${pkgs.lib.concatMapStringsSep "\n" (path: ''
              _expanded="${path}"
              _expanded="''${_expanded//\$HOME/$HOME}"
              _expanded="''${_expanded//\$PWD/$PWD}"
              if [ -e "$_expanded" ]; then
                _OPTIONAL_BINDS="$_OPTIONAL_BINDS --bind $_expanded $_expanded"
              fi
            '') extraReadWritePaths}

            # Standard optional paths (create binds only if they exist)
            for _path in \
              "$HOME/.claude" \
              "$HOME/.config/claude-code" \
              "$HOME/.config/git" \
              "$HOME/.gemini" \
              "$HOME/.codex" \
              "$HOME/.npm" \
              "$HOME/.local/share/pnpm/store"
            do
              if [ -e "$_path" ]; then
                _OPTIONAL_BINDS="$_OPTIONAL_BINDS --bind $_path $_path"
              fi
            done

            # SSH and gitconfig (read-only)
            for _path in "$HOME/.ssh" "$HOME/.gitconfig"; do
              if [ -e "$_path" ]; then
                _OPTIONAL_BINDS="$_OPTIONAL_BINDS --ro-bind $_path $_path"
              fi
            done

            # SSL certificates (read-only, try common locations)
            for _path in /etc/ssl /etc/pki/tls; do
              if [ -d "$_path" ]; then
                _OPTIONAL_BINDS="$_OPTIONAL_BINDS --ro-bind $_path $_path"
              fi
            done

            # ── GitHub token env vars ───────────────────────────────
            _GH_ENV_ARGS=""
            ${pkgs.lib.optionalString (githubTokenPath != null) ''
              if [ -n "$_GH_TOKEN" ]; then
                _GH_ENV_ARGS="--setenv GH_TOKEN $_GH_TOKEN --setenv GITHUB_TOKEN $_GH_TOKEN"
              fi
            ''}

            # ── Custom environment variables ────────────────────────
            _CUSTOM_ENV_ARGS=""
            ${pkgs.lib.concatStringsSep "\n" (
              pkgs.lib.mapAttrsToList (name: value: ''
                _CUSTOM_ENV_ARGS="$_CUSTOM_ENV_ARGS --setenv ${name} ${toString value}"
              '') env
            )}

            # ── Execute in sandbox ──────────────────────────────────
            exec ${pkgs.bubblewrap}/bin/bwrap \
              --dev /dev \
              --proc /proc \
              --tmpfs /tmp \
              --tmpfs "$HOME" \
              --ro-bind /nix/store /nix/store \
              --ro-bind "$_RESOLV" /etc/resolv.conf \
              --ro-bind /etc/passwd /etc/passwd \
              --ro-bind /etc/group /etc/group \
              --ro-bind /etc/hosts /etc/hosts \
              --bind "$PWD" "$PWD" \
              $_GIT_PARENT_ARGS \
              $_OPTIONAL_BINDS \
              --chdir "$PWD" \
              --die-with-parent \
              --unshare-pid \
              --setenv PATH "${mainBin}:${pathString}" \
              --setenv HOME "$HOME" \
              --setenv TERM "''${TERM:-xterm-256color}" \
              --setenv SSL_CERT_FILE "$_SSL_CERT_FILE" \
              --setenv SSL_CERT_DIR "$_SSL_CERT_DIR" \
              $_GH_ENV_ARGS \
              $_CUSTOM_ENV_ARGS \
              ${runScript} "$@"
          '';
        in pkgs.runCommand "${package.pname}-sandbox" {
          meta = package.meta or {} // {
            mainProgram = package.pname;
          };
        } ''
          mkdir -p $out/bin
          ln -s ${wrapperScript} $out/bin/${package.pname}
          ${pkgs.lib.optionalString (shortName != package.pname) ''
            ln -s ${wrapperScript} $out/bin/${shortName}
          ''}
        '';

    in {

      # ── Library function ──────────────────────────────────────
      # Wrap any package in the agent sandbox. Use this to sandbox
      # agents that aren't pre-packaged below.
      lib.mkAgentSandbox = mkAgentWrapper;

      # ── Overlay ───────────────────────────────────────────────
      # Adds sandboxed agent packages to pkgs.
      # Each agent runs in yolo mode since the sandbox provides OS-level isolation.
      overlays.default = final: prev: {
        claude-code-sandbox = mkAgentWrapper {
          pkgs = final;
          package = final.llm-agents.claude-code;
          runScript = "claude --dangerously-skip-permissions";
          addPkgs = defaultAddPkgs final;
        };

        gemini-cli-sandbox = mkAgentWrapper {
          pkgs = final;
          package = final.llm-agents.gemini-cli;
          runScript = "gemini --yolo";
          addPkgs = defaultAddPkgs final;
        };

        codex-sandbox = mkAgentWrapper {
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
          in mkAgentWrapper {
            pkgs = pkgs;
            package = testPkg;
            runScript = "security-test";
            addPkgs = with pkgs; [ coreutils bash curl gh git openssh ];
          };
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
