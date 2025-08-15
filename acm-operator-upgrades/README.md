# 🚀 ACM Operator Upgrades Demo

This demo shows how to manage operator lifecycle using Red Hat Advanced Cluster Management (ACM) policies. We'll demonstrate version pinning, controlled upgrades, and rollout management using the Web Terminal operator as an example.

## 📋 Prerequisites

- **OpenShift Container Platform** with ACM installed
  - Tested on OCP 4.16.45 and ACM 2.11
- **Managed Cluster**: At least one OCP cluster joined to ACM and configured in the `development` ClusterSet
  - Policies will be stored in namespace `development-policies`
- **CLI Access**: `oc` command-line tool configured for your hub cluster

## 🎯 Overview

This demonstration covers:

### 🔒 Version Management

- Create policies to install operators at specific versions
- Lock operators to prevent unwanted upgrades
- Maintain version consistency across cluster sets

### 📈 Controlled Upgrades

- Discover available operator versions
- Configure OperatorPolicy for controlled upgrades
- Monitor rollout progress across managed clusters

### ⚙️ Posible Management Options

- **Template-based approach**: Update operator versions centrally using ConfigMaps
- **Custom CatalogSource**: Create curated lists of approved operator versions

## 🛠️ Step-by-Step Implementation

### 1️⃣ Discover Available Operator Versions

First, let's explore what versions of the Web Terminal operator are available in the marketplace:

```bash
oc get packagemanifests.packages.operators.coreos.com -n openshift-marketplace web-terminal -o yaml
```

<details>
<summary>Web Terminal PackageManifest Output (click to expand)</summary>

