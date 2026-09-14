# Branch freeze

Freezes a branch by upserting a repo-level GitHub **ruleset** with the
*Restrict updates* rule (`{"type": "update"}`), which blocks both direct pushes
and PR merges. Unfreezing keeps the ruleset and only disables it, so the id and
configuration survive between freezes.

Classic branch protection is not enough here: it stops direct pushes but still
lets anyone with write access merge a PR. The `update` rule gates both.

## Requirements

- The repository must be on a plan where rulesets are available for its
  visibility (private repos need GitHub Team or Enterprise).
- A token with `Administration: write` on the repository, stored as the
  `REPO_ADMIN_TOKEN` secret. The default `GITHUB_TOKEN` cannot administer
  rulesets.

## Usage

```yaml
- uses: ./.github/actions/branch-freeze
  with:
    operation: freeze          # or unfreeze
    branch: development
    bypass-users: alice,bob    # optional, who can still merge while frozen
    token: ${{ secrets.REPO_ADMIN_TOKEN }}
```

Run it from the Actions tab via the **Branch freeze** workflow
(`.github/workflows/branch-freeze.yml`).

## Inputs

| Input | Required | Default | Notes |
|---|---|---|---|
| `operation` | yes | — | `freeze` or `unfreeze` |
| `repository` | yes | current repo | `owner/name` |
| `branch` | yes | `development` | Branch to gate |
| `actor` | no | `github.actor` | Who is running the operation. A `freeze` over an already active freeze is refused unless this user holds a bypass on it. |
| `bypass-users` | no | — | Comma separated GitHub usernames allowed to push and merge during the freeze. Logins are resolved to numeric user ids by the action; empty entries and duplicates are ignored. Without it the freeze applies to everyone, including admins. |
| `ruleset-name` | no | `branch-code-freeze` | One ruleset is reused per repo |
| `token` | yes | — | See requirements |

Output: `ruleset-id`.

## Notes

- The upsert is idempotent — rerunning never duplicates the ruleset.
- Listing rulesets uses `--paginate`; without it a repo with many rulesets
  hides the existing one and a duplicate gets created.
- `unfreeze` on a repo with no such ruleset warns and exits 0.
- The workflow always passes `github.actor`, so whoever launches the freeze
  keeps merge access without having to name themselves.
- The `PUT` replaces the whole ruleset, so the bypass list has to be supplied on
  every freeze; it is not remembered from the previous run.
- Freezing a branch that is already frozen is refused unless `actor` is in the
  existing bypass list, and freezing a second branch while another one is frozen
  is refused outright. One ruleset per repo cannot hold two freezes, and without
  the guard the second run would silently take over the first one's bypass list
  or thaw its branch. `unfreeze` is never gated, so a freeze can always be lifted.
