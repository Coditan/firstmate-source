# Forgejo pull request identity

Empirical record for the third forge in `bin/fm-pr-lib.sh`, alongside the existing GitHub and GitLab identities.
Every command below was run on 2026-08-19 and its output is reproduced exactly.

This is the first slice of the captain's decision to replace GitHub with the fleet's own self-hosted forge.
It answers one question - which forge does a change address belong to - and answers it for a third forge.
It changes nothing else, and the boundary is stated at the end rather than left to be discovered.

## Versions

```
$ bash --version | head -1
GNU bash, version 5.2.21(1)-release (x86_64-pc-linux-gnu)
```

## The evidence instance

All live evidence here reads <https://codeberg.org>, a public Forgejo instance that needs no credential, so a reader can rerun every command below and see the same shape.
It is not this fleet's instance and is used only because a public one can be cited.
The fleet's own instance is named by configuration and appears in no tracked file; `docs/configuration.md` "Forge instance" owns where that value comes from.

```
$ curl -sS https://codeberg.org/api/v1/version
{"version":"16.0.0-dev-694-33ae492b+gitea-1.22.0"}
```

## The route, taken from the forge rather than from memory

A Forgejo pull request lives at `/<owner>/<repository>/pulls/<number>`, plural, which is neither GitHub's singular `/pull/<number>` nor GitLab's `/-/merge_requests/<number>`.
The forge itself is the source for that: its API returns the canonical web address of each pull request.

```
$ curl -sS 'https://codeberg.org/api/v1/repos/forgejo/forgejo/pulls?limit=1&state=all' \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["html_url"])'
https://codeberg.org/forgejo/forgejo/pulls/13995

$ curl -sS -o /dev/null -w '%{http_code}\n' https://codeberg.org/forgejo/forgejo/pulls/13995
200

$ curl -sS -o /dev/null -w '%{http_code}\n' https://codeberg.org/forgejo/forgejo/pull/1
404
```

One property of that route is worth recording because it looks like a defect and is not.
Forgejo gives issues and pull requests one shared index space, so asking for a `/pulls/<n>` that names an issue redirects to the issue rather than answering:

```
$ curl -sS -D - -o /dev/null https://codeberg.org/forgejo/forgejo/pulls/1 | grep -iE '^(HTTP|location)'
HTTP/2 303
location: /forgejo/forgejo/issues/1
```

Identity parsing does not follow that redirect and does not need to: it resolves an address, and whether the number names a pull request is the forge's answer to give when something finally asks it.

## The host is configuration, and a wrong host is refused

GitLab already carried its host in the stored identity because it had to, and Forgejo is the same kind of forge.
The difference is that this fleet runs one Forgejo instance and any other is somebody else's.
So the host is not merely carried, it is checked: an address is resolved as a Forgejo pull request only when its host is exactly the instance this home is configured for.

The sequence below runs the parser over the real address above, first with no instance configured, then with one, then against a look-alike host.
`FM_HOME` points at a scratch home so the reading is the fixture's and not this seat's, and `FM_FORGEJO_HOST` is unset so the file is what answers:

```
$ . bin/fm-pr-lib.sh
$ fm_pr_url_parse https://codeberg.org/forgejo/forgejo/pulls/13995 || echo refused
refused

$ printf 'codeberg.org\n' > "$FM_HOME/config/forgejo-host"
$ fm_pr_url_parse https://codeberg.org/forgejo/forgejo/pulls/13995 \
    && printf 'provider=%s host=%s path=%s number=%s owner=%s repo=%s\n' \
       "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER" "$FM_PR_OWNER" "$FM_PR_REPO"
provider=forgejo host=codeberg.org path=forgejo/forgejo number=13995 owner= repo=

$ fm_pr_url_parse https://codeberg.org.evil/forgejo/forgejo/pulls/13995 || echo refused
refused

$ fm_pr_url_parse https://github.com/o/r/pull/1 && printf 'provider=%s host=%s\n' "$FM_PR_PROVIDER" "$FM_PR_HOST"
provider=github host=github.com

$ fm_pr_url_parse https://gitlab.com/g/p/-/merge_requests/1 && printf 'provider=%s host=%s\n' "$FM_PR_PROVIDER" "$FM_PR_HOST"
provider=gitlab host=gitlab.com
```

Three properties of that refusal are load-bearing for every later Forgejo slice, because each relies on this parser's answer instead of repeating the host check.

The refusal is a refusal, not a warning and not a pass-through.
`https://codeberg.org.evil/...` has the exact shape of a Forgejo pull request, and a shape test alone is how a tool ends up acting on someone else's server.

An unconfigured home has no Forgejo provider at all rather than a guessed one.
Before this slice a Forgejo address was refused everywhere; in a home that names no instance it still is, byte for byte.

A `/pulls/<number>` address is answered or refused in one place and is never reinterpreted as another provider.
No GitHub or GitLab address can take that shape, so a refused Forgejo address falls through to nothing.

`tests/fm-pr-check-security.test.sh` proves the refusal by trying it, over a matrix of look-alike hosts and non-canonical spellings, rather than by asserting that a check exists.

## No forge hostname is in the code

`tests/fm-pr-check-security.test.sh` proves that the same project path and pull request number resolve under both `forge.example` and `code.internal`, while a home with neither setting refuses every address of that shape, which a hardcoded host could not produce.
Moving the fleet to a different instance is therefore a configuration change, exactly as reaching a self-hosted GitLab already is.
`tests/fm-pr-check-security.test.sh` already made the equivalent assertion for `gitlab.com`; this slice extends the same rule to the forge the fleet is moving onto.

## What deliberately did not change

The two forges that already worked behave identically to before, proven by their own tests passing unchanged.

Nothing watched or merged a Forgejo pull request when this slice landed.

**Updated 2026-08-22: the merge path learned this forge.**
`bin/fm-pr-merge.sh` now merges a pull request on the configured instance through `forgejo-axi`, passing the head commit that forge requires, and [`docs/forgejo-merge-helper.md`](forgejo-merge-helper.md) owns that evidence and its boundary.
It reads this parser's answer rather than repeating the host check, which is what the three properties above were written to support.

Watching is still absent, and the refusal below is unchanged:
`bin/fm-pr-poll.sh` reads GitHub and GitLab only, and because the poll is silent on everything it cannot read, arming a Forgejo watch would report success and then watch nothing.
So `bin/fm-pr-check.sh` still refuses it where the refusal can still be reported:

```
$ fm-pr-check.sh task-a https://forge.example/team/tools/pulls/7
error: watching a Forgejo pull request is not supported yet
```

That refusal is expected to be removed by the slice that teaches the poll to read this forge.
The merge path does not remove it and does not route around it: it records through `fm-pr-check.sh --no-watch`, which records the same metadata, arms nothing, and says in its own output that nothing will report the merge.

## Maintaining this file

This is an evidence record, so it changes only when something in it is re-measured.
When the poll or the merge path learns this forge, replace the refusal above with what those paths then do, and record the commands and output that established it.
