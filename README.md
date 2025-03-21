# Deploy Kubernetes on Fedora CoreOS using sysexts

This is an example using Fedora CoreOS and Kubeadm to deploy a Kubernetes
cluster using systemd system extensions (sysexts).

This example is intentionally only partially automated as it serves as a
tutorial to discover how those projects together to setup a Kurbenetes cluster.

**Important note:** Support for sysexts is still work in progress for Fedora
CoreOS, so there is currently no ideal way of updating them in sync with Fedora
CoreOS updates.

If you need something more complete and automated, take a look at
[Typhoon](https://typhoon.psdn.io/).

## How to

- Add you SSH public key to a file named `ssh_authorized_keys` (one per line)
- Generate the Butane configs:
  ```
  $ just generate
  ```
- Start the virtual machines using libvirtd
  - or use the Ignition configs to set them up on your favorite platform
  ```
  $ just install
  ```
- Connect to the first control plane node and initiliaze it using `kubeadm`:
  ```
  $ ssh core@$(just virsh-get-ip fcos-kube-cp-1)
  core@fcos-kube-cp-1$ sudo kubeadm init --pod-network-cidr=10.244.0.0/16 --cri-socket=unix:///run/crio/crio.sock
  ```
- Copy the kube config to the current user or to your system:
  ```
  core@fcos-kube-cp-1$ mkdir -p $HOME/.kube
  core@fcos-kube-cp-1$ sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  core@fcos-kube-cp-1$ sudo chown $(id -u):$(id -g) $HOME/.kube/config
  ```
- Setup a CNI:
  ```
  # Flannel
  core@fcos-kube-cp-1$ kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
  # Calico
  core@fcos-kube-cp-1$ kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.24.1/manifests/calico.yaml
  ```
- Wait and verify that the nodes are ready
  ```
  core@fcos-kube-cp-1$ kubectl get nodes
  core@fcos-kube-cp-1$ kubectl get pods --namespace kube-system
  ```
- Get the kubeadm token from the server:
  ```
  core@fcos-kube-cp-1$ kubeadm token create --print-join-command
  ```
- Connect to the worker nodes and have them join the cluster:
  ```
  $ ssh core@$(just virsh-get-ip fcos-kube-w-1)
  core@fcos-kube-w-1$ sudo kubeadm join 192.168.122.XYZ:6443 --token XYZ --discovery-token-ca-cert-hash sha256:XYZ
  ```
- Verify that all nodes joined the cluster:
  ```
  core@fcos-kube-cp-1$ kubectl get nodes
  ```
- Add the worker tag to the worker nodes:
  ```
  core@fcos-kube-cp-1$ for n in $(seq 1 3); do kubectl label node fcos-kube-w-$n node-role.kubernetes.io/worker=worker; done
  ```
- Deploy an example application and scale it:
  ```
  $ kubectl create deployment kubernetes-bootcamp --image=gcr.io/google-samples/kubernetes-bootcamp:v1
  $ kubectl get deployments
  $ kubectl get pods
  $ kubectl scale deployments/kubernetes-bootcamp --replicas=9
  $ kubectl get pods -o wide
  ```

## Options available

Edit the values at the top of the `justfile` to update those options.

- Architectures: Defaults to `x86_64`. `aarch64` should also work.
- Fedora CoreOS stream: Defaults to `stable`. `testing` or `next` should also
  work.
- Kubernetes versions: Defaults to the latest stable version available in
  Fedora (currently `1.32`). Should also work with all Kubernetes versions
  available in Fedora for the current release of Fedora CoreOS. As of today:
  `1.29`, `1.30`, `1.31`, `1.32`.
- Number of worker nodes: Defaults to 3
- Number of control plane nodes: Limited to 1 for now

## Faster local deployment when using libivrtd

- Download the sysexts on your libvirtd host:
  ```
  $ just download-sysext
  ```
- Serve them locally:
  ```
  $ just serve
  ```
- Open the firewall rules in firewalld (as needed):
  ```
  # Temporarily
  $ sudo firewall-cmd --zone=libvirt --add-port=8000/tcp
  # To make it also permanent
  $ sudo firewall-cmd --zone=libvirt --add-port=8000/tcp --permanent
  ```
- Update the source URL in the `justfile` to point to your host (likely
  `http://192.168.122.1:8000/`)
- Regenerate the Ignition config to point to the host as the source of the
  sysexts
  ```
  $ just generate
  ```

## References

- [Kubeadm documentation](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Getting started with Kubernetes](https://www.flatcar.org/docs/latest/container-runtimes/getting-started-with-kubernetes/)
  from the Flatcar documentation, which heavily inspired this example
- [High Availability Kubernetes](https://www.flatcar.org/docs/latest/container-runtimes/high-availability-kubernetes/)
  from the Flatcar documentation for a more automated example with a highly
  available control plane
- [travier/sysexts](https://github.com/travier/fedora-sysexts): Example systemd
  system extensions for Fedora CoreOS and other image based Fedora variants

## License

MIT, see [LICENSE](LICENSE).
