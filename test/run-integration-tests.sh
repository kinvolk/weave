#!/bin/bash
#
# Description:
#   This script runs all Weave Net's integration tests on the specified
#   provider (default: Google Cloud Platform).
#
# Usage:
#
#   Run all integration tests on Google Cloud Platform:
#   $ ./run-integration-tests.sh
#
#   Run all integration tests on Amazon Web Services:
#   PROVIDER=aws ./run-integration-tests.sh
#

DIR="$(dirname "$0")"
. "$DIR/../tools/provisioning/config.sh" # Import gcp_on, do_on, and aws_on.
. "$DIR/config.sh" # Import greenly.

# Variables:
APP="weave-net"
PROJECT="weave-net-tests"  # Only used when PROVIDER is gcp.
NAME=${NAME:-"$(whoami | sed -e 's/[\.\_]*//g' | cut -c 1-4)"}
PROVIDER=${PROVIDER:-gcp}  # Provision using provided provider, or Google Cloud Platform by default.
NUM_HOSTS=${NUM_HOSTS:-10}
PLAYBOOK=${PLAYBOOK:-setup_weave-net_test.yml}
TESTS=${TESTS:-}
RUNNER_ARGS=${RUNNER_ARGS:-""}
# Dependencies' versions:
DOCKER_VERSION=${DOCKER_VERSION:-1.11.2}
KUBERNETES_VERSION=${KUBERNETES_VERSION:-1.5.1}
KUBERNETES_CNI_VERSION=${KUBERNETES_CNI_VERSION:-0.3.0.1}
# Google Cloud Platform image's name & usage (only used when PROVIDER is gcp):
IMAGE_NAME=${IMAGE_NAME:-"$(echo $APP"-docker"$DOCKER_VERSION"-k8s"$KUBERNETES_VERSION"-k8scni"$KUBERNETES_CNI_VERSION | sed -e 's/[\.\_]*//g')"}
DISK_NAME_PREFIX=${DISK_NAME_PREFIX:-$NAME}
USE_IMAGE=${USE_IMAGE:-}
CREATE_IMAGE=${CREATE_IMAGE:-}
CREATE_IMAGE_TIMEOUT_IN_SECS=${CREATE_IMAGE_TIMEOUT_IN_SECS:-600}
# Lifecycle flags:
SKIP_CREATE=${SKIP_CREATE:-}
SKIP_CONFIG=${SKIP_CONFIG:-}
SKIP_DESTROY=${SKIP_DESTROY:-}
ONLY_DESTROY=${ONLY_DESTROY:-}

function print_vars() {
  echo "--- Variables: Main ---"
  echo "PROVIDER=$PROVIDER"
  echo "NUM_HOSTS=$NUM_HOSTS"
  echo "PLAYBOOK=$PLAYBOOK"
  echo "TESTS=$TESTS"
  echo "RUNNER_ARGS=$RUNNER_ARGS"
  echo "--- Variables: Versions ---"
  echo "DOCKER_VERSION=$DOCKER_VERSION"
  echo "KUBERNETES_VERSION=$KUBERNETES_VERSION"
  echo "KUBERNETES_CNI_VERSION=$KUBERNETES_CNI_VERSION"
  echo "IMAGE_NAME=$IMAGE_NAME"
  echo "DISK_NAME_PREFIX=$DISK_NAME_PREFIX"
  echo "USE_IMAGE=$USE_IMAGE"
  echo "CREATE_IMAGE=$CREATE_IMAGE"
  echo "CREATE_IMAGE_TIMEOUT_IN_SECS=$CREATE_IMAGE_TIMEOUT_IN_SECS"
  echo "--- Variables: Flags ---"
  echo "SKIP_CREATE=$SKIP_CREATE"
  echo "SKIP_CONFIG=$SKIP_CONFIG"
  echo "SKIP_DESTROY=$SKIP_DESTROY"
  echo "ONLY_DESTROY=$ONLY_DESTROY"
}

function verify_dependencies() {
  local deps=(python terraform ansible-playbook)
  for dep in "${deps[@]}"; do 
    if [ ! $(which $dep) ]; then 
      >&2 echo "$dep is not installed or not in PATH."
      exit 1
    fi
  done
}

