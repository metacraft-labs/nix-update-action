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
    return 0
  fi

  # A package whose version string nix-update cannot parse is one it can never
  # update. Report it and move on rather than abandoning every package that
  # sorts after it -- one unparseable package used to stop the whole run, and
  # with it the nightly update PR.
  if [[ "${log}" == *"could not parse the version"* ]]; then
    echo "Package '${package}' has no parseable version, skipping."
    return 0
  fi

  echo "${log}" >&2
  return "${status}"
}

enterFlakeFolder
sanitizeInputs
determinePackages
updatePackages
