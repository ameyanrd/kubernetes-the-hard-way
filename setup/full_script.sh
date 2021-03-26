#!/bin/bash

# Colors
RED='\033[0;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color
# Template
# echo -e "${RED}${NC}\n"
# echo -e "${YEL}${NC}\n"

# Prerequisites
echo -e "${RED}Prerequites${NC}\n"
## Set the region
gcloud config set compute/region us-west1
## Set the zone
gcloud config set compute/zone us-west1-c

# Installing the Client Tools
echo -e "${RED}Installing the Client Tools${NC}\n"
## Install CFSSL
wget -q --show-progress --https-only --timestamping \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssl \
  https://storage.googleapis.com/kubernetes-the-hard-way/cfssl/1.4.1/linux/cfssljson
chmod +x cfssl cfssljson
sudo mv cfssl cfssljson /usr/local/bin/
## Verification
echo -e "${YEL}Verify CFSSL${NC}\n"
cfssl version
echo -e "${YEL}Verify CFSSLJSON${NC}\n"
cfssljson --version
## Install kubectl
wget https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl
chmod +x kubectl
sudo mv kubectl /usr/local/bin/
## Verification
echo -e "${YEL}Verify KUBECTL${NC}\n"
kubectl version --client

# Provisioning Compute Resources
echo -e "${RED}Provisioning Compute Resources${NC}\n"
## Create a dedicated VPC
echo -e "${YEL}Create a dedicated VPC: kubernetes-the-hard-way${NC}\n"
gcloud compute networks create kubernetes-the-hard-way --subnet-mode custom
## Create a subnet for VMs in this VPC
echo -e "${YEL}Create a subnet for VMs in this VPC${NC}\n"
gcloud compute networks subnets create kubernetes \
  --network kubernetes-the-hard-way \
  --range 10.240.0.0/24

echo -e "${YEL}Create the Internal and External communication firewalls${NC}\n"
## Create a firewall for internal communication across all protocols
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-internal \
  --allow tcp,udp,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 10.240.0.0/24,10.200.0.0/16
## Create a firewall rule that allows external SSH, ICMP, and HTTPS
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-external \
  --allow tcp:22,tcp:6443,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 0.0.0.0/0
