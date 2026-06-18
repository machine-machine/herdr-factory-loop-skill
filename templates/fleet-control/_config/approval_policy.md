# approval_policy.md — Layer 3: unblocking orchestrators

When an orchestrator goes `blocked`, the loop reads its visible screen and matches it against
`approve_allow.txt` then `approve_deny.txt` (**deny wins**):
- match in allow, no match in deny → auto-approve (send Enter). Routine: tests, installs, reads.
- match in deny, or no match in either → **escalate** to `stages/<stage>/review/<mission>.md`
  and surface via the `NEEDS_REVIEW` status. The human (or you, the meta) decides.

Escalate-always class: force-push, push/deploy to main/prod, deleting branches/DBs/volumes,
secret/credential/token access, `rm -rf`. These are the orchestrator's escalations to YOU; you
in turn surface prod/destructive ones to the human. Never auto-approve another tier's risk.
