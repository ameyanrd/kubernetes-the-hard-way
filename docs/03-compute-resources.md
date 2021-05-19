# Provisioning Compute Resources

Kubernetes requires a set of machines to host the Kubernetes control plane and the worker nodes where containers are ultimately run. In this lab you will provision the compute resources required for running a secure and highly available Kubernetes cluster across a single [compute zone](https://cloud.google.com/compute/docs/regions-zones/regions-zones).

> Ensure a default compute zone and region have been set as described in the [Prerequisites](01-prerequisites.md#set-a-default-compute-region-and-zone) lab.

## Networking

The Kubernetes [networking model](https://kubernetes.io/docs/concepts/cluster-administration/networking/#kubernetes-model) assumes a flat network in which containers and nodes can communicate with each other. In cases where this is not desired [network policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) can limit how groups of containers are allowed to communicate with each other and external network endpoints.

> Setting up network policies is out of scope for this tutorial.

### Virtual Private Cloud Network

In this section a dedicated [Virtual Private Cloud](https://cloud.google.com/compute/docs/networks-and-firewalls#networks) (VPC) network will be setup to host the Kubernetes cluster.

A VPC is basically a subset of a Public Cloud Service with all of its resources isolated from the rest of the public cloud. It is a virtual version of a physical network. Since it's isolated, it is secure, and it can share resources with the rest of the cloud network. Organisations using a VPC need not pay for software, hardware, or maintenance. Since a public cloud service is being used, you only pay for the resources you use and hence, it is cost-effective. More details can be found [here](https://www.checkpoint.com/cyber-hub/cloud-security/what-is-vpc-virtual-private-cloud/).

Create the `kubernetes-the-hard-way` custom VPC network:

```
gcloud compute networks create kubernetes-the-hard-way --subnet-mode custom
```

A [subnet](https://cloud.google.com/compute/docs/vpc/#vpc_networks_and_subnets) must be provisioned with an IP address range large enough to assign a private IP address to each node in the Kubernetes cluster.

Create the `kubernetes` subnet in the `kubernetes-the-hard-way` VPC network:

```
gcloud compute networks subnets create kubernetes \
  --network kubernetes-the-hard-way \
  --range 10.240.0.0/24
```

> The `10.240.0.0/24` IP address range can host up to 254 compute instances.
 
To understand what subnets are, it is important to understand the structure of an IP address. Since we're dealing with IPv4 addresses, we'll only be discussing that in detail here.

An IP address is a unique identifier used to identify devices over a network. An IP address can be public or private. A public IP address is that which is visible over the internet and is used to uniquely identify devices over the internet. A private IP address, on the other hand, uniquely identifies devices in a network and is usually assigned by a local network administrator or a router. The scope of a private IP is local to the network that the device is a part of.

An IPv4 address is a 4-byte long address separated by dots. Each byte is represented in the decimal format and can have any value between 0 and 255. They allow for 2<sup>32</sup> unique addresses. An example of an IPv4 address is `10.240.1.1`. The term IP used hereafter would refer to IPv4 addresses unless specified otherwise. To allow for easier searching of IP addresses from such a huge set of addresses over the internet, we have two further sub-classes within the IP address - the network address and the host address. This is analogous to postal codes in India - where the first digit stands for the postal region/state, and the next few digits are allotted to districts within the larger states. The network part is used to identify the network, amd the host part is used to pin-point the device within that network. 

Let's consider an example - `10.240.1.1`. Here `10.x.x.x` identifies the network, while `x.240.1.1` identifies the host device.

Based on these sub classes, IP addresses divided into five classes -

- **Class A** - `0.0.0.0	to 127.0.0.0` - Only the first 8 bits identify the network. It can therefore have 128 networks and (2<sup>24</sup>-2) devices per network. Used by networks with a large number devices. `127.x.x.x` is a special address called the loop-back address.
 
- **Class B** - `128.0.0.0 to 191.255.0.0` - First 16 bits identify the network. Used for the networks with a medium number of hosts.
 
- **Class C** - `192.0.0.0 to 223.255.255.0` - First 24 bits used to identify the network, usually used by local networks, like in a computer lab or your home for instance.
 
- **Class D** - `224.0.0.0 to 239.255.255.255` - All 4 octets identify a network uniquely. All devices connected to a network use the same address, and is used for multicasting.

- **Class E** - `240.0.0.0 to 255.255.255.255` - This address class is reserved for experiments and research.

The first address of a particular class is reserved for the network, and the last one reserved for broadcasting.

Coming back to subnets, a subnet mask identifies the network part in a network. It can be represented in two formats -

- **Dotted decimal format** - `255.255.255.0` is a subnet mask for an IP address belonging to Class C. Similarly, `255.255.0.0` is a subnet mask for that of Class B. A deeper understanding can be obtained by looking at how IP addresses work at the binary level. You can read more [here](https://www.garykessler.net/library/subnet_masks.html).

- **Decimal format** - Represented by the number of digits that form the network part of a network. For example, `192.168.0.1/24`. Here, 24 is the subnet mask which means the first 24 bits (or the first 3 bytes) form the network part of the address and the last byte identifies the host. 

Subnet masks also introduce the concept of [Classless Inter Domain Routing (CIDR)](https://whatismyipaddress.com/cidr). Classless inter-domain routing (CIDR) is a set of Internet protocol (IP) standards that is used to create unique identifiers for networks and individual devices. You can read more about IP addresses, subnets and CIDRs [here](https://www.digitalocean.com/community/tutorials/understanding-ip-addresses-subnets-and-cidr-notation-for-networking).

### Firewall Rules

A firewall is a network security device that monitors incoming and outgoing network traffic and decides whether to allow or block specific traffic based on a defined set of security rules.

Create a firewall rule that allows internal communication across all protocols:

```
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-internal \
  --allow tcp,udp,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 10.240.0.0/24,10.200.0.0/16
```

Create a firewall rule that allows external SSH, ICMP, and HTTPS:

```
gcloud compute firewall-rules create kubernetes-the-hard-way-allow-external \
  --allow tcp:22,tcp:6443,icmp \
  --network kubernetes-the-hard-way \
  --source-ranges 0.0.0.0/0
```

> An [external load balancer](https://cloud.google.com/compute/docs/load-balancing/network/) will be used to expose the Kubernetes API Servers to remote clients.

An external load balancer distributes traffic coming in from the internet to the VPC. On the contrary, an internal load balancer is assigned to a private subnet and does not have a public IP address. It routes traffic to clients within the subnet.

List the firewall rules in the `kubernetes-the-hard-way` VPC network:

```
gcloud compute firewall-rules list --filter="network:kubernetes-the-hard-way"
```

> output

```
NAME                                    NETWORK                  DIRECTION  PRIORITY  ALLOW                 DENY  DISABLED
kubernetes-the-hard-way-allow-external  kubernetes-the-hard-way  INGRESS    1000      tcp:22,tcp:6443,icmp        False
kubernetes-the-hard-way-allow-internal  kubernetes-the-hard-way  INGRESS    1000      tcp,udp,icmp                Fals
```

### Kubernetes Public IP Address

Allocate a static IP address that will be attached to the external load balancer fronting the Kubernetes API Servers:

```
gcloud compute addresses create kubernetes-the-hard-way \
  --region $(gcloud config get-value compute/region)
```

Verify the `kubernetes-the-hard-way` static IP address was created in your default compute region:

```
gcloud compute addresses list --filter="name=('kubernetes-the-hard-way')"
```

> output

```
NAME                     ADDRESS/RANGE   TYPE      PURPOSE  NETWORK  REGION    SUBNET  STATUS
kubernetes-the-hard-way  XX.XXX.XXX.XXX  EXTERNAL                    us-west1          RESERVED
```

## Compute Instances

The compute instances in this lab will be provisioned using [Ubuntu Server](https://www.ubuntu.com/server) 20.04, which has good support for the [containerd container runtime](https://github.com/containerd/containerd). Each compute instance will be provisioned with a fixed private IP address to simplify the Kubernetes bootstrapping process.

### Kubernetes Controllers

Kubernetes controllers are just watch-dogs that watch the state of your cluster, then make or request changes where needed. It tries to move the current cluster state closer to the desired state.

Create three compute instances which will host the Kubernetes control plane:

```
for i in 0 1 2; do
  gcloud compute instances create controller-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-2004-lts \
    --image-project ubuntu-os-cloud \
    --machine-type e2-standard-2 \
    --private-network-ip 10.240.0.1${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,controller
done
```

### Kubernetes Workers

Kubernetes workers are nodes within the cluster. Each worker instance requires a pod subnet allocation from the Kubernetes cluster CIDR range. The pod subnet allocation will be used to configure container networking in a later exercise. The `pod-cidr` instance metadata will be used to expose pod subnet allocations to compute instances at runtime.

> The Kubernetes cluster CIDR range is defined by the Controller Manager's `--cluster-cidr` flag. In this tutorial the cluster CIDR range will be set to `10.200.0.0/16`, which supports 254 subnets.

Create three compute instances which will host the Kubernetes worker nodes:

```
for i in 0 1 2; do
  gcloud compute instances create worker-${i} \
    --async \
    --boot-disk-size 200GB \
    --can-ip-forward \
    --image-family ubuntu-2004-lts \
    --image-project ubuntu-os-cloud \
    --machine-type e2-standard-2 \
    --metadata pod-cidr=10.200.${i}.0/24 \
    --private-network-ip 10.240.0.2${i} \
    --scopes compute-rw,storage-ro,service-management,service-control,logging-write,monitoring \
    --subnet kubernetes \
    --tags kubernetes-the-hard-way,worker
done
```

### Verification

List the compute instances in your default compute zone:

```
gcloud compute instances list --filter="tags.items=kubernetes-the-hard-way"
```

> output

```
NAME          ZONE        MACHINE_TYPE   PREEMPTIBLE  INTERNAL_IP  EXTERNAL_IP    STATUS
controller-0  us-west1-c  e2-standard-2               10.240.0.10  XX.XX.XX.XXX   RUNNING
controller-1  us-west1-c  e2-standard-2               10.240.0.11  XX.XXX.XXX.XX  RUNNING
controller-2  us-west1-c  e2-standard-2               10.240.0.12  XX.XXX.XX.XXX  RUNNING
worker-0      us-west1-c  e2-standard-2               10.240.0.20  XX.XX.XXX.XXX  RUNNING
worker-1      us-west1-c  e2-standard-2               10.240.0.21  XX.XX.XX.XXX   RUNNING
worker-2      us-west1-c  e2-standard-2               10.240.0.22  XX.XXX.XX.XX   RUNNING
```

## Configuring SSH Access

The SSH protocol (also referred to as Secure Shell) is a method for secure remote login from one computer to another. SSH will be used to configure the controller and worker instances. When connecting to compute instances for the first time SSH keys will be generated for you and stored in the project or instance metadata as described in the [connecting to instances](https://cloud.google.com/compute/docs/instances/connecting-to-instance) documentation.

Test SSH access to the `controller-0` compute instances:

```
gcloud compute ssh controller-0
```

If this is your first time connecting to a compute instance SSH keys will be generated for you. Enter a passphrase at the prompt to continue:

```
WARNING: The public SSH key file for gcloud does not exist.
WARNING: The private SSH key file for gcloud does not exist.
WARNING: You do not have an SSH key for gcloud.
WARNING: SSH keygen will be executed to generate a key.
Generating public/private rsa key pair.
Enter passphrase (empty for no passphrase):
Enter same passphrase again:
```

At this point the generated SSH keys will be uploaded and stored in your project:

```
Your identification has been saved in /home/$USER/.ssh/google_compute_engine.
Your public key has been saved in /home/$USER/.ssh/google_compute_engine.pub.
The key fingerprint is:
SHA256:nz1i8jHmgQuGt+WscqP5SeIaSy5wyIJeL71MuV+QruE $USER@$HOSTNAME
The key's randomart image is:
+---[RSA 2048]----+
|                 |
|                 |
|                 |
|        .        |
|o.     oS        |
|=... .o .o o     |
|+.+ =+=.+.X o    |
|.+ ==O*B.B = .   |
| .+.=EB++ o      |
+----[SHA256]-----+
Updating project ssh metadata...-Updated [https://www.googleapis.com/compute/v1/projects/$PROJECT_ID].
Updating project ssh metadata...done.
Waiting for SSH key to propagate.
```

After the SSH keys have been updated you'll be logged into the `controller-0` instance:

```
Welcome to Ubuntu 20.04 LTS (GNU/Linux 5.4.0-1019-gcp x86_64)
...
```

Type `exit` at the prompt to exit the `controller-0` compute instance:

```
$USER@controller-0:~$ exit
```
> output

```
logout
Connection to XX.XX.XX.XXX closed
```

Next: [Provisioning a CA and Generating TLS Certificates](04-certificate-authority.md)
