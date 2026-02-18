# nix-agent-sandbox

OS-level [bubblewrap](https://github.com/containers/bubblewrap) sandbox for AI coding agents (Claude Code, Gemini CLI, Codex) via Nix.

Wraps agent CLIs in Linux kernel namespaces so the process can only see an explicit list of filesystem paths, regardless of what the agent's internal permission system allows. SSH keys, browser profiles, other projects, and everything outside the mount list are invisible to the sandboxed process.

## Quick start

### Claude Code

```bash
# Run sandboxed Claude Code in current directory (yolo mode enabled)
cd ~/projects/my-app
nix run github:ncrmro/nix-agent-sandbox

# Or explicitly
nix run github:ncrmro/nix-agent-sandbox#claude-code

# Pass additional arguments
nix run github:ncrmro/nix-agent-sandbox -- "fix the failing tests"
```

### Gemini CLI

```bash
# Run sandboxed Gemini CLI in current directory (yolo mode enabled)
cd ~/projects/my-app
nix run github:ncrmro/nix-agent-sandbox#gemini-cli

# Or use the alias
nix run github:ncrmro/nix-agent-sandbox#gemini

# Pass additional arguments
nix run github:ncrmro/nix-agent-sandbox#gemini -- "explain this codebase"
```

### OpenAI Codex

```bash
# Run sandboxed Codex in current directory (yolo mode enabled)
cd ~/projects/my-app
nix run github:ncrmro/nix-agent-sandbox#codex

# Pass additional arguments
nix run github:ncrmro/nix-agent-sandbox#codex -- "add unit tests for the auth module"
```

### Unwrapped (no sandbox)

If you need full filesystem access without the bubblewrap sandbox:

```bash
nix run github:ncrmro/nix-agent-sandbox#claude-code-unwrapped
nix run github:ncrmro/nix-agent-sandbox#gemini-cli-unwrapped
nix run github:ncrmro/nix-agent-sandbox#codex-unwrapped
```

### Security validation

Validate that sandbox isolation is working:

```bash
nix run github:ncrmro/nix-agent-sandbox#security-test
```

## Packages

| Package | Description |
|---------|-------------|
| `default` / `claude-code` | Claude Code in bubblewrap (yolo mode) |
| `claude-code-unwrapped` | Claude Code without sandbox |
| `gemini-cli` / `gemini` | Gemini CLI in bubblewrap (yolo mode) |
| `gemini-cli-unwrapped` | Gemini CLI without sandbox |
| `codex` | OpenAI Codex in bubblewrap (yolo mode) |
| `codex-unwrapped` | OpenAI Codex without sandbox |
| `security-test` | Validation script that runs inside the sandbox to confirm isolation |

## How the sandbox works

```
Host OS
  $PWD/
    .nix/                    # gitignored, persistent across sessions
      store/                 # overlay upper layer (new/modified store paths)
      merged/                # fuse-overlayfs mount point
      work/                  # overlayfs workdir
      var/                   # nix database

  fuse-overlayfs (on host, before bwrap)
    lowerdir=/nix/store      # host store (read-only)
    upperdir=$PWD/.nix/store # persistent writes
    squash_to_uid=$(id -u)   # all files appear owned by caller

  +-- Outer Ring: bubblewrap (user namespace, --uid 0 --gid 0)
  |     Mount namespace: only $PWD + agent configs + certs
  |     /nix/store ← bind .nix/merged (fuse-overlayfs view)
  |     /nix/var ← bind $PWD/.nix/var (persistent DB)
  |     PID namespace: isolated
  |     Network: allowed (API access)
  |   +-- Agent runs as uid 0 in user namespace (IS_SANDBOX=1)
  |         chmod/chown handled by FUSE userspace (no kernel issues)
```

The outer ring prevents the process from seeing anything outside the mount list. A **fuse-overlayfs** mount on the host merges the host nix store (read-only lower layer) with `$PWD/.nix/store` (persistent upper layer). The `squash_to_uid` option makes all files appear owned by the calling user, so chmod/chown operations go through FUSE userspace without kernel permission issues. The merged view is bind-mounted into bwrap as `/nix/store`. The agent runs as uid 0 in a user namespace for nix single-user mode compatibility. New derivations are written to the upper layer and persist across sessions.

A **persistent `.nix/` directory** in `$PWD` stores the overlay upper layer and nix database. On first run, the wrapper script initializes the nix DB and loads the agent's closure on the host (before entering bwrap). Subsequent runs are fast — no re-downloading.

**Add `.nix/` to your `.gitignore`** — it contains binary store paths that shouldn't be committed.

**Sandboxed packages run in yolo mode by default** (`--dangerously-skip-permissions` for Claude, `--yolo` for Gemini/Codex). This is safe because the kernel constrains the blast radius — the agent can only access `$PWD` and its config directories regardless of what commands it runs.

### What the agent can access

| Path | Mode | Purpose |
|------|------|---------|
| `$PWD` | read-write | Current project directory (resolved at runtime) |
| `/nix/store` | read-write | Overlayfs: host store (lower) + `$PWD/.nix/store` (upper) |
| `$PWD/.nix/var` → `/nix/var` | read-write | Persistent nix database |
| `$PWD/.nix/work` | internal | Overlayfs workdir (same filesystem as upper) |
| `~/.claude`, `~/.claude.json` | read-write | Claude auth and configuration |
| `~/.config/claude-code` | read-write | Claude additional config |
| `~/.gemini` | read-write | Gemini CLI auth and config |
| `~/.codex` | read-write | Codex CLI auth and config |
| `~/.gitconfig` | read-only | Git user config (name, email, aliases) |
| `~/.config/git` | read-write | Git XDG config (credential helpers need write) |
| `~/.ssh` | read-only | SSH keys for git operations |
| `/etc/ssl/certs`, `/etc/hosts` | read-only | Provided by FHS rootfs |

Everything else (browser data, other home directories, `/etc/shadow`) is invisible. The host `/nix/store` is only visible as the read-only lower layer of the overlay — the agent cannot modify host store paths.

### What the agent can run

The sandbox includes: `git`, `ripgrep`, `fd`, `coreutils`, `bash`, `grep`, `sed`, `find`, `curl`, `gh`, `nodejs`, and `nix`. Nix runs in single-user mode with `sandbox = false` (nix's own sandbox cannot nest inside bwrap). Agents can run `nix build`, `nix develop`, and `nix run` to build derivations and launch sub-agents. Built paths persist in `$PWD/.nix/store` across sessions — subsequent builds are fast (cached). If an executable isn't in the `addPkgs` list, it doesn't exist in the sandbox.

## Adding to a devShell

### Using the overlay (recommended)

Add `nix-agent-sandbox` as a flake input and apply the overlay. This gives you `pkgs.claude-code-sandbox`, `pkgs.gemini-cli-sandbox`, and `pkgs.codex-sandbox` alongside your other packages.

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-agent-sandbox.url = "github:ncrmro/nix-agent-sandbox";
  };

  outputs = { nixpkgs, nix-agent-sandbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true;
        overlays = [ nix-agent-sandbox.overlays.default ];
      };
    in {
      devShells.${system} = {
        # Sandboxed: agent can only see $PWD and its own config
        default = pkgs.mkShell {
          packages = [
            pkgs.claude-code-sandbox
            pkgs.gemini-cli-sandbox
            pkgs.codex-sandbox
          ];
        };

        # Unwrapped: full filesystem access, agent's own sandbox only
        unwrapped = pkgs.mkShell {
          packages = [
            pkgs.llm-agents.claude-code
            pkgs.llm-agents.gemini-cli
            pkgs.llm-agents.codex
          ];
        };
      };
    };
}
```

### Using packages directly

If you don't want to use the overlay, reference packages from the flake input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-agent-sandbox.url = "github:ncrmro/nix-agent-sandbox";
  };

  outputs = { nixpkgs, nix-agent-sandbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      devShells.${system}.default = pkgs.mkShell {
        packages = [
          nix-agent-sandbox.packages.${system}.claude-code   # sandboxed
          nix-agent-sandbox.packages.${system}.gemini-cli    # sandboxed
          nix-agent-sandbox.packages.${system}.codex         # sandboxed
        ];
      };
    };
}
```