## List the firewall rules in the kubernetes-the-hard-way VPC network
echo -e "${YEL}List the firewall rules in the kubernetes-the-hard-way VPC network${NC}\n"
gcloud compute firewall-rules list --filter="network:kubernetes-the-hard-way"
## Allocate a static IP address that will be attached to the external load balancer fronting the Kubernetes API Servers
gcloud compute addresses create kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region)
## Verify the kubernetes-the-hard-way static IP address was created in your default compute region
echo -e "${YEL}Verify the kubernetes-the-hard-way static IP address was created in your default compute region${NC}\n"
gcloud compute addresses list --filter="name=('kubernetes-the-hard-way')"
## Create two compute instances which will host the Kubernetes control plane
echo -e "${YEL}Create controller instances${NC}\n"
for i in 0 1; do
  gcloud compute instances create controller-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-2004-lts \
    --image-project ubuntu-os-cloud \
    --machine-type n1-standard-1 \
    --private-network-ip 10.240.0.1${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,controller
done
## Create two compute instances which will host the Kubernetes worker nodes
echo -e "${YEL}Create worker instances${NC}\n"
for i in 0 1; do
  gcloud compute instances create worker-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-2004-lts \
    --image-project ubuntu-os-cloud \
    --machine-type n1-standard-1 \
    --metadata pod-cidr=10.200.${i}.0/24 \
    --private-network-ip 10.240.0.2${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,worker
done
## List the compute instances in your default compute zone
echo -e "${YEL}Verify the Controller and Worker Nodes${NC}\n"
gcloud compute instances list --filter="tags.items=kubernetes-the-hard-way"

# Provisioning a CA and Generating TLS Certificates
echo -e "${RED}Provisioning a CA and Generating TLS Certificates${NC}"
## Generate the CA configuration file, certificate, and private key:
echo -e "${YEL}Generate the CA configuration file, certificate, and private key:${NC}\n"
{

cat > ca-config.json <<EOF
{
  "signing": {
    "default": {
      "expiry": "8760h"
    },
    "profiles": {
      "kubernetes": {
        "usages": ["signing", "key encipherment", "server auth", "client auth"],
        "expiry": "8760h"
      }
    }
  }
}
EOF

cat > ca-csr.json <<EOF
{
  "CN": "Kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "CA",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert -initca ca-csr.json | cfssljson -bare ca

}
## Generate the admin client certificate and private key
echo -e "${YEL}Generate the admin client certificate and private key${NC}\n"
{

cat > admin-csr.json <<EOF
{
  "CN": "admin",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:masters",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  admin-csr.json | cfssljson -bare admin

}
## Generate a certificate and private key for each Kubernetes worker node
echo -e "${YEL}Generate a certificate and private key for each Kubernetes worker node${NC}\n"
for instance in worker-0 worker-1; do
cat > ${instance}-csr.json <<EOF
{
  "CN": "system:node:${instance}",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:nodes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

EXTERNAL_IP=$(gcloud compute instances describe ${instance} \
  --format 'value(networkInterfaces[0].accessConfigs[0].natIP)')

INTERNAL_IP=$(gcloud compute instances describe ${instance} \
  --format 'value(networkInterfaces[0].networkIP)')

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=${instance},${EXTERNAL_IP},${INTERNAL_IP} \
  -profile=kubernetes \
  ${instance}-csr.json | cfssljson -bare ${instance}
done
## Generate the kube-controller-manager client certificate and private key
echo -e "${YEL}Generate the kube-controller-manager client certificate and private key${NC}\n"
{

cat > kube-controller-manager-csr.json <<EOF
{
  "CN": "system:kube-controller-manager",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-controller-manager",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-controller-manager-csr.json | cfssljson -bare kube-controller-manager

}
## Generate the kube-proxy client certificate and private key
echo -e "${YEL}Generate the kube-proxy client certificate and private key${NC}\n"
{

cat > kube-proxy-csr.json <<EOF
{
  "CN": "system:kube-proxy",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:node-proxier",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-proxy-csr.json | cfssljson -bare kube-proxy

}
## Generate the kube-scheduler client certificate and private key
echo -e "${YEL}Generate the kube-scheduler client certificate and private key${NC}\n"
{

cat > kube-scheduler-csr.json <<EOF
{
  "CN": "system:kube-scheduler",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "system:kube-scheduler",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  kube-scheduler-csr.json | cfssljson -bare kube-scheduler

}
## Generate the Kubernetes API Server certificate and private key
echo -e "${YEL}Generate the Kubernetes API Server certificate and private key${NC}\n"
{

KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region) \
  --format 'value(address)')

KUBERNETES_HOSTNAMES=kubernetes,kubernetes.default,kubernetes.default.svc,kubernetes.default.svc.cluster,kubernetes.svc.cluster.local

cat > kubernetes-csr.json <<EOF
{
  "CN": "kubernetes",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -hostname=10.32.0.1,10.240.0.10,10.240.0.11,10.240.0.12,${KUBERNETES_PUBLIC_ADDRESS},127.0.0.1,${KUBERNETES_HOSTNAMES} \
  -profile=kubernetes \
  kubernetes-csr.json | cfssljson -bare kubernetes

}
## Generate the service-account certificate and private key
echo -e "${YEL}Generate the service-account certificate and private key${NC}\n"
{

cat > service-account-csr.json <<EOF
{
  "CN": "service-accounts",
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "US",
      "L": "Portland",
      "O": "Kubernetes",
      "OU": "Kubernetes The Hard Way",
      "ST": "Oregon"
    }
  ]
}
EOF

cfssl gencert \
  -ca=ca.pem \
  -ca-key=ca-key.pem \
  -config=ca-config.json \
  -profile=kubernetes \
  service-account-csr.json | cfssljson -bare service-account

}
## Copy the appropriate certificates and private keys to each worker instance
echo -e "${YEL}Copy the appropriate certificates and private keys to each worker instance${NC}"
for instance in worker-0 worker-1; do
  gcloud compute scp ca.pem ${instance}-key.pem ${instance}.pem ${instance}:~/
done
## Copy the appropriate certificates and private keys to each controller instance
echo -e "${YEL}Copy the appropriate certificates and private keys to each controller instance${NC}"
for instance in controller-0 controller-1; do
  gcloud compute scp ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
    service-account-key.pem service-account.pem ${instance}:~/
done

# Generating Kubernetes Configuration Files for Authentication
echo -e "${RED}Generating Kubernetes Configuration Files for Authentication${NC}"

## Retrieve the kubernetes-the-hard-way static IP address
echo -e "${YEL}Retrieve the kubernetes-the-hard-way static IP address${NC}"
KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region) \
  --format 'value(address)')
## Generate a kubeconfig file for each worker node
echo -e "${YEL}Generate a kubeconfig file for each worker node${NC}"
for instance in worker-0 worker-1; do
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-credentials system:node:${instance} \
    --client-certificate=${instance}.pem \
    --client-key=${instance}-key.pem \
    --embed-certs=true \
    --kubeconfig=${instance}.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:node:${instance} \
    --kubeconfig=${instance}.kubeconfig

  kubectl config use-context default --kubeconfig=${instance}.kubeconfig
done
## Generate a kubeconfig file for the kube-proxy service
echo -e "${YEL}Generate a kubeconfig file for the kube-proxy service${NC}"
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443 \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-credentials system:kube-proxy \
    --client-certificate=kube-proxy.pem \
    --client-key=kube-proxy-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-proxy \
    --kubeconfig=kube-proxy.kubeconfig

  kubectl config use-context default --kubeconfig=kube-proxy.kubeconfig
}
## Generate a kubeconfig file for the kube-controller-manager service
echo -e "${YEL}Generate a kubeconfig file for the kube-controller-manager service${NC}"
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-credentials system:kube-controller-manager \
    --client-certificate=kube-controller-manager.pem \
    --client-key=kube-controller-manager-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-controller-manager \
    --kubeconfig=kube-controller-manager.kubeconfig

  kubectl config use-context default --kubeconfig=kube-controller-manager.kubeconfig
}
## Generate a kubeconfig file for the kube-scheduler service
echo -e "${YEL}Generate a kubeconfig file for the kube-scheduler service${NC}"
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-credentials system:kube-scheduler \
    --client-certificate=kube-scheduler.pem \
    --client-key=kube-scheduler-key.pem \
    --embed-certs=true \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=system:kube-scheduler \
    --kubeconfig=kube-scheduler.kubeconfig

  kubectl config use-context default --kubeconfig=kube-scheduler.kubeconfig
}
## Generate a kubeconfig file for the admin user
echo -e "${YEL}Generate a kubeconfig file for the admin user${NC}"
{
  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://127.0.0.1:6443 \
    --kubeconfig=admin.kubeconfig

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem \
    --embed-certs=true \
    --kubeconfig=admin.kubeconfig

  kubectl config set-context default \
    --cluster=kubernetes-the-hard-way \
    --user=admin \
    --kubeconfig=admin.kubeconfig

  kubectl config use-context default --kubeconfig=admin.kubeconfig
}
## Copy the appropriate kubelet and kube-proxy kubeconfig files to each worker instance
echo -e "${YEL}Copy the appropriate kubelet and kube-proxy kubeconfig files to each worker instance${NC}"
for instance in worker-0 worker-1; do
  gcloud compute scp ${instance}.kubeconfig kube-proxy.kubeconfig ${instance}:~/
