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
        nix         # Allows agents to launch sub-agents via nix run
        util-linux  # Provides unshare + mount for nested sandbox scoping
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

          # Closure registration for nix DB initialization inside sandbox
          closureInfo = pkgs.closureInfo { rootPaths = addPkgs ++ [ package ]; };

          # Init script: runs as mapped root inside bwrap user namespace.
          # DB is already initialized by the wrapper (on the host).
          # Writes nix.conf and drops privileges before exec'ing the agent.
          initScript = pkgs.writeShellScript "init-nix" ''
            set -euo pipefail

            # Write nix.conf for single-user mode.
            mkdir -p /etc/nix
            cat > /etc/nix/nix.conf << NIXCONF
experimental-features = nix-command flakes
sandbox = false
NIXCONF

            # Create .links dir on overlay (nix expects it for deduplication)
            mkdir -p /nix/store/.links 2>/dev/null || true

            # Drop root and exec the agent
            exec ${pkgs.util-linux}/bin/unshare \
              --user --map-user="$__SANDBOX_ORIG_UID" --map-group="$__SANDBOX_ORIG_GID" -- "$@"
          '';

          wrapperScript = pkgs.writeShellScript "agent-sandbox" ''
            set -euo pipefail

            # ── Create persistent .nix directory ─────────────────────
            # Store paths and nix DB persist across sessions for fast startup.
            # .work is the overlayfs workdir (must be on same fs as upper).
            # Add .nix/ to your .gitignore.
            mkdir -p "$PWD/.nix/store" "$PWD/.nix/var" "$PWD/.nix/work"

            # ── Initialize nix DB on host (first run only) ────────────
            # Must happen BEFORE entering bwrap because nix-store --init
            # tries to chown /nix/store which fails on overlayfs mount points.
            # We use a temp store dir for --init (it creates the DB schema
            # in the state dir) and the real /nix/store for --load-db
            # (it registers closure paths that exist in the host store).
            if [ ! -f "$PWD/.nix/var/nix/db/db.sqlite" ]; then
              _tmpstore=$(mktemp -d)
              mkdir -p "$PWD/.nix/var/nix/db" "$PWD/.nix/var/nix/gcroots/per-user" \
                       "$PWD/.nix/var/nix/profiles/per-user" "$PWD/.nix/var/nix/temproots" \
                       "$PWD/.nix/var/nix/userpool" "$PWD/.nix/var/nix/daemon-socket"
              NIX_REMOTE=local NIX_STORE_DIR="$_tmpstore" NIX_STATE_DIR="$PWD/.nix/var" \
                ${pkgs.nix}/bin/nix-store --init 2>/dev/null || true
              rm -rf "$_tmpstore"
              # Register closure paths — the host /nix/store has all paths
              NIX_REMOTE=local NIX_STATE_DIR="$PWD/.nix/var" \
                ${pkgs.nix}/bin/nix-store --load-db < ${closureInfo}/registration
            fi

            # ── Nested sandbox detection ─────────────────────────────
            #
            # Problem: bubblewrap (bwrap) cannot nest inside another bwrap sandbox.
            # When bwrap runs pivot_root inside an outer bwrap namespace, it tries
            # to resolve paths like /oldroot/etc/passwd which don't exist in the
            # outer namespace's filesystem view. This is a known kernel-level
            # limitation (bubblewrap issues #164, #273, #543) with no workaround.
            #
            # Detection: The outer sandbox sets __NIX_AGENT_SANDBOXED=1 (see the
            # --setenv flags in the bwrap invocation below). If this variable is
            # present, we know we're already inside a bwrap sandbox.
            #
            # Solution: Instead of bwrap, use `unshare --mount` which creates a
            # new mount namespace from the current filesystem view WITHOUT
            # pivot_root. This avoids the /oldroot path resolution problem entirely.
            #
            # Scoping: Even though we can't use bwrap's full isolation, we still
            # want to restrict the inner agent to its own $PWD (e.g., a worktree)
            # rather than giving it access to the entire outer sandbox's $PWD.
            # We achieve this by:
            #   1. Making all mounts private (no propagation to parent namespace)
            #   2. Overlaying tmpfs on the outer sandbox's $PWD to hide it
            #   3. Re-bind-mounting just the inner agent's $PWD on top
            #
            # The outer sandbox's $PWD is recorded in __NIX_AGENT_SANDBOX_PWD so
            # we know what path to hide. Scoping only applies when the inner $PWD
            # is a subdirectory of the outer $PWD (typical worktree layout).
            #
            # If __NIX_AGENT_SANDBOX_PWD is unset or $PWD is not a sub-path,
            # we skip scoping and just exec the agent — safe default behavior.
            #
            if [ "''${__NIX_AGENT_SANDBOXED:-}" = "1" ]; then
              # Already inside a bwrap sandbox — cannot nest bwrap.
              #
              # Strategy: two-phase namespace setup.
              #
              # Phase 1 (outer unshare): --user --mount --map-root-user
              #   Creates user + mount namespace with UID mapped to root.
              #   Root is needed for mount(8) syscalls (tmpfs, bind mounts).
              #   We do all mount operations in this phase.
              #
              # Phase 2 (inner unshare): --user --map-user=<orig> --map-group=<orig>
              #   Creates a nested user namespace that remaps root back to the
              #   original UID/GID. This is required because some agents (e.g.,
              #   Claude Code) refuse to run as root for security reasons.
              #   The mount namespace from Phase 1 is inherited — mounts persist.
              #
              # UID/GID are passed via env vars to avoid quoting issues across
              # the multiple shell/Nix string nesting layers.
              export __SANDBOX_ORIG_UID=$(id -u)
              export __SANDBOX_ORIG_GID=$(id -g)
              export PATH="${mainBin}:${pathString}:$PATH"
              exec ${pkgs.util-linux}/bin/unshare --user --mount --map-root-user -- ${pkgs.bash}/bin/bash -c '
                # ── Phase 1: Mount operations (as mapped root) ────────

                # Privatize mount tree so our changes do not propagate
                ${pkgs.util-linux}/bin/mount --make-rprivate /

                # Scope inner agent to its own $PWD by hiding outer PWD.
                # The inner $PWD content must be saved to a temp mount point
                # BEFORE overlaying tmpfs, because it lives under the outer path.
                #
                # Example:
                #   Outer PWD = /home/user/vault
                #   Inner PWD = /home/user/vault/.repos/owner/repo
                #   Result: vault root is empty tmpfs, repo is accessible
                _OUTER_PWD="''${__NIX_AGENT_SANDBOX_PWD:-}"
                if [ -n "$_OUTER_PWD" ] && [ "$_OUTER_PWD" != "$PWD" ] && echo "$PWD" | grep -qF "$_OUTER_PWD/"; then
                  _SAVE=$(mktemp -d /tmp/.inner-pwd-save.XXXXXX)
                  ${pkgs.util-linux}/bin/mount --bind "$PWD" "$_SAVE"
                  ${pkgs.util-linux}/bin/mount -t tmpfs tmpfs "$_OUTER_PWD"
                  mkdir -p "$PWD"
                  ${pkgs.util-linux}/bin/mount --bind "$_SAVE" "$PWD"
                fi

                # ── Nix config (inherited persistent store from outer sandbox) ────
                # Write nix.conf so nix-command and flakes work
                mkdir -p /etc/nix
                cat > /etc/nix/nix.conf << NIXCONF
