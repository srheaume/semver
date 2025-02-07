#!/usr/bin/env bash

#
#  This file is part of semver.sh.
#
#  semver.sh is free software: you can redistribute it and/or modify
#  it under the terms of the GNU Lesser General Public License as published by
#  the Free Software Foundation, either version 3 of the License, or
#  (at your option) any later version.
#
#  semver.sh is distributed in the hope that it will be useful,
#  but WITHOUT ANY WARRANTY; without even the implied warranty of
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#  GNU Lesser General Public License for more details.
#
#  You should have received a copy of the GNU Lesser General Public License
#  along with semver.sh.  If not, see <https://www.gnu.org/licenses/>.
#

set -eo pipefail

__SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly __SCRIPT_NAME

#=============================================================================
# Private Constants

readonly __RELEASE_TYPES=("ga" "la" "stable")

#=============================================================================
# Private Variables

__arg_command=""
__opt_base_version="0.1.0"
__opt_bootstrap_ref=""
__opt_branch="${__opt_branch:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")}"
__opt_versioning_strategy="commit-count"
__opt_json=false
__opt_request_number=""
__opt_request_type="pr"
__opt_project_name=""
__opt_remote=""
__opt_quiet=false
__opt_release_type="stable"
__opt_skip_breaking_changes_from=()

#=============================================================================
# Private Methods

#-----------------------------------------------------------------------------
# Usage
#-----------------------------------------------------------------------------

__usage_print() {
    cat <<EOF
Usage: ${__SCRIPT_NAME} <COMMAND> [OPTION]...

Commands:
  show-version                 Display the semantic version for the specified
                               branch or the current branch if none is
                               provided.
  show-changelog-range         Output the 'from' and 'to' Git refs for
                               generating a changelog.
  create-release-branch        Create a new release branch using the calculated
                               semantic version.
  create-hotfix-branch         Create a new hotfix branch for patching a stable
                               version.
  finish-release-branch        Finalize a release branch by tagging and marking
                               it as stable.
  finish-hotfix-branch         Finalize a hotfix branch by tagging and marking
                               it as stable.

Options:
  General Options:
        --project-name <name>  Project name to prefix branches and tags.
                               Defaults to an empty string.
        --base-version <version>
                               Base version to use if no tags are found.
                               Defaults to "0.1.0".
        --remote <name>        Remote repository to interact with.
                               Defaults to auto-detection
                               ('origin' or the first available).
        --json                 Output information in JSON format.
    -q, --quiet                Suppress detailed output showing the branches
                               and tags being created.
    -h, --help                 Display this help message and exit.

  show-version Options:
    (inherits General Options)
    -b, --branch <branch>      Branch to calculate the semantic version for.
                               Defaults to the current branch.
        --versioning-strategy <strategy>
                               Strategy for determining the pre-release version:
                                - commit-count (default)
                                - request-number
        --request-number <number>
                               The PR/MR number to use as the pre-release
                               increment. Required if
                               --versioning-strategy="request-number".
        --request-type <type>  Type of the request, either 'pr' for Pull Request
                               or 'mr' for Merge Request. Defaults to 'pr'.
        --skip-breaking-changes-from <author>
                               Ignore breaking changes from a specific author
                               (e.g., dependabot[bot]).
                               Repeat the option to specify multiple authors.

  show-changelog-range Options:
    (inherits General Options)
    -b, --branch <branch>      Branch to get the changelog range for.
                               Defaults to the current branch.
        --bootstrap-ref <ref>  Used only for the first 'semver.sh'-tracked
                               release on a legacy project to specify a
                               starting point. This is ignored if a previous
                               'semver.sh' release is found.

  create-release-branch Options:
    (inherits General Options)
        --skip-breaking-changes-from <author>
                               Ignore breaking changes from a specific author
                               (e.g., dependabot[bot]).
                               Repeat the option to specify multiple authors.

  create-hotfix-branch Options:
    (inherits General Options)
    -b, --branch <branch>      Specify the branch of the stable version to
                               patch (e.g., release/v1.2.0).

  finish-release-branch Options:
    (inherits General Options)
    -b, --branch <branch>      Specify the release branch to finalize (e.g.,
                               release/v1.2.0).
        --release-type <type>  Type of release for the version:
                                - stable: a stable release (default)
                                - ga: general availability
                                - la: limited availability

  finish-hotfix-branch Options:
    (inherits General Options)
    -b, --branch <branch>      Specify the hotfix branch to finalize (e.g.,
                               hotfix/1.2.1).
        --release-type <type>  Type of release for the version:
                                - stable: a stable release (default)
                                - ga: general availability
                                - la: limited availability
EOF
}

