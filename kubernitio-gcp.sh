#!/bin/bash
#
# Spin up a Kognitio cluster on Google Kubernetes Engine
#

KOGNITIO_IMAGE="kognitio/kognitio:latest"   # which docker image to use - kognitio/kognitio is standard
K8S_NUM_NODES=3                      # number of nodes to provision in the Kubernetes cluster
K8S_NODE_TYPE="custom-8-65536-ext"   # the type of node to provision
K8S_USE_PREEMPTIBLE="true"           # true to use premptible (spot) instances for the Kubernetes nodes
KOGNITIO_NODE_MEMORY="56Gi"          # the amount of memory to allocate to the Kognitio containers
K8S_ZONE="europe-west2-c"            # which zone to build the cluster and filesystem in
K8S_CLUSTER="my-kube"                # name of the Kubernetes cluster
K8S_NODEGROUP="kognitio-nodes"       # nodegroup for the Kognitio nodes
K8S_APP_TAG="kognitio-mycluster"     # app label
K8S_NODE_TAG="kognitio-mycluster-db" # tag for kognitio cluster nodes
K8S_PV="mycluster-volume"            # name of the persistent volume
K8S_PVC="mycluster-storage"          # name of the persistent volume claim
K8S_LB_SVC="mycluster-external-service" # name of the load balancer service
FILESTORE="mycluster-filestore"      # name of the filestore 

case "$1" in
"delete")
  set +e
  gcloud filestore instances delete ${FILESTORE} --zone ${K8S_ZONE} --async <<< "y"
  gcloud container clusters delete ${K8S_CLUSTER} --zone ${K8S_ZONE} <<< "y"
  ;;
"create") 
  set -e
  
  # test to see if we have a valid CIDR for the load balancer firewall
  CIDR=$2
  if [[ ! "$CIDR" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(\/([0-9]|[1-2][0-9]|3[0-2]))?$ ]]; then 
    echo "CIDR block [$CIDR] for load balancer missing or malformed"
    echo "Usage $0 create <cidr block>"
    echo "Suggested CIDR is <your IP address>/32 "
    exit 1
  fi

  # create the filestore (using --async so we can build the K8S cluster while we wait for it) 
  gcloud filestore instances create ${FILESTORE} \
      --zone ${K8S_ZONE} \
      --tier STANDARD \
      --file-share name="data",capacity=1TB \
      --network name="default" \
      --async

  # create the Kubernetes cluster
  if [[ "${K8S_USE_PREEMPTIBLE}" == "true" ]] ; then PREEMPTIBLE="--preemptible"; else PREEMPTIBLE=""; fi

  gcloud container clusters create ${K8S_CLUSTER} \
    --zone ${K8S_ZONE}  \
    --no-enable-basic-auth \
    --scopes=storage-rw \
    --metadata disable-legacy-endpoints=true \
    --cluster-version "latest" \
    --machine-type ${K8S_NODE_TYPE} \
    ${PREEMPTIBLE} \
    --image-type "COS" \
    --disk-type "pd-standard" \
    --disk-size "10" \
    --labels app=${K8S_APP_TAG} \
    --node-labels name=${K8S_NODE_TAG} \
    --num-nodes ${K8S_NUM_NODES} \
    --no-enable-autoupgrade \
    --enable-stackdriver-kubernetes \
    --format=json


  # check that the filestore is ready and if so, get its IP address
  while true; do
    sleep 5
    FSTORESTAT=`gcloud filestore instances describe ${FILESTORE} --zone=${K8S_ZONE} --format=json`
    if [[ "$(jq -r '.state' <<< $FSTORESTAT)" == "READY" ]] ; then
      FSTORE_IP=$(jq -r '.networks[0].ipAddresses[0]' <<< ${FSTORESTAT})
      echo "Filestore Ready - IP Address : ${FSTORE_IP}"
      break
    else
      echo "Filestore state = $(jq '.state' <<< $FSTORESTAT)"
    fi
  done

  # attach a Kubernetes persistent volume to the GCP filestore

  kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${K8S_PV}
spec:
  capacity:
    storage: 1000Gi
  accessModes:
    - ReadWriteMany
  nfs:
    server: ${FSTORE_IP}
    path: "/data"
