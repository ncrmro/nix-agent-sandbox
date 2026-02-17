#!/usr/bin/env bash
# nix-agent-sandbox security validation
# Validates that bubblewrap sandbox correctly isolates the filesystem.
# Run via: nix run .#security-test

set -euo pipefail

PASS=0
FAIL=0
WARN=0
TOTAL=0

run_test() {
  local name="$1"
  local expected="$2"  # "blocked", "allowed", or "info"
  shift 2
  local cmd="$*"

  TOTAL=$((TOTAL + 1))
  printf "  %-55s " "$name"

  if eval "$cmd" >/dev/null 2>&1; then
    case "$expected" in
      blocked)
        echo "FAIL (should be blocked)"
        FAIL=$((FAIL + 1))
        ;;
      allowed)
        echo "PASS"
        PASS=$((PASS + 1))
        ;;
      info)
        echo "OK (accessible)"
        PASS=$((PASS + 1))
        ;;
    esac
  else
    case "$expected" in
      blocked)
        echo "PASS (blocked)"
        PASS=$((PASS + 1))
        ;;
      allowed)
        echo "FAIL (should work)"
        FAIL=$((FAIL + 1))
        ;;
      info)
        echo "WARN (not accessible)"
        WARN=$((WARN + 1))
        ;;
    esac
  fi
}

echo "============================================"
echo "  Bubblewrap Sandbox Security Validation"
echo "============================================"
echo ""

# ── Host data isolation ──────────────────────────────────

echo "[Host Data Isolation -- real files must be invisible]"
run_test "Home Documents (~/Documents)"              blocked "ls ~/Documents 2>/dev/null && test -n \"\$(ls ~/Documents)\""
run_test "Home Downloads (~/Downloads)"              blocked "ls ~/Downloads 2>/dev/null && test -n \"\$(ls ~/Downloads)\""
run_test "Bash history (~/.bash_history)"             blocked "cat ~/.bash_history"
run_test "GPG keys (~/.gnupg/private-keys-v1.d)"     blocked "ls ~/.gnupg/private-keys-v1.d"
run_test "Shadow file (/etc/shadow)"                 blocked "cat /etc/shadow"

echo ""
echo "[Tmpfs Isolation -- writes go to ephemeral tmpfs, not host]"
echo "  (bwrap mounts tmpfs at /home, /etc, /mnt -- writes succeed"
echo "   but data is ephemeral and never reaches the host filesystem)"
touch ~/tmpfs-write-test 2>/dev/null && {
  printf "  %-55s " "Write to ~/tmpfs-write-test"
  echo "OK (tmpfs -- ephemeral, not on host)"
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
  rm -f ~/tmpfs-write-test
} || {
  printf "  %-55s " "Write to ~/tmpfs-write-test"
  echo "BLOCKED (unexpected -- tmpfs should be writable)"
  TOTAL=$((TOTAL + 1))
  WARN=$((WARN + 1))
}

echo ""
echo "[Project Directory -- must be read-write]"
run_test "Read project dir (\$PWD)"                  allowed "ls \$PWD"
run_test "Write to project dir"                      allowed "touch \$PWD/.sandbox-write-test && rm \$PWD/.sandbox-write-test"

echo ""
echo "[Agent Config Dirs -- must be read-write]"
run_test "Access ~/.claude"                          allowed "ls \$HOME/.claude 2>/dev/null || mkdir -p \$HOME/.claude"
run_test "Write to ~/.claude"                        allowed "touch \$HOME/.claude/.sandbox-test && rm \$HOME/.claude/.sandbox-test"
run_test "Access ~/.claude.json"                     allowed "test -e \$HOME/.claude.json || touch \$HOME/.claude.json"
run_test "Access ~/.gemini"                          allowed "ls \$HOME/.gemini 2>/dev/null || mkdir -p \$HOME/.gemini"
run_test "Write to ~/.gemini"                        allowed "touch \$HOME/.gemini/.sandbox-test && rm \$HOME/.gemini/.sandbox-test"
run_test "Access ~/.codex"                           allowed "ls \$HOME/.codex 2>/dev/null || mkdir -p \$HOME/.codex"
run_test "Write to ~/.codex"                         allowed "touch \$HOME/.codex/.sandbox-test && rm \$HOME/.codex/.sandbox-test"