done
## Copy the appropriate kube-controller-manager and kube-scheduler kubeconfig files to each controller instance
echo -e "${YEL}Copy the appropriate kube-controller-manager and kube-scheduler kubeconfig files to each controller instance${NC}"
for instance in controller-0 controller-1; do
  gcloud compute scp admin.kubeconfig kube-controller-manager.kubeconfig kube-scheduler.kubeconfig ${instance}:~/
done

# Generating the Data Encryption Config and Key
echo -e "${RED}Generating the Data Encryption Config and Key${NC}"

## Generate an encryption key
echo -e "${YEL}Generate an encryption key${NC}"
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
## Create the encryption-config.yaml encryption config file
echo -e "${YEL}Create the encryption-config.yaml encryption config file${NC}"
cat > encryption-config.yaml <<EOF
kind: EncryptionConfig
apiVersion: v1
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: key1
              secret: ${ENCRYPTION_KEY}
      - identity: {}
EOF
## Copy the encryption-config.yaml encryption config file to each controller instance
echo -e "${YEL}Copy the encryption-config.yaml encryption config file to each controller instance${NC}"
for instance in controller-0 controller-1; do
  gcloud compute scp encryption-config.yaml ${instance}:~/
done

# Bootstrapping the etcd cluster
echo -e "${RED}Bootstrapping the etcd cluster${NC}"

## SSH into controllers
echo -e "${YEL}SSH into controllers${NC}"
for instance in controller-0 controller-1; do
    cat > bs_etcd.sh << EOF1
# Colors
RED='\033[0;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\${YEL}Download the official etcd release binaries from the etcd GitHub project\${NC}\n"
wget -q --show-progress --https-only --timestamping \
  "https://github.com/etcd-io/etcd/releases/download/v3.4.10/etcd-v3.4.10-linux-amd64.tar.gz"

echo -e "\${YEL}Extract and install the etcd server and the etcdctl command line utility\${NC}\n"
{
  tar -xvf etcd-v3.4.10-linux-amd64.tar.gz
  sudo mv etcd-v3.4.10-linux-amd64/etcd* /usr/local/bin/
}

echo -e "\${YEL}Configure the etcd Server\${NC}\n"
{
  sudo mkdir -p /etc/etcd /var/lib/etcd
  sudo chmod 700 /var/lib/etcd
  sudo cp ca.pem kubernetes-key.pem kubernetes.pem /etc/etcd/
}

echo -e "\${YEL}Retrieve the internal IP address for the current compute instance\${NC}\n"
INTERNAL_IP=\$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

echo -e "\${YEL}Set the etcd name to match the hostname of the current compute instance\${NC}\n"
ETCD_NAME=\$(hostname -s)

echo -e "\${YEL}Create the etcd.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/etcd.service
[Unit]
Description=etcd
Documentation=https://github.com/coreos

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd \\
  --name \${ETCD_NAME} \\
  --cert-file=/etc/etcd/kubernetes.pem \\
  --key-file=/etc/etcd/kubernetes-key.pem \\
  --peer-cert-file=/etc/etcd/kubernetes.pem \\
  --peer-key-file=/etc/etcd/kubernetes-key.pem \\
  --trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-trusted-ca-file=/etc/etcd/ca.pem \\
  --peer-client-cert-auth \\
  --client-cert-auth \\
  --initial-advertise-peer-urls https://\${INTERNAL_IP}:2380 \\
  --listen-peer-urls https://\${INTERNAL_IP}:2380 \\
  --listen-client-urls https://\${INTERNAL_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://\${INTERNAL_IP}:2379 \\
  --initial-cluster-token etcd-cluster-0 \\
  --initial-cluster controller-0=https://10.240.0.10:2380,controller-1=https://10.240.0.11:2380,controller-2=https://10.240.0.12:2380 \\
  --initial-cluster-state new \\
  --data-dir=/var/lib/etcd
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo -e "\${YEL}Start the etcd Server\${NC}\n"
{
  sudo systemctl daemon-reload
  sudo systemctl enable etcd
  sudo systemctl start etcd
}

