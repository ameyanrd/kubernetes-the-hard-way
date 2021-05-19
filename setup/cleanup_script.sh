#!/bin/bash

# Colors
RED='\033[0;31m'
NC='\033[0m' # No Color
# Template
# echo -e "${RED}${NC}\n"

# Delete the controller and worker compute instances
echo -e "${RED}Delete the controller and worker compute instances${NC}\n"
gcloud -q compute instances delete \
  controller-0 controller-1 controller-2 \
  worker-0 worker-1 worker-2 \
  --zone $(gcloud config get-value compute/zone)

# Delete the external load balancer network resources
echo -e "${RED}Delete the external load balancer network resources${NC}\n"
{
  gcloud -q compute forwarding-rules delete kubernetes-forwarding-rule \
    --region $(gcloud config get-value compute/region)

  gcloud -q compute target-pools delete kubernetes-target-pool

  gcloud -q compute http-health-checks delete kubernetes

  gcloud -q compute addresses delete kubernetes-the-hard-way
}

# Delete the kubernetes-the-hard-way firewall rules
echo -e "${RED}Delete the kubernetes-the-hard-way firewall rules${NC}\n"
gcloud -q compute firewall-rules delete \
  kubernetes-the-hard-way-allow-nginx-service \
  kubernetes-the-hard-way-allow-internal \
  kubernetes-the-hard-way-allow-external \
  kubernetes-the-hard-way-allow-health-check

# Delete the kubernetes-the-hard-way network VPC
echo -e "${RED}Delete the kubernetes-the-hard-way network VPC${NC}\n"
{
  gcloud -q compute routes delete \
    kubernetes-route-10-200-0-0-24 \
    kubernetes-route-10-200-1-0-24 \
    kubernetes-route-10-200-2-0-24

  gcloud -q compute networks subnets delete kubernetes

  gcloud -q compute networks delete kubernetes-the-hard-way
}
