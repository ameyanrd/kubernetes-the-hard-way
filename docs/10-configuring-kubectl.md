# Configuring kubectl for Remote Access

In this lab you will generate a kubeconfig file for the `kubectl` command line utility based on the `admin` user credentials.


## Base definitions

### High availability

Generally, the term availability is used to describe the period of time when a service is available by a system to respond to a request made by a user. 

#### Measuring Availability

Availability is often expressed as a percentage indicating how much **uptime** is expected from a particular system or component in a given period of time, where a value of 100% would indicate that the system never fails. For instance, a system that guarantees 99% of availability in a period of one year can have up to 3.65 days of downtime (as 1% of 365 = 3.65)

> High availabity generally comes at the cost of high performance which is how fast the server can process and respond to requests issued by the client. This needs a powerful machine but often due to good computational power availability takes a hit. In order to get around this we use `reundancy` meaning, multiple API servers which can all respond to the requests of the client however the administering of requests to the API server will be done by what's called a **Load Balancer**
> 

### Load balancer

A type of reverse proxy that distributes traffic across servers. Load balancers can be found in many parts of a system, from the DNS layer all the way to the database layer.

![Image of load balancer at work](https://assets.digitalocean.com/articles/high-availability/Diagram_2.png)

Run the commands in this lab from the same directory used to generate the admin client certificates.

## The Admin Kubernetes Configuration File

Each kubeconfig requires a Kubernetes API Server to connect to. To support high availability the IP address assigned to the external load balancer fronting the Kubernetes API Servers will be used.

Generate a kubeconfig file suitable for authenticating as the `admin` user:

```
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
```

## Verification

Check the health of the remote Kubernetes cluster:

```
kubectl get componentstatuses
```

> output

```
NAME                 STATUS    MESSAGE             ERROR
scheduler            Healthy   ok
controller-manager   Healthy   ok
etcd-0               Healthy   {"health":"true"}
etcd-1               Healthy   {"health":"true"}
etcd-2               Healthy   {"health":"true"}
```

List the nodes in the remote Kubernetes cluster:

```
kubectl get nodes
```

> output

```
NAME       STATUS   ROLES    AGE     VERSION
worker-0   Ready    <none>   2m30s   v1.18.6
worker-1   Ready    <none>   2m30s   v1.18.6
worker-2   Ready    <none>   2m30s   v1.18.6
```

Next: [Provisioning Pod Network Routes](11-pod-network-routes.md)
