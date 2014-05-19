#!/bin/bash

MASTER=-1
MASTER_IP=
NUM_REGISTERED_WORKERS=0
BASEDIR=$(cd $(dirname $0); pwd)
REGIONSERVERS="${BASEDIR}/regionservers"
MASTER_HOSTNAME=hbase-master
WORKER_HOSTNAME=hbase-worker

# starts the Spark/Shark master container
function start_master() {
    echo "starting master container"
    if [ "$DEBUG" -gt 0 ]; then
        echo sudo docker run -d --dns $NAMESERVER_IP -h ${MASTER_HOSTNAME}${DOMAINNAME} $VOLUME_MAP $1:$2
    fi
    MASTER=$(sudo docker run -d --dns $NAMESERVER_IP -h ${MASTER_HOSTNAME}${DOMAINNAME} $VOLUME_MAP $1:$2)

    if [ "$MASTER" = "" ]; then
        echo "error: could not start master container from image $1:$2"
        exit 1
    fi

    echo "started master container:      $MASTER"
    sleep 3
    MASTER_IP=$(sudo docker logs $MASTER 2>&1 | egrep '^MASTER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
    echo "MASTER_IP:                     $MASTER_IP"
    echo "address=\"/$MASTER_HOSTNAME/$MASTER_IP\"" >> $DNSFILE
}

# starts a number of Spark/Shark workers
function start_workers() {
	
	rm -f $REGIONSERVERS

    for i in `seq 1 $NUM_WORKERS`; do
        echo "starting worker container"
	hostname="${WORKER_HOSTNAME}${i}${DOMAINNAME}"
        if [ "$DEBUG" -gt 0 ]; then
	    echo sudo docker run -d --dns $NAMESERVER_IP -h $hostname $VOLUME_MAP $1:$2 ${MASTER_IP}
        fi
	WORKER=$(sudo docker run -d --dns $NAMESERVER_IP -h $hostname $VOLUME_MAP $1:$2 ${MASTER_IP})

        if [ "$WORKER" = "" ]; then
            echo "error: could not start worker container from image $1:$2"
            exit 1
        fi

	echo "started worker container:  $WORKER"
	sleep 3
	WORKER_IP=$(sudo docker logs $WORKER 2>&1 | egrep '^WORKER_IP=' | awk -F= '{print $2}' | tr -d -c "[:digit:] .")
	echo "address=\"/$hostname/$WORKER_IP\"" >> $DNSFILE
    echo "WORKER #${i} IP: $WORKER_IP" 
    echo $WORKER_IP >> $REGIONSERVERS
    done
}

# prints out information on the cluster
function print_cluster_info() {
    BASEDIR=$(cd $(dirname $0); pwd)"/.."
    echo ""
    echo "***********************************************************************"
    echo ""
    echo "visit Hadoop Namenode at:   http://$MASTER_IP:50070"
    echo "ssh into master via:        ssh -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${MASTER_IP}"
    echo ""
    echo "/data mapped:               $VOLUME_MAP"
    echo ""
    echo "kill master via:           sudo docker kill $MASTER"
    echo "***********************************************************************"
    echo ""
    echo "to enable cluster name resolution add the following line to _the top_ of your host's /etc/resolv.conf:"
    echo "nameserver $NAMESERVER_IP"
}

function get_num_registered_workers() {
    sleep 2
    NUM_REGISTERED_WORKERS=$(($NUM_REGISTERED_WORKERS+1))    
}

function wait_for_master {
    echo -n "waiting for master "
    sleep 1
    echo ""
    echo -n "waiting for nameserver to find master "
    check_hostname result "$MASTER_HOSTNAME" "$MASTER_IP"
    until [ "$result" -eq 0 ]; do
        echo -n "."
        sleep 1
        check_hostname result "$MASTER_HOSTNAME" "$MASTER_IP"
    done
    echo ""
    sleep 2
}

function start_hbase {
    
	chmod 400 $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa
	
    echo -n "updating regionservers file"
    scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentityFile=$BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa $REGIONSERVERS root@$MASTER_IP:/opt/hbase/conf/

    echo -n "change regionservers file permission"
    ssh -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${MASTER_IP} "chown hdfs.hdfs /opt/hbase/conf/regionservers"

    #update the core-site.xml and hbase-site.xml and start hadoop datanodes
    while read WORKERADDRESS
    do
        echo "updating core-site.xml on ${WORKERADDRESS}"
        ssh -n -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${MASTER_IP} "scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentityFile=/root/.ssh/id_rsa /etc/hadoop/core-site.xml root@${WORKERADDRESS}:/etc/hadoop/"
        
        echo "starting datanode on ${WORKERADDRESS}"
        ssh -n -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${WORKERADDRESS} "service hadoop-datanode start"
    
		sleep 2
	
    done < $REGIONSERVERS

    echo "starting zookeeper on ${MASTER_IP}"
    ssh -n -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${MASTER_IP} "/usr/local/zookeeper/bin/zkServer.sh start"

    echo "starting hbase master on ${MASTER_IP}"
    ssh -n -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${MASTER_IP} "sudo -u hdfs /opt/hbase/bin/hbase-daemon.sh --config /opt/hbase/conf start master"

    #update the hbase-site.xml and hbase-site.xml and start hbase regionservers
    while read WORKERADDRESS
    do

		echo "updating hbase-site.xml on ${WORKERADDRESS}"
    	ssh -n -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${MASTER_IP} "scp -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o IdentityFile=/root/.ssh/id_rsa /opt/hbase/conf/hbase-site.xml root@${WORKERADDRESS}:/opt/hbase/conf/"
        echo "starting hbase regionserver on ${WORKERADDRESS}"
    	ssh -n -i $BASEDIR/apache-hadoop-hdfs-precise/files/id_rsa -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no root@${WORKERADDRESS} "sudo -u hdfs /opt/hbase/bin/hbase-daemon.sh --config /opt/hbase/conf start regionserver"
    
    	sleep 2

    done < $REGIONSERVERS
}