EOF

  # create a persistent volume claim to give to the deployment 

  kubectl create -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${K8S_PVC}
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 1000Gi
EOF

  # deploy the Kognitio app
  echo "creating the Deployment with one pod"
  kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${K8S_APP_TAG}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ${K8S_APP_TAG}
  template:
    metadata:
      labels:
        app: ${K8S_APP_TAG}
    spec:
      volumes:
      - name: ${K8S_PVC}
        persistentVolumeClaim:
          claimName: ${K8S_PVC}
      containers:
      - name: ${K8S_NODE_TAG}
        image: ${KOGNITIO_IMAGE}
        resources:
            limits:
              memory: "${KOGNITIO_NODE_MEMORY}"
        ports:
          - name: odbc
            containerPort: 6550
        volumeMounts:
            - name: ${K8S_PVC}
              mountPath: /data
EOF

  echo "waiting for pods to stabilise"
  while true; do
    sleep 5
    PODS_RUNNING=true
    for pod_status in $(kubectl get pods -l app=${K8S_APP_TAG} -o=jsonpath={.items[*].status.phase}); do
      if [[ "${pod_status}" != "Running" ]] ; then
        PODS_RUNNING=false
      fi
    done
    if [[ ${PODS_RUNNING} == true ]] ; then
      break;
    fi
    echo "Waiting for all pods to enter Running state"
  done

# ToDo: command line option of LoadBalancer, NodePort etc
  echo "creating load balancer"
  kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: ${K8S_LB_SVC}
spec:
  type: LoadBalancer
  selector:
    app: ${K8S_APP_TAG}
  ports:
  - protocol: TCP
    port: 6550
    targetPort: 6550
  loadBalancerSourceRanges:
  - $CIDR
EOF

  # get the first pod
  FIRST_POD=$(kubectl get pods -l app=${K8S_APP_TAG} -o=json | jq -r '.items[0].metadata.name')

  # create the kognitio database
  echo "###################################"
  echo "## Initialising Kognitio cluster ##"
  echo "##        INPUT REQUIRED         ##"
  echo "###################################"

  kubectl exec -it ${FIRST_POD} -- kognitio-cluster-init

  # resize if required - not much point if you knew what size cluster you wanted
  # gcloud container clusters resize ${K8S_CLUSTER} --zone ${K8S_ZONE} --node-pool default-pool --num-nodes ${K8S_NUM_NODES} <<< 'y'

  echo "creating the rest of the pods"
  kubectl scale deployment.v1.apps/${K8S_APP_TAG} --replicas=${K8S_NUM_NODES}

  # wait for all the nodes to join the Kognitio cluster
  while true; do
    sleep 5
    NODES_READY=$(kubectl exec -it ${FIRST_POD} -- wxprobe -H | grep full: | sed 's/.*: \([0-9]\).*/\1/')
    if [[ "${NODES_READY}" == "${K8S_NUM_NODES}" ]] ; then
      echo "${NODES_READY} of ${K8S_NUM_NODES} nodes ready - installing database "
      break
    else
      echo "Waiting for ${K8S_NUM_NODES} nodes to join the cluster - ${NODES_READY} joined"
    fi
  done

  echo "###################################"
  echo "## Initialising Kognitio server  ##"
  echo "##        INPUT REQUIRED         ##"
  echo "###################################"

  kubectl exec -it ${FIRST_POD} -- kognitio-create-database

  # wait for loadbalancer and report IP address 
  while true; do
    sleep 5
    LB_IP=$(kubectl get svc ${K8S_LB_SVC} -o=jsonpath={.status.loadBalancer.ingress[0].ip})
    if [[ "${LB_IP}" == "" ]] ; then
      echo "Waiting for load balancer to allocate external IP address"
    else
      echo "#######################################################################"
      echo "Kognitio server installed on ${K8S_NUM_NODES} nodes"
      echo "Load balancer ready - connect to cluster on ${LB_IP} port 6550"
      break
    fi
  done
  ;;
"info")
  LB_IP=$(kubectl get svc ${K8S_LB_SVC} -o=jsonpath={.status.loadBalancer.ingress[0].ip})
  echo "Connect to Kognitio cluster on ${LB_IP} port 6550"
  ;;
*)
  echo "Usage $0 create <CIDR block> | delete | info"
  exit 1
  ;;
esac
