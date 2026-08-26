# Manual Kubernetes Bootstrap

This document records the validated manual procedure for building the TinyTasks Kubernetes cluster. It is the source of truth for the subsequent Ansible implementation.

## Scope

- Terraform has already created three clean Ubuntu servers, the Hetzner private network, static private IPs, SSH access, and firewall attachments.
- Node-side commands are run as `root` unless stated otherwise.
- The cluster contains one control-plane node and two worker nodes. The control plane is not highly available.
- `kubeadm init` and `kubeadm join` are one-time operations on clean nodes. Do not rerun them after success.
- Never commit `/etc/kubernetes/admin.conf`, bootstrap tokens, or generated join configurations.

## Environment

| Item | Value |
| --- | --- |
| OS  | Ubuntu 24.04 |
| Kubernetes repository | `v1.36` |
| Kubernetes version | `v1.36.3` |
| Container runtime | `containerd` |
| CRI socket | `unix:///var/run/containerd/containerd.sock` |
| Calico | `v3.32.1`, eBPF data plane |
| Pod CIDR | `192.168.0.0/16` |
| Service CIDR | `10.96.0.0/12` |
| Public interface | `eth0` |
| Private interface | `enp7s0` |

| Node | Role | Private IP |
| --- | --- | --- |
| `tinytasks-platform-control-plane` | control plane | `10.0.0.10` |
| `tinytasks-platform-worker-1` | worker | `10.0.0.11` |
| `tinytasks-platform-worker-2` | worker | `10.0.0.12` |

## 1. Run the node preflight

**Run on:** all nodes

Wait for cloud-init:

```bash
cloud-init status --wait
```

Validate the OS, kernel, hostname, private interface, and expected address:

```bash
. /etc/os-release

test "${ID}" = "ubuntu"
test "${VERSION_ID}" = "24.04"
dpkg --compare-versions "$(uname -r | cut -d- -f1)" ge 5.10

NODE_NAME="$(hostname -s)"

case "${NODE_NAME}" in
  tinytasks-platform-control-plane)
    EXPECTED_PRIVATE_IP="10.0.0.10"
    ;;
  tinytasks-platform-worker-1)
    EXPECTED_PRIVATE_IP="10.0.0.11"
    ;;
  tinytasks-platform-worker-2)
    EXPECTED_PRIVATE_IP="10.0.0.12"
    ;;
  *)
    echo "Unexpected hostname: ${NODE_NAME}" >&2
    exit 1
    ;;
esac

ip link show dev enp7s0 \
  | grep -q '<[^>]*UP[^>]*>'

ip -4 -o address show dev enp7s0 \
  | grep -Eq "[[:space:]]${EXPECTED_PRIVATE_IP}/32[[:space:]]"
```

Validate public and private routing:

```bash
ip -4 -brief address
ip route show

ip route show default \
  | grep -q 'dev eth0'

ip route show 10.0.0.0/16 \
  | grep -q 'dev enp7s0'
```

Validate private routing and connectivity to the other nodes:

```bash
for PEER_IP in 10.0.0.10 10.0.0.11 10.0.0.12; do
  [ "${PEER_IP}" = "${EXPECTED_PRIVATE_IP}" ] && continue

  ROUTE="$(ip route get "${PEER_IP}")"
  printf '%s\n' "${ROUTE}"

  printf '%s\n' "${ROUTE}" | grep -q 'dev enp7s0'
  printf '%s\n' "${ROUTE}" | grep -q "src ${EXPECTED_PRIVATE_IP}"

  ping -c 3 -W 2 "${PEER_IP}"
done
```

If `enp7s0` is absent, down, or missing its private address, reboot the affected node once, wait for cloud-init, and rerun the whole preflight. If it still fails, stop and fix the Terraform or Hetzner network attachment.

## 2. Configure node prerequisites

**Run on:** all nodes

Fail if swap is active or configured:

```bash
if swapon --noheadings --show=NAME | grep -q .; then
  swapon --show
  echo "Active swap detected" >&2
  exit 1
fi

if grep -nE \
  '^[[:space:]]*[^#].*[[:space:]]swap[[:space:]]' \
  /etc/fstab; then
  echo "Swap entry detected in /etc/fstab" >&2
  exit 1
fi
```

Enable IPv4 forwarding:

