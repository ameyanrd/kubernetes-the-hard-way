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
gcloud compute networks create kubernetes-the-hard-way --subnet-mode custom
## Create a subnet for VMs in this VPC
gcloud compute networks subnets create kubernetes \
  --network kubernetes-the-hard-way \
  --range 10.240.0.0/24
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
for instance in controller-0 controller-1 controller-2; do
  gcloud compute scp encryption-config.yaml ${instance}:~/
done

# Bootstrapping the etcd cluster
echo -e "${RED}Bootstrapping the etcd cluster${NC}"

## SSH into controllers
#echo -e "${YEL}SSH into controllers${NC}"
#for instance in controller-0 controller-1; do
#    gcloud compute ssh ${instance}
#done
