# capk-test

This repository contains a script and manifests for deploying the OpenShift
Assisted Cluster API providers on an OpenShift management cluster backed by
KubeVirt.

## Prerequisites

- An OpenShift cluster with cluster-admin permissions.
- The `oc`, `kubectl`, and `clusterctl` commands installed and available in
  `PATH`.
- The OpenShift cluster's kubeconfig exported in `KUBECONFIG`.
- A pull-secret JSON file. Set `PULLSECRET` to its path, or provide the path
  when prompted by `prepare-capk.sh`.
- The SSH public key at `~/.ssh/id_rsa.pub`.
- Access to the `redhat-operators` catalog and an internet connection. The
  script downloads cert-manager and Assisted Service manifests from GitHub.
- Sufficient capacity for LVM storage, OpenShift Virtualization, and the
  Assisted Service components.
- Each node selected for storage must have at least one unused block device;
  the LVM operator must be able to discover and wipe it for the `vg1` device
  class. Do not use a device containing data.

Run the setup script from the repository root:

```sh
export KUBECONFIG=/path/to/management-cluster-kubeconfig
# Optional: otherwise the script prompts for this path.
export PULLSECRET=/path/to/pull-secret.json
bash prepare-capk.sh
```

The script stops on the first error and prints `=== Done ===` only after all
setup steps complete.

## What `prepare-capk.sh` Does

The script:

1. Creates the `openshift-storage` namespace, installs the LVM Storage
   operator from the `stable-4.22` channel, and creates an `LVMCluster` with
   the default `vg1` device class and `lvms-vg1` storage class.
2. Creates the `openshift-cnv` namespace, installs OpenShift Virtualization
   from the `stable` channel, and waits for the
   `kubevirt-hyperconverged` resource to become available.
3. Installs cert-manager v1.14.3 and waits for its deployments to become
   available.
4. Initializes Cluster API with the KubeVirt infrastructure provider using
   `clusterctl`.
5. Patches the CAPI controller deployment to remove explicit `runAsUser` and
   `runAsGroup` values so it is compatible with OpenShift SCCs.
6. Installs the CAPOA bootstrap and control-plane providers from `capboa/` and
   `capcoa/`.
7. Installs Assisted Service and its supporting resources from
   `install_assisted/`, then waits for the `assisted-service` deployment in
   the `assisted-installer` namespace.
8. Creates the `kubevirt-tenant` namespace and stores the management-cluster
   kubeconfig in the `infra-cluster-credentials` Secret in that namespace.
9. Reads the pull-secret JSON and `~/.ssh/id_rsa.pub`, renders a local copy of
   `capoa_capk_deploy.yaml`, and applies the rendered tenant-cluster manifest.

The setup can take several minutes because the script waits for each operator
and deployment to become ready. The LVM and CNV readiness checks time out
after approximately 5 to 15 minutes depending on the component. The final
Assisted Service readiness loop retries until the deployment becomes
available.

## Deploy the Tenant Cluster

Before running the script, review `capoa_capk_deploy.yaml` and update the
environment-specific values, especially:

- The `rhcos-golden-4.22` PVC referenced by the KubeVirt machine template.
- The `baseDomain`, OpenShift `distributionVersion`, and replica count.
- The `lvms-vg1` storage class if the management cluster uses a different
  storage class.

The script automatically applies a generated local copy of the manifest after
the management-cluster setup completes. The generated copy includes the
base64-encoded pull secret and SSH public key and is removed when the script
exits. This creates the `kubevirt-tenant` Cluster API resources, including a
KubeVirt cluster, machine template, three-replica OpenShift Assisted control
plane, and the top-level CAPI `Cluster` resource.

Use the following commands to watch provisioning:

```
oc get cluster -A
oc get kubevirtcluster -A
oc get kubevirtmachine -A
oc get dv -A
oc get aci -A
```