```bash
cat > /etc/sysctl.d/99-kubernetes.conf <<'EOF_SYSCTL'
net.ipv4.ip_forward = 1
EOF_SYSCTL

sysctl --system
test "$(sysctl -n net.ipv4.ip_forward)" = "1"
```

## 3. Install and configure containerd

**Run on:** all nodes

```bash
apt-get update
apt-get install -y containerd

install -d -m 0755 /etc/containerd
containerd config default > /etc/containerd/config.toml

sed -i \
  's/SystemdCgroup = false/SystemdCgroup = true/' \
  /etc/containerd/config.toml
```

Validate the configuration and start the service:

```bash
grep -q 'SystemdCgroup = true' \
  /etc/containerd/config.toml

if grep -Eq \
  '^disabled_plugins[[:space:]]*=.*"cri"' \
  /etc/containerd/config.toml; then
  echo "The containerd CRI plugin is disabled" >&2
  exit 1
fi

systemctl enable containerd
systemctl restart containerd

systemctl is-enabled containerd
systemctl is-active containerd
test -S /run/containerd/containerd.sock
```

Verify the CRI plugin. This check supports the plugin names used by containerd 1.x and 2.x:

```bash
ctr plugins ls | awk '
  (
    $1 == "io.containerd.grpc.v1" && $2 == "cri" ||
    $1 == "io.containerd.cri.v1" && $2 == "runtime"
  ) && $4 == "ok" {
    found = 1
  }
  END {
    exit(found ? 0 : 1)
  }
'

containerd --version
runc --version
```

## 4. Install and pin Kubernetes packages

**Run on:** all nodes

Install repository dependencies and force APT to use IPv4 in this environment:

```bash
apt-get update
apt-get install -y \
  ca-certificates \
  curl \
  gpg

echo 'Acquire::ForceIPv4 "true";' \
  > /etc/apt/apt.conf.d/99force-ipv4
```

`pkgs.k8s.io` returned `403 Forbidden` over IPv6 on these servers, so this guide deliberately uses IPv4 for APT and the signing-key download.

Configure the Kubernetes `v1.36` repository:

```bash
install -d -m 0755 /etc/apt/keyrings

curl -4 -fsSL --retry 5 \
  https://pkgs.k8s.io/core:/stable:/v1.36/deb/Release.key \
  | gpg --batch --yes --dearmor \
      --output /etc/apt/keyrings/kubernetes-apt-keyring.gpg

cat > /etc/apt/sources.list.d/kubernetes.list <<'EOF_APT'
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.36/deb/ /
EOF_APT

apt-get update
```

Resolve and install the exact package build for Kubernetes `1.36.3`:

```bash
KUBERNETES_PATCH_VERSION="1.36.3"

KUBERNETES_PACKAGE_VERSION="$(
  apt-cache madison kubeadm \
    | awk -v version="${KUBERNETES_PATCH_VERSION}" \
        '$3 ~ ("^" version "-") { print $3; exit }'
)"

test -n "${KUBERNETES_PACKAGE_VERSION}"
printf 'Installing package version: %s\n' \
  "${KUBERNETES_PACKAGE_VERSION}"

apt-get install -y \
  kubelet="${KUBERNETES_PACKAGE_VERSION}" \
  kubeadm="${KUBERNETES_PACKAGE_VERSION}" \
  kubectl="${KUBERNETES_PACKAGE_VERSION}"

apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
```

The kubelet may restart until the node is initialized or joined. Verify package alignment and CRI access:

```bash
kubeadm version -o short
kubelet --version
kubectl version --client
apt-mark showhold | sort

crictl \
  --runtime-endpoint unix:///run/containerd/containerd.sock \
  info > /dev/null
```

Expected Kubernetes version: `v1.36.3`. The held packages must be `kubeadm`, `kubectl`, and `kubelet`.

## 5. Create, upload, and validate the kubeadm configuration

### Local workstation

Create the tracked file `docs/kubeadm-config.yaml`:

```yaml
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration

localAPIEndpoint:
  advertiseAddress: 10.0.0.10
  bindPort: 6443

nodeRegistration:
  name: tinytasks-platform-control-plane
  criSocket: unix:///var/run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: 10.0.0.10

---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration

clusterName: tinytasks-platform
kubernetesVersion: v1.36.3

networking:
  podSubnet: 192.168.0.0/16
  serviceSubnet: 10.96.0.0/12
  dnsDomain: cluster.local

---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration

cgroupDriver: systemd
```

Upload it from the repository root:

