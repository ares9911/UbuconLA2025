#!/bin/bash
# install-k8s-worker-ubuntu.sh
# Configuraciones Iniciales para Ubuntu

# k8s does not work with swap enabled
swapoff -a
sed -i '/swap/ s/^\(.*\)$/#\1/g' /etc/fstab

# Configuraciones para deshabilitar ufw (firewall en Ubuntu)
systemctl stop ufw && systemctl disable ufw

# Configuraciones de apparmor (equivalente a selinux en Ubuntu)
systemctl stop apparmor && systemctl disable apparmor

# Configuración de hosts para el cluster
ip_master="192.168.56.10"
ip_worker1="192.168.56.11"
#ip_worker2="100.69.138.19"

name_master="master"
name_worker1="worker"
#name_worker2="lnxsmwnigprod03"

# Función de Control de nombres de hosts
function asignacion_host(){
    confimacion_1=$(grep "$ip_master $name_master" /etc/hosts)
    if [ -z "$confimacion_1" ]; then
        echo "$ip_master $name_master" >> /etc/hosts
    fi
    confimacion_2=$(grep "$ip_worker1 $name_worker1" /etc/hosts)
    if [ -z "$confimacion_2" ]; then
        echo "$ip_worker1 $name_worker1" >> /etc/hosts
    fi
}
asignacion_host

# Remover docker si existe
apt remove -y docker docker-engine docker.io containerd runc

# Instalar algunos paquetes como: vim, curl, wget, git
apt update
apt install -y vim curl wget git socat

# Actualizar el Sistema Operativo
# apt upgrade -y

# Agregar modulos necesarios al kernel de linux
modprobe overlay
modprobe br_netfilter

cat << EOF | tee /etc/modules-load.d/k8s.conf 
overlay
br_netfilter
EOF

# INSTALACIÓN DE DOCKER EN UBUNTU
apt install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Agregar repositorio oficial de Docker
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null

apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# INSTALACIÓN DEL CONTAINER RUNTIME INTERFACE (CRI) - cri-dockerd
wget https://github.com/Mirantis/cri-dockerd/releases/download/v0.3.16/cri-dockerd-0.3.16.amd64.tgz
tar -xzf cri-dockerd-0.3.16.amd64.tgz
cp cri-dockerd/cri-dockerd /usr/local/bin/
chmod +x /usr/local/bin/cri-dockerd

# Crear servicio systemd para cri-dockerd
cat << EOF | tee /etc/systemd/system/cri-docker.service
[Unit]
Description=CRI Interface for Docker Application Container Engine
Documentation=https://docs.mirantis.com
After=network-online.target firewalld.service docker.service
Wants=network-online.target
Requires=cri-docker.socket

[Service]
Type=notify
ExecStart=/usr/local/bin/cri-dockerd --network-plugin=cni --pod-infra-container-image=registry.k8s.io/pause:3.8
ExecReload=/bin/kill -s HUP \$MAINPID
TimeoutSec=0
RestartSec=2
Restart=always
StartLimitBurst=3
StartLimitInterval=60s
LimitNOFILE=infinity
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
Delegate=yes
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

cat << EOF | tee /etc/systemd/system/cri-docker.socket
[Unit]
Description=CRI Docker Socket for the API
PartOf=cri-docker.service

[Socket]
ListenStream=%t/cri-dockerd.sock
SocketMode=0660
SocketUser=root
SocketGroup=docker

[Install]
WantedBy=sockets.target
EOF

# INICIO DE PROCESOS DE DOCKER Y CRI
systemctl enable docker && systemctl start docker
systemctl daemon-reload
systemctl enable cri-docker.service && systemctl start cri-docker.service
systemctl enable cri-docker.socket && systemctl start cri-docker.socket

# CREACIÓN DEL USUARIO "swadmin" Y GESTIÓN EN EL GRUPO DOCKER
adduser --disabled-password --gecos "" swadmin
echo "swadmin:admin1!" | chpasswd

# Docker group user configuration
if getent group "docker" &>/dev/null; then
	usermod -aG docker root
	usermod -aG docker swadmin
    echo "El grupo 'docker' existe, y agregaron los usuarios 'swadmin' y 'root' al grupo."
else
	groupadd docker
	usermod -aG docker root
	usermod -aG docker swadmin
    echo "Se creo el grupo 'docker' y se agregaron los usuarios 'swadmin' y 'root' al grupo."
fi

# INICIO DE UN CONTENEDOR DE HELLO-WORLD PARA PROBAR DOCKER
docker run hello-world
sleep 10

docker info
sleep 10

# CONFIGURACIONES ADICIONALES PARA PROXY (si es necesario)
if [ ! -z "$HTTP_PROXY" ]; then
	mkdir -p /etc/systemd/system/docker.service.d
	cat > /etc/systemd/system/docker.service.d/http-proxy.conf << EOD
[Service]
Environment="HTTP_PROXY=${HTTP_PROXY}" "HTTPS_PROXY=${HTTP_PROXY}" "NO_PROXY=localhost,10.0.0.0/8,192.168.0.0/16,172.16.0.0/12,192.168.56.10"
EOD
	systemctl daemon-reload
	systemctl restart docker
fi

# AGREGAR REPOSITORIO PARA LA INSTALACIÓN DE KUBERNETES
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.33/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.33/deb/ /' | tee /etc/apt/sources.list.d/kubernetes.list

# INSTALAR KUBERNETES EN LA VERSIÓN 1.33.0
apt update
apt install -y kubelet=1.33.0-1.1 kubeadm=1.33.0-1.1 kubectl=1.33.0-1.1
apt-mark hold kubelet kubeadm kubectl

# GESTION DE CPU Y MEMORIA PARA EL CLUSTER
if [ -f /etc/systemd/system.conf -a ! -f /etc/systemd/system.conf.d/kubernetes-accounting.conf ]; then
	mkdir -p /etc/systemd/system.conf.d
	cat <<EOD >/etc/systemd/system.conf.d/kubernetes-accounting.conf
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes  
EOD
fi

if [ -f /lib/systemd/system/kubelet.service.d/10-kubeadm.conf ]; then
	cat <<EOD >>/lib/systemd/system/kubelet.service.d/10-kubeadm.conf
CPUAccounting=true
MemoryAccounting=true
EOD
fi

# INICIO DEL PROCESO DE KUBELET 
systemctl start kubelet && systemctl enable kubelet

# CONFIGURACIONES DE RED NECESARIAS PARA EL CLUSTER
cat > /etc/sysctl.d/k8s.conf << EOD
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOD

sysctl --system

# REINICIO DE PROCESOS IMPORTANTES 
systemctl daemon-reload && systemctl restart docker && systemctl restart kubelet 

echo "[-] Validar que los procesos hayan iniciado correctamente"
echo "[-] Usar el comando systemctl status docker, respectivamente con cada Proceso"
echo "    Procesos:"
echo "    			[-] docker"
echo "    			[-] kubelet"
echo "    			[-] cri-docker"
echo "    			[-] cri-docker.socket"

echo "[install-k8s-worker] now copy /etc/kubernetes/node-join.sh from master (scp root@<master>:/etc/kubernetes/node-join.sh .)"
