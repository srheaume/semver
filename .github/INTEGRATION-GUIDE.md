# GitHub Actions Integration Guide

To simplify integration with your CI/CD pipeline, this repository provides a suite of self-contained, reusable GitHub
Actions that automate the entire versioning and release lifecycle.

These actions are designed to be composable and live in the `.github/actions/` directory of your repository.

### Actions Overview

- **`compute-semver`:** An action that calculates the semantic version for a branch. Ideal for automated CI
  builds.
- **`compute-changelog-range`:** An action that calculates the Git refs needed to generate a changelog.
- **`create-release-branch`:** An action that starts a new release from `develop`.
- **`finish-release-branch`:** An action that finalizes a release by creating its stable tag.
- **`create-hotfix-branch`:** An action that starts a new hotfix from a stable branch.
- **`finish-hotfix-branch`:** An action that finalizes a hotfix by creating its stable tag.

---

### `compute-semver` Action

This is a high-level action that automates version calculation. It is designed to be the first step in a CI job after
checking out the code. It intelligently detects the branch context (e.g., a pull request or a direct push) and uses the
appropriate versioning strategy.

**Inputs:**

| Name                         | Description                                                                            | Required | Default   |
|------------------------------|----------------------------------------------------------------------------------------|----------|-----------|
| `project_name`               | The project name prefix.                                                               | `false`  | `""`      |
| `base_version`               | The base version to use if no tags are found.                                          | `false`  | `"0.1.0"` |
| `skip_breaking_changes_from` | A comma or newline-separated list of authors whose breaking changes should be ignored. | `false`  | `""`      |

**Outputs:**

| Name          | Description                         | Example       |
|---------------|-------------------------------------|---------------|
| `semver`      | The full computed semantic version. | `1.2.0-pr.42` |
| `major`       | The major version component.        | `1`           |
| `minor`       | The minor version component.        | `2`           |
| `patch`       | The patch version component.        | `0`           |
| `pre_release` | The pre-release identifier.         | `pr`          |
| `increment`   | The pre-release increment value.    | `42`          |

**Workflow Example (Automated CI):**

This workflow runs on every pull request, computes the pre-release version, and uses it in a build step.

```yaml
name: "CI Pipeline"

on:
  pull_request:
    branches:
      - "develop"
      - "hotfix/**"
      - "release/**"
    types:
      - "opened"
      - "synchronize"
  merge_group:

jobs:
  build:
    name: "Build and Test"
    runs-on: "ubuntu-latest"
    steps:
      - name: "Checkout Source Code"
        uses: "actions/checkout@v5"
        with:
          fetch-depth: 0 # Required to access full commit history

      - name: "Compute Semantic Version"
        id: "compute_semantic_version"
        uses: "srheaume/semver/.github/actions/compute-semver@v0.1.0-stable"
        with:
          # A multiline string of authors to ignore for breaking changes
          skip_breaking_changes_from: |
            dependabot[bot]

      - name: "Build Application"
        run: |
          echo "Building application with version: ${{ steps.compute_semantic_version.outputs.semver }}"
          # ./build.sh
```

---

### `compute-changelog-range` Action

This action calculates the `from` and `to` Git references required to generate a changelog.

**Inputs:**

| Name            | Description                                                                                  | Required | Default |
|-----------------|----------------------------------------------------------------------------------------------|----------|---------|
| `project_name`  | The project name prefix.                                                                     | `false`  | `""`    |
| `bootstrap_ref` | For legacy projects, a commit SHA or tag to use as the starting point for the first release. | `false`  | `""`    |

**Outputs:**

| Name   | Description                             | Example                                     |
|--------|-----------------------------------------|---------------------------------------------|
| `from` | The starting Git ref for the changelog. | `4a0f1b2d7a5b3c9e6f1g8h2i3j4k5l6m7n8o9p0q`  |
| `to`   | The ending Git ref for the changelog.   | `8c7d3e5f1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p7` |

**Workflow Example (Automated CI):**

```yaml
name: "Create Changelog"

on:
  push:
    tags:
      - "v*.*.*-stable"
      - "v*.*.*-ga"
      - "v*.*.*-la"

jobs:
  generate-changelog:
    name: "Generate Changelog"
    runs-on: "ubuntu-latest"
    steps:
      - name: "Checkout Source Code"
        uses: "actions/checkout@v5"
        with:
          fetch-depth: 0 # Required to access full commit history

      - name: "Compute Changelog Range"
        id: "compute_changelog_range"
        uses: "srheaume/semver/.github/actions/compute-changelog-range@v0.1.0-stable"

      - name: "Generate Changelog"
        run: |
          git log "${{ steps.compute_changelog_range.outputs.from }}..${{ steps.compute_changelog_range.outputs.to }}" --pretty=format:"- %s (%h)" > "CHANGELOG.md"
          
      - name: "Upload Artifact"
        uses: "actions/upload-artifact@v4"
        with:
          name: "CHANGELOG"
          path: "CHANGELOG.md"
```

---

