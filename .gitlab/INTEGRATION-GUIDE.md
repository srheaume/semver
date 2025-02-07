# GitLab CI/CD Integration Guide

To simplify integration with your CI/CD pipeline, this repository provides a suite of self-contained, reusable GitLab
CI/CD Components that automate the entire versioning and release lifecycle.

### Components Overview

- **`.compute-semver`:** A component that calculates the semantic version and passes it to downstream jobs.
- **`.compute-changelog-range`:** A component that calculates the Git refs needed to generate a changelog.
- **`.create-release-branch`:** A component that starts a new release from `develop`.
- **`.finish-release-branch`:** A component that finalizes a release by creating its stable tag.
- **`.create-hotfix-branch`:** A component that starts a new hotfix from a stable branch.
- **`.finish-hotfix-branch`:** A component that finalizes a hotfix by creating its stable tag.

---

### `.compute-semver` Component

Calculates the semantic version for a branch. Designed for automated triggers like merge requests.

**Inputs (`spec:inputs`):**

| Name                         | Description                                                                            | Required | Default   |
|------------------------------|----------------------------------------------------------------------------------------|----------|-----------|
| `project_name`               | The project name prefix.                                                               | `false`  | `""`      |
| `base_version`               | The base version to use if no tags are found.                                          | `false`  | `"0.1.0"` |
| `skip_breaking_changes_from` | A comma or newline-separated list of authors whose breaking changes should be ignored. | `false`  | `""`      |

**Outputs (`dotenv` Artifact):**

| Variable             | Description                         | Example       |
|----------------------|-------------------------------------|---------------|
| `SEMVER_VERSION`     | The full computed semantic version. | `1.2.0-mr.42` |
| `SEMVER_MAJOR`       | The major version component.        | `1`           |
| `SEMVER_MINOR`       | The minor version component.        | `2`           |
| `SEMVER_PATCH`       | The patch version component.        | `0`           |
| `SEMVER_PRE_RELEASE` | The pre-release identifier.         | `mr`          |
| `SEMVER_INCREMENT`   | The pre-release increment value.    | `42`          |

**Usage Example (Automated CI):**

```yaml
workflow:
  rules:
    - if: $CI_COMMIT_BRANCH == "develop"
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"

stages: [ prepare, build ]

include:
  - remote: 'https://raw.githubusercontent.com/srheaume/semver/refs/tags/v0.1.0-stable/.gitlab/ci-templates/jobs/compute-semver/compute-semver.yml'
    inputs:
      skip_breaking_changes_from: |
        dependabot[bot]

compute-semver:
  stage: prepare
  extends: .compute-semver

build:
  stage: build
  needs: [ compute-semver ]
  script:
    - echo "Building version ${SEMVER_VERSION}"
```

---

### `.compute-changelog-range` Component

Calculates the `from` and `to` Git references for generating a changelog, making it easy to create release notes for a
branch.

**Inputs (`spec:inputs`):**

| Name            | Description                                                                                  | Required | Default |
|-----------------|----------------------------------------------------------------------------------------------|----------|---------|
| `project_name`  | The project name prefix.                                                                     | `false`  | `""`    |
| `bootstrap_ref` | For legacy projects, a commit SHA or tag to use as the starting point for the first release. | `false`  | `""`    |

**Outputs (`dotenv` Artifact):**

| Variable                | Description                             | Example                                     |
|-------------------------|-----------------------------------------|---------------------------------------------|
| `SEMVER_CHANGELOG_FROM` | The starting Git ref for the changelog. | `4a0f1b2d7a5b3c9e6f1g8h2i3j4k5l6m7n8o9p0q`  |
| `SEMVER_CHANGELOG_TO`   | The ending Git ref for the changelog.   | `8c7d3e5f1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p7` |

**Usage Example (Automated CI):**

```yaml
workflow:
  rules:
    - if: $CI_COMMIT_TAG =~ /^v[0-9]+\.[0-9]+\.[0-9]+-stable$/

stages: [ prepare, release-management ]

include:
  - remote: 'https://raw.githubusercontent.com/srheaume/semver/refs/tags/v0.1.0-stable/.gitlab/ci-templates/jobs/compute-changelog-range/compute-changelog-range.yml'

compute-changelog-range:
  stage: prepare
  extends: .compute-changelog-range

generate-changelog:
  stage: release-management
  needs: [ compute-changelog-range ]
  script:
    - git log "${SEMVER_CHANGELOG_FROM}..${SEMVER_CHANGELOG_TO}" --pretty=format:"- %s (%h)" > "CHANGELOG.md"

  artifacts:
    paths:
      - CHANGELOG.md
```

---

### `.create-release-branch` Component

Starts a new release from `develop`. Best used as a manual job.

**Inputs (`spec:inputs`):**