## Verification of etcd cluster members
echo -e "\${YEL}Verification: List of the etcd cluster members\${NC}\n"
sudo ETCDCTL_API=3 etcdctl member list \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/etcd/ca.pem \
  --cert=/etc/etcd/kubernetes.pem \
  --key=/etc/etcd/kubernetes-key.pem

EOF1
    chmod +x bs_etcd.sh
    gcloud compute scp bs_etcd.sh ${instance}:.
    rm -rf etcd.sh
    echo -e "${YEL}SSHing into ${instance}...\n\n Please run bs_etcd.sh inside it and exit.${NC}\n"
    gcloud compute ssh ${instance}
done

# Bootstrapping the Kubernetes Control Plane
echo -e "${RED}Bootstrapping the Kubernetes Control Plane${NC}\n"

## SSH into controllers
echo -e "${YEL}SSH into controllers${NC}\n"
for instance in controller-0 controller-1; do
    cat > bs_kcp.sh << EOF1
# Colors
RED='\033[0;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\${YEL}Create the Kubernetes configuration directory\${NC}\n"
sudo mkdir -p /etc/kubernetes/config

echo -e "\${YEL}Download the official Kubernetes release binaries\${NC}\n"
wget -q --show-progress --https-only --timestamping \
  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-apiserver" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-controller-manager" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-scheduler" \
  "https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl"

echo -e "\${YEL}Install Kubernetes binaries\${NC}\n"
{
  chmod +x kube-apiserver kube-controller-manager kube-scheduler kubectl
  sudo mv kube-apiserver kube-controller-manager kube-scheduler kubectl /usr/local/bin/
}

echo -e "\${YEL}Configure the Kubernetes API Server\${NC}\n"
{
  echo -e "\${YEL}1. Make /var/lib/kubernetes/\${NC}\n"
  sudo mkdir -p /var/lib/kubernetes/

  echo -e "\${YEL}2. Move the CA, Kubernetes (apiserver) and service-account certificates and private keys to the above folder\${NC}\n"
  sudo mv ca.pem ca-key.pem kubernetes-key.pem kubernetes.pem \
    service-account-key.pem service-account.pem \
    encryption-config.yaml /var/lib/kubernetes/
}

## Fetch internal IP used to advertise the API Server
echo -e "\${YEL}3. Fetch internal IP used to advertise the API Server\${NC}\n"
INTERNAL_IP=\$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

## Create the kube-apiserver.service systemd unit file
echo -e "\${YEL}4. Create the kube-apiserver.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/kube-apiserver.service
[Unit]
Description=Kubernetes API Server
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-apiserver \\
  --advertise-address=\${INTERNAL_IP} \\
  --allow-privileged=true \\
  --apiserver-count=3 \\
  --audit-log-maxage=30 \\
  --audit-log-maxbackup=3 \\
  --audit-log-maxsize=100 \\
  --audit-log-path=/var/log/audit.log \\
  --authorization-mode=Node,RBAC \\
  --bind-address=0.0.0.0 \\
  --client-ca-file=/var/lib/kubernetes/ca.pem \\
  --enable-admission-plugins=NamespaceLifecycle,NodeRestriction,LimitRanger,ServiceAccount,DefaultStorageClass,ResourceQuota \\
  --etcd-cafile=/var/lib/kubernetes/ca.pem \\
  --etcd-certfile=/var/lib/kubernetes/kubernetes.pem \\
  --etcd-keyfile=/var/lib/kubernetes/kubernetes-key.pem \\
  --etcd-servers=https://10.240.0.10:2379,https://10.240.0.11:2379,https://10.240.0.12:2379 \\
  --event-ttl=1h \\
  --encryption-provider-config=/var/lib/kubernetes/encryption-config.yaml \\
  --kubelet-certificate-authority=/var/lib/kubernetes/ca.pem \\
  --kubelet-client-certificate=/var/lib/kubernetes/kubernetes.pem \\
  --kubelet-client-key=/var/lib/kubernetes/kubernetes-key.pem \\
  --kubelet-https=true \\
  --runtime-config='api/all=true' \\
  --service-account-key-file=/var/lib/kubernetes/service-account.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --service-node-port-range=30000-32767 \\
  --tls-cert-file=/var/lib/kubernetes/kubernetes.pem \\
  --tls-private-key-file=/var/lib/kubernetes/kubernetes-key.pem \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## Configure the Kubernetes Controller Manager