#-----------------------------------------------------------------------------
# Logging Utilities
#-----------------------------------------------------------------------------

__error_log() {
    local __param_message="${1}"

    printf "\033[0;31mERROR\033[0m: %b\n" "${__param_message}" >&2
    exit 1
}

#-----------------------------------------------------------------------------
# Git Utilities
#-----------------------------------------------------------------------------

__git_branch_fetch_if_missing() {
    local __param_branch="${1}"

    # Return immediately if the branch already exists locally
    if git show-ref --verify --quiet "refs/heads/${__param_branch}"; then
        return 0
    fi

    # If not local, find the branch on a remote
    git fetch "${__opt_remote}" "${__param_branch}:${__param_branch}" --quiet || {
        __error_log "branch '${__param_branch}' not found on remote '${__opt_remote}'"
    }
}

__git_get_default_remote() {
    if git remote | grep -q "^origin$"; then
        echo "origin"
    else
        git remote | head -n 1
    fi
}

__git_is_repo_valid() {
    git rev-parse --is-inside-work-tree &>/dev/null &&
        git rev-parse --verify HEAD &>/dev/null
}

__git_ref_exists() {
    local __param_ref="${1}"

    # 1. Check if it's a local branch
    git show-ref --verify --quiet "refs/heads/${__param_ref}" || \
    # 2. Check if it's a remote branch on the specified remote
    git ls-remote --quiet --exit-code "${__opt_remote}" "refs/heads/${__param_ref}" &>/dev/null || \
    # 3. Fallback: Check if it's any other valid reference (commit, tag, HEAD, etc.)
    #    The '^{commit}' suffix ensures the ref points to a commit object.
    git rev-parse --verify --quiet "${__param_ref}^{commit}" &>/dev/null
}

__git_tag_exists() {
    local __param_tag="${1}"

    # Check if the tag exists locally or remotely
    git tag --list | grep -q "^${__param_tag}$" ||
        git ls-remote --quiet --exit-code --tags "${__opt_remote}" "refs/tags/${__param_tag}" &>/dev/null
}

#-----------------------------------------------------------------------------
# Command-Line Argument Parsing and Validation
#-----------------------------------------------------------------------------

