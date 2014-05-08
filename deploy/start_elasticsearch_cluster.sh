#!/bin/bash

MASTER=-1
MASTER_IP=
NUM_REGISTERED_WORKERS=0
BASEDIR=$(cd $(dirname $0); pwd)
ELASTICSERVERS="${BASEDIR}/elasticservers"

# starts the elasticsearch master container
function start_master() {
    echo "starting master container"
    if [ "$DEBUG" -gt 0 ]; then
        echo sudo docker run -d --dns $NAMESERVER_IP -h master${DOMAINNAME} $VOLUME_MAP $1:$2
    fi
    MASTER=$(sudo docker run -d --dns $NAMESERVER_IP -h master${DOMAINNAME} $VOLUME_MAP $1:$2)

    if [ "$MASTER" = "" ]; then
        echo "error: could not start master container from image $1:$2"
        exit 1
    fi

    echo "started master container:      $MASTER"
    sleep 3
    MASTER_IP=$(sudo docker logs $MASTER 2>&1 | egrep '^MASTER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
    echo "MASTER_IP:                     $MASTER_IP"
    echo "address=\"/master/$MASTER_IP\"" >> $DNSFILE
}

# starts a number of elasticsearch workers
function start_workers() {
	
	rm -f $ELASTICSERVERS

    for i in `seq 1 $NUM_WORKERS`; do
        echo "starting worker container"
	hostname="worker${i}${DOMAINNAME}"
        if [ "$DEBUG" -gt 0 ]; then
	    echo sudo docker run -d --dns $NAMESERVER_IP -h $hostname $VOLUME_MAP $1:$2
        fi
	WORKER=$(sudo docker run -d --dns $NAMESERVER_IP -h $hostname $VOLUME_MAP $1:$2)

        if [ "$WORKER" = "" ]; then
            echo "error: could not start worker container from image $1:$2"
            exit 1
        fi

	echo "started worker container:  $WORKER"
	sleep 3
	WORKER_IP=$(sudo docker logs $WORKER 2>&1 | egrep '^WORKER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
	echo "address=\"/$hostname/$WORKER_IP\"" >> $DNSFILE
    echo "WORKER #${i} IP: $WORKER_IP" 
    echo $WORKER_IP >> $ELASTICSERVERS
    echo "WORKER #${i} CLUSTER HEALTH: http://${WORKER_IP}:9200/_plugin/head/"
    done
}

# prints out information on the cluster
function print_cluster_info() {
    BASEDIR=$(cd $(dirname $0); pwd)"/.."
    echo ""
    echo "***********************************************************************"
    echo ""
    echo "/data mapped:               $VOLUME_MAP"
    echo ""
    echo "MASTER_IP: ${MASTER_IP}"
    echo ""
    echo "WORKERS:"
    cat -n $ELASTICSERVERS
    echo "***********************************************************************"
    echo ""
    echo "to enable cluster name resolution add the following line to _the top_ of your host's /etc/resolv.conf:"
    echo "nameserver $NAMESERVER_IP"
}

: <<'END'
function get_num_registered_workers() {
    sleep 2
    NUM_REGISTERED_WORKERS=$(($NUM_REGISTERED_WORKERS+1))    
}
END

function wait_for_master {
    echo -n "waiting for master "
    sleep 1
    echo ""
    echo -n "waiting for nameserver to find master "
    check_hostname result master "$MASTER_IP"
    until [ "$result" -eq 0 ]; do
        echo -n "."
        sleep 1
        check_hostname result master "$MASTER_IP"
    done
    echo ""
    sleep 2
}


