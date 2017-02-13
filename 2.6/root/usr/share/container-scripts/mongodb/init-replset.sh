#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

source "${CONTAINER_SCRIPTS_PATH}/common.sh"

# This is a full hostname that will be added to replica set
# (for example, "replica-2.mongodb.myproject.svc.cluster.local")
readonly MEMBER_HOST="$(container_addr)"

# Initializes the replica set configuration.
#
# Arguments:
# - $1: host address[:port]
#
# Uses the following global variables:
# - MONGODB_REPLICA_NAME
# - MONGODB_ADMIN_PASSWORD
# - MONGODB_INITIAL_REPLICA_COUNT
function initiate() {
  local host="$1"

  # Wait for all nodes to be listed in endpoints() and accept connections
  current_endpoints=$(endpoints)
  if [ -n "${MONGODB_INITIAL_REPLICA_COUNT:-}" ]; then
    echo -n "=> Waiting for $MONGODB_INITIAL_REPLICA_COUNT MongoDB endpoints ..."
    while [[ "$(echo "${current_endpoints}" | wc -l)" -lt ${MONGODB_INITIAL_REPLICA_COUNT} ]]; do
      sleep 2
      current_endpoints=$(endpoints)
    done
  else
    echo "Attention: MONGODB_INITIAL_REPLICA_COUNT is not set and it could lead to a improperly configured replica set."
    echo "To fix this, set MONGODB_INITIAL_REPLICA_COUNT variable to the number of members in the replica set in"
    echo "the configuration of post deployment hook."

    echo -n "=> Waiting for MongoDB endpoints ..."
    while [ -z "${current_endpoints}" ]; do
      sleep 2
      current_endpoints=$(endpoints)
    done
  fi
  echo "${current_endpoints}"
  echo "=> Waiting for all endpoints to accept connections..."
  for node in ${current_endpoints}; do
    wait_for_mongo_up ${node} &>/dev/null
  done

  local config="{_id: '${MONGODB_REPLICA_NAME}', $(replset_config_members "${current_endpoints}")}"

  info "Initiating MongoDB replica using: ${config}"
  mongo --eval "quit(rs.initiate(${config}).ok ? 0 : 1)" --quiet

  info "Waiting for PRIMARY status ..."
  mongo --eval "while (!rs.isMaster().ismaster) { sleep(100); }" --quiet

  info "Creating MongoDB users ..."
  mongo_create_admin
  mongo_create_user "-u admin -p ${MONGODB_ADMIN_PASSWORD}"

  info "Successfully initialized replica set"
}

# Adds a host to the replica set configuration.
#
# Arguments:
# - $1: host address[:port]
#
# Global variables:
# - MONGODB_ADMIN_PASSWORD
function add_member() {
  local host="$1"
  info "Adding ${host} to replica set ..."

  if [ -z "$(endpoints)" ]; then
    info "ERROR: couldn't add host to replica set!"
    info "CAUSE: DNS lookup for '${MONGODB_SERVICE_NAME:-mongodb}' returned no results."
    return 1
  fi

  local replset_addr
  replset_addr="$(replset_addr)"

  if ! mongo admin -u admin -p "${MONGODB_ADMIN_PASSWORD}" --host "${replset_addr}" --eval "while (!rs.add('${host}').ok) { sleep(100); }" --quiet; then
    info "ERROR: couldn't add host to replica set!"
    return 1
  fi

  info "Waiting for PRIMARY/SECONDARY status ..."
  mongo --eval "while (!rs.isMaster().ismaster && !rs.isMaster().secondary) { sleep(100); }" --quiet

  info "Successfully joined replica set"
}

info "Waiting for local MongoDB to accept connections ..."
wait_for_mongo_up &>/dev/null

if [[ $(mongo --eval 'db.isMaster().setName' --quiet) == "${MONGODB_REPLICA_NAME}" ]]; then
  info "Replica set '${MONGODB_REPLICA_NAME}' already exists, skipping initialization"
  exit 0
fi

# Initialize replica set only if we're the first member
if [ "$1" == "initiate" ]; then
  main_process_id=$2
  # Initiate replica set
  initiate "${MEMBER_HOST}"

  # Exit this pod
  kill ${main_process_id}
else
  add_member "${MEMBER_HOST}"
fi