```bash
CONTROL_PLANE_PUBLIC_IP="$(
  terraform -chdir=terraform/hetzner \
    output -raw control_plane_public_ip
)"

scp -i ~/.ssh/hetzner_devops_platform \
  docs/kubeadm-config.yaml \
  root@"${CONTROL_PLANE_PUBLIC_IP}":/root/kubeadm-config.yaml
```

### Control-plane node

```bash
chmod 600 /root/kubeadm-config.yaml

kubeadm config validate \
  --config /root/kubeadm-config.yaml
```

Expected output: `ok`. Do not continue on validation failure.

## 6. Initialize the control plane

**Run on:** control-plane node

```bash
test ! -e /etc/kubernetes/admin.conf

kubeadm init \
  --config /root/kubeadm-config.yaml
```

Do not interrupt or rerun the command after success. The node may remain `NotReady`, and CoreDNS may remain `Pending`, until the CNI is installed.

## 7. Configure kubectl and verify the control plane

**Run on:** control-plane node

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
```

The control plane must register with internal IP `10.0.0.10`.

Verify its default isolation taint:

```bash
kubectl get node tinytasks-platform-control-plane \
  -o jsonpath='{range .spec.taints[*]}{.key}{":"}{.effect}{"\n"}{end}' \
  | grep -Fx \
      'node-role.kubernetes.io/control-plane:NoSchedule'
```

Do not run the command that removes this taint. Application workloads will run on workers.

Delete the bootstrap token created automatically by `kubeadm init`; a fresh short-lived token will be created immediately before joining workers:

```bash
kubeadm token list

TOKEN_ID="replace-with-token-id"
kubeadm token delete "${TOKEN_ID}"
```

`<TOKEN_ID>` is the six-character part before the dot in the token printed by `kubeadm token list`.

The administrator kubeconfig is a privileged credential. Do not copy it into the repository.

## 8. Install Calico with the eBPF data plane

**Run on:** control-plane node

Install the pinned CRDs and Tigera Operator:

```bash
kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/v1_crd_projectcalico_org.yaml

kubectl create -f \
  https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/tigera-operator.yaml
```

Wait for the operator:

```bash
kubectl rollout status \
  --namespace tigera-operator \
  deployment/tigera-operator \
  --timeout=5m
```

Download and inspect the pinned eBPF custom resources:

```bash
curl -fsSLO --retry 5 \
  https://raw.githubusercontent.com/projectcalico/calico/v3.32.1/manifests/custom-resources-bpf.yaml

grep -E \
  'linuxDataplane|bpfNetworkBootstrap|kubeProxyManagement|cidr:' \
  custom-resources-bpf.yaml
```

The file must contain:

```text
linuxDataplane: BPF
bpfNetworkBootstrap: Enabled
kubeProxyManagement: Enabled
cidr: 192.168.0.0/16
```

Apply it and wait for the Tigera status resources to appear before waiting on their conditions:

```bash
kubectl create -f custom-resources-bpf.yaml

for STATUS in \
  apiserver \
  calico \
  goldmane \
  ippools \
  kubeproxy-monitor \
  tiers \
  whisker
do
  timeout 10m bash -c "
    until kubectl get tigerastatus ${STATUS} > /dev/null 2>&1; do
      sleep 5
    done
  "
done

kubectl wait \
  --for=condition=Available \
  tigerastatus \
  --all \
  --timeout=10m

kubectl get tigerastatus
kubectl get pods -n calico-system -o wide
kubectl get nodes -o wide
kubectl get pods -A
```

Verify that the control plane is `Ready`, CoreDNS is `Running`, and no `kube-proxy` DaemonSet remains:

```bash
kubectl wait \
  --for=condition=Ready \
  node/tinytasks-platform-control-plane \
  --timeout=5m

kubectl rollout status \
  --namespace kube-system \
  deployment/coredns \
  --timeout=5m

if kubectl get daemonset \
  --namespace kube-system \
  kube-proxy > /dev/null 2>&1; then
  echo "Unexpected kube-proxy DaemonSet detected" >&2
  exit 1
fi
```

Remove the downloaded manifest after successful installation:

```bash
rm -f custom-resources-bpf.yaml
```

## 9. Generate short-lived worker join credentials

**Run on:** control-plane node

Keep this shell open until both workers have joined and the token has been deleted:

```bash
JOIN_TOKEN="$(kubeadm token generate)"