```yaml
apiVersion: packages.operators.coreos.com/v1
kind: PackageManifest
metadata:
  creationTimestamp: "2025-08-14T07:44:11Z"
  labels:
    catalog: redhat-operators
    catalog-namespace: openshift-marketplace
    hypershift.openshift.io/managed: "true"
    operatorframework.io/arch.amd64: supported
    operatorframework.io/os.linux: supported
    provider: Red Hat
    provider-url: ""
  name: web-terminal
  namespace: openshift-marketplace
spec: {}
status:
  catalogSource: redhat-operators
  catalogSourceDisplayName: Red Hat Operators
  catalogSourceNamespace: openshift-marketplace
  catalogSourcePublisher: Red Hat
  channels:
  - currentCSV: web-terminal.v1.11.1-0.1747215995.p
    currentCSVDesc:
      annotations:
        alm-examples: |-
          [
          ]
        capabilities: Basic Install
        categories: Developer Tools
        certified: "false"
        containerImage: registry.redhat.io/web-terminal/web-terminal-rhel9-operator@sha256:0478d14e92df84fdfbf4584384d34dc9a71427a6487c2564d2eb7815ba1ac12b
        createdAt: "2021-10-26T07:24:32Z"
        description: Start a web terminal in your browser with common CLI tools for
          interacting with the cluster
        features.operators.openshift.io/disconnected: "false"
        features.operators.openshift.io/fips-compliant: "false"
        features.operators.openshift.io/proxy-aware: "true"
        features.operators.openshift.io/tls-profiles: "false"
        features.operators.openshift.io/token-auth-aws: "false"
        features.operators.openshift.io/token-auth-azure: "false"
        features.operators.openshift.io/token-auth-gcp: "true"
        olm.substitutesFor: web-terminal.v1.11.1
        operatorframework.io/suggested-namespace: openshift-operators
        operators.openshift.io/valid-subscription: '["OpenShift Container Platform",
          "OpenShift Platform Plus"]'
        repository: https://github.com/redhat-developer/web-terminal-operator/
        support: Red Hat, Inc.
      apiservicedefinitions: {}
      customresourcedefinitions:
        required:
        - kind: DevWorkspaceRouting
          name: devworkspaceroutings.controller.devfile.io
          version: v1alpha1
        - kind: DevWorkspace
          name: devworkspaces.workspace.devfile.io
          version: v1alpha1
      description: |
        Start a web terminal in your browser with common CLI tools for interacting with
        the cluster.

        **Note:** The Web Terminal Operator integrates with the OpenShift Console in
        OpenShift 4.5.3 and higher to simplify web terminal instance creation and
        automate OpenShift login. In earlier versions of OpenShift, the operator can
        be installed but web terminals will have to be created and accessed manually.

        ## Description
        The Web Terminal Operator leverages the
        [DevWorkspace Operator](https://github.com/devfile/devworkspace-operator)
        to provision enviroments which support common cloud CLI tools. When this
        operator is installed, the DevWorkspace Operator will be installed as a
        dependency.

        ## How to Install
        Press the **Install** button, choose the upgrade strategy, and wait for the
        **Installed** Operator status.

        When the operator is installed, you will see a terminal button appear on the
        top right of the console after refreshing the OpenShift console window.

        ## How to Uninstall
        The Web Terminal Operator requires manual steps to fully uninstall the operator.
        As the Web Terminal Operator is designed as a way to access the OpenShift
        cluster, web terminal instances store user credentials. To avoid exposing these
        credentials to unwanted parties, the operator deploys webhooks and finalizers
        that aren't removed when the operator is uninstalled. See the
        [uninstall guide](https://docs.openshift.com/container-platform/latest/web_console/web_terminal/uninstalling-web-terminal.html)
        for more details.

        ## Documentation
        Documentation for this Operator is available at https://docs.openshift.com/container-platform/latest/web\_console/web\_terminal/installing-web-terminal.html
      displayName: Web Terminal
      installModes:
      - supported: false
        type: OwnNamespace
      - supported: false
        type: SingleNamespace
      - supported: false
        type: MultiNamespace
      - supported: true
        type: AllNamespaces
      keywords:
      - workspace
      - devtools
      - developer
      - ide
      - terminal
      links:
      - name: Web Terminal Repo
        url: https://github.com/redhat-developer/web-terminal-operator/
      maintainers:
      - email: aobuchow@redhat.com
        name: Andrew Obuchowicz
      - email: ibuziuk@redhat.com
        name: Ilya Buziuk
      maturity: alpha
      provider:
        name: Red Hat
      relatedImages:
      - registry.redhat.io/web-terminal/web-terminal-exec-rhel9@sha256:cfc8200340655a045f45d02fa327538f87e98d6369bdef2b46cf447053c44426
      - registry.redhat.io/web-terminal/web-terminal-rhel9-operator@sha256:0478d14e92df84fdfbf4584384d34dc9a71427a6487c2564d2eb7815ba1ac12b
      - registry.redhat.io/web-terminal/web-terminal-tooling-rhel9@sha256:5c24220f884dcdf1b1e5ac1e20dc6b7c8c4300bb89e8f118c0b11c331a56ab3f
      version: 1.11.1+0.1747215995.p
    entries:
    - name: web-terminal.v1.11.1-0.1747215995.p
      version: 1.11.1+0.1747215995.p
    - name: web-terminal.v1.11.1
      version: 1.11.1
    - name: web-terminal.v1.11.0
      version: 1.11.0
    - name: web-terminal.v1.10.1
      version: 1.10.1
    - name: web-terminal.v1.10.1-0.1740684238.p
      version: 1.10.1+0.1740684238.p
    - name: web-terminal.v1.10.0-0.1731481377.p
      version: 1.10.0+0.1731481377.p
    - name: web-terminal.v1.10.0-0.1732652667.p
      version: 1.10.0+0.1732652667.p
    - name: web-terminal.v1.10.0
      version: 1.10.0
    - name: web-terminal.v1.10.0-0.1727169028.p
      version: 1.10.0+0.1727169028.p
    - name: web-terminal.v1.10.0-0.1720435222.p
      version: 1.10.0+0.1720435222.p
    - name: web-terminal.v1.10.0-0.1720402943.p
      version: 1.10.0+0.1720402943.p
    - name: web-terminal.v1.9.0-0.1708477317.p
      version: 1.9.0+0.1708477317.p
    - name: web-terminal.v1.9.0
      version: 1.9.0
    - name: web-terminal.v1.8.0-0.1708477299.p
      version: 1.8.0+0.1708477299.p
    - name: web-terminal.v1.8.0-0.1701199376.p
      version: 1.8.0+0.1701199376.p
    - name: web-terminal.v1.8.0-0.1692219820.p
      version: 1.8.0+0.1692219820.p
    - name: web-terminal.v1.8.0
      version: 1.8.0
    - name: web-terminal.v1.7.0-0.1682321121.p
      version: 1.7.0+0.1682321121.p
    - name: web-terminal.v1.7.0-0.1692219820.p
      version: 1.7.0+0.1692219820.p
    - name: web-terminal.v1.7.0
      version: 1.7.0
    - name: web-terminal.v1.7.0-0.1681197295.p
      version: 1.7.0+0.1681197295.p
    - name: web-terminal.v1.7.0-0.1708477265.p
      version: 1.7.0+0.1708477265.p
    - name: web-terminal.v1.7.0-0.1684429884.p
      version: 1.7.0+0.1684429884.p
    - name: web-terminal.v1.6.0
      version: 1.6.0
    - name: web-terminal.v1.6.0-0.1692219820.p
      version: 1.6.0+0.1692219820.p
    - name: web-terminal.v1.5.1-0.1661829403.p
      version: 1.5.1+0.1661829403.p
    - name: web-terminal.v1.5.1
      version: 1.5.1
    - name: web-terminal.v1.5.0-0.1657220207.p
      version: 1.5.0+0.1657220207.p
    - name: web-terminal.v1.5.0
      version: 1.5.0
    - name: web-terminal.v1.4.0
      version: 1.4.0
    - name: web-terminal.v1.3.0
      version: 1.3.0
    name: fast
  defaultChannel: fast
  packageName: web-terminal
  provider:
    name: Red Hat
```

