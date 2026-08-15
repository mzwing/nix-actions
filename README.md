# nix-actions

Shared GitHub composite actions for [nur-packages](https://github.com/mzwing/nur-packages) and [nix-config](https://github.com/mzwing/nix-config): Nix setup, a Tailscale-connected distributed build fleet, and the ephemeral Attic cache that holds the fleet's private build intermediates.

```yaml
- uses: mzwing/nix-actions/nix/setup@master
  with:
    cachix-name: mzwing
```

## Actions

| Action | Runs on | Purpose |
| --- | --- | --- |
| `nix/setup` | anywhere | Install Nix with the shared substituters, optionally Cachix and devenv |
| `nix/restore-store` | anywhere | Restore the store from Actions Cache and clear stale lock files |
| `nix/gc-store` | anywhere | Root the current lock's build closure, collect the rest |
| `tailnet/join` | anywhere | Join the CI tailnet (and repair macOS DNS afterwards) |
| `tailnet/pin-peer` | macOS | Pin a peer in `/etc/hosts` where MagicDNS is unavailable |
| `builders/attach` | coordinator | Claim the fleet and register it with the local Nix daemon |
| `builders/serve` | builder | Stay alive while the coordinator drives builds over ssh-ng |
| `builders/release` | coordinator | Signal the fleet that the run is over |
| `store-cache/prepare-dirs` | cache host | Create the Attic subtree and move the runner temp dir into the big pool |
| `store-cache/start` | cache host | Bring up this run's Attic server |
| `store-cache/adopt-checkpoint` | cache host | Promote a restored checkpoint over the restored finalized generation |
| `store-cache/connect` | builder, coordinator | Point a machine at the Attic cache |
| `store-cache/verify` | coordinator | Fail fast unless Attic answers from both sides |
| `store-cache/checkpoint` | cache host | Stage a mid-run snapshot for saving |
| `store-cache/signal-checkpoint` | coordinator | Ask the cache host for a mid-run snapshot |
| `store-cache/reclaim-quota` | cache host | Clear the cache family so the next save fits in the 10 GiB repo quota |
| `store-cache/reconcile` | coordinator | Upload whatever the post-build hook missed, then fix the retention set |
| `store-cache/finalize` | cache host | Prune, verify and quiesce the generation for persisting |
| `cachix/push` | coordinator | Realise a closure locally and push it to Cachix |
| `git/commit-and-push` | anywhere | Commit as github-actions[bot] and optionally trigger a workflow |

## Layout

Every action is a directory with `action.yml` plus the scripts it runs — no inline shell in YAML, so everything is covered by shellcheck and ruff.

```
lib/ci.sh                  logging, input validation, hardened ssh, bounded waits
lib/caches.sh              the public binary caches, defined once
lib/probe-public-paths.py  narinfo filter shared by reconcile and finalize
store-cache/attic-state.sh state the store-cache actions hand across steps
```

Scripts source the library relative to their own location:

```bash
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/ci.sh"
```

## Two rules worth keeping

**Every ssh goes through `ci_ssh`/`ci_scp`.** A CI tailnet link can black-hole instead of resetting, and ssh without liveness probes then blocks in `read()` forever. That is not a slow build, it is a dead one: Nix's worker reads the `build-remote` hook's verdict synchronously, and that hook connects to a machine before answering, so one wedged connection freezes *every* concurrent build until the job hits GitHub's six-hour limit. `builders/attach` writes the equivalent options into `/etc/ssh/ssh_config.d` for Nix's own ssh-ng connections, deliberately without the control-plane multiplexing, so a stuck control connection cannot take the fleet with it.

**Every wait uses `ci_wait_until`.** It takes a deadline, so no loop in this repository can run forever by accident.

## Development

```sh
devenv shell          # or direnv allow
just lint             # everything CI checks
just fmt              # rewrite in place
just check-consumers  # does nur-packages/nix-config still resolve against this tree?
```

`just check-consumers` reads the sibling repositories' workflows and verifies each `uses:` names an action that exists here and passes only inputs it declares. Run it after any rename.