function provision_locally() {
  case "$1" in
    on)
      (cd "$(dirname "${BASH_SOURCE[0]}")" && vagrant up)
      local status=$?
      eval $(vagrant ssh-config | sed \
        -ne 's/\ *HostName /ssh_hosts=/p' \
        -ne 's/\ *User /ssh_user=/p' \
        -ne 's/\ *Port /ssh_port=/p' \
        -ne 's/\ *IdentityFile /ssh_id_file=/p')
      SKIP_CONFIG=1  # Vagrant directly configures virtual machines using Ansible -- see also: Vagrantfile
      return $status
      ;;
    off)
      vagrant destroy -f
      ;;
    *)
      >&2 echo "Unknown command $1. Usage: {on|off}."
      exit 1
      ;;
  esac
}

function setup_gcloud() {
  # Authenticate:
  gcloud auth activate-service-account --key-file "$GOOGLE_CREDENTIALS_FILE" 1>/dev/null
  # Set current project:
  gcloud config set project $PROJECT
}

function image_exists() {
  gcloud compute images list | grep $PROJECT | grep $IMAGE_NAME
}

function image_ready() {
  # GCP images seem to be listed before they are actually ready for use, 
  # typically failing the build with: "googleapi: Error 400: The resource is not ready".
  # We therefore consider the image to be ready once the disk of its template instance has been deleted.
  ! gcloud compute disks list | grep $DISK_NAME_PREFIX
}

function wait_for_image() {
  greenly echo "> Waiting for GCP image $IMAGE_NAME to be created..."
  for i in $(seq $CREATE_IMAGE_TIMEOUT_IN_SECS); do
    image_exists && image_ready && return 0
    if ! ((i % 60)); then echo "Waited for $i seconds and still waiting..."; fi
    sleep 1
  done
  redly echo "> Waited $CREATE_IMAGE_TIMEOUT_IN_SECS seconds for GCP image $IMAGE_NAME to be created, but image could not be found."
  exit 1
}

function create_image() {
  if [ -n "$CREATE_IMAGE" ]; then
    greenly echo "> Creating GCP image $IMAGE_NAME..."; local begin_img=$(date +%s)
    local num_hosts=1
    terraform apply -input=false -var "app=$APP" -var "name=$NAME" -var "num_hosts=$num_hosts" "$DIR/../tools/provisioning/gcp"
    configure_with_ansible $(terraform output username) "$(terraform output public_ips)," "$(terraform output private_key_path)" $num_hosts
    local zone=$(terraform output zone)
    local name=$(terraform output instances_names)
    gcloud -q compute instances delete $name --keep-disks boot --zone $zone
    gcloud compute images create $IMAGE_NAME --source-disk $name --source-disk-zone $zone \
      --description "Testing image for Weave Net based on $(terraform output image), Docker $DOCKER_VERSION, Kubernetes $KUBERNETES_VERSION and Kubernetes CNI $KUBERNETES_CNI_VERSION."
    gcloud compute disks delete $name --zone $zone
    terraform destroy -force "$DIR/../tools/provisioning/gcp"
    rm terraform.tfstate*
    echo; greenly echo "> Created GCP image $IMAGE_NAME in $(date -u -d @$(($(date +%s)-$begin_img)) +"%T")."
  else
    wait_for_image
  fi
}

function update_local_etc_hosts() {
  # Remove old entries (if present):
  for host in $1; do sudo sed -i "/$host/d" /etc/hosts; done
  # Add new entries:
  sudo sh -c "echo \"$2\" >> /etc/hosts"
}

function upload_etc_hosts() {
  # Remove old entries (if present):
  $SSH $3 'for host in '$1'; do sudo sed -i "/$host/d" /etc/hosts; done'
  # Add new entries:
  echo "$2" | $SSH $3 "sudo -- sh -c \"cat >> /etc/hosts\""
}

function update_remote_etc_hosts() {
  local pids=""
  for host in $1; do
    upload_etc_hosts "$1" "$2" $host &
    local pids="$pids $!"
  done
  for pid in $pids; do wait $pid; done
}

function provision_remotely() {
  case "$1" in
    on)
      terraform apply -input=false -parallelism="$NUM_HOSTS" -var "app=$APP" -var "name=$NAME" -var "num_hosts=$NUM_HOSTS" "$DIR/../tools/provisioning/$2"
      local status=$?
      ssh_user=$(terraform output username)
      ssh_id_file=$(terraform output private_key_path)
      ssh_hosts=$(terraform output hostnames)
      return $status
      ;;
    off)
      terraform destroy -force "$DIR/../tools/provisioning/$2"
      ;;
    *)
      >&2 echo "Unknown command $1. Usage: {on|off}."
      exit 1
      ;;
  esac
}

