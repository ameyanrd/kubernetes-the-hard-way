# Setup

This is the single script for bootstrapping Kubernetes.

## For GCloud Shell

Use `full_script.sh` for bootstrapping.
Use `cleanup_script.sh` for cleanup.

## For Dockerfile users

The Dockerfile uses an Ubuntu image having Google Cloud SDK.

### Build docker container

From the directory having `Dockerfile`, `full_script.sh` and
`cleanup_script.sh`, run the following command:

`sudo docker build -t ubuntu:gcp .`

### Run the docker container and open a TTY session

`sudo docker run -it ubuntu:gcp`

### Initialization

Run `gcloud init` to authenticate yourself and set the correct
GCP project.

The script sets the region and zone. You may skip it while
initialization.

Now, use the `full_script.sh` and `cleanup_script.sh` as
in case of GCloud Shell.
