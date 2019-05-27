#!/bin/bash
# Ideally, we never have any bugs in cluster delete.
# However, even in this ideal scenario, we need
# protection from a patch under review breaking cluster delete
# and filling up our tenant with undeletable resources.
# In this case call the destroy script with `-f|--force`

CONFIG=${CONFIG:-cluster_config.sh}
if [ ! -r "$CONFIG" ]; then
    echo "Could not find cluster configuration file."
    echo "Make sure $CONFIG file exists in the shiftstack-ci directory and that it is readable"
    exit 1
fi
source ./${CONFIG}

opts=$(getopt -n "$0"  -o "fi:" --long "force,infra-id:"  -- "$@")

eval set --$opts

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--force)
            FORCE=true
            shift
            ;;

        -i|--infra-id)
            INFRA_ID=$2
            shift 2
            ;;

        *)
            break
            ;;
    esac
done

if [ ! -z "$INFRA_ID" ]; then
    TMP_DIR=$(mktemp -d -t shiftstack-XXXXXXXXXX)
    echo "{\"clusterName\":\"$CLUSTER_NAME\",\"infraID\":\"$INFRA_ID\",\"openstack\":{\"region\":\"$OPENSTACK_REGION\",\"cloud\":\"$OS_CLOUD\",\"identifier\":{\"openshiftClusterID\":\"$INFRA_ID\"}}}" > $TMP_DIR/metadata.json
fi

if [[ $FORCE == true ]]; then
    echo Destroying cluster using openstack cli
    if [ -z "$INFRA_ID" ] && [ -f $CLUSTER_NAME/metadata.json ]; then
        # elements created by the cluster are named $CLUSTER_NAME-hash by the installer
        INFRA_ID=$(jq .infraID $CLUSTER_NAME/metadata.json | sed "s/\"//g")
    fi

    if [ -z "$INFRA_ID" ]; then
        echo "Could not find infrastructure id."
        echo "You may specify it with -i|--infra-id option to the script."
        exit 1
    fi

    openstack server list -c ID -f value --name $INFRA_ID | xargs --no-run-if-empty openstack server delete
    openstack router remove subnet  $INFRA_ID-external-router $INFRA_ID-service
    openstack router remove subnet  $INFRA_ID-external-router $INFRA_ID-nodes
    # delete interfaces from the router
    openstack network trunk list -c Name -f value | grep $INFRA_ID | xargs --no-run-if-empty openstack network trunk delete
    openstack port list --network $INFRA_ID-openshift -c ID -f value | xargs --no-run-if-empty openstack port delete

    # delete interfaces from the router
    PORT=$(openstack router show $INFRA_ID-external-router -c interfaces_info -f value | cut -d '"' -f 12)
    openstack router remove port $INFRA_ID-external-router $PORT


    openstack router unset --external-gateway $INFRA_ID-external-router
    openstack router delete $INFRA_ID-external-router

    openstack network delete $INFRA_ID-openshift

    openstack security group delete $INFRA_ID-api
    openstack security group delete $INFRA_ID-master
    openstack security group delete $INFRA_ID-worker


    for c in $(openstack container list -f value); do
        echo $c
        openstack container show $c | grep $INFRA_ID
        if [ $? -eq 0 ]; then
            CONTAINER=$c
        fi
    done

    if [ ! -z "$CONTAINER" ]; then
        openstack object list -f value $CONTAINER | xargs --no-run-if-empty openstack object delete $CONTAINER
        openstack container delete $CONTAINER
    fi
else
    echo Destroying cluster using openshift-install
    $GOPATH/src/github.com/openshift/installer/bin/openshift-install --log-level=debug destroy cluster --dir ${TMP_DIR:-$CLUSTER_NAME}
fi

if [ ! -z "$TMP_DIR" ]; then
    rm -rf $TMP_DIR
fi
