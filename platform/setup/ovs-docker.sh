#!/bin/bash
# Copyright (C) 2014 Nicira, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at:
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.



# original file at https://github.com/openvswitch/ovs/blob/master/utilities/ovs-docker
#
# changes:
#   append ovs-vsctl add-port to ../groups/add_ports.sh
#   append all following comands to ../groups/ip_setup.sh
# this way all ports can be added in one go -> speeds up process by hours!!!



# Check for programs we'll need.
search_path () {
    save_IFS=$IFS
    IFS=:
    for dir in $PATH; do
        IFS=$save_IFS
        if test -x "$dir/$1"; then
            return 0
        fi
    done
    IFS=$save_IFS
    echo >&2 "$0: $1 not found in \$PATH, please install and try again"
    exit 1
}

ovs_vsctl () {
    ovs-vsctl --timeout=60 "$@"
}

create_netns_link () {
    mkdir -p /var/run/netns
    if [ ! -e /var/run/netns/"$PID" ]; then
        ln -s /proc/"$PID"/ns/net /var/run/netns/"$PID"
        trap 'delete_netns_link' 0
        for signal in 1 2 3 13 14 15; do
            trap 'delete_netns_link; trap - $signal; kill -$signal $$' $signal
        done
    fi
}

delete_netns_link () {
    rm -f /var/run/netns/"$PID"
}

add_port () {
    BRIDGE="$1"
    INTERFACE="$2"
    CONTAINER="$3"

    if [ -z "$BRIDGE" ] || [ -z "$INTERFACE" ] || [ -z "$CONTAINER" ]; then
        echo >&2 "$UTIL add-port: not enough arguments (use --help for help)"
        exit 1
    fi

    shift 3
    while [ $# -ne 0 ]; do
        case $1 in
            --ipaddress=*)
                ADDRESS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --macaddress=*)
                MACADDRESS=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --gateway=*)
                GATEWAY=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --mtu=*)
                MTU=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --delay=*)
                DELAY=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            --throughput=*)
                THROUGHPUT=`expr X"$1" : 'X[^=]*=\(.*\)'`
                shift
                ;;
            *)
                echo >&2 "$UTIL add-port: unknown option \"$1\""
                exit 1
                ;;
        esac
    done

    if PID=`docker inspect -f '{{.State.Pid}}' "$CONTAINER"`; then :; else
        echo >&2 "$UTIL: Failed to get the PID of the container"
        exit 1
    fi

    create_netns_link

    # Create a veth pair.
    ID=`uuidgen -s --namespace @url --name "${BRIDGE}_${INTERFACE}_${CONTAINER}" | sed 's/-//g'`
    PORTNAME="${ID:0:13}"

    echo "#ip link add "${PORTNAME}_l" type veth peer name "${PORTNAME}_c >> groups/ip_setup.sh
    ip link add "${PORTNAME}_l" type veth peer name "${PORTNAME}_c"
    echo "ip link delete "${PORTNAME}_l >> groups/delete_veth_pairs.sh

    echo "-- add-port "$BRIDGE" "${PORTNAME}_l" \\" >> groups/add_ports.sh
    echo "-- set interface "${PORTNAME}_l" external_ids:container_id="$CONTAINER" external_ids:container_iface="$INTERFACE" \\" >> groups/add_ports.sh

    echo "ip link set "${PORTNAME}_l" up" >> groups/ip_setup.sh

    # Move "${PORTNAME}_c" inside the container and changes its name.
    echo "PID=$(docker inspect -f '{{.State.Pid}}' "$CONTAINER")">> groups/ip_setup.sh
    echo "create_netns_link" >> groups/ip_setup.sh
    echo "ip link set "${PORTNAME}_c" netns "\$PID"" >> groups/ip_setup.sh
    echo "ip netns exec "\$PID" ip link set dev "${PORTNAME}_c" name "$INTERFACE"" >> groups/ip_setup.sh
    echo "ip netns exec "\$PID" ip link set "$INTERFACE" up" >> groups/ip_setup.sh

    if [ -n "$MTU" ]; then
        ip netns exec "$PID" ip link set dev "$INTERFACE" mtu "$MTU"
    fi

    if [ -n "$ADDRESS" ]; then
        echo "ip netns exec "\$PID" ip addr add "$ADDRESS" dev "$INTERFACE"" >> groups/ip_setup.sh
    fi

    if [ -n "$MACADDRESS" ]; then
        echo "ip netns exec "$PID" ip link set dev "$INTERFACE" address "$MACADDRESS"" >> groups/ip_setup.sh
    fi

    if [ -n "$GATEWAY" ]; then
        echo "ip netns exec "$PID" ip route add default via "$GATEWAY"" >> groups/ip_setup.sh
    fi

    if [ -n "$DELAY" ]; then
        echo "tc qdisc add dev "${PORTNAME}"_l root netem delay "${DELAY}" " >> groups/delay_throughput.sh
    fi

    if [ -n "$THROUGHPUT" ]; then
        echo "echo -n \" -- set interface "${PORTNAME}"_l ingress_policing_rate="${THROUGHPUT}" \" >> groups/throughput.sh " >> groups/delay_throughput.sh
    fi

}

connect_ports () {
    BRIDGE="$1"
    INTERFACE1="$2"
    CONTAINER1="$3"
    INTERFACE2="$4"
    CONTAINER2="$5"

    if [ -z "$BRIDGE" ] || [ -z "$INTERFACE1" ] || [ -z "$CONTAINER1" ] || [ -z "$INTERFACE2" ] || [ -z "$CONTAINER2" ]; then
        echo >&2 "$UTIL connect-ports: not enough arguments (use --help for help)"
        exit 1
    fi

    ID1=`uuidgen -s --namespace @url --name ${BRIDGE}_${INTERFACE1}_${CONTAINER1} | sed 's/-//g'`
    PORTNAME1="${ID1:0:13}"
    ID2=`uuidgen -s --namespace @url --name ${BRIDGE}_${INTERFACE2}_${CONTAINER2} | sed 's/-//g'`
    PORTNAME2="${ID2:0:13}"

    echo "port_id1=\`ovs-vsctl get Interface ${PORTNAME1}_l ofport\`" >> groups/ip_setup.sh
    echo "port_id2=\`ovs-vsctl get Interface ${PORTNAME2}_l ofport\`" >> groups/ip_setup.sh

    echo "ovs-ofctl add-flow $BRIDGE in_port=\$port_id1,actions=output:\$port_id2" >> groups/ip_setup.sh
    echo "ovs-ofctl add-flow $BRIDGE in_port=\$port_id2,actions=output:\$port_id1" >> groups/ip_setup.sh
}

UTIL=$(basename $0)
search_path ovs-vsctl
search_path docker
search_path uuidgen

if (ip netns) > /dev/null 2>&1; then :; else
    echo >&2 "$UTIL: ip utility not found (or it does not support netns),"\
             "cannot proceed"
    exit 1
fi

if [ "$1" == "add-port" ]; then
    shift
    $(add_port "$@")
elif [ "$1" == "connect-ports" ]; then
    shift
    $(connect_ports "$@")
fi