JOIN_COMMAND="$(
  kubeadm token create "${JOIN_TOKEN}" \
    --ttl 30m \
    --print-join-command
)"

CA_CERT_HASH="$(
  printf '%s\n' "${JOIN_COMMAND}" \
    | sed -n 's/.*--discovery-token-ca-cert-hash[[:space:]]\+\([^[:space:]]\+\).*/\1/p'
)"

test -n "${JOIN_TOKEN}"
test -n "${CA_CERT_HASH}"

printf '%s\n' "${JOIN_COMMAND}"
```

Do not execute the printed command directly. Each worker needs a `JoinConfiguration` with its assigned private node IP.

## 10. Join both workers

Complete this step on `worker-1` first, verify it from the control plane, then repeat it on `worker-2`.

### Worker node

Set the worker-specific values:

```bash
NODE_NAME="$(hostname -s)"

case "${NODE_NAME}" in
  tinytasks-platform-worker-1)
    NODE_IP="10.0.0.11"
    ;;
  tinytasks-platform-worker-2)
    NODE_IP="10.0.0.12"
    ;;
  *)
    echo "Unexpected worker hostname: ${NODE_NAME}" >&2
    exit 1
    ;;
esac
```

Enter the token and CA hash printed in step 9. `read -s` keeps the token out of terminal output and shell history:

```bash
read -rsp 'Bootstrap token: ' JOIN_TOKEN
echo
read -rp 'CA certificate hash (sha256:...): ' CA_CERT_HASH

printf '%s\n' "${JOIN_TOKEN}" \
  | grep -Eq '^[a-z0-9]{6}\.[a-z0-9]{16}$'

printf '%s\n' "${CA_CERT_HASH}" \
  | grep -Eq '^sha256:[a-f0-9]{64}$'
```

Create and protect the temporary join configuration:

```bash
umask 077

cat > /root/kubeadm-join.yaml <<EOF_JOIN
apiVersion: kubeadm.k8s.io/v1beta4
kind: JoinConfiguration

discovery:
  bootstrapToken:
    apiServerEndpoint: "10.0.0.10:6443"
    token: "${JOIN_TOKEN}"
    caCertHashes:
      - "${CA_CERT_HASH}"

nodeRegistration:
  name: "${NODE_NAME}"
  criSocket: "unix:///var/run/containerd/containerd.sock"
  kubeletExtraArgs:
    - name: node-ip
      value: "${NODE_IP}"
EOF_JOIN

unset JOIN_TOKEN CA_CERT_HASH

kubeadm config validate \
  --config /root/kubeadm-join.yaml
```

Expected output: `ok`. Join the node and remove the secret file immediately after success:

```bash
test ! -e /etc/kubernetes/kubelet.conf

kubeadm join \
  --config /root/kubeadm-join.yaml

rm -f /root/kubeadm-join.yaml
```

### Control-plane node

After each join, verify the node and its private IP:

```bash
kubectl get nodes -o wide
```

The worker may be `NotReady` briefly while Calico initializes. The expected internal addresses are:

```text
tinytasks-platform-worker-1   10.0.0.11
tinytasks-platform-worker-2   10.0.0.12
```

`ROLES: <none>` is normal for kubeadm worker nodes.

## 11. Finalize and verify the three-node cluster

**Run on:** control-plane node

Revoke the worker bootstrap token as soon as both `kubeadm join` commands have succeeded:

```bash
kubeadm token delete "${JOIN_TOKEN%%.*}"
unset JOIN_TOKEN JOIN_COMMAND CA_CERT_HASH
```

If the original shell was lost, use `kubeadm token list` and delete the corresponding token ID manually.

Wait for all nodes:

```bash
export KUBECONFIG=/etc/kubernetes/admin.conf

kubectl wait \
  --for=condition=Ready \
  node \
  --all \
  --timeout=5m

test "$(kubectl get nodes --no-headers | wc -l)" -eq 3
kubectl get nodes -o wide
```

Restart CoreDNS after the workers join so its replicas can be rescheduled across the enlarged cluster:

```bash
kubectl rollout restart \
  --namespace kube-system \
  deployment/coredns

kubectl rollout status \
  --namespace kube-system \
  deployment/coredns \
  --timeout=5m

kubectl get pods \
  --namespace kube-system \
  --selector k8s-app=kube-dns \
  -o wide