experimental-features = nix-command flakes
sandbox = false
NIXCONF

                # The persistent .nix/ is inherited from outer sandbox and already
                # initialized. Just verify DB exists (should always be true).
                if [ ! -f /nix/var/nix/db/db.sqlite ]; then
                  # Fallback: initialize if somehow missing
                  mkdir -p /nix/var/nix/db /nix/var/nix/gcroots/per-user \
                           /nix/var/nix/profiles/per-user /nix/var/nix/temproots \
                           /nix/var/nix/userpool /nix/var/nix/daemon-socket
                  ${pkgs.nix}/bin/nix-store --init
                  if [ -f /nix/.closure-registration ]; then
                    ${pkgs.nix}/bin/nix-store --load-db < /nix/.closure-registration
                  fi
                fi

                # Fix /nix ownership for privilege drop
                chown -R 0:0 /nix/store /nix/var 2>/dev/null || true

                # ── Phase 2: Drop root and execute agent ──────────────
                cd "$PWD"
                exec ${pkgs.util-linux}/bin/unshare \
                  --user --map-user="$__SANDBOX_ORIG_UID" --map-group="$__SANDBOX_ORIG_GID" -- \
                  '"${runScript}"' "$@"
              ' -- "$@"
            fi

            # ── Resolve symlinks for NixOS ──────────────────────────
            # NixOS uses symlinks for /etc/resolv.conf that break inside bwrap
            _RESOLV=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)

            # NixOS SSL certs are symlinks through /etc/static to /nix/store
            # Resolve to the actual Nix store path so they work inside the sandbox.
            # In nested sandboxes, the symlink may be dangling but SSL_CERT_FILE
            # is already set correctly by the outer sandbox — prefer it if valid.
            if [ -n "''${SSL_CERT_FILE:-}" ] && [ -r "$SSL_CERT_FILE" ]; then
              _SSL_CERT_FILE="$SSL_CERT_FILE"
            else
              _SSL_CERT_FILE=$(readlink -f /etc/ssl/certs/ca-certificates.crt 2>/dev/null || echo /etc/ssl/certs/ca-certificates.crt)
            fi
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

            # SSH directory (read-only)
            # If ~/.ssh/config is a symlink (Home Manager), SSH rejects it due to
            # "bad permissions" (sees lrwxrwxrwx). Set GIT_SSH_COMMAND to use the
            # resolved config path directly.
            _GIT_SSH_COMMAND=""
            if [ -d "$HOME/.ssh" ]; then
              _OPTIONAL_BINDS="$_OPTIONAL_BINDS --ro-bind $HOME/.ssh $HOME/.ssh"
              if [ -L "$HOME/.ssh/config" ]; then
                _ssh_config_resolved=$(readlink -f "$HOME/.ssh/config")
                if [ -f "$_ssh_config_resolved" ]; then
                  _GIT_SSH_COMMAND="ssh -F $_ssh_config_resolved"
                fi
              fi
            fi

            # gitconfig (read-only)
            if [ -e "$HOME/.gitconfig" ]; then
              _OPTIONAL_BINDS="$_OPTIONAL_BINDS --ro-bind $HOME/.gitconfig $HOME/.gitconfig"
            fi

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

            # ── Capture original UID/GID for privilege drop ─────────
            _ORIG_UID=$(id -u)
            _ORIG_GID=$(id -g)

            # ── Execute in sandbox ──────────────────────────────────
            # bwrap's --overlay mounts overlayfs natively:
            #   - Host /nix/store as lower layer (read-only source)
            #   - $PWD/.nix/store as upper layer (persistent writes)
            #   - $PWD/.nix/work as overlayfs workdir
            # init-nix initializes nix DB, drops privileges, execs agent.
            exec ${pkgs.bubblewrap}/bin/bwrap \
              --dev /dev \
              --proc /proc \
              --tmpfs /tmp \
              --tmpfs "$HOME" \
              --overlay-src /nix/store \
              --overlay "$PWD/.nix/store" "$PWD/.nix/work" /nix/store \
              --bind "$PWD/.nix/var" /nix/var \
              --ro-bind ${closureInfo}/registration /nix/.closure-registration \
              --symlink ${pkgs.coreutils}/bin/env /usr/bin/env \
              --symlink ${pkgs.bash}/bin/bash /bin/sh \
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
              --unshare-user --uid 0 --gid 0 \
              --setenv PATH "${mainBin}:${pathString}" \
              --setenv HOME "$HOME" \
              --setenv TERM "''${TERM:-xterm-256color}" \
              --setenv SSL_CERT_FILE "$_SSL_CERT_FILE" \
              --setenv SSL_CERT_DIR "$_SSL_CERT_DIR" \
              --setenv NIX_CONFIG "experimental-features = nix-command flakes" \
              --setenv __NIX_AGENT_SANDBOXED 1 \
              --setenv __NIX_AGENT_SANDBOX_PWD "$PWD" \
              --setenv __SANDBOX_ORIG_UID "$_ORIG_UID" \
              --setenv __SANDBOX_ORIG_GID "$_ORIG_GID" \
              $_GH_ENV_ARGS \
              ''${_GIT_SSH_COMMAND:+--setenv GIT_SSH_COMMAND "$_GIT_SSH_COMMAND"} \
              $_CUSTOM_ENV_ARGS \
              ${initScript} ${runScript} "$@"
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
            addPkgs = with pkgs; [ coreutils bash curl gh git openssh nix util-linux ];
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