## Wrapping other agents

Use `lib.mkAgentSandbox` to sandbox any CLI package:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-agent-sandbox.url = "github:ncrmro/nix-agent-sandbox";
  };

  outputs = { nixpkgs, nix-agent-sandbox, ... }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          # nix-bwrapper overlay is required for mkBwrapper
          nix-agent-sandbox.inputs.nix-bwrapper.overlays.default
        ];
      };
    in {
      packages.${system}.my-sandboxed-tool = nix-agent-sandbox.lib.mkAgentSandbox {
        inherit pkgs;
        package = pkgs.some-cli-tool;
        runScript = "my-tool";
        # Optional: extra paths to expose
        extraReadPaths = [ "/path/to/readonly/data" ];
        extraReadWritePaths = [ "$HOME/.my-tool-config" ];
        # Optional: GitHub token from agenix or another secrets manager
        githubTokenPath = "/run/agenix/github-agents-token";
        # Optional: environment variables
        env = {
          MY_API_KEY = "$(cat /run/secrets/api-key)";
        };
      };
    };
}
```

### `mkAgentSandbox` parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `pkgs` | attrset | required | Nixpkgs with nix-bwrapper overlay applied |
| `package` | derivation | required | The package to sandbox |
| `runScript` | string | required | Binary name to exec inside the sandbox |
| `addPkgs` | list | git, rg, fd, coreutils, bash, curl, gh, nodejs | Executables available inside the sandbox |
| `env` | attrset | `{}` | Environment variables (shell expressions evaluated at runtime) |
| `extraReadPaths` | list | `[]` | Additional read-only bind mounts |
| `extraReadWritePaths` | list | `[]` | Additional read-write bind mounts |
| `githubTokenPath` | string/null | `null` | Path to a GitHub token file (mounted read-only) |

## GitHub token

The sandbox supports GitHub tokens via two methods:

**Environment variable** (works everywhere):

```bash
export GITHUB_TOKEN=ghp_...
nix run github:ncrmro/nix-agent-sandbox
```

**Secrets manager** (e.g., agenix): pass `githubTokenPath` to `mkAgentSandbox`:

```nix
nix-agent-sandbox.lib.mkAgentSandbox {
  # ...
  githubTokenPath = "/run/agenix/github-agents-token";
  env.GITHUB_TOKEN = "$(cat /run/agenix/github-agents-token)";
};
```

The token file is mounted read-only. The agent can read it but cannot modify it.

## NixOS DNS fix

NixOS manages `/etc/resolv.conf` as a symlink chain that breaks inside bubblewrap's `--tmpfs /etc`. This flake includes a workaround that resolves the chain on the host and bind-mounts the real file directly. No manual configuration needed.

See the [spike report](https://github.com/ncrmro/nix-agent-sandbox/issues) for details on the root cause (affects buildFHSEnv, rootless Podman, and the Nix daemon sandbox).

## Security validation

Run the test suite inside the sandbox:

```bash
nix run .#security-test
```

Tests cover:
- **Host data isolation**: Documents, Downloads, bash_history, GPG keys, /etc/shadow
- **Tmpfs isolation**: writes to `~/` succeed but are ephemeral
- **Project directory**: `$PWD` is readable and writable
- **Agent config dirs**: `~/.claude`, `~/.gemini`, `~/.codex` accessible
- **Git config**: `~/.gitconfig` read-only, `~/.config/git` read-write
- **SSH keys**: `~/.ssh` readable but not writable
- **Networking**: SSL certs, DNS resolution, HTTPS connectivity
- **Nix store**: persistent single-user mode, `nix-store --verify`, `nix build` works, privilege drop verified, no daemon socket, no host `/nix` access

## Nested sandboxes

When a sandboxed agent launches another sandboxed agent (e.g., Claude Code spawning Gemini CLI), bubblewrap cannot nest — `pivot_root` fails inside an existing bwrap namespace ([bubblewrap#164](https://github.com/containers/bubblewrap/issues/164), [#273](https://github.com/containers/bubblewrap/issues/273), [#543](https://github.com/containers/bubblewrap/issues/543)). The wrapper detects nesting via the `__NIX_AGENT_SANDBOXED=1` sentinel and falls back to `unshare --user --mount` for the inner agent.

### How it works

```
Host OS
  +-- Outer Ring: bubblewrap (full isolation)
  |     Mount namespace, PID namespace, tmpfs $HOME
  |     Only $PWD + agent configs + certs visible
  |   +-- Inner Ring: unshare --user --mount (scoped)
  |         Mount namespace only (inherits outer FS view)
  |         Hides outer $PWD via tmpfs overlay
  |         Re-exposes only the inner agent's $PWD
