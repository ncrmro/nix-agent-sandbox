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
  +-- Outer Ring: bubblewrap (kernel namespaces)
  |     Mount namespace: only $PWD + agent configs + certs
  |     IPC namespace: isolated
  |     Network: allowed (API access)
  |   +-- Inner Ring: Agent's built-in sandbox
  |         Command filtering, network restrictions, file controls
```

The outer ring prevents the process from seeing anything outside the mount list. The inner ring provides granular control within those mounts.

**Sandboxed packages run in yolo mode by default** (`--dangerously-skip-permissions` for Claude, `--yolo` for Gemini/Codex). This is safe because the kernel constrains the blast radius — the agent can only access `$PWD` and its config directories regardless of what commands it runs.

### What the agent can access

| Path | Mode | Purpose |
|------|------|---------|
| `$PWD` | read-write | Current project directory (resolved at runtime) |
| `~/.claude`, `~/.claude.json` | read-write | Claude auth and configuration |
| `~/.config/claude-code` | read-write | Claude additional config |
| `~/.gemini` | read-write | Gemini CLI auth and config |
| `~/.codex` | read-write | Codex CLI auth and config |
| `/etc/ssl/certs`, `/etc/hosts` | read-only | Provided by FHS rootfs |
| `/nix/store` | read-only | Package closures for sandboxed tools |

Everything else (SSH keys, browser data, other home directories, `/etc/shadow`) is invisible.

### What the agent can run

The sandbox includes: `git`, `ripgrep`, `fd`, `coreutils`, `bash`, `grep`, `sed`, `find`, `curl`, `gh`, and `nodejs`. If an executable isn't in the `addPkgs` list, it doesn't exist in the sandbox.

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
- **Host data isolation**: SSH keys, Documents, Downloads, bash_history, GPG keys, /etc/shadow
- **Tmpfs isolation**: writes to `~/` succeed but are ephemeral
- **Project directory**: `$PWD` is readable and writable
- **Agent config dirs**: `~/.claude`, `~/.gemini`, `~/.codex` accessible
- **Networking**: SSL certs, DNS resolution, HTTPS connectivity
- **Nix store**: readable but not writable

## Limitations

- `/nix/store` is fully readable (buildFHSEnv constraint). The agent can read any derivation, not just its closure.
- Network is all-or-nothing. Restricting to specific API hosts requires an external proxy or nftables rules.
- Linux only (bubblewrap uses kernel namespaces).
- The NixOS DNS fix depends on nix-bwrapper's internal `etc_ignored` variable name remaining stable.

## Credits

- [nix-bwrapper](https://github.com/Naxdy/nix-bwrapper) by Naxdy
- [llm-agents.nix](https://github.com/numtide/llm-agents.nix) by numtide
- [bubblewrap](https://github.com/containers/bubblewrap) by the containers project
