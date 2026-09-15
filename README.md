# nix-actions

Shared GitHub composite actions for [nur-packages](https://github.com/mzwing/nur-packages) and [nix-config](https://github.com/mzwing/nix-config): Nix setup, a Tailscale-connected distributed build fleet, and the ephemeral Attic cache that holds the fleet's private build intermediates.

```yaml
- uses: mzwing/nix-actions/nix/setup@master
  with:
    cachix-name: mzwing
```

`.github/workflows/distributed-build.yml` is the whole build pipeline as a reusable workflow; nix-config and nur-packages each call it in about thirty lines.

## Layout

Every action is a directory with `action.yml` — which documents its own inputs — plus the scripts it runs. No inline shell in YAML, so everything is covered by shellcheck and ruff.

```
lib/ci.sh                  logging, input validation, hardened ssh, bounded waits
lib/caches.sh              the public binary caches, defined once
lib/pins.sh                the nixpkgs revision attic and rclone come from
lib/probe-public-paths.py  narinfo filter shared by reconcile and finalize
store-cache/attic-state.sh state the store-cache actions hand across steps
store-cache/rclone.sh      rclone bootstrap shared by pull and push
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
