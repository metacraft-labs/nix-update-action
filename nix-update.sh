#!/usr/bin/env bash
set -euo pipefail

enterFlakeFolder() {
  if [[ -n "${PATH_TO_FLAKE_DIR}" ]]; then
    cd "${PATH_TO_FLAKE_DIR}"
  fi
}

sanitizeInputs() {
  # remove all whitespace
  PACKAGES="${PACKAGES// /}"
  BLACKLIST="${BLACKLIST// /}"
  UNSTABLE="${UNSTABLE// /}"
  FROM_BRANCH="${FROM_BRANCH// /}"
}

determinePackages() {
  # determine packages to update
  if [[ -z "${PACKAGES}" ]]; then
    PACKAGES=$(nix flake show --json | jq -r '[.packages[] | keys[]] | sort | unique |  join(",")')
  fi
}

updated=()
skipped=()
failed=()

updatePackages() {
  # update packages
  for PACKAGE in ${PACKAGES//,/ }; do
    if [[ ",${BLACKLIST}," == *",${PACKAGE},"* ]]; then
      echo "Package '${PACKAGE}' is blacklisted, skipping."
      continue
    fi

    # Every package this script can update is defined by a
    # `./packages/<name>/default.nix` file -- that path is what gets handed to
    # `--override-filename`. A flake commonly also exposes packages built
    # inline (test fixtures, image builders, helper scripts); those have no such
    # file and no upstream version to track, so they are not ours to update.
    filename="./packages/${PACKAGE}/default.nix"
    if [[ ! -f "${filename}" ]]; then
      echo "Package '${PACKAGE}' has no ${filename}, skipping."
      skipped+=("${PACKAGE}")
      continue
    fi

    echo "Updating package '${PACKAGE}'."
    if [[ ",${UNSTABLE}," == *",${PACKAGE},"* ]]; then
      updateOnePackage "${PACKAGE}" "${filename}" --version=unstable
    elif [[ ",${FROM_BRANCH}," == *",${PACKAGE},"* ]]; then
      updateOnePackage "${PACKAGE}" "${filename}" --version=branch
    else
      updateOnePackage "${PACKAGE}" "${filename}"
    fi
  done
}

updateOnePackage() {
  local package="$1" filename="$2"
  shift 2

  local log status=0
  log="$(nix-update --flake --commit "${package}" --override-filename "${filename}" "$@" 2>&1 >/dev/null)" || status=$?
  if [[ ${status} -eq 0 ]]; then
    updated+=("${package}")
    return 0
  fi

  # Not every package a flake exposes describes an upstream release. Ones built
  # from a local path or a generated derivation have no version to parse and no
  # source URL to re-point, and nix-update can never update them.
  if [[ "${log}" == *"could not parse the version"* ]] ||
    [[ "${log}" == *"Could not find a url in the derivations src attribute"* ]]; then
    echo "Package '${package}' is not version-tracked upstream, skipping."
    skipped+=("${package}")
    return 0
  fi

  # A package that fails for any other reason is reported, but does not abort
  # the run: one bad package must not cost every package after it its update,
  # nor suppress the pull request that carries the ones that did update.
  echo "::warning::nix-update could not update '${package}'"
  echo "${log}" >&2
  failed+=("${package}")
  return 0
}

reportSummary() {
  echo "Updated: ${#updated[@]}, skipped: ${#skipped[@]}, failed: ${#failed[@]}."
  if [[ ${#failed[@]} -gt 0 ]]; then
    echo "Failed packages: ${failed[*]}"
  fi

  # Every attempted package failing is not a package problem, it is a broken
  # environment -- surface that as a failed run rather than an empty PR.
  if [[ ${#failed[@]} -gt 0 && ${#updated[@]} -eq 0 ]]; then
    echo "::error::nix-update failed for every package it attempted."
    return 1
  fi
}

enterFlakeFolder
sanitizeInputs
determinePackages
updatePackages
reportSummary