function provision() {
  local action=$([ $1 == "on" ] && echo "Provisioning" || echo "Shutting down")
  echo; greenly echo "> $action test host(s) on [$PROVIDER]..."; local begin_prov=$(date +%s)
  case "$2" in
    aws)
      aws_on
      provision_remotely $1 $2
      ;;
    do)
      do_on
      provision_remotely $1 $2
      ;;
    gcp)
      gcp_on
      if [ -n "$USE_IMAGE" ]; then
        setup_gcloud
        image_exists || create_image
        export TF_VAR_gcp_image="$IMAGE_NAME"  # Override the default image name.
        SKIP_CONFIG=1  # No need to configure the image, since already done when making the template
      fi
      provision_remotely $1 $2
      ;;
    vagrant)
      # TODO:
      provision_locally $1
      ;;
    *)
      >&2 echo "Unknown provider $2. Usage: PROVIDER={gcp|aws|do|vagrant}."
      exit 1
      ;;
  esac

  if [ "$1" == "on" ]; then
    export SSH="ssh -l $ssh_user -i $ssh_id_file -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    # Set up /etc/hosts files on this ("local") machine and the ("remote") testing machines, to map hostnames and IP addresses, so that:
    # - this machine communicates with the testing machines via their public IPs;
    # - testing machines communicate between themselves via their private IPs;
    # - we can simply use just the hostname in all scripts to refer to machines, and the difference between public and private IP becomes transparent.
    # N.B.: if you decide to use public IPs everywhere, note that some tests may fail (e.g. test #115).
    update_local_etc_hosts "$ssh_hosts" "$(terraform output public_etc_hosts)"
    update_remote_etc_hosts "$ssh_hosts" "$(terraform output private_etc_hosts)"
  fi

  echo; greenly echo "> Provisioning took $(date -u -d @$(($(date +%s)-$begin_prov)) +"%T")."
}

function configure_with_ansible() {
  ansible-playbook -u "$1" -i "$2" --private-key="$3" --forks="${4:-$NUM_HOSTS}" \
    --ssh-extra-args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null" \
    --extra-vars "docker_version=$DOCKER_VERSION kubernetes_version=$KUBERNETES_VERSION kubernetes_cni_version=$KUBERNETES_CNI_VERSION" \
    "$DIR/../tools/config_management/$PLAYBOOK"
}

function configure() {
  echo; greenly echo "> Configuring test host(s)..."; local begin_conf=$(date +%s)
  local inventory_file=$(mktemp /tmp/ansible_inventory_XXXXX)
  echo "[all]" > "$inventory_file"
  echo "$2" | sed "s/$/:$3/" >> "$inventory_file"
  # Configure the provisioned machines using Ansible, allowing up to 3 retries upon failure (e.g. APT connectivity issues, etc.):
  for i in $(seq 3); do
    configure_with_ansible "$1" "$inventory_file" "$4" && break || >&2 echo "#$i: Ansible failed. Retrying now..."
  done
  echo; greenly echo "> Configuration took $(date -u -d @$(($(date +%s)-$begin_conf)) +"%T")."
}

function run_tests() {
  export HOSTS="$(echo "$3" | tr '\n' ' ')"
  shift 3 # Drop the first 3 arguments, the remainder being, optionally, the list of tests to run.
  "$DIR/setup.sh"
  set +e # Do not fail this script upon test failure, since we need to shut down the test cluster regardless of success or failure.
  echo; greenly echo "> Running tests..."; local begin_tests=$(date +%s)
  "$DIR/run_all.sh" $@
  local status=$?
  echo; greenly echo "> Tests took $(date -u -d @$(($(date +%s)-$begin_tests)) +"%T")."
  return $status
}

begin=$(date +%s)
print_vars
verify_dependencies

if [ -z "$ONLY_DESTROY" ]; then
  provision on $PROVIDER
  if [ $? -ne 0 ]; then
    >&2 echo "> Failed to provision test host(s)."
    exit 1
  fi

  if [ -z "$SKIP_CONFIG" ]; then
    configure $ssh_user "$ssh_hosts" ${ssh_port:-22} $ssh_id_file
    if [ $? -ne 0 ]; then
      >&2 echo "Failed to configure test host(s)."
      exit 1
    fi
  fi

  run_tests $ssh_user $ssh_id_file "$ssh_hosts" "$TESTS"
  status=$?
fi
if [ -z "$SKIP_DESTROY" ]; then
  provision off $PROVIDER
fi

echo; greenly echo "> Build took $(date -u -d @$(($(date +%s)-$begin)) +"%T")."
exit $status