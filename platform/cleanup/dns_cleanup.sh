#!/bin/bash
#
# delete links between groups and dns server
# delet link between measurement container to dns server

set -o errexit
set -o pipefail
set -o nounset

DIRECTORY="$1"
source "${DIRECTORY}"/config/subnet_config.sh

# read configs
readarray groups < "${DIRECTORY}"/config/AS_config.txt
readarray routers < "${DIRECTORY}"/config/router_config.txt
group_numbers=${#groups[@]}
n_routers=${#routers[@]}

echo -n "-- --if-exists del-br dns " >> "${DIRECTORY}"/ovs_command.txt

# del bridge bewteen measurement to dns service
br_name="dns_measurement"
echo -n "-- --if-exists del-br "${br_name}" " >> "${DIRECTORY}"/ovs_command.txt