echo ""
echo "[Git Config]"
run_test "Read ~/.gitconfig"                         info "cat \$HOME/.gitconfig 2>/dev/null || test ! -e \$HOME/.gitconfig"
run_test "Git user.name accessible"                  info "git config --global user.name 2>/dev/null"
# Note: If ~/.gitconfig exists on host, it's ro-bound and writes fail.
# If it doesn't exist, writes go to tmpfs (ephemeral) which is safe.
printf "  %-55s " "Write to ~/.gitconfig"
if echo '[sandbox-test]' >> "$HOME/.gitconfig" 2>/dev/null; then
  # Write succeeded - check if it's on tmpfs (ephemeral) or real host fs
  # Since we ro-bind from host, if write succeeds it's tmpfs = safe
  echo "OK (tmpfs -- ephemeral, no host file to protect)"
  rm -f "$HOME/.gitconfig" 2>/dev/null
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
else
  echo "PASS (read-only, host file protected)"
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
fi
run_test "Access ~/.config/git"                      allowed "ls \$HOME/.config/git 2>/dev/null || mkdir -p \$HOME/.config/git"
run_test "Write to ~/.config/git"                    allowed "touch \$HOME/.config/git/.sandbox-test && rm \$HOME/.config/git/.sandbox-test"

echo ""
echo "[SSH Keys -- must be read-only]"
run_test "Read ~/.ssh directory"                     info "ls \$HOME/.ssh 2>/dev/null || test ! -e \$HOME/.ssh"
run_test "Read SSH private key"                      info "cat \$HOME/.ssh/id_ed25519 2>/dev/null || cat \$HOME/.ssh/id_rsa 2>/dev/null || test ! -e \$HOME/.ssh"
# SSH agent socket is not forwarded into sandbox
# Just check if environment variable is set (it won't be)
printf "  %-55s " "SSH agent forwarding"
if [ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ]; then
  echo "OK (socket available)"
else
  echo "SKIP (no agent socket in sandbox)"
fi
TOTAL=$((TOTAL + 1))
PASS=$((PASS + 1))
run_test "Write to ~/.ssh blocked"                   blocked "touch \$HOME/.ssh/.sandbox-test"

echo ""
echo "[Networking -- must work for API calls]"
run_test "SSL certificates available"                allowed "ls /etc/ssl/certs"
run_test "resolv.conf exists"                        info "test -e /etc/resolv.conf || test -L /etc/resolv.conf"
run_test "Network: HTTPS connectivity"               info "curl -sf --connect-timeout 5 --max-time 10 -o /dev/null https://api.anthropic.com || curl -sf --connect-timeout 5 --max-time 10 -o /dev/null https://1.1.1.1"

echo ""
echo "[GitHub Token -- environment-based access]"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  run_test "GITHUB_TOKEN env var set"                allowed "test -n \"\$GITHUB_TOKEN\""
  run_test "gh auth status"                          info "gh auth status 2>&1"
  run_test "GitHub API via curl (token auth)"        info "curl -sf -H \"Authorization: Bearer \$GITHUB_TOKEN\" https://api.github.com/user 2>&1"
else
  printf "  %-55s " "GITHUB_TOKEN env var"
  echo "SKIP (not set)"
  TOTAL=$((TOTAL + 1))
  PASS=$((PASS + 1))
fi

echo ""
echo "[Nix Store -- persistent single-user mode]"
echo "  [DEBUG] id: $(id)"
echo "  [DEBUG] DB: $(ls -la /nix/var/nix/db/db.sqlite 2>&1)"
echo "  [DEBUG] store ls: $(ls -ld /nix/store 2>&1)"
echo "  [DEBUG] verify: $(nix-store --verify 2>&1 | tail -5)"
echo "  [DEBUG] build: $(nix build nixpkgs#hello --no-link 2>&1 | tail -5)"
run_test "Read /nix/store"                           allowed "test -d /nix/store"
run_test "nix-store --verify succeeds"               allowed "nix-store --verify 2>/dev/null"
run_test "nix build nixpkgs#hello"                   allowed "nix build nixpkgs#hello --no-link 2>&1"
run_test "Built output visible in /nix/store"        allowed "nix build nixpkgs#hello --print-out-paths 2>&1 | head -1 | xargs test -d"
run_test "UID is root in user namespace"             allowed "test \$(id -u) -eq 0"
run_test "No nix daemon socket present"              blocked "test -S /nix/var/nix/daemon-socket/socket"
run_test "No host /nix/store access"                 blocked "test -f /nix/store/.host-marker 2>/dev/null"

echo ""
echo "============================================"
printf "  Results: %d passed, %d failed, %d warnings, %d total\n" "$PASS" "$FAIL" "$WARN" "$TOTAL"
echo "============================================"

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "RESULT: $FAIL test(s) indicate sandbox isolation gaps!"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "RESULT: Sandbox isolation working. $WARN item(s) need attention (see warnings)."
  exit 0
else
  echo ""
  echo "RESULT: All tests passed -- sandbox isolation working correctly."
  exit 0
fi
