# approval_policy.md — Layer 3 (stable reference)

When a worker goes `blocked`, the loop reads its visible screen and decides:
**auto-approve** (send Enter) or **escalate** (write to `stages/<stage>/review/<slice>.md`,
set `STATUS: NEEDS_REVIEW`, notify). Default when unsure: **escalate**.

The script's decision is purely pattern-based and conservative:

1. If the screen matches any line in `_config/approve_deny.txt` → **escalate** (always).
2. Else if it matches any line in `_config/approve_allow.txt` → **auto-approve**.
3. Else → **escalate**.

`deny` wins over `allow`. Patterns are extended-regex, case-insensitive, one per line,
`#` comments ignored. Keep `deny` broad and `allow` narrow.

Never auto-approve: force-push, `git push` to a protected branch, branch/worktree
deletion, secret or credential access, network exfiltration, `rm -rf`, package
publishing. These belong to a human (or your reasoning), not a regex.