echo -e "\${YEL}Configure the Kubernetes Controller Manager\${NC}\n"
echo -e "\${YEL}1. Move the kube-controller-manager kubeconfig into /var/lib/kubernetes\${NC}\n"
sudo mv kube-controller-manager.kubeconfig /var/lib/kubernetes/

echo -e "\${YEL}2. Create the kube-controller-manager.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/kube-controller-manager.service
[Unit]
Description=Kubernetes Controller Manager
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-controller-manager \\
  --bind-address=0.0.0.0 \\
  --cluster-cidr=10.200.0.0/16 \\
  --cluster-name=kubernetes \\
  --cluster-signing-cert-file=/var/lib/kubernetes/ca.pem \\
  --cluster-signing-key-file=/var/lib/kubernetes/ca-key.pem \\
  --kubeconfig=/var/lib/kubernetes/kube-controller-manager.kubeconfig \\
  --leader-elect=true \\
  --root-ca-file=/var/lib/kubernetes/ca.pem \\
  --service-account-private-key-file=/var/lib/kubernetes/service-account-key.pem \\
  --service-cluster-ip-range=10.32.0.0/24 \\
  --use-service-account-credentials=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## Configure the Kubernetes Scheduler
echo -e "\${YEL}Configure the Kubernetes Scheduler\${NC}\n"
echo -e "\${YEL}1. Move the kube-scheduler kubeconfig into /var/lib/kubernetes\${NC}\n"
sudo mv kube-scheduler.kubeconfig /var/lib/kubernetes/

echo -e "\${YEl}2. Create the kube-scheduler.yaml configuration file\${NC}\n"
cat <<EOF | sudo tee /etc/kubernetes/config/kube-scheduler.yaml
apiVersion: kubescheduler.config.k8s.io/v1alpha1
kind: KubeSchedulerConfiguration
clientConnection:
  kubeconfig: "/var/lib/kubernetes/kube-scheduler.kubeconfig"
leaderElection:
  leaderElect: true
EOF

echo -e "\${YEL}3. Create the kube-scheduler.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/kube-scheduler.service
[Unit]
Description=Kubernetes Scheduler
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-scheduler \\
  --config=/etc/kubernetes/config/kube-scheduler.yaml \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

## Start the Controller Services (API server, Control Manager, Kube-scheduler)
echo -e "\${YEL}Start the Controller Services (API server, Control Manager, Kube-scheduler)\${NC}\n"
{
  sudo systemctl daemon-reload
  sudo systemctl enable kube-apiserver kube-controller-manager kube-scheduler
  sudo systemctl start kube-apiserver kube-controller-manager kube-scheduler
}

## Enable HTTP Health Checks
echo -e "\${YEL}Enable HTTP Health Checks\${NC}\n"

echo -e "\${YEL}1. Install a basic web server to handle HTTP health checks\${NC}\n"
sudo apt-get update
sudo apt-get install -y nginx

echo -e "\${YEL}2. Configure the Nginx server for health check endpoint\${NC}\n"
cat > kubernetes.default.svc.cluster.local <<EOF
server {
  listen      80;
  server_name kubernetes.default.svc.cluster.local;

  location /healthz {
     proxy_pass                    https://127.0.0.1:6443/healthz;
     proxy_ssl_trusted_certificate /var/lib/kubernetes/ca.pem;
  }
}
EOF

echo -e "\${YEL}3. Move the above file to sites-available and create a soft link to sites-enabled\${NC}\n"
{
  sudo mv kubernetes.default.svc.cluster.local \
    /etc/nginx/sites-available/kubernetes.default.svc.cluster.local

  sudo ln -s /etc/nginx/sites-available/kubernetes.default.svc.cluster.local /etc/nginx/sites-enabled/
}

echo -e "\${YEL}4. Restart and Enable Nginx\${NC}\n"
sudo systemctl restart nginx
sudo systemctl enable nginx

echo -e "\${YEL}Verification of Controller Services and HTTP health-check proxy\${NC}\n"
echo -e "\${YEL}1. Check the components (use admin kubeconfig for authentication)\${NC}\n"
kubectl get componentstatuses --kubeconfig admin.kubeconfig

echo -e "\${YEL}2. Test the nginx HTTP health check proxy\${NC}\n"
curl -H "Host: kubernetes.default.svc.cluster.local" -i http://127.0.0.1/healthz

EOF1
    chmod +x bs_kcp.sh
    gcloud compute scp bs_kcp.sh ${instance}:.
    rm -rf bs_kcp.sh
    echo -e "${YEL}SSHing into ${instance}...\n\n Please run bs_kcp.sh inside it and exit.${NC}\n"
    gcloud compute ssh ${instance}
done

## RBAC for Kubelet Authorization
echo -e "${YEL}RBAC for Kubelet Authorization${NC}\n"
echo -e "${YEL}(Access to the Kubelet API is required for retrieving metrics, logs, and executing commands in pods.)${NC}\n"
echo -e "${YEL}(Commands need to be executed in any one of the controllers)${NC}\n"

cat > bs_rbac.sh << EOF1

# Colors
RED='\033[0;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

