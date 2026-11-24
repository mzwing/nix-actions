{pkgs, ...}: {
  languages.nix = {
    enable = true;
    lsp.enable = true;
  };

  languages.python.enable = true;

  packages = with pkgs; [
    act
    actionlint
    alejandra
    just
    nixd
    ruff
    shellcheck
    shfmt
    ty
    yamllint
    yq-go
  ];

  enterTest = ''
    act --version
    actionlint -version
    alejandra --version
    just --version
    nixd --version
    ruff --version
    shellcheck --version
    shfmt --version
    ty --version
    yamllint --version
    yq --version
  '';
}
