#!/bin/bash
#
# This fork promises that any non-AWS backend of lancedb can be built without
# aws-lc-rs. Consumers that build slim images for a single backend (e.g.
# GCS-only) rely on this: aws-lc-rs compiles C/assembly through its cmake build
# dependency, which bloats builds, complicates cross-compilation, and forces a
# second crypto provider on deployments that standardize on ring. This script
# enforces the promise. It resolves each non-AWS backend under the
# provider-neutral TLS feature (tls-no-provider) and fails if aws-lc-rs or
# cmake appears.
#
# It checks the FUNCTIONAL configuration (backend + tls-no-provider), not the
# bare backend: the opendal HTTP transport is opt-in, so a bare backend has no
# TLS stack and would pass this check vacuously while it fails at run time. To
# guard against that, each combination must also resolve a reqwest HTTP
# transport (opendal-http-transport-reqwest); a missing transport is an error.
#
# The usual way this regresses is a dependency bump that changes a TLS default,
# not a local change. lancedb forwards the lance-io tls-* features, and lance-io
# wires the granular opendal http-transport-reqwest-rustls-no-provider feature.
#
# If this check fails, fix the feature wiring rather than exempting the crate.
#
# Two dependencies link aws-lc-rs themselves, and no feature wiring can prevent
# it:
# - The AWS SDK, through aws-smithy-http-client. Feature combinations that
#   include it (aws, dynamodb) are not checked.
# - opendal-service-hf, through hf-xet -> xet-client, which enables
#   reqwest/rustls by default. This fork removed the huggingface feature.

set -euo pipefail

cd "$(dirname "$0")/.."

FORBIDDEN=(aws-lc-rs aws-lc-sys aws-lc-fips-sys cmake)
REQUIRED=(opendal-http-transport-reqwest)

# The tls-* features exist in the lance fork only, so the check resolves against
# it. The patch is passed on the command line, because the manifests in this
# repository keep the plain crates.io dependencies.
LANCE_GIT=${LANCE_GIT:-https://github.com/instant-labs/lance.git}
LANCE_BRANCH=${LANCE_BRANCH:-release/11.x-instant}
LANCE_CRATES=(
    lance lance-arrow lance-core lance-datafusion lance-datagen lance-encoding
    lance-file lance-index lance-io lance-linalg lance-namespace
    lance-namespace-impls lance-table lance-testing
)

PATCH=()
for crate in "${LANCE_CRATES[@]}"; do
    PATCH+=(--config "patch.crates-io.${crate}.git=\"${LANCE_GIT}\"")
    PATCH+=(--config "patch.crates-io.${crate}.branch=\"${LANCE_BRANCH}\"")
done

# Cargo rewrites Cargo.lock when it resolves with the patch. Put the committed
# lock file back when this script exits.
lock_backup=$(mktemp)
cp Cargo.lock "$lock_backup"
trap 'mv -f "$lock_backup" Cargo.lock' EXIT

check() {
    local desc="$1"
    shift

    local deps
    deps=$(cargo tree "${PATCH[@]}" -e normal,build --prefix none --format '{p}' "$@" | awk '{print $1}' | sort -u)

    local failed=0
    for crate in "${FORBIDDEN[@]}"; do
        if grep -qx "$crate" <<<"$deps"; then
            echo "error: forbidden dependency '$crate' found in $desc, pulled in via:"
            cargo tree "${PATCH[@]}" -e normal,build "$@" -i "$crate"
            failed=1
        fi
    done
    for crate in "${REQUIRED[@]}"; do
        if ! grep -qx "$crate" <<<"$deps"; then
            echo "error: $desc is missing HTTP transport '$crate'; the forbidden-dependency check would pass vacuously. Wire a provider-neutral TLS transport."
            failed=1
        fi
    done
    if [[ $failed -ne 0 ]]; then
        exit 1
    fi
    echo "ok: $desc is free of {${FORBIDDEN[*]}} and has an HTTP transport"
}

check "lancedb (gcs, tls-no-provider)" -p lancedb --no-default-features --features gcs,tls-no-provider
check "lancedb (gcs, remote, tls-no-provider)" -p lancedb --no-default-features --features gcs,remote,tls-no-provider
check "lancedb (azure, tls-no-provider)" -p lancedb --no-default-features --features azure,tls-no-provider
check "lancedb (oss, tls-no-provider)" -p lancedb --no-default-features --features oss,tls-no-provider
check "lancedb (cos, tls-no-provider)" -p lancedb --no-default-features --features cos,tls-no-provider
check "lancedb (goosefs, tls-no-provider)" -p lancedb --no-default-features --features goosefs,tls-no-provider