## Create the system:kube-apiserver-to-kubelet ClusterRole with permissions to access the Kubelet API and perform most common tasks associated with managing pods
echo -e "\${YEL}Create the system:kube-apiserver-to-kubelet ClusterRole with permissions to access the Kubelet API and perform most common tasks associated with managing pods\${NC}\n"

cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRole
metadata:
  annotations:
    rbac.authorization.kubernetes.io/autoupdate: "true"
  labels:
    kubernetes.io/bootstrapping: rbac-defaults
  name: system:kube-apiserver-to-kubelet
rules:
  - apiGroups:
      - ""
    resources:
      - nodes/proxy
      - nodes/stats
      - nodes/log
      - nodes/spec
      - nodes/metrics
    verbs:
      - "*"
EOF

## Bind the system:kube-apiserver-to-kubelet ClusterRole to the kubernetes user
echo -e "\${YEL}Bind the system:kube-apiserver-to-kubelet ClusterRole to the kubernetes user\${NC}\n"

cat <<EOF | kubectl apply --kubeconfig admin.kubeconfig -f -
apiVersion: rbac.authorization.k8s.io/v1beta1
kind: ClusterRoleBinding
metadata:
  name: system:kube-apiserver
  namespace: ""
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-apiserver-to-kubelet
subjects:
  - apiGroup: rbac.authorization.k8s.io
    kind: User
    name: kubernetes
EOF

EOF1

chmod +x bs_rbac.sh
gcloud compute scp bs_rbac.sh controller-0:.
rm -rf bs_rbac.sh
echo -e "${YEL}SSHing into Controller-0...\n\n Please run bs_rbac.sh inside it and exit.${NC}\n"
gcloud compute ssh controller-0

## The Kubernetes Frontend Load Balancer
echo -e "${YEL}The Kubernetes Frontend Load Balancer${NC}\n"

{
  echo -e "${YEL}1. Get the public IP address for Load Balancer${NC}\n"
  KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
    --region $(gcloud config get-value compute/region) \
    --format 'value(address)')
  echo -e "${YEL}2. Create HTTP health checks on path /healthz${NC}\n"
  gcloud compute http-health-checks create kubernetes \
    --description "Kubernetes Health Check" \
    --host "kubernetes.default.svc.cluster.local" \
    --request-path "/healthz"
  echo -e "${YEL}3. Create Firewall Rule to allow for the health check${NC}\n"
  gcloud compute firewall-rules create kubernetes-the-hard-way-allow-health-check \
    --network kubernetes-the-hard-way \
    --source-ranges 209.85.152.0/22,209.85.204.0/22,35.191.0.0/16 \
    --allow tcp
  echo -e "${YEL}4. Create a target pool for the controllers where the above HTTP health check takes place${NC}\n"
  gcloud compute target-pools create kubernetes-target-pool \
    --http-health-check kubernetes
  echo -e "${YEL}Add the instances controller-n to the target pool${NC}\n"
  gcloud compute target-pools add-instances kubernetes-target-pool \
   --instances controller-0,controller-1
  echo -e "${YEL}Create a forwarding rule on the port of KUBERNETES_PUBLIC_ADDRESS${NC}\n"
  gcloud compute forwarding-rules create kubernetes-forwarding-rule \
    --address ${KUBERNETES_PUBLIC_ADDRESS} \
    --ports 6443 \
    --region $(gcloud config get-value compute/region) \
    --target-pool kubernetes-target-pool
}

## Verification
echo -e "${YEL}Verification${NC}\n"
echo -e "${YEL}1. Retrieve the kubernetes-the-hard-way static IP address${NC}\n"
KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region) \
  --format 'value(address)')

echo -e "${YEL}2. Make a HTTPS request for the Kubernetes version INFO:${NC}\n"
curl --cacert ca.pem https://${KUBERNETES_PUBLIC_ADDRESS}:6443/version

# Bootstrapping the Kubernetes Worker Nodes

echo -e "${RED}Bootstrapping the Kubernetes Worker Nodes${NC}\n"

for instance in worker-0 worker-1; do
    cat > bs_kwn.sh << EOF1
# Colors
RED='\033[0;31m'
YEL='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\${YEL}Install the OS dependencies\${NC}\n"
{
  sudo apt-get update
  sudo apt-get -y install socat conntrack ipset
}

echo -e "\${YEL}Diable Swap\${NC}\n"
sudo swapoff -a

echo -e "\${YEL}Download and Install Worker Binaries\${NC}\n"
wget -q --show-progress --https-only --timestamping \
  https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.18.0/crictl-v1.18.0-linux-amd64.tar.gz \
  https://github.com/opencontainers/runc/releases/download/v1.0.0-rc91/runc.amd64 \
  https://github.com/containernetworking/plugins/releases/download/v0.8.6/cni-plugins-linux-amd64-v0.8.6.tgz \
  https://github.com/containerd/containerd/releases/download/v1.3.6/containerd-1.3.6-linux-amd64.tar.gz \
  https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubectl \
  https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kube-proxy \
  https://storage.googleapis.com/kubernetes-release/release/v1.18.6/bin/linux/amd64/kubelet

