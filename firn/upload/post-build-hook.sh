#!/bin/sh
# Nix waits for this hook, so it only enqueues; the drainer skips dotfiles, so the rename publishes each entry whole
entry="$(mktemp /tmp/firn-spool/.XXXXXX)"
# shellcheck disable=SC2086
printf '%s\n' ${OUT_PATHS} >"${entry}"
mv "${entry}" "/tmp/firn-spool/${entry##*/.}"
