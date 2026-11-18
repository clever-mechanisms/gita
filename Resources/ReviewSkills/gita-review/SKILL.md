---
name: gita-review
description: "Gitā's own code review: read a range of commits (a branch against its base, unpushed or incoming commits, or a single commit) and report the bugs, regressions, security problems, data loss and missing tests in it, most severe first. Use when asked to review a branch, a commit or a diff and no other review method is given."
---

# Gitā Review

Review one change: the commits and diff named in the prompt. The prompt also gives the commands that show them; use
those commands rather than `HEAD`, because the change is not always the checked-out branch.

## 1. Understand the change

- Read the commit messages first (the `git log` command in the prompt) to learn what the change means to do.
- Look at the shape of the diff (`git diff --stat`) before reading it, and decide where the risk is: new behaviour,
  changed contracts, deleted code, concurrency, persistence, security boundaries.
- Read the full diff. Open the surrounding code whenever a hunk alone doesn't show what it affects: callers of a
  changed function, other implementations of a changed protocol, the tests of a changed module.
- When the change isn't checked out, read its files with `git show <change>:<path>`.

## 2. Look for real problems

Spend the time on what would hurt someone if it shipped:

- **Bugs**: wrong results, unhandled cases (empty, nil, zero, very large, Unicode, concurrent), off-by-one errors,
  inverted conditions, errors swallowed or reported wrongly.
- **Regressions**: behaviour that used to work and no longer does, callers broken by a changed signature or meaning,
  removed code that something still depends on.
- **Security**: untrusted input reaching a shell, a path, SQL, HTML or a URL; secrets in code or logs; permissions
  widened; checks skipped.
- **Data loss**: writes that can overwrite or delete user data, migrations without a way back, destructive operations
  without confirmation.
- **Tests**: new behaviour without a test, tests that can't fail, tests changed to match a bug.

Skip style nits, naming preferences and formatting a formatter would fix. Raise a design concern only when it will
cause a concrete problem, and name that problem.

Check each finding before you report it: re-read the code, trace the call, and drop anything you can't back with a
concrete case.

## 3. Report

List the findings most severe first. For each one give:

1. `file:line`
2. What goes wrong, as a concrete case: the input or state, and the wrong result.
3. A suggested fix, in a sentence or a short snippet.

Group the findings as **Blocking**, **Should fix** and **Minor**, leaving out empty groups. When there is nothing to
report, say so plainly rather than inventing findings.

End with a one-line verdict: ready to merge, ready after the blocking fixes, or not ready, and why.
