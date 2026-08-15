# shfmt --find descends into the generated .devenv/.direnv trees, so keep it to real sources.
shell_sources := "shfmt --find . | grep -v '^\\.'"

default: lint

# Every check CI runs.
lint: lint-nix lint-yaml lint-actions lint-shell lint-python

# Rewrite every file in place.
fmt:
    alejandra .
    {{ shell_sources }} | xargs shfmt --write
    ruff format .
    ruff check --fix .

lint-nix:
    alejandra --check .

lint-yaml:
    yamllint .

lint-actions:
    actionlint

# Discovery is by shebang, so nothing needs a hand-maintained list.
lint-shell:
    {{ shell_sources }} | xargs shfmt --diff
    {{ shell_sources }} | xargs shellcheck

lint-python:
    ruff format --check .
    ruff check .
    ty check

# Check the consuming repositories against this one; catches a rename or a dropped input before a six-hour build does.
check-consumers *repos='../nur-packages ../nix-config':
    ./check-consumers.sh {{ repos }}