```

Two-phase namespace setup:
1. `unshare --user --mount --map-root-user` creates a user namespace with root mapping (needed for `mount(8)` syscalls since bwrap drops all capabilities)
2. Mount operations hide the outer `$PWD` and re-expose the inner worktree
3. `unshare --user --map-user=<orig> --map-group=<orig>` drops back to the original UID/GID before exec'ing the agent (some agents refuse to run as root)

### Isolation differences vs. first-level sandbox

The nested path provides **weaker isolation** than the outer bwrap. This is an inherent limitation, not a bug.

| Property | First-level (bwrap) | Nested (unshare) |
|----------|-------------------|-----------------|
| Filesystem | Minimal — only explicit bind mounts | Inherits full outer FS view |
| PID namespace | Isolated (`--unshare-pid`) | Shared with outer sandbox |
| Home directory | Fresh tmpfs | Same as outer sandbox |
| `/nix/store` | Overlayfs (host lower + persistent upper) | Inherited from outer sandbox |
| `$PWD` scoping | Only `$PWD` bound | Outer `$PWD` hidden via tmpfs, inner `$PWD` re-exposed |
| `~/.ssh` | Read-only bind mount | Inherited from outer (read-only) |

The inner agent can see everything the outer agent can see (minus the outer `$PWD`). It can also signal processes in the outer sandbox (shared PID namespace).

### Known issues

**~~Concurrent nesting race condition.~~** Fixed — now uses `mktemp -d` for safe concurrent operation.

**Path prefix check uses regex.** The `grep -q "^$_OUTER_PWD/"` check that determines whether scoping applies treats `$_OUTER_PWD` as a regex pattern. Paths containing `.`, `+`, or other regex metacharacters could match more broadly than intended. Should use `grep -qF` (fixed string) instead. Low risk since filesystem paths rarely contain these characters and the worst case is "scoping applied when it shouldn't be" (which just hides a directory that was already accessible).

**No PID isolation in nested path.** The nested agent shares the outer sandbox's PID namespace. A misbehaving inner agent could `kill` the outer agent's processes. Both run as the same UID, so this isn't a privilege escalation, but it breaks process isolation between agents.

## Limitations

- Nix runs with `sandbox = false` because nix's own build sandbox cannot nest inside bwrap's user namespace. Builds are not hermetic but the bwrap sandbox constrains filesystem access.
- Network is all-or-nothing. Restricting to specific API hosts requires an external proxy or nftables rules.
- Linux only (bubblewrap uses kernel namespaces).
- The `.nix/` directory grows with each build. Periodically delete it to reclaim space: `rm -rf .nix/`

## Credits

- [nix-bwrapper](https://github.com/Naxdy/nix-bwrapper) by Naxdy
- [llm-agents.nix](https://github.com/numtide/llm-agents.nix) by numtide
- [bubblewrap](https://github.com/containers/bubblewrap) by the containers project