echo -e "\${YEL}Create the installation directories\${NC}\n"
sudo mkdir -p \
  /etc/cni/net.d \
  /opt/cni/bin \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/lib/kubernetes \
  /var/run/kubernetes

echo -e "\${YEL}Install the worker binaries\${NC}\n"
{
  mkdir containerd
  tar -xvf crictl-v1.18.0-linux-amd64.tar.gz
  tar -xvf containerd-1.3.6-linux-amd64.tar.gz -C containerd
  sudo tar -xvf cni-plugins-linux-amd64-v0.8.6.tgz -C /opt/cni/bin/
  sudo mv runc.amd64 runc
  chmod +x crictl kubectl kube-proxy kubelet runc
  sudo mv crictl kubectl kube-proxy kubelet runc /usr/local/bin/
  sudo mv containerd/bin/* /bin/
}

echo -e "\${YEL}Configure CNI Networking\${NC}\n"

echo -e "\${YEL}1. Retrieve the Pod CIDR range for the current compute instance\${NC}\n"
POD_CIDR=\$(curl -s -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/attributes/pod-cidr)

echo -e "\${YEL}2. Create the bridge network configuration file\${NC}\n"
cat <<EOF | sudo tee /etc/cni/net.d/10-bridge.conf
{
    "cniVersion": "0.3.1",
    "name": "bridge",
    "type": "bridge",
    "bridge": "cnio0",
    "isGateway": true,
    "ipMasq": true,
    "ipam": {
        "type": "host-local",
        "ranges": [
          [{"subnet": "\${POD_CIDR}"}]
        ],
        "routes": [{"dst": "0.0.0.0/0"}]
    }
}
EOF

echo -e "\${YEL}3. Create the loopback network configuration file\${NC}\n"
cat <<EOF | sudo tee /etc/cni/net.d/99-loopback.conf
{
    "cniVersion": "0.3.1",
    "name": "lo",
    "type": "loopback"
}
EOF

echo -e "\${YEL}Configure containerd\${NC}\n"

echo -e "\${YEL}1. Create the containerd configuration file\${NC}\n"
sudo mkdir -p /etc/containerd/

cat << EOF | sudo tee /etc/containerd/config.toml
[plugins]
  [plugins.cri.containerd]
    snapshotter = "overlayfs"
    [plugins.cri.containerd.default_runtime]
      runtime_type = "io.containerd.runtime.v1.linux"
      runtime_engine = "/usr/local/bin/runc"
      runtime_root = ""
EOF

echo -e "\${YEL}2. Create the containerd.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/containerd.service
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target

[Service]
ExecStartPre=/sbin/modprobe overlay
ExecStart=/bin/containerd
Restart=always
RestartSec=5
Delegate=yes
KillMode=process
OOMScoreAdjust=-999
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity

[Install]
WantedBy=multi-user.target
EOF

echo -e "\${YEL}Configure the Kubelet\${NC}\n"
{
  sudo mv \${HOSTNAME}-key.pem \${HOSTNAME}.pem /var/lib/kubelet/
  sudo mv \${HOSTNAME}.kubeconfig /var/lib/kubelet/kubeconfig
  sudo mv ca.pem /var/lib/kubernetes/
}

echo -e "\${YEL}1. Create the kubelet-config.yaml configuration file\${NC}\n"
cat <<EOF | sudo tee /var/lib/kubelet/kubelet-config.yaml
kind: KubeletConfiguration
apiVersion: kubelet.config.k8s.io/v1beta1
authentication:
  anonymous:
    enabled: false
  webhook:
    enabled: true
  x509:
    clientCAFile: "/var/lib/kubernetes/ca.pem"
authorization:
  mode: Webhook
clusterDomain: "cluster.local"
clusterDNS:
  - "10.32.0.10"
podCIDR: "\${POD_CIDR}"
resolvConf: "/run/systemd/resolve/resolv.conf"
runtimeRequestTimeout: "15m"
tlsCertFile: "/var/lib/kubelet/\${HOSTNAME}.pem"
tlsPrivateKeyFile: "/var/lib/kubelet/\${HOSTNAME}-key.pem"
EOF

echo -e "\${YEL}Create the kubelet.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/kubelet.service
[Unit]
Description=Kubernetes Kubelet
Documentation=https://github.com/kubernetes/kubernetes
After=containerd.service
Requires=containerd.service

[Service]
ExecStart=/usr/local/bin/kubelet \\
  --config=/var/lib/kubelet/kubelet-config.yaml \\
  --container-runtime=remote \\
  --container-runtime-endpoint=unix:///var/run/containerd/containerd.sock \\
  --image-pull-progress-deadline=2m \\
  --kubeconfig=/var/lib/kubelet/kubeconfig \\
  --network-plugin=cni \\
  --register-node=true \\
  --v=2
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo -e "\${YEL}Configure the Kubernetes Proxy\${NC}\n"
sudo mv kube-proxy.kubeconfig /var/lib/kube-proxy/kubeconfig

echo -e "\${YEL}1. Create the kube-proxy-config.yaml configuration file\${NC}\n"
cat <<EOF | sudo tee /var/lib/kube-proxy/kube-proxy-config.yaml
kind: KubeProxyConfiguration
apiVersion: kubeproxy.config.k8s.io/v1alpha1
clientConnection:
  kubeconfig: "/var/lib/kube-proxy/kubeconfig"
mode: "iptables"
clusterCIDR: "10.200.0.0/16"
EOF

echo -e "\${YEL}2. Create the kube-proxy.service systemd unit file\${NC}\n"
cat <<EOF | sudo tee /etc/systemd/system/kube-proxy.service
[Unit]
Description=Kubernetes Kube Proxy
Documentation=https://github.com/kubernetes/kubernetes

[Service]
ExecStart=/usr/local/bin/kube-proxy \\
  --config=/var/lib/kube-proxy/kube-proxy-config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

echo -e "\${YEL}Start the Worker Services\${NC}\n"
{
  sudo systemctl daemon-reload
  sudo systemctl enable containerd kubelet kube-proxy
  sudo systemctl start containerd kubelet kube-proxy
}
EOF1
    chmod +x bs_kwn.sh
    gcloud compute scp bs_kwn.sh ${instance}:.
    rm -rf bs_kwn.sh
    echo -e "${YEL}SSHing into ${instance}...\n\n Please run bs_kwn.sh inside it and exit.${NC}\n"
    gcloud compute ssh ${instance}
done

gcloud compute ssh controller-0 \
  --command "kubectl get nodes --kubeconfig admin.kubeconfig"

# Configuring kubectl for Remote Access
echo -e "${RED}Configuring kubectl for Remote Access${NC}\n"

echo -e "${YEL}Generate a kubeconfig file suitable for authenticating as the admin user${NC}\n"
{
  KUBERNETES_PUBLIC_ADDRESS=$(gcloud compute addresses describe kubernetes-the-hard-way \
    --region $(gcloud config get-value compute/region) \
    --format 'value(address)')

  kubectl config set-cluster kubernetes-the-hard-way \
    --certificate-authority=ca.pem \
    --embed-certs=true \
    --server=https://${KUBERNETES_PUBLIC_ADDRESS}:6443

  kubectl config set-credentials admin \
    --client-certificate=admin.pem \
    --client-key=admin-key.pem

  kubectl config set-context kubernetes-the-hard-way \
    --cluster=kubernetes-the-hard-way \
    --user=admin

  kubectl config use-context kubernetes-the-hard-way
}

## Verification
echo -e "${YEL}Verification${NC}\n"
echo -e "${YEL}1. Check the health of the remote Kubernetes cluster${NC}\n"
kubectl get componentstatuses

echo -e "${YEL}2. List the nodes in the remote Kubernetes cluster${NC}\n"
kubectl get nodes

# Provisioning Pod Network Routes

echo -e "${RED}Provisioning Pod Network Routes${NC}\n"

echo -e "${RED}Print the internal IP address and Pod CIDR range for each worker instance${NC}\n"
for instance in worker-0 worker-1; do
  gcloud compute instances describe ${instance} \
    --format 'value[separator=" "](networkInterfaces[0].networkIP,metadata.items[0].value)'
done

echo -e "${YEL}Routes${NC}\n"
echo -e "${YEL}1. Create network routes for each worker instance${NC}\n"
for i in 0 1 2; do
  gcloud compute routes create kubernetes-route-10-200-${i}-0-24 \
    --network kubernetes-the-hard-way \
    --next-hop-address 10.240.0.2${i} \
    --destination-range 10.200.${i}.0/24
done

echo -e "${YEL}List the routes in the kubernetes-the-hard-way VPC network${NC}\n"
gcloud compute routes list --filter "network: kubernetes-the-hard-way"

# Deploying the DNS Cluster Add-on
echo -e "${RED}Deploying the DNS Cluster Add-on${NC}\n"

echo -e "${YEL}The DNS Cluster Add-on${NC}\n"
echo -e "${YEL}1. Deploy the coredns cluster add-on${NC}\n"
kubectl apply -f https://storage.googleapis.com/kubernetes-the-hard-way/coredns-1.7.0.yaml

echo -e "${YEL}2. List the pods created by the kube-dns deployment${NC}\n"
kubectl get pods -l k8s-app=kube-dns -n kube-system

echo -e "${YEL}Verification${NC}\n"
echo -e "${YEL}1. Create a busybox deployment${NC}\n"
kubectl run busybox --image=busybox:1.28 --command -- sleep 3600

echo -e "${YEL}2. List the pod created by the busybox deployment${NC}\n"
kubectl get pods -l run=busybox

echo -e "${YEL}3. Retrieve the full name of the busybox pod${NC}\n"
POD_NAME=$(kubectl get pods -l run=busybox -o jsonpath="{.items[0].metadata.name}")

echo -e "${YEL}4. Execute a DNS lookup for the kubernetes service inside the busybox pod${NC}\n"
kubectl exec -ti $POD_NAME -- nslookup kubernetes

