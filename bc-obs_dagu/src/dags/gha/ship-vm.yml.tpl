name: "Ship → {{VM_NAME}}"

on:
  push:
    paths:
{{PATH_FILTERS}}    branches: [main]
  workflow_dispatch:

concurrency:
  group: ship-{{VM_NAME}}
  cancel-in-progress: false

jobs:
  ship:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2
          submodules: true

      - name: Update submodules to latest
        run: git submodule update --remote

      - uses: ./.github/actions/setup-deps
        with:
{{SSH_CONFIG}}          sops_age_key: ${{ secrets.SOPS_AGE_KEY }}
{{DOCKER_STEPS}}
      - name: Ship services
        run: bash .github/workflows/scripts/ship-vm.sh {{VM_NAME}}