### `create-release-branch` Action

This action starts a new release. It runs the `semver.sh create-release-branch` command to calculate the next release
version from `develop`, create the `release/vX.Y.Z` branch, and push it to the repository.

**Inputs:**

| Name                         | Description                                                    | Required | Default   |
|------------------------------|----------------------------------------------------------------|----------|-----------|
| `github_token`               | The GitHub token used to push. Must be `secrets.GITHUB_TOKEN`. | `true`   |           |
| `project_name`               | The project name prefix.                                       | `false`  | `""`      |
| `base_version`               | The base version to use if no tags are found.                  | `false`  | `"0.1.0"` |
| `skip_breaking_changes_from` | Authors to ignore for breaking changes.                        | `false`  | `""`      |

**Outputs:**

| Name     | Description                                                            |
|----------|------------------------------------------------------------------------|
| `branch` | The name of the newly created release branch (e.g., `release/v1.2.0`). |
| `tag`    | The name of the release start marker tag.                              |

**Workflow Example (Manual Trigger):**

```yaml
name: "Start New Release"

on:
  workflow_dispatch:

jobs:
  create-release-branch:
    name: "Create Release Branch"
    runs-on: "ubuntu-latest"
    permissions:
      contents: "write" # Required to push the new branch and tag
    steps:
      - name: "Checkout Source Code"
        uses: "actions/checkout@v5"
        with:
          fetch-depth: 0 # Required to access full commit history

      - name: "Create New Release Branch"
        uses: "srheaume/semver/.github/actions/create-release-branch@v0.1.0-stable"
        with:
          github_token: "${{ secrets.GITHUB_TOKEN }}"
```

---

### `finish-release-branch` Action

This action finalizes a release by creating and pushing its stable tag (e.g., `v1.2.0-stable`).

**Inputs:**

| Name           | Description                                                          | Required | Default    |
|----------------|----------------------------------------------------------------------|----------|------------|
| `github_token` | The GitHub token used to push. Must be `secrets.GITHUB_TOKEN`.       | `true`   |            |
| `project_name` | The project name prefix.                                             | `false`  | `""`       |
| `branch`       | The name of the release branch to finalize (e.g., `release/v1.2.0`). | `true`   |            |
| `release_type` | The type of release for the tag: `'stable'`, `'ga'`, or `'la'`.      | `false`  | `"stable"` |

**Outputs:**

| Name  | Description                               |
|-------|-------------------------------------------|
| `tag` | The name of the newly created stable tag. |

**Workflow Example (Manual Trigger):**

```yaml
name: "Finalize Release"

on:
  workflow_dispatch:
    inputs:
      branch:
        description: "The full name of the release branch to finalize (e.g., release/v1.2.0)"
        required: true

jobs:
  finish-release:
    name: "Finalize Release Branch"
    runs-on: "ubuntu-latest"
    permissions:
      contents: "write" # Required to push the new tag
    steps:
      - name: "Checkout Source Code"
        uses: "actions/checkout@v5"
        with:
          fetch-depth: 0 # Required to access full commit history

      - name: "Finalize Release Branch"
        uses: "srheaume/semver/.github/actions/finish-release-branch@v0.1.0-stable"
        with:
          github_token: "${{ secrets.GITHUB_TOKEN }}"
          branch: "${{ github.event.inputs.branch }}"
```

---

### `create-hotfix-branch` Action

This action starts a new hotfix. It calculates the next patch version from a stable base branch and creates the
`hotfix/vX.Y.Z` branch.

**Inputs:**

| Name           | Description                                                             | Required |
|----------------|-------------------------------------------------------------------------|----------|
| `github_token` | The GitHub token used to push. Must be `secrets.GITHUB_TOKEN`.          | `true`   |
| `project_name` | The project name prefix.                                                | `false`  |
| `branch`       | The stable branch to patch (e.g., `release/v1.2.0` or `hotfix/v1.2.1`). | `true`   |

**Outputs:**

| Name     | Description                                                          |
|----------|----------------------------------------------------------------------|
| `branch` | The name of the newly created hotfix branch (e.g., `hotfix/v1.2.1`). |
| `tag`    | The name of the hotfix start marker tag.                             |

---

### `finish-hotfix-branch` Action

This action finalizes a hotfix by creating and pushing its stable tag.

**Inputs:**

| Name           | Description                                                        | Required | Default    |
|----------------|--------------------------------------------------------------------|----------|------------|
| `github_token` | The GitHub token used to push. Must be `secrets.GITHUB_TOKEN`.     | `true`   |            |
| `project_name` | The project name prefix.                                           | `false`  | `""`       |
| `branch`       | The name of the hotfix branch to finalize (e.g., `hotfix/v1.2.1`). | `true`   |            |
| `release_type` | The type of release for the tag: `'stable'`, `'ga'`, or `'la'`.    | `false`  | `"stable"` |

**Outputs:**

| Name  | Description                               |
|-------|-------------------------------------------|
| `tag` | The name of the newly created stable tag. |
