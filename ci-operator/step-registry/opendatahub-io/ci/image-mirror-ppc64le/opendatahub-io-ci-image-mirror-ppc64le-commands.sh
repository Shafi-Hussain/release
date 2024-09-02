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
mkdir -p $HOME/.ssh

SSH_KEY_PATH="$HOME/.ssh/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR"


# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH



POWERVS_IP="169.45.57.76"

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
export PULL_NUMBER=921

# set build any env to be set on Power VM
cat <<EOF > $HOME/env_vars.sh
REPO_OWNER=${REPO_OWNER:-UNKNOWN}
REPO_NAME=${REPO_NAME:-UNKNOWN}

PULL_BASE_REF=${PULL_BASE_REF:-UNKNOWN}
PULL_BASE_SHA=${PULL_BASE_SHA:-UNKNOWN}
PULL_HEAD_REF=${PULL_HEAD_REF:-UNKNOWN}
PULL_NUMBER=${PULL_NUMBER:-UNKNOWN}
PULL_ORGANIZATION=${PULL_ORGANIZATION:-UNKNOWN}
PULL_PULL_SHA=${PULL_PULL_SHA:-UNKNOWN}
PULL_REFS=${PULL_REFS:-UNKNOWN}
PULL_REGISTRY=${PULL_REGISTRY:-UNKNOWN}
PULL_URL=${PULL_URL:-UNKNOWN}

REGISTRY_HOST=${REGISTRY_HOST:-UNKNOWN}
REGISTRY_ORG=${REGISTRY_ORG:-UNKNOWN}
IMAGE_REPO=${IMAGE_REPO:-UNKNOWN}
IMAGE_TAG=${IMAGE_TAG:-UNKNOWN}
DESTINATION_REGISTRY_REPO=${DESTINATION_REGISTRY_REPO:-UNKNOWN}
#DESTINATION_IMAGE_REF=${DESTINATION_IMAGE_REF:-UNKNOWN}
DESTINATION_IMAGE_REF=quay.io/shafi_rhel/opendatahub-operator:incubation-pr-921
IMAGE_FLOATING_TAG=${IMAGE_FLOATING_TAG:-UNKNOWN}
FLOATING_IMAGE_REF=${FLOATING_IMAGE_REF:-UNKNOWN}

JOB_NAME=${JOB_NAME:-UNKNOWN}
JOB_TYPE=${JOB_TYPE:-UNKNOWN}
PROW_JOB_ID=${PROW_JOB_ID:-UNKNOWN}
RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST:-UNKNOWN}
RELEASE_VERSION=${RELEASE_VERSION:-UNKNOWN}

PR_AUTHOR=${PR_AUTHOR:-UNKNOWN}
PR_CHANGESET=${PR_CHANGESET:-UNKNOWN}
PR_COMMENTERS=${PR_COMMENTERS:-UNKNOWN}
PR_NUMBER=${PR_NUMBER:-UNKNOWN}
PR_REPO_NAME=${PR_REPO_NAME:-UNKNOWN}
PR_SHA=${PR_SHA:-UNKNONW}
PR_URLS=${PR_URLS:-UNKNOWN}


JOB_SPEC=$JOB_SPEC
EOF

log "INFO Request Metadata:"
cat $HOME/env_vars.sh

log "INFO Sending Metadata to $POWERVS_IP"
cat $HOME/env_vars.sh | ssh $SSH_ARGS root@$POWERVS_IP "cat > /root/env_vars.sh"

log "INFO SSH to Power VM for Build/Push"
timeout --kill-after 10m 120m ssh $SSH_ARGS root@$POWERVS_IP bash -x - << EOF
	
	# install docker
	#dnf install -y yum-utils \
	#&& dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo \
	#&& dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
	#&& systemctl start docker

	# install podman
	dnf install -y podman
        #export XDG_RUNTIME_DIR=/root/.podman

	# Install repo specific dependencies
	dnf install -y go gcc gcc-c++ make

	source env_vars.sh
	env >> debug_env
	
	rm -rf BUILD
	mkdir BUILD && cd BUILD
	git clone https://github.com/$$REPO_OWNER/$$REPO_NAME.git -b $$PULL_BASE_REF .

	git fetch origin pull/$$PULL_NUMBER/head:build_branch
	git checkout build_branch

	sed -i s/amd64/ppc64le/g Dockerfiles/Dockerfile
	IMG=$DESTINATION_IMAGE_REF make image-build
	IMG=$DESTINATION_IMAGE_REF make image-push
	
EOF

