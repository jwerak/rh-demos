# Demo správy životního cyklu operátorů pomocí ACM

Správa instalace a upgradů operátorů napříč clustery OpenShift pomocí politik Red Hat Advanced Cluster Management (ACM). Tato demonstrace využívá operátor Web Terminal jako příklad pro předvedení připnutí verzí, řízených upgradů a správy zavádění na úrovni celé flotily prostřednictvím OperatorPolicy.

- [Demo správy životního cyklu operátorů pomocí ACM](#demo-správy-životního-cyklu-operátorů-pomocí-acm)
  - [Přehled](#přehled)
  - [Předpoklady](#předpoklady)
    - [Nasazení Hosted Clusteru](#nasazení-hosted-clusteru)
      - [Varianta A: GUI (ACM konzole)](#varianta-a-gui-acm-konzole)
      - [Varianta B: CLI (hcp)](#varianta-b-cli-hcp)
    - [Ověření Hosted Clusteru](#ověření-hosted-clusteru)
  - [Příprava: ClusterSet a namespace pro politiky](#příprava-clusterset-a-namespace-pro-politiky)
  - [Průvodce demonstrací](#průvodce-demonstrací)
    - [1. Zjištění dostupných verzí operátora](#1-zjištění-dostupných-verzí-operátora)
    - [2. Instalace operátora v připnuté verzi](#2-instalace-operátora-v-připnuté-verzi)
    - [3. Ověření instalace verze v1.9.0](#3-ověření-instalace-verze-v190)
    - [4. Spuštění řízeného upgradu](#4-spuštění-řízeného-upgradu)
    - [5. Monitorování upgradu a ověření compliance](#5-monitorování-upgradu-a-ověření-compliance)
    - [6. Odstranění operátora pomocí politiky](#6-odstranění-operátora-pomocí-politiky)
  - [Úklid](#úklid)
  - [Struktura Kustomize](#struktura-kustomize)
  - [Generátor politik](#generátor-politik)
  - [Další zdroje](#další-zdroje)

## Přehled

Tato demonstrace pokrývá tři klíčové schopnosti:

- **Správa verzí**: Připnutí operátorů na konkrétní verze pomocí OperatorPolicy s polem `versions` a `startingCSV`
- **Řízené upgrady**: Rozšíření seznamu povolených verzí a přepnutí z `inform` (audit) na `enforce` (aktivní náprava) pro spuštění upgradů
- **Zavádění na úrovni flotily**: Cílení na konkrétní sady clusterů pomocí pravidel Placement pro řízení, které clustery operátor obdrží

## Předpoklady

- **OpenShift Container Platform 4.14+** s nainstalovaným ACM
- Operátory **OpenShift Virtualization** a **MetalLB** nainstalované (pro nasazení hosted clusteru)
- **CLI nástroje**: `oc`, `hcp`, `kustomize`
- Spravovaný cluster připojený k ACM (tato demonstrace používá hosted cluster nasazený přes HyperShift)

### Nasazení Hosted Clusteru

Demonstrace cílí na spravovaný cluster. Pokud ho ještě nemáte, nasaďte hosted cluster jedním z níže uvedených postupů.

Referenční laboratorní prostředí: [Using Hosted Control Planes for OpenShift on OpenShift](https://catalog.demo.redhat.com/catalog?search=hcp&item=babylon-catalog-prod%2Fopenshift-cnv.hcp-ocp-virt-cnv.prod) z Red Hat Demo Platform.

#### Varianta A: GUI (ACM konzole)

1. Přihlaste se do OpenShift konzole a přejděte na **Infrastructure -> Clusters**
2. Ověřte, že `local-cluster` je spravovaný a **hypershift-addon** je přítomen pod Add-ons
3. Ověřte přihlašovací údaje: přejděte na **Credentials** a potvrďte, že existuje `kubevirt-secret` (obsahující pull-secret a veřejný SSH klíč). Pokud chybí, vytvořte ho.
4. Přejděte na `local-cluster` a vytvořte projekt s názvem `clusters` (**Home -> Projects -> Create Project**)
5. Přepněte zpět na zobrazení **All Clusters**, klikněte na **Create cluster**
6. Vyberte **Red Hat OpenShift Virtualization** -> typ control plane **Hosted**
7. Nakonfigurujte detaily clusteru:
   - Credential: `kubevirt-secret`
   - Název clusteru: `my-hosted-cluster`
   - Sada clusterů: `default`
   - Release image: OpenShift 4.17.x
   - Etcd storage class: `ocs-external-storagecluster-ceph-rbd`
8. **Zapněte YAML** a změňte sekci networking, abyste předešli konfliktům CIDR s hubem:
   ```yaml
   networking:
     clusterNetwork:
       - cidr: 10.136.0.0/14
     serviceNetwork:
       - cidr: 172.32.0.0/16
   ```
9. Klikněte na Next a nakonfigurujte node pool: název: my-node-pool, 2 repliky, 2 jádra, 8 GiB paměti, auto-repair zapnuto
10. Klikněte na **Create** a počkejte ~15-20 minut na nasazení

#### Varianta B: CLI (hcp)

```bash
# Extrakce pull secretu z hub clusteru
oc get secret -n openshift-config pull-secret \
  -o template='{{index .data ".dockerconfigjson"}}' | base64 --decode > /tmp/pull-secret.json

# Vytvoření namespace clusters
oc create namespace clusters

# Nasazení hosted clusteru
hcp create cluster kubevirt \
  --name my-hosted-cluster \
  --release-image quay.io/openshift-release-dev/ocp-release:4.17.14-x86_64 \
  --node-pool-replicas 2 \
  --pull-secret /tmp/pull-secret.json \
  --memory 8Gi \
  --cores 2 \
  --etcd-storage-class ocs-external-storagecluster-ceph-rbd \
  --namespace clusters \
  --cluster-cidr 10.136.0.0/14 \
  --service-cidr 172.32.0.0/16
```

### Ověření Hosted Clusteru

Počkejte, až bude cluster dostupný (~15-20 minut):

```bash
watch oc get hostedclusters -n clusters
# Počkejte na PROGRESS=Completed a AVAILABLE=True

# Ověřte, že cluster je registrován jako spravovaný cluster
oc get managedclusters
# Měl by zobrazit my-hosted-cluster s AVAILABLE=True
```

## Příprava: ClusterSet a namespace pro politiky

Před spuštěním demonstrace vytvořte namespace, ClusterSet a vazby:

```bash
# Vytvoření namespace pro politiky
oc create namespace development-policies

# Vytvoření development ClusterSet
cat <<'EOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSet
metadata:
  name: development
spec:
  clusterSelector:
    selectorType: ExclusiveClusterSetLabel
EOF

# Přidání hosted clusteru do ClusterSet
oc label managedcluster my-hosted-cluster \
  cluster.open-cluster-management.io/clusterset=development --overwrite

# Navázání ClusterSet na namespace pro politiky
cat <<'EOF' | oc apply -f -
apiVersion: cluster.open-cluster-management.io/v1beta2
kind: ManagedClusterSetBinding
metadata:
  name: development
  namespace: development-policies
spec:
  clusterSet: development
EOF

# Ověření
oc get managedclusterset development
# Mělo by zobrazit "1 ManagedClusters selected"
```

## Průvodce demonstrací

### 1. Zjištění dostupných verzí operátora

Vypište všechny verze Web Terminal v kanálu `fast`:

```bash
oc get packagemanifests.packages.operators.coreos.com \
  -n openshift-marketplace web-terminal \
  -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' \
  | sort -V
```

### 2. Instalace operátora v připnuté verzi

Počáteční overlay nasadí operátor Web Terminal připnutý na verzi **v1.9.0** v režimu `enforce`. Pole `versions` obsahuje pouze `[web-terminal.v1.9.0]`, což zabraňuje jakýmkoli automatickým upgradům.

```bash
kustomize build operators/web-terminal/overlays/initial/ | oc apply -f -
```

### 3. Ověření instalace verze v1.9.0

Počkejte ~60-90 sekund na instalaci operátora:

```bash
oc get policy -n development-policies
# COMPLIANCE STATE by měl zobrazit Compliant — operátor je nainstalován
# a připnut na v1.9.0.

# Zobrazení detailní zprávy o compliance pro potvrzení instalace v1.9.0
oc get policy development-policies.web-terminal -n my-hosted-cluster \
  -o jsonpath='{.status.details[0].history[0].message}'
# Mělo by hlásit: "Compliant; ... ClusterServiceVersion (web-terminal.v1.9.0) -
#   install strategy completed with no errors"
```

Politika používá `complianceConfig.upgradesAvailable: Compliant`, takže hlásí Compliant, dokud je operátor ve verzi uvedené v poli `versions` — i když v katalogu existují novější verze. Upgrady mimo povolený seznam jsou pozastaveny (jejich InstallPlany zůstávají neschválené), ale nevyvolávají porušení.

### 4. Spuštění řízeného upgradu

Aktualizovaný overlay rozšiřuje pole `versions` o všechny verze od v1.9.0 po v1.12.1. Protože je aktivní režim `enforce`, spustí se skutečný upgrade přes řetězec verzí.

```bash
kustomize build operators/web-terminal/overlays/updated/ | oc apply -f -
```

### 5. Monitorování upgradu a ověření compliance

Sledujte upgrade operátora přes verze v reálném čase:

```bash
# Sledování compliance politiky
watch oc get policy -n development-policies

# Zobrazení detailních zpráv o průběhu (spouštějte opakovaně pro sledování řetězce upgradů)
oc get policy development-policies.web-terminal -n my-hosted-cluster \
  -o jsonpath='{.status.details[0].history[0].message}'
```

Operátor se automaticky upgraduje přes řetězec verzí: **v1.9.0 -> v1.10.x -> v1.11.x -> v1.12.1**. Celý upgrade trvá přibližně 3-5 minut.

> **Poznámka:** Politika může krátce zobrazit **NonCompliant** během upgradu, zatímco OLM zpracovává InstallPlany a řeší cestu upgradu. To je během aktivních upgradů očekávané.

Po dokončení bude politika zobrazovat **Compliant** se zprávou: `ClusterServiceVersion (web-terminal.v1.12.1-...) - install strategy completed with no errors`.

### 6. Odstranění operátora pomocí politiky

Overlay pro odstranění mění `complianceType` z `musthave` na `mustnothave`, čímž instruuje politiku k odstranění operátora ze spravovaných clusterů. `removalBehavior` řídí, co se vyčistí: Subscription a CSV jsou smazány, CRDs jsou zachovány a OperatorGroup je smazán pouze pokud ho nepoužívá žádný jiný operátor.

```bash
kustomize build operators/web-terminal/overlays/removed/ | oc apply -f -
```

Počkejte ~30-60 sekund na odstranění operátora:

```bash
oc get policy -n development-policies
# COMPLIANCE STATE by měl zobrazit Compliant — operátor byl odstraněn.

# Potvrzení, že operátor je odstraněn na spravovaném clusteru
oc get policy development-policies.web-terminal -n my-hosted-cluster \
  -o jsonpath='{.status.details[0].history[0].message}'
# Mělo by hlásit: "Compliant; the policy spec is valid, the Subscription was deleted, ..."
```

## Úklid

```bash
# Odstranění politiky, placement a binding
kustomize build operators/web-terminal/overlays/removed/ | oc delete -f -

# Volitelně odstranění nastavení ClusterSet
oc delete managedclustersetbinding development -n development-policies
oc delete managedclusterset development
oc delete namespace development-policies

# Volitelně zničení hosted clusteru
hcp destroy cluster kubevirt --name my-hosted-cluster --namespace clusters
```

## Struktura Kustomize

Doporučený přístup používá vzor base/overlay v `operators/web-terminal/`:

```
operators/
└── web-terminal/
    ├── base/                          # Společné komponenty politiky
    │   ├── policy.yaml               # OperatorPolicy (v1.9.0, inform)
    │   ├── placement.yaml            # Cílí na development ClusterSet
    │   ├── placementbinding.yaml     # Váže politiku na placement
    │   └── kustomization.yaml
    └── overlays/
        ├── initial/                   # Režim enforce, jedna verze
        │   └── kustomization.yaml
        ├── updated/                   # Režim enforce, cesta upgradu na v1.12.1
        │   └── kustomization.yaml    # JSON 6902 patche
        └── removed/                   # Režim enforce, odstranění operátora
            └── kustomization.yaml    # JSON 6902 patche
```

Overlaye používají JSON 6902 patche pro změnu pouze toho, co se liší od base:
- **updated**: rozšiřuje `versions` z `[v1.9.0]` na celou cestu upgradu
- **removed**: mění `complianceType` na `mustnothave` a přidává `removalBehavior` pro smazání operátora

Podrobnosti o přidávání nových operátorů naleznete v [operators/README.md](operators/README.md).

## Generátor politik

ACM obsahuje kustomize plugin PolicyGenerator pro generování politik ze šablon:

```bash
# Instalace pluginu: https://github.com/open-cluster-management-io/policy-generator-plugin
kustomize build --enable-alpha-plugins ./policy-generator/configmap/
```

Politiky založené na šablonách s vyhledáváním v ConfigMap:

```bash
oc apply -f ./policy-generator/configmap-template/policies.yaml
```

## Další zdroje

- [Getting Started with OperatorPolicy](https://developers.redhat.com/articles/2024/08/08/getting-started-operatorpolicy#)
- [ACM OperatorPolicy Documentation](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/governance/governance#operator-policy)
- [Using Hosted Control Planes for OpenShift on OpenShift](https://catalog.demo.redhat.com/catalog?search=hcp&item=babylon-catalog-prod%2Fopenshift-cnv.hcp-ocp-virt-cnv.prod)
- [Kustomize Documentation](https://kubectl.docs.kubernetes.io/references/kustomize/)
- [OpenShift Operator Lifecycle Manager](https://docs.redhat.com/en/documentation/openshift_container_platform/4.16/html/operators/understanding-operators#operator-lifecycle-manager-olm)
