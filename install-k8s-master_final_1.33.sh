#!/bin/bash
# install-k8s-master-ubuntu.sh
# additional master configuration for Ubuntu

# install jq
apt update
apt install -y jq

# configure/enable networking for the cluster
kubeadm config images pull --kubernetes-version=1.33.0 --cri-socket=unix:///var/run/cri-dockerd.sock
kubeadm init --pod-network-cidr=10.244.0.0/16 --apiserver-advertise-address=192.168.100.6 --cri-socket=unix:///var/run/cri-dockerd.sock

# create script with non-expiring token for worker nodes to join cluster
archivo_token="/tmp/node-join.sh"

function token(){
    echo "#!/bin/bash" > /etc/kubernetes/node-join.sh
    kubeadm token create --ttl=0 --print-join-command >> "$archivo_token"
    while IFS= read -r linea; do
        Palabra=$(echo $linea | awk '{print $1,$2}')
        if [ "$Palabra" == "kubeadm join" ]; then
            echo "$linea--cri-socket=unix:///var/run/cri-dockerd.sock" >> /etc/kubernetes/node-join.sh
        fi
    done < "$archivo_token"
    find "$archivo_token" -type f -delete
}
token

# set k8s config to allow the kubectl command to run
export KUBECONFIG=/etc/kubernetes/admin.conf

mkdir -p $HOME/.kube
cp -if /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

# root will have permission to /etc/kubernetes/admin.conf, so add another non-root user
mkdir -p ~swadmin/.kube
chown swadmin:swadmin ~swadmin/.kube
cp -if /etc/kubernetes/admin.conf ~swadmin/.kube/config
chown swadmin:swadmin ~swadmin/.kube/config

# apply flannel as Container Network Interface (CNI)
kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml

# avoid message log bloat
if [ -f /etc/cni/net.d/10-flannel.conf -a -f /etc/cni/net.d/10-flannel.conflist ]; then
  if [ `diff /etc/cni/net.d/10-flannel.conf /etc/cni/net.d/10-flannel.conflist | wc -l` -eq 0 ]; then
    rm /etc/cni/net.d/10-flannel.conf
  else
    echo "WARNING!!! flannel .conf and .conflist exist but are different. You may find that messages are logged every 5 seconds leading to log file bloat"
  fi
fi

echo "[install-k8s-master] 0. Remaining commands to be run manually"
echo "[install-k8s-master] 1. kubectl get pods -n kube-system  # Wait until all pods reach running state"
echo "[install-k8s-master] 2. kubectl get nodes                # Master should be in Ready state"
echo "[install-k8s-master] 3. Now provision a worker node. As a final step, copy /etc/kubernetes/node-join.sh to the worker node and execute it"
echo "[install-k8s-master] 4. Alternately, run the following command on master: kubeadm token create --print-join-command"