</details>

### 2️⃣ Install Initial Operator Version

Now let's install Web Terminal at a specific version (`web-terminal.v1.9.0`) using ACM policies:

```bash
oc apply -f ./files/policy-initial.yml
```

💡 **Note**: This policy will deploy the Web Terminal operator at version 1.9.0 across all clusters in the target ClusterSet, ensuring consistency.

### 3️⃣ Verify Available Versions

List all available versions in the `fast` channel to plan your upgrade path:

```bash
oc get packagemanifests.packages.operators.coreos.com -n openshift-marketplace web-terminal -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' | sort -V
```

<details>
<summary>Example list of current versions in channel (click to expand)</summary>

```yaml
- web-terminal.v1.3.0
- web-terminal.v1.4.0
- web-terminal.v1.5.0
- web-terminal.v1.5.0-0.1657220207.p
- web-terminal.v1.5.1
- web-terminal.v1.5.1-0.1661829403.p
- web-terminal.v1.6.0
- web-terminal.v1.6.0-0.1692219820.p
- web-terminal.v1.7.0
- web-terminal.v1.7.0-0.1681197295.p
- web-terminal.v1.7.0-0.1682321121.p
- web-terminal.v1.7.0-0.1684429884.p
- web-terminal.v1.7.0-0.1692219820.p
- web-terminal.v1.7.0-0.1708477265.p
- web-terminal.v1.8.0
- web-terminal.v1.8.0-0.1692219820.p
- web-terminal.v1.8.0-0.1701199376.p
- web-terminal.v1.8.0-0.1708477299.p
- web-terminal.v1.9.0
- web-terminal.v1.9.0-0.1708477317.p
- web-terminal.v1.10.0
- web-terminal.v1.10.0-0.1720402943.p
- web-terminal.v1.10.0-0.1720435222.p
- web-terminal.v1.10.0-0.1727169028.p
- web-terminal.v1.10.0-0.1731481377.p
- web-terminal.v1.10.0-0.1732652667.p
- web-terminal.v1.10.1
- web-terminal.v1.10.1-0.1740684238.p
- web-terminal.v1.11.0
- web-terminal.v1.11.1
- web-terminal.v1.11.1-0.1747215995.p
```

</details>

### 4️⃣ Execute Controlled Upgrade

Apply the updated policy to upgrade operators to version 1.10.1 across your cluster set:

```bash
oc apply -f ./files/policy-updated.yml
```

### 5️⃣ Monitor Upgrade Progress

Watch the operator upgrade process in real-time:

```bash
watch oc get csv -n openshift-operators
```

🔍 **What to look for**:

- ClusterServiceVersion (CSV) transitions from old to new version
- Operator pod restarts and becomes ready
- No failed installations or conflicts

## 📋 Policy Files Overview

This demo includes two main policy files:

### `policy-initial.yml`

- Installs Web Terminal operator at version **1.9.0**
- Uses `musthave` compliance to ensure installation
- Targets the `development` ClusterSet
- Sets `startingCSV` to lock the initial version

### `policy-updated.yml`

- Allows upgrades from **1.9.0** to **1.10.1**
- Includes patch versions (e.g., `1.10.0-0.1720402943.p`)
- Uses `Automatic` upgrade approval for seamless updates
- Maintains the same targeting and compliance settings

🎯 **Key Difference**: The updated policy expands the `versions` array to include newer releases, enabling controlled upgrade paths.

## 📚 Additional Resources

### 📖 Documentation

- [Getting Started with OperatorPolicy](https://developers.redhat.com/articles/2024/08/08/getting-started-operatorpolicy#) - Comprehensive guide to OperatorPolicy usage
- [Policy-based Governance with ACM](https://www.redhat.com/en/blog/comply-to-standards-using-policy-based-governance-of-red-hat-advanced-cluster-management-for-kubernetes) - Best practices for compliance
- [OpenShift Operator Lifecycle Manager](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/operators/understanding-operators#operator-lifecycle-manager-olm) - Understanding OLM concepts
