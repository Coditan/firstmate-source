# Triage labels

This repository does not use GitHub Issue labels for Matt Pocock's five-role triage vocabulary.
Map those roles onto fleet backlog state instead.
`needs-triage` means an unsized queued item.
`needs-info` means a held item waiting on missing information.
`ready-for-human` means a held item waiting on human action or review.
`ready-for-agent` means the item appears in `tasks-axi ready`.
`wontfix` means an `out-of-course` record.
This is a deliberate departure from the setup skill's default because GitHub Issues are not the tracker here.
Changing back to plain tracker labels is a policy change in this file.
