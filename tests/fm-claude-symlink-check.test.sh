#!/usr/bin/env bash
# Behavior tests for bin/fm-claude-symlink-check.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-claude-symlink-check)

# fixture_repo <dir>: a repo on "main" whose CLAUDE.md is a correct symlink to
# AGENTS.md.
fixture_repo() {
  local repo=$1
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# agents\n' > "$repo/AGENTS.md"
  git -C "$repo" add AGENTS.md
  ( cd "$repo" && ln -s AGENTS.md CLAUDE.md )
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" branch -M main
}

test_matching_symlink_passes() {
  local repo out rc
  repo="$TMP_ROOT/matching"
  fixture_repo "$repo"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for a matching symlink, got $rc: $out"
  assert_contains "$out" "ok:" "matching symlink did not report ok"
  pass "fm-claude-symlink-check.sh: matching CLAUDE.md symlink passes"
}

test_regular_file_fails_with_recovery_commands() {
  local repo out rc
  repo="$TMP_ROOT/regular-file"
  fixture_repo "$repo"
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is a regular file"
  assert_contains "$out" "error:" "regular-file breakage did not report an error"
  assert_contains "$out" "regular file" "error did not name the actual problem"
  assert_contains "$out" "checkout main -- CLAUDE.md" "error did not include the git checkout recovery command"
  assert_contains "$out" "ln -sfn AGENTS.md" "error did not include the ln -sfn recovery command"
  pass "fm-claude-symlink-check.sh: CLAUDE.md demoted to a regular file fails with recovery commands"
}

test_missing_claude_md_fails() {
  local repo out rc
  repo="$TMP_ROOT/missing"
  fixture_repo "$repo"
  rm "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md is missing"
  assert_contains "$out" "error:" "missing CLAUDE.md did not report an error"
  assert_contains "$out" "missing" "error did not describe the file as missing"
  pass "fm-claude-symlink-check.sh: missing CLAUDE.md fails"
}

test_wrong_symlink_target_fails() {
  local repo out rc
  repo="$TMP_ROOT/wrong-target"
  fixture_repo "$repo"
  rm "$repo/CLAUDE.md"
  ( cd "$repo" && ln -s WRONG.md CLAUDE.md )
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for a symlink pointing at the wrong target"
  assert_contains "$out" "error:" "wrong-target symlink did not report an error"
  assert_contains "$out" "WRONG.md" "error did not name the actual (wrong) target"
  pass "fm-claude-symlink-check.sh: symlink pointing at the wrong target fails"
}

test_dangling_symlink_fails() {
  local repo out rc
  repo="$TMP_ROOT/dangling"
  fixture_repo "$repo"
  rm "$repo/AGENTS.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when CLAUDE.md dangles, got: $out"
  assert_contains "$out" "dangling symlink" "dangling CLAUDE.md was not reported as dangling"
  assert_contains "$out" "checkout main -- 'AGENTS.md'" "error did not include the target-restore command"
  pass "fm-claude-symlink-check.sh: dangling CLAUDE.md symlink fails"
}

test_runs_from_a_subdirectory() {
  local repo out rc
  repo="$TMP_ROOT/subdir"
  fixture_repo "$repo"
  mkdir -p "$repo/pkg"
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo/pkg" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when run from a subdirectory of a broken repo, got: $out"
  assert_contains "$out" "regular file" "subdirectory invocation did not detect the root CLAUDE.md breakage"
  pass "fm-claude-symlink-check.sh: run from a subdirectory it still checks the repo root"
}

test_unknown_base_ref_errors() {
  local repo out rc
  repo="$TMP_ROOT/bogus-base"
  fixture_repo "$repo"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" no-such-ref 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit for an unresolvable base ref, got: $out"
  assert_contains "$out" "error:" "unresolvable base ref did not report an error"
  assert_contains "$out" "no-such-ref" "error did not name the unresolvable ref"
  pass "fm-claude-symlink-check.sh: an unresolvable base ref errors instead of skipping"
}

test_uncommitted_restore_still_fails() {
  local repo out rc
  repo="$TMP_ROOT/uncommitted-restore"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm demote

  git -C "$repo" checkout main -- CLAUDE.md
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit while the branch tip still carries the broken CLAUDE.md, got: $out"
  assert_contains "$out" "branch tip" "error did not point at the branch tip"
  assert_contains "$out" "Commit the restored symlink" "error did not tell the worker to commit the restore"

  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm restore
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 once the restored symlink is committed, got $rc: $out"
  assert_contains "$out" "ok:" "committed restore did not report ok"
  pass "fm-claude-symlink-check.sh: a restore only passes once it is committed"
}

test_branch_tip_dropping_claude_md_fails() {
  local repo out rc
  repo="$TMP_ROOT/tip-drops-file"
  fixture_repo "$repo"
  git -C "$repo" checkout -q -b fm/worker
  git -C "$repo" rm -q CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm drop
  ( cd "$repo" && ln -s AGENTS.md CLAUDE.md )
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit when the branch tip drops CLAUDE.md, got: $out"
  assert_contains "$out" "drops CLAUDE.md entirely" "error did not describe the dropped file"
  pass "fm-claude-symlink-check.sh: a branch tip that dropped CLAUDE.md fails"
}

test_repo_without_symlink_policy_skips() {
  local repo out rc
  repo="$TMP_ROOT/no-policy"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '# claude\n' > "$repo/CLAUDE.md"
  git -C "$repo" add CLAUDE.md
  git -C "$repo" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm initial
  git -C "$repo" branch -M main
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for a repo without a CLAUDE.md symlink policy, got $rc: $out"
  assert_contains "$out" "skip:" "repo without a symlink policy did not report skip"
  pass "fm-claude-symlink-check.sh: repo without a CLAUDE.md symlink policy skips silently"
}

test_repo_without_claude_md_at_all_skips() {
  local repo out rc
  repo="$TMP_ROOT/no-claude-file"
  fm_git_init_commit "$repo"
  git -C "$repo" branch -M main
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" main 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] || fail "expected exit 0 for a repo with no CLAUDE.md at all, got $rc: $out"
  assert_contains "$out" "skip:" "repo without any CLAUDE.md did not report skip"
  pass "fm-claude-symlink-check.sh: repo with no CLAUDE.md at all skips silently"
}

test_auto_detects_origin_default_branch() {
  local repo bare out rc
  repo="$TMP_ROOT/auto-detect-src"
  bare="$TMP_ROOT/auto-detect-bare"
  fixture_repo "$repo"
  fm_git_add_origin "$repo" "$bare"
  git -C "$repo" fetch --quiet origin
  git -C "$repo" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
  rm "$repo/CLAUDE.md"
  printf 'stale content\n' > "$repo/CLAUDE.md"
  out=$("$ROOT/bin/fm-claude-symlink-check.sh" "$repo" 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "expected a non-zero exit with auto-detected origin/main base, got: $out"
  assert_contains "$out" "origin/main" "auto-detected base was not origin/main"
  pass "fm-claude-symlink-check.sh: auto-detects the origin default branch when no base-ref is given"
}

test_matching_symlink_passes
test_regular_file_fails_with_recovery_commands
test_missing_claude_md_fails
test_wrong_symlink_target_fails
test_dangling_symlink_fails
test_runs_from_a_subdirectory
test_unknown_base_ref_errors
test_uncommitted_restore_still_fails
test_branch_tip_dropping_claude_md_fails
test_repo_without_symlink_policy_skips
test_repo_without_claude_md_at_all_skips
test_auto_detects_origin_default_branch