```

Normally the two CoreDNS replicas should be visible on different nodes. Do not make this a hard bootstrap failure unless explicit topology-spread constraints are later added.

Verify Calico and the eBPF configuration:

```bash
kubectl rollout status \
  --namespace calico-system \
  daemonset/calico-node \
  --timeout=10m

test "$(
  kubectl get pods \
    --namespace calico-system \
    --selector k8s-app=calico-node \
    --no-headers \
    | wc -l
)" -eq 3

kubectl wait \
  --for=condition=Available \
  tigerastatus \
  --all \
  --timeout=10m

kubectl get tigerastatus
kubectl get pods -n calico-system -o wide
```

Verify the node addresses, control-plane taint, system Pods, and absence of `kube-proxy`:

```bash
EXPECTED_NODES="$({
  printf '%s %s\n' tinytasks-platform-control-plane 10.0.0.10
  printf '%s %s\n' tinytasks-platform-worker-1 10.0.0.11
  printf '%s %s\n' tinytasks-platform-worker-2 10.0.0.12
} | sort)"

ACTUAL_NODES="$(
  kubectl get nodes \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}' \
    | sort
)"

test "${ACTUAL_NODES}" = "${EXPECTED_NODES}"

kubectl get node tinytasks-platform-control-plane \
  -o jsonpath='{range .spec.taints[*]}{.key}{":"}{.effect}{"\n"}{end}' \
  | grep -Fx \
      'node-role.kubernetes.io/control-plane:NoSchedule'

if kubectl get daemonset \
  --namespace kube-system \
  kube-proxy > /dev/null 2>&1; then
  echo "Unexpected kube-proxy DaemonSet detected" >&2
  exit 1
fi

kubectl get pods -A \
  --field-selector=status.phase!=Running,status.phase!=Succeeded
```

The final command must return no Pods requiring investigation.

## 12. Run and clean up the cluster smoke test

**Run on:** control-plane node

This temporary test verifies workload placement on both workers, cross-node Pod networking, EndpointSlice creation, direct ClusterIP routing, cluster DNS, and Service routing through DNS. It is not part of the GitOps desired state.

Remove any leftover smoke-test namespace from a previous interrupted run:

```bash
kubectl delete namespace cluster-smoke-test \
  --ignore-not-found \
  --wait=true \
  --timeout=2m
```

Create the resources:

```bash
kubectl apply -f - <<'EOF_SMOKE'
apiVersion: v1
kind: Namespace
metadata:
  name: cluster-smoke-test

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: smoke-server
  namespace: cluster-smoke-test
spec:
  replicas: 2
  selector:
    matchLabels:
      app: smoke-server
  template:
    metadata:
      labels:
        app: smoke-server
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node-role.kubernetes.io/control-plane
                    operator: DoesNotExist
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  app: smoke-server
              topologyKey: kubernetes.io/hostname
      containers:
        - name: server
          image: registry.k8s.io/e2e-test-images/agnhost:2.53
          args:
            - netexec
            - --http-port=8080
          ports:
            - name: http
              containerPort: 8080
          readinessProbe:
            tcpSocket:
              port: http
            periodSeconds: 2
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              cpu: 100m
              memory: 64Mi

---
apiVersion: v1
kind: Service
metadata:
  name: smoke-server
  namespace: cluster-smoke-test
spec:
  selector:
    app: smoke-server
  ports:
    - name: http
      port: 80
      targetPort: http

---
apiVersion: v1
kind: Pod
metadata:
  name: smoke-client
  namespace: cluster-smoke-test
spec:
  nodeSelector:
    kubernetes.io/hostname: tinytasks-platform-worker-1
  restartPolicy: Never
  containers:
    - name: client
      image: registry.k8s.io/e2e-test-images/agnhost:2.53
      args:
        - pause
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          cpu: 50m
          memory: 32Mi
EOF_SMOKE
```

Wait for readiness:

```bash
kubectl rollout status \
  --namespace cluster-smoke-test \
  deployment/smoke-server \
  --timeout=3m

kubectl wait \
  --namespace cluster-smoke-test \
  --for=condition=Ready \
  pod/smoke-client \
  --timeout=3m
```

Verify that the two server replicas run on the two workers and that the client runs on worker 1:

```bash
kubectl get pods \
  --namespace cluster-smoke-test \
  -o wide

SERVER_NODES="$(
  kubectl get pods \
    --namespace cluster-smoke-test \
    --selector app=smoke-server \
    -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' \
    | sort
)"

