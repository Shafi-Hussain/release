#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

# log function
log_file="${ARTIFACT_DIR}/mirror.log"
log() {
    local ts
    ts=$(date --iso-8601=seconds)
    echo "$ts" "$@" | tee -a "$log_file"
}

SECRET_DIR="/tmp/vault/powervs-rhr-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/ODH_POWER_SSH_KEY"
HOME=/tmp
SSH_KEY_PATH="$HOME/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR"


# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

POWERVS_IP=odh-power-node.ecosystemci.cis.ibm.net

REGISTRY_TOKEN_FILE="$SECRETS_PATH/$REGISTRY_SECRET/$REGISTRY_SECRET_FILE"
if [[ ! -r "$REGISTRY_TOKEN_FILE" ]]; then
    log "ERROR Registry secret file not found: $REGISTRY_TOKEN_FILE"
    exit 1
fi

log "INFO Copying secret file ${REGISTRY_TOKEN_FILE}"
# for docker
#cat ${REGISTRY_TOKEN_FILE} | ssh $SSH_ARGS root@$POWERVS_IP "mkdir -p /root/.docker; cat > /root/.docker/config.json"
# for podman
#cat ${REGISTRY_TOKEN_FILE} | ssh $SSH_ARGS root@$POWERVS_IP "mkdir -p /root/.podman/containers; cat > /root/.podman/containers/auth.json"

# Get current date
current_date=$(date +%F)
log "INFO Current date is $current_date"

# Get RELEASE_VERSION
log "INFO Z-stream version is $RELEASE_VERSION"

# Get IMAGE_REPO
log "INFO Image repo is $IMAGE_REPO"

# Get IMAGE_TAG if not provided
if [[ -z "$IMAGE_TAG" ]]; then
    case "$JOB_TYPE" in
        presubmit)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="pr-${PULL_NUMBER}"
            if [[ -n "${RELEASE_VERSION-}" ]]; then
                IMAGE_TAG="${RELEASE_VERSION}-${IMAGE_TAG}"
            fi
            ;;
        postsubmit)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-${PULL_BASE_SHA:0:7}"
            IMAGE_FLOATING_TAG="${RELEASE_VERSION}"
            ;;
        periodic)
            log "INFO Building default image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-nightly-${current_date}"
            ;;
        *)
            log "ERROR Cannot publish an image from a $JOB_TYPE job"
            exit 1
            ;;
    esac
fi

# Get IMAGE_TAG if it's equal to YearIndex in YYYYMMDD format
if [[ "$IMAGE_TAG" == "YearIndex" ]]; then
    YEAR_INDEX=$(echo "$(date +%Y%m%d)")
    case "$JOB_TYPE" in
        presubmit)
            log "INFO Building YearIndex image tag for a $JOB_TYPE job"
            IMAGE_TAG="pr-${PULL_NUMBER}"
            if [[ -n "${RELEASE_VERSION-}" ]]; then
                IMAGE_TAG="${RELEASE_VERSION}-${IMAGE_TAG}"
            fi
            ;;
        postsubmit)
            log "INFO Building YearIndex image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-${YEAR_INDEX}-${PULL_BASE_SHA:0:7}"
            IMAGE_FLOATING_TAG="${RELEASE_VERSION}-${YEAR_INDEX}"
            ;;
        periodic)
            log "INFO Building weekly image tag for a $JOB_TYPE job"
            IMAGE_TAG="${RELEASE_VERSION}-weekly"
            ;;
        *)
            log "ERROR Cannot publish an image from a $JOB_TYPE job"
            exit 1
            ;;
    esac
fi

log "INFO Image tag is $IMAGE_TAG"

# Check if running in openshift/release only in presubmit jobs because
# REPO_OWNER and REPO_NAME are not available for other types
dry=false
if [[ "$JOB_TYPE" == "presubmit" ]]; then
    if [[ "$REPO_OWNER" == "openshift" && "$REPO_NAME" == "release" ]]; then
        log "INFO Running in openshift/release, setting dry-run to true"
        dry=true
    fi
fi