__command_line_parse() {
    local __opts
    if ! __opts="$(getopt --options "b:qh" --longoptions "base-version:,bootstrap-ref:,branch:,help,json,project-name:,quiet,release-type:,remote:,request-number:,request-type:,skip-breaking-changes-from:,versioning-strategy:" -n "${__SCRIPT_NAME}" -- "${@}")"; then
        __error_log "failed parsing options"
    fi

    eval set -- "${__opts}"

    while true; do
        case "${1}" in
        "--base-version")
            __opt_base_version="${2}"
            shift 2
            ;;
        "--bootstrap-ref")
            __opt_bootstrap_ref="${2}"
            shift 2
            ;;
        "-b" | "--branch")
            __opt_branch="${2}"
            shift 2
            ;;
        "-h" | "--help")
            __usage_print
            exit 0
            ;;
        "--json")
            __opt_json=true
            shift
            ;;
        "--project-name")
            __opt_project_name="${2}"
            shift 2
            ;;
        "-q" | "--quiet")
            __opt_quiet=true
            shift
            ;;
        "--release-type")
            __opt_release_type="${2}"
            shift 2
            ;;
        "--remote")
            __opt_remote="${2}"
            shift 2
            ;;
        "--request-number")
            __opt_request_number="${2}"
            shift 2
            ;;
        "--request-type")
            __opt_request_type="${2}"
            shift 2
            ;;
        "--skip-breaking-changes-from")
            __opt_skip_breaking_changes_from+=("${2}")
            shift 2
            ;;
        "--versioning-strategy")
            __opt_versioning_strategy="${2}"
            shift 2
            ;;
        --)
            break
            ;;
        *)
            __error_log "internal error"
            ;;
        esac
    done

    if [[ $# -lt 2 ]]; then
        __error_log "missing arguments"
    fi

    if [[ $# -gt 2 ]]; then
        __error_log "too many arguments"
    fi

    __arg_command="${2}"
}

__command_line_validate() {
    # Set the default remote if the user has not provided one
    if [[ -z "${__opt_remote}" ]]; then
        __opt_remote="$(__git_get_default_remote)"
    fi

    # Validate that the configured remote (either user-provided or auto-detected) exists
    if ! git remote | grep -q "^${__opt_remote}$"; then
        __error_log "remote '${__opt_remote}' does not exist"
    fi

    # Determine branch prefix from project name if provided
    local __branch_prefix="${__opt_project_name:+${__opt_project_name}/}"

    # Validate base version format
    if ! [[ "${__opt_base_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        __error_log "invalid base version: '${__opt_base_version}'"
    fi

    # Ensure the specified branch is present locally, as it's a prerequisite for all subsequent commands
    __git_branch_fetch_if_missing "${__opt_branch}"

    # Command-specific validation
    case "${__arg_command}" in
    "show-version" | "show-changelog-range" | "create-release-branch")
        # No additional checks
        ;;
    "create-hotfix-branch")
        # Validate branch format for hotfix branch creation
        if [[ ! "${__opt_branch}" =~ ^${__branch_prefix}release/v[0-9]+\.[0-9]+\.[0-9]+$ && ! "${__opt_branch}" =~ ^${__branch_prefix}hotfix/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            __error_log "branch must be a release or hotfix branch (e.g., '${__branch_prefix}release/v*' or '${__branch_prefix}hotfix/v*')"
        fi
        ;;
    "finish-release-branch")
        # Validate branch format for release branch finishing
        if [[ ! "${__opt_branch}" =~ ^${__branch_prefix}release/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            __error_log "branch must be a release branch (e.g., '${__branch_prefix}release/v*')"
        fi
        ;;
    "finish-hotfix-branch")
        # Validate branch format for hotfix branch finishing
        if [[ ! "${__opt_branch}" =~ ^${__branch_prefix}hotfix/v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            __error_log "branch must be a hotfix branch (e.g., '${__branch_prefix}hotfix/v*')"
        fi
        ;;
    *)
        __error_log "invalid command"
        ;;
    esac

    # Ensure the development branch exists locally, fetching if necessary
    local __develop_branch="${__branch_prefix}develop"
    __git_branch_fetch_if_missing "${__develop_branch}"

    # Validate versioning strategy
    case "${__opt_versioning_strategy}" in
    "commit-count")
        # No additional checks
        ;;
    "request-number")
        # Request number must be specified
        if [[ -z "${__opt_request_number}" ]]; then
            __error_log "request number must be specified when using the 'request-number' versioning strategy"
        fi
        ;;
    *)
        __error_log "invalid versioning strategy: '${__opt_versioning_strategy}'"
        ;;
    esac

    # Validate request type
    if [[ "${__opt_request_type}" != "pr" && "${__opt_request_type}" != "mr" ]]; then
        __error_log "invalid request type: '${__opt_request_type}'"
    fi

    # Validate the release type
    local __release_type
    for __release_type in "${__RELEASE_TYPES[@]}"; do
        if [[ "${__opt_release_type}" == "${__release_type}" ]]; then
            break
        fi
    done

    if [[ "${__opt_release_type}" != "${__release_type}" ]]; then
        __error_log "invalid release type: '${__opt_release_type}'"
    fi

    # Validate bootstrap ref if provided
    if [[ -n "${__opt_bootstrap_ref}" ]]; then
        if ! __git_ref_exists "${__opt_bootstrap_ref}"; then
            __error_log "invalid bootstrap reference: '${__opt_bootstrap_ref}'"
        fi
    fi
}

#-----------------------------------------------------------------------------
# Semantic Versioning (SemVer) Calculation
#-----------------------------------------------------------------------------

__marker_tag_get_closest() {
    local __param_branch="${1}"
    local __param_develop_branch="${2}"
    local __param_start_marker_tag_format="${3}"

    local __marker_tag=""

    if [[ "${__param_branch}" == "${__param_develop_branch}" ]]; then
        # Handle the development branch
        local __commit_hash __current_marker_tag
        __commit_hash="$(git rev-parse "${__param_branch}")"
        __current_marker_tag="$(git describe --tags --exact-match --match "${__param_start_marker_tag_format}" "${__commit_hash}" 2>/dev/null)"

        if [[ -n "${__current_marker_tag}" ]]; then
            # If on a marker tag, find the previous one
            __marker_tag="$(git tag --list "${__param_start_marker_tag_format}" | sort -V | awk -v tag="${__current_marker_tag}" '
                    $0 == tag { exit }
                    { prev = $0 }
                    END { print prev }
                ')"
        else
            # Find the closest marker tag merged into the branch
            __marker_tag="$(git tag --merged "${__param_branch}" --list "${__param_start_marker_tag_format}" | sort -V | tail -n 1)"
        fi
    else
        # For other branches (release, hotfix, etc.), find the closest merged marker tag
        __marker_tag="$(git tag --merged "${__param_branch}" --list "${__param_start_marker_tag_format/\*/${__param_branch##*v}}")"
    fi

    echo "${__marker_tag}"
}

__semver_calculate() {
    # Define default pre-release type and marker format
    local __pre_release __start_marker_tag_format
    local __found_stable_type=""

    case "${__opt_branch}" in
    develop | */develop)
        __pre_release="dev"
        __start_marker_tag_format="${__opt_project_name:+${__opt_project_name}-}v*-release-start-marker"
        ;;
    release/v* | */release/v*)
        __pre_release="rc"
        __start_marker_tag_format="${__opt_project_name:+${__opt_project_name}-}v*-release-start-marker"

        # Check if a stable tag matches this branch version
        local __branch_version="${__opt_branch##*v}"
        local __release_type
        for __release_type in "${__RELEASE_TYPES[@]}"; do
            local __candidate_tag="${__opt_project_name:+${__opt_project_name}-}v${__branch_version}-${__release_type}"
            if __git_tag_exists "${__candidate_tag}" && \
               git merge-base --is-ancestor "${__candidate_tag}" "${__opt_branch}" 2>/dev/null; then
                __found_stable_type="${__release_type}"
                break
            fi
        done
        ;;
    hotfix/v* | */hotfix/v*)
        __pre_release="rc"
        __start_marker_tag_format="${__opt_project_name:+${__opt_project_name}-}v*-hotfix-start-marker"

        # Check if a stable tag matches this branch version
        local __branch_version="${__opt_branch##*v}"
        local __release_type
        for __release_type in "${__RELEASE_TYPES[@]}"; do
            local __candidate_tag="${__opt_project_name:+${__opt_project_name}-}v${__branch_version}-${__release_type}"
            if __git_tag_exists "${__candidate_tag}" && \
               git merge-base --is-ancestor "${__candidate_tag}" "${__opt_branch}" 2>/dev/null; then
                __found_stable_type="${__release_type}"
                break
            fi
        done
        ;;
    *)
        __error_log "unsupported branch type: '${__opt_branch}'"
        ;;
    esac

    # Override pre-release type if the versioning strategy is based on a request number
    [[ "${__opt_versioning_strategy}" == "request-number" ]] && __pre_release="${__opt_request_type}"

    local __version_major __version_minor __version_patch __version_increment
    local __semver

    # ------------------------------------------------------------------------
    # SCENARIO A: A stable tag was found (Stable/GA/LA Context)
    # ------------------------------------------------------------------------
    if [[ -n "${__found_stable_type}" ]]; then
        local __version="${__opt_branch##*v}"
        IFS='.' read -r __version_major __version_minor __version_patch <<<"${__version}"

        __semver="${__version}-${__found_stable_type}"

        if ${__opt_json}; then
            cat <<EOF
{
  "semver": "${__semver}",
  "components": {
    "major": ${__version_major},
    "minor": ${__version_minor},
    "patch": ${__version_patch},
    "release_type": "${__found_stable_type}"
  }
}
EOF
        else
            echo "${__semver}"
        fi

    # ------------------------------------------------------------------------
    # SCENARIO B: No stable tag found (Development/RC Context)
    # ------------------------------------------------------------------------
    else
        local __develop_branch="${__opt_project_name:+${__opt_project_name}/}develop"
        local __marker_tag
        __marker_tag="$(__marker_tag_get_closest "${__opt_branch}" "${__develop_branch}" "${__start_marker_tag_format}")"

        local __commit_range __version
        if [[ -n "${__marker_tag}" ]]; then
            __commit_range="$(git rev-list --reverse "${__marker_tag}..${__opt_branch}")"
            __version="$(echo "${__marker_tag}" | sed -E 's/^[a-zA-Z0-9_-]*-?v([0-9]+\.[0-9]+\.[0-9]+)-(release|hotfix)-start-marker$/\1/')"
        else
            __commit_range="$(git rev-list --reverse "${__opt_branch}")"
            __version="${__opt_base_version}"
        fi

        IFS='.' read -r __version_major __version_minor __version_patch <<<"${__version}"

        # Check for breaking changes
        local __breaking_change=false
        if [[ -n "${__commit_range}" ]]; then
            while IFS= read -r __commit; do
                local __commit_message
                __commit_message="$(git log --format=%B -n 1 "${__commit}")"
                if echo "${__commit_message}" | head -n 1 | grep -qE '^[a-z]+(\([a-z]+\))?!:.+' ||
                    echo "${__commit_message}" | tail -n +2 | grep -qE '^BREAKING CHANGE:.*'; then

                    if [[ "${__opt_branch}" != "${__develop_branch}" ]]; then
                        __error_log "breaking changes are not allowed on release or hotfix branches"
                    fi

                    local __commit_author
                    __commit_author="$(git show -s --format="%an" "${__commit}")"
                    local __skip_commit=false
                    for __author in "${__opt_skip_breaking_changes_from[@]}"; do
                        [[ "${__author}" == "${__commit_author}" ]] && __skip_commit=true && break
                    done

                    if [[ "${__skip_commit}" == false ]]; then
                        __breaking_change=true
                        break
                    fi
                fi
            done <<<"${__commit_range}"
        fi

        # Increment version (Develop only logic)
        if [[ "${__opt_branch}" == "${__develop_branch}" ]]; then
            if [[ "${__breaking_change}" == "true" ]]; then
                __version_major="$((__version_major + 1))"
                __version_minor="0"
                __version_patch="0"
            elif [[ -n "${__marker_tag}" || "${__version}" != "${__opt_base_version}" ]]; then
                __version_minor="$((__version_minor + 1))"
            fi
        fi

        # Calculate increment
        __version_increment="0"
        if [[ "${__opt_versioning_strategy}" == "request-number" ]]; then
            __version_increment="${__opt_request_number}"
        else
            if [[ -n "${__marker_tag}" ]]; then
                __version_increment="$(git rev-list --count "${__marker_tag}..${__opt_branch}")"
                [[ "${__opt_branch}" == "${__develop_branch}" ]] && __version_increment="$((__version_increment - 1))"
            else
                __version_increment="$(($(git rev-list --count "${__opt_branch}") - 1))"
            fi
        fi

        __semver="${__version_major}.${__version_minor}.${__version_patch}-${__pre_release}.${__version_increment}"

        if ${__opt_json}; then
            cat <<EOF
{
  "semver": "${__semver}",
  "components": {
    "major": ${__version_major},
    "minor": ${__version_minor},
    "patch": ${__version_patch},
    "pre_release": "${__pre_release}",
    "increment": ${__version_increment}
  }
}
EOF
        else
            echo "${__semver}"
        fi
    fi
}

#-----------------------------------------------------------------------------
# Command Callbacks
#-----------------------------------------------------------------------------

__command_show_version() {
    __semver_calculate
}

__command_show_changelog_range() {
    local __from_ref=""
    local __to_ref
    __to_ref="$(git rev-parse "${__opt_branch}^{commit}")"

    if [[ "${__opt_branch}" =~ hotfix/v ]]; then
        local __version="${__opt_branch##*v}"
        local __start_marker_tag_format="${__opt_project_name:+${__opt_project_name}-}v${__version}-hotfix-start-marker"

        local __hotfix_start_marker
        __hotfix_start_marker="$(git tag --merged "${__opt_branch}" --list "${__start_marker_tag_format}")"

        if [[ -z "${__hotfix_start_marker}" ]]; then
            __error_log "could not find the hotfix start marker tag for branch '${__opt_branch}'"
        fi

        __from_ref="$(git rev-parse "${__hotfix_start_marker}^{commit}")"
    else
        local __start_marker_tag_format="${__opt_project_name:+${__opt_project_name}-}v*-release-start-marker"

        local __current_marker_tag
        __current_marker_tag="$(git tag --merged "${__opt_branch}" --list "${__start_marker_tag_format}" | sort -V | tail -n1)"

        __from_ref="$(git tag --list "${__start_marker_tag_format}" | sort -V | awk -v tag="${__current_marker_tag}" '
            $0 == tag { exit }
            { prev = $0 }
            END { print prev }
        ')"

        if [[ -z "${__from_ref}" ]]; then
            if [[ -n "${__opt_bootstrap_ref}" ]]; then
                __from_ref="${__opt_bootstrap_ref}"
            else
                __from_ref="$(git rev-list --max-parents=0 "${__opt_branch}" | tail -n 1)"
            fi
        fi

        __from_ref="$(git rev-parse "${__from_ref}^{commit}")"
    fi

    # Output the results
    if ${__opt_json}; then
        cat <<EOF
{
  "from": "${__from_ref}",
  "to": "${__to_ref}"
}
EOF
    else
        echo "${__from_ref}..${__to_ref}"
    fi
}

__command_create_release_branch() {
    # Save the original value of __opt_json in __opt_json_saved
    local __opt_json_saved="${__opt_json}"

    # Define the base branch (develop) from which to create the release branch
    __opt_branch="${__opt_project_name:+${__opt_project_name}/}develop"
    __opt_json=false

    # Calculate the next semantic version and strip any pre-release or build metadata
    local __version
    __version="$(__semver_calculate)"
    __version="${__version%%-*}"

    # Restore the original value of __opt_json from __opt_json_saved
    __opt_json="${__opt_json_saved}"

    # Define release branch and marker tag
    local __release_branch="${__opt_project_name:+${__opt_project_name}/}release/v${__version}"
    local __marker_tag="${__opt_project_name:+${__opt_project_name}-}v${__version}-release-start-marker"

    # Check if the release branch already exists to avoid duplicates
    if __git_ref_exists "${__release_branch}"; then
        __error_log "release branch '${__release_branch}' already exists"
    fi

    # Create the release branch and push it to the remote repository
    git branch "${__release_branch}" "${__opt_branch}"
    git push "${__opt_remote}" "${__release_branch}"

    # Check if the release start marker tag already exists
    if __git_tag_exists "${__marker_tag}"; then
        __error_log "marker tag '${__marker_tag}' already exists"
    fi

    # Create and push the release start marker tag
    git tag -a "${__marker_tag}" -m "release start marker for version '${__version}'" "${__release_branch}"
    git push "${__opt_remote}" "${__marker_tag}"

    # Verbose output to display the created branch and tag
    if ! ${__opt_quiet}; then
        if ${__opt_json}; then
            cat <<EOF
{
  "branch": "${__release_branch}",
  "tag": "${__marker_tag}"
}
EOF
        else
            echo "branch: ${__release_branch}"
            echo "tag: ${__marker_tag}"
        fi
    fi
}

__command_create_hotfix_branch() {
    # Extract version from the branch name (assumes version is in the format v<version>)
    local __version="${__opt_branch##*v}"

    # Check if a stable tag exists for the given version and release type
    local __stable_tag_exists=false
    local __release_type

    # Loop through each possible release type to check for a stable tag
    for __release_type in "${__RELEASE_TYPES[@]}"; do
        local __stable_tag="v${__version}-${__release_type}"

        # If a stable tag is found, set the flag to true and exit the loop
        if __git_tag_exists "${__stable_tag}"; then
            __stable_tag_exists=true
            break
        fi
    done

    # Log an error if no stable tag exists for the given version
    if ! ${__stable_tag_exists}; then
        __error_log "stable tag for version '${__version}' does not exist"
    fi

    # Increment the patch version for the hotfix (e.g., v1.2.3 becomes v1.2.4)
    local __version_major __version_minor __version_patch
    IFS='.' read -r __version_major __version_minor __version_patch <<<"${__version}"
    __version="${__version_major}.${__version_minor}.$((__version_patch + 1))"

    # Define the hotfix branch name and marker tag format
    local __hotfix_branch="${__opt_project_name:+${__opt_project_name}/}hotfix/v${__version}"
    local __marker_tag="${__opt_project_name:+${__opt_project_name}-}v${__version}-hotfix-start-marker"

    # Check if the hotfix branch already exists to avoid duplicates
    if __git_ref_exists "${__hotfix_branch}"; then
        __error_log "hotfix branch '${__hotfix_branch}' already exists"
    fi

    # Create the hotfix branch and push it to the remote repository
    git branch "${__hotfix_branch}" "${__opt_branch}"
    git push "${__opt_remote}" "${__hotfix_branch}"

    # Check if the hotfix start marker tag already exists
    if __git_tag_exists "${__marker_tag}"; then
        __error_log "marker tag '${__marker_tag}' already exists"
    fi

    # Create and push the hotfix start marker tag
    git tag -a "${__marker_tag}" -m "hotfix start marker for version '${__version}'" "${__hotfix_branch}"
    git push "${__opt_remote}" "${__marker_tag}"

    # Verbose output to display the created branch and tag
    if ! ${__opt_quiet}; then
        if ${__opt_json}; then
            cat <<EOF
{
  "branch": "${__hotfix_branch}",
  "tag": "${__marker_tag}"
}
EOF
        else
            echo "branch: ${__hotfix_branch}"
            echo "tag: ${__marker_tag}"
        fi
    fi
}

__command_finish_release_branch() {
    # Extract version from the branch name (assumes version is in the format v<version>)
    local __version="${__opt_branch##*v}"
    local __stable_tag="${__opt_project_name:+${__opt_project_name}-}v${__version}-${__opt_release_type}"

    # Check if the stable tag already exists to avoid duplicates
    if __git_tag_exists "${__stable_tag}"; then
        __error_log "stable tag '${__stable_tag}' already exists"
    fi

    # Create the annotated stable tag and push it to the remote repository
    git tag -a "${__stable_tag}" -m "stable version ${__version} (${__opt_release_type})" "${__opt_branch}"
    git push "${__opt_remote}" "${__stable_tag}"

    # Verbose output to display the created stable tag
    if ! ${__opt_quiet}; then
        if ${__opt_json}; then
            cat <<EOF
{
  "tag": "${__stable_tag}"
}
EOF
        else
            echo "tag: ${__stable_tag}"
        fi
    fi
}

__command_finish_hotfix_branch() {
    # Reuse the logic from the finish release branch function
    __command_finish_release_branch
}

#=============================================================================
# Main Function

main() {
    # Parse command-line options
    __command_line_parse "${@}"

    # Check if the script is executed within a valid Git repository
    if ! __git_is_repo_valid; then
        __error_log "current directory is not a valid Git repository or the HEAD reference is missing"
    fi

    # Validate the parsed options and arguments
    __command_line_validate

    # Execute the command based on the user's input
    case "${__arg_command}" in
    "show-version")
        __command_show_version
        ;;
    "show-changelog-range")
        __command_show_changelog_range
        ;;
    "create-release-branch")
        __command_create_release_branch
        ;;
    "create-hotfix-branch")
        __command_create_hotfix_branch
        ;;
    "finish-release-branch")
        __command_finish_release_branch
        ;;
    "finish-hotfix-branch")
        __command_finish_hotfix_branch
        ;;
    esac
}

# Execute the main function with provided arguments
main "${@}"