EXPECTED_SERVER_NODES="$(
  printf '%s\n' \
    tinytasks-platform-worker-1 \
    tinytasks-platform-worker-2 \
    | sort
)"

test "${SERVER_NODES}" = "${EXPECTED_SERVER_NODES}"

test "$(
  kubectl get pod smoke-client \
    --namespace cluster-smoke-test \
    -o jsonpath='{.spec.nodeName}'
)" = "tinytasks-platform-worker-1"
```

Verify that the Service has two endpoints:

```bash
ENDPOINT_COUNT="$(
  kubectl get endpointslices \
    --namespace cluster-smoke-test \
    --selector kubernetes.io/service-name=smoke-server \
    -o jsonpath='{range .items[*].endpoints[*]}{.addresses[0]}{"\n"}{end}' \
    | grep -c .
)"

test "${ENDPOINT_COUNT}" -eq 2
```

Read the IP of the server Pod on worker 2 and test direct cross-node connectivity from the client on worker 1:

```bash
WORKER_2_POD_IP="$(
  kubectl get pods \
    --namespace cluster-smoke-test \
    --selector app=smoke-server \
    --field-selector spec.nodeName=tinytasks-platform-worker-2 \
    -o jsonpath='{.items[0].status.podIP}'
)"

test -n "${WORKER_2_POD_IP}"

kubectl exec \
  --namespace cluster-smoke-test \
  smoke-client \
  -- /agnhost connect \
      --timeout=5s \
      "${WORKER_2_POD_IP}:8080"
```

Test ClusterIP Service routing directly:

```bash
SERVICE_IP="$(
  kubectl get service \
    --namespace cluster-smoke-test \
    smoke-server \
    --output=jsonpath='{.spec.clusterIP}'
)"

test -n "${SERVICE_IP}"

kubectl exec \
  --namespace cluster-smoke-test \
  smoke-client \
  -- /agnhost connect \
      --timeout=5s \
      "${SERVICE_IP}:80"
```

Test CoreDNS resolution and Service routing through the Service FQDN:

```bash
kubectl exec \
  --namespace cluster-smoke-test \
  smoke-client \
  -- /agnhost connect \
      --timeout=5s \
      smoke-server.cluster-smoke-test.svc.cluster.local:80
```

All three connectivity checks must exit successfully.

Always remove the temporary namespace, including after a failed check:

```bash
kubectl delete namespace cluster-smoke-test \
  --ignore-not-found \
  --wait=true \
  --timeout=2m

if kubectl get namespace cluster-smoke-test \
  > /dev/null 2>&1; then
  echo "Smoke-test namespace still exists" >&2
  exit 1
fi
```

Final verification:

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

All three nodes must remain `Ready`, and all Kubernetes and Calico system Pods must remain healthy.

## Ansible handoff

The manual bootstrap is complete only after step 12 passes and `cluster-smoke-test` has been removed.

Recommended structure:

```text
ansible/
├── inventories/
├── playbooks/
│   ├── bootstrap-cluster.yml
│   └── validate-cluster.yml
└── roles/
    ├── preflight/
    ├── common/
    ├── containerd/
    ├── kubernetes_packages/
    ├── control_plane/
    ├── cni/
    ├── worker/
    └── cluster_validation/
```

The Ansible implementation must:

- wait for cloud-init and validate the expected OS, hostnames, private interfaces, addresses, routes, and connectivity before changing nodes;
- perform at most one reboot and one complete recheck when the Hetzner private interface is not ready;
- pin Kubernetes and Calico versions;
- verify containerd, its CRI plugin, and the `systemd` cgroup driver;
- guard `kubeadm init` with the absence of `/etc/kubernetes/admin.conf`;
- guard `kubeadm join` with the absence of `/etc/kubernetes/kubelet.conf`;
- render worker-specific `JoinConfiguration` files with the assigned private IPs;
- use a short-lived bootstrap token, protect secret-bearing tasks with `no_log`, and revoke the token after the workers join;
- wait for all three nodes, CoreDNS, Calico, and Tigera status resources;
- verify that the control-plane taint remains and that `kube-proxy` is absent in Calico eBPF mode;
- run the temporary smoke test from `cluster_validation` and delete its namespace in an Ansible `always` block;
- finish with exactly three `Ready` nodes using `10.0.0.10`, `10.0.0.11`, and `10.0.0.12` as internal addresses.