| Name                         | Description                                   | Required | Default   |
|------------------------------|-----------------------------------------------|----------|-----------|
| `project_name`               | The project name prefix.                      | `false`  | `""`      |
| `base_version`               | The base version to use if no tags are found. | `false`  | `"0.1.0"` |
| `skip_breaking_changes_from` | Authors to ignore for breaking changes.       | `false`  | `""`      |

**Outputs (`dotenv` Artifact):**

| Variable                    | Description                                   | Example                       |
|-----------------------------|-----------------------------------------------|-------------------------------|
| `SEMVER_RELEASE_BRANCH`     | The name of the newly created release branch. | `release/v1.2.0`              |
| `SEMVER_RELEASE_MARKER_TAG` | The name of the release start marker tag.     | `v1.2.0-release-start-marker` |

**Usage Example (Manual Trigger):**

```yaml
workflow:
  rules:
    - if: $CI_COMMIT_BRANCH == "develop"

stages: [ release-management ]

include:
  - remote: 'https://raw.githubusercontent.com/srheaume/semver/refs/tags/v0.1.0-stable/.gitlab/ci-templates/jobs/create-release-branch/create-release-branch.yml'
    inputs:
      skip_breaking_changes_from: |
        dependabot[bot]

create-release-branch:
  stage: release-management
  extends: .create-release-branch
  rules:
    - if: $CI_PIPELINE_SOURCE == "web"
      when: manual
    - when: never
```

---

### `.finish-release-branch` Component

Finalizes a release by creating and pushing its stable tag.

**Inputs (`spec:inputs`):**

| Name           | Description                                                          | Required | Default    |
|----------------|----------------------------------------------------------------------|----------|------------|
| `project_name` | The project name prefix.                                             | `false`  | `""`       |
| `branch`       | The name of the release branch to finalize (e.g., `release/v1.2.0`). | `true`   |            |
| `release_type` | The type of release for the tag: `'stable'`, `'ga'`, or `'la'`.      | `false`  | `"stable"` |

**Outputs (`dotenv` Artifact):**

| Variable                    | Description                               | Example         |
|-----------------------------|-------------------------------------------|-----------------|
| `SEMVER_RELEASE_STABLE_TAG` | The name of the newly created stable tag. | `v1.2.0-stable` |

**Usage Example (Manual Trigger with Input):**

```yaml
workflow:
  rules:
    - if: $CI_COMMIT_BRANCH == "develop"

variables:
  RELEASE_BRANCH_TO_FINALIZE:
    description: "The name of the release branch to finalize (e.g., `release/v1.2.0`)"

stages: [ release-management ]

include:
  - remote: 'https://raw.githubusercontent.com/srheaume/semver/refs/tags/v0.1.0-stable/.gitlab/ci-templates/jobs/finish-release-branch/finish-release-branch.yml'
    inputs:
      branch: $RELEASE_BRANCH_TO_FINALIZE

finish-release-branch:
  stage: release-management
  extends: .finish-release-branch
  rules:
    - if: $CI_PIPELINE_SOURCE == "web" && $RELEASE_BRANCH_TO_FINALIZE
      when: manual
    - when: never
```

---

### `.create-hotfix-branch` Component

Starts a new hotfix from a stable base branch.

**Inputs (`spec:inputs`):**

| Name           | Description                                                             | Required |
|----------------|-------------------------------------------------------------------------|----------|
| `project_name` | The project name prefix.                                                | `false`  |
| `branch`       | The stable branch to patch (e.g., `release/v1.2.0` or `hotfix/v1.2.1`). | `true`   |

**Outputs (`dotenv` Artifact):**

| Variable                   | Description                                  | Example                      |
|----------------------------|----------------------------------------------|------------------------------|
| `SEMVER_HOTFIX_BRANCH`     | The name of the newly created hotfix branch. | `hotfix/v1.2.1`              |
| `SEMVER_HOTFIX_MARKER_TAG` | The name of the hotfix start marker tag.     | `v1.2.1-hotfix-start-marker` |

---

### `.finish-hotfix-branch` Component

Finalizes a hotfix branch by creating and pushing its stable tag.

**Inputs (`spec:inputs`):**

| Name           | Description                                                        | Required | Default    |
|----------------|--------------------------------------------------------------------|----------|------------|
| `project_name` | The project name prefix.                                           | `false`  | `""`       |
| `branch`       | The name of the hotfix branch to finalize (e.g., `hotfix/v1.2.1`). | `true`   |            |
| `release_type` | The type of release for the tag: `'stable'`, `'ga'`, or `'la'`.    | `false`  | `"stable"` |

**Outputs (`dotenv` Artifact):**

| Variable                   | Description                               | Example         |
|----------------------------|-------------------------------------------|-----------------|
| `SEMVER_HOTFIX_STABLE_TAG` | The name of the newly created stable tag. | `v1.2.1-stable` |