# Build destination image reference
DESTINATION_REGISTRY_REPO="$REGISTRY_HOST/$REGISTRY_ORG/$IMAGE_REPO"
DESTINATION_IMAGE_REF="$DESTINATION_REGISTRY_REPO:$IMAGE_TAG"
if [[ -n "${IMAGE_FLOATING_TAG-}" ]]; then
    FLOATING_IMAGE_REF="$DESTINATION_REGISTRY_REPO:$IMAGE_FLOATING_TAG"
    DESTINATION_IMAGE_REF="$DESTINATION_IMAGE_REF $FLOATING_IMAGE_REF"
fi

export REPO_OWNER=opendatahub-io
export REPO_NAME=opendatahub-operator
export PULL_BASE_REF=incubation
export PULL_NUMBER=1047
export DESTINATION_IMAGE_REF=quay.io/shafi_rhel/opendatahub-operator:incubation-pr-$PULL_NUMBER
#export SOURCE_IMAGE_REF=quay.io/opendatahub/opendatahub-operator:latest

# set build any env to be set on Power VM
cat <<EOF > $HOME/env_vars.sh
REPO_OWNER=${REPO_OWNER:-UNKNOWN}
REPO_NAME=${REPO_NAME:-UNKNOWN}
PULL_BASE_REF=${PULL_BASE_REF:-UNKNOWN}
PULL_BASE_SHA=${PULL_BASE_SHA:-UNKNOWN}
PULL_NUMBER=${PULL_NUMBER:-UNKNOWN}
PULL_PULL_SHA=${PULL_PULL_SHA:-UNKNOWN}
PULL_REFS=${PULL_REFS:-UNKNOWN}
REGISTRY_HOST=${REGISTRY_HOST:-UNKNOWN}
REGISTRY_ORG=${REGISTRY_ORG:-UNKNOWN}
IMAGE_REPO=${IMAGE_REPO:-UNKNOWN}
IMAGE_TAG=${IMAGE_TAG:-UNKNOWN}
SOURCE_IMAGE_REF=${SOURCE_IMAGE_REF:-UNKNOWN}
DESTINATION_REGISTRY_REPO=${DESTINATION_REGISTRY_REPO:-UNKNOWN}
DESTINATION_IMAGE_REF=${DESTINATION_IMAGE_REF:-UNKNOWN}
JOB_NAME=${JOB_NAME:-UNKNOWN}
JOB_TYPE=${JOB_TYPE:-UNKNOWN}
PROW_JOB_ID=${PROW_JOB_ID:-UNKNOWN}
RELEASE_VERSION=${RELEASE_VERSION:-UNKNOWN}
JOB_SPEC=$JOB_SPEC
BUILD=${IMAGE_TAG:-$(date +%s)}
EOF

log "INFO Request Metadata:"
cat $HOME/env_vars.sh

log "INFO Sending Metadata to $POWERVS_IP"
cat $HOME/env_vars.sh | ssh $SSH_ARGS root@$POWERVS_IP "cat > /root/env_vars.sh"

log "INFO SSH to Power VM for Manifest Build/Push"
timeout --kill-after 10m 60m ssh $SSH_ARGS root@$POWERVS_IP bash -x - << EOF
        source env_vars.sh

        # for manifests. quay.io does not support format=oci (ref: https://github.com/containers/podman/issues/8353)
        export BUILDAH_FORMAT=docker

        # pull & retag
        docker pull \$DESTINATION_IMAGE_REF-ppc64le

        docker pull quay.io/opendatahub/opendatahub-operator:latest
        AMD=\$(docker inspect quay.io/opendatahub/opendatahub-operator:latest | jq '.[0].Id' | tr -d '"' | cut -d: -f2)
        docker tag \$AMD \$DESTINATION_IMAGE_REF-amd64
        docker push \$DESTINATION_IMAGE_REF-amd64

        docker manifest create \$DESTINATION_IMAGE_REF \$DESTINATION_IMAGE_REF-amd64 \$DESTINATION_IMAGE_REF-ppc64le
        docker manifest push \$DESTINATION_IMAGE_REF

EOF
