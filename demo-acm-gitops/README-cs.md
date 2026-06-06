# ACM GitOps: Životní cyklus operátorů s promocí z dev do prod

Správa instalace a upgradů operátorů napříč clustery OpenShift pomocí ArgoCD + ACM OperatorPolicy. Tato ukázka provisionuje HCP clustery, nasazuje operátory (Web Terminal, Quay) a demonstruje git-based promoci z dev do prod.

> Základní demo bez GitOps viz [Správa životního cyklu operátorů pomocí ACM](../demo-acm-policies/README-cs.md).

## Přehled

- **GitOps-řízené HCP clustery**: ArgoCD provisionuje dev a prod hosted clustery pomocí HostedCluster CR
- **ACM OperatorPolicy**: Operátory nasazované na spravované clustery prostřednictvím vynucování ACM politik
- **Promoce z dev do prod**: Změny jdou do demo větve — přidání operátoru nebo upgrade verze je git commit + push
- **ApplicationSet auto-discovery**: ArgoCD automaticky objevuje prostředí podle adresářové struktury
- **Snadný reset**: Smazání demo větve, vytvoření znovu z masteru — ArgoCD vše vrátí zpět

## Předpoklady

- **OpenShift Container Platform 4.14+** s nainstalovaným ACM/MCE
- **OpenShift Virtualization** a **MetalLB** operátory nainstalované
- **CLI nástroje**: `oc`, `kustomize`
- Dostatečné prostředky clusteru pro 2 HCP clustery (~8 jader + 32 GB RAM celkem)

## Architektura

```txt
┌──────────────────────────────────────────────────────────────────┐
│  Git Repozitář                                                   │
│  větev: demo/<vaše-id> (vytvořená z masteru)                     │
│                                                                  │
│  environments/dev/clusters/    environments/prod/clusters/       │
│  environments/dev/policies/    environments/prod/policies/       │
└──────────────────────┬───────────────────────────────────────────┘
                       │ ArgoCD ApplicationSet
                       │ (git directory generátor)
                       ▼
┌─────────────────────────────────────────────────────────────────┐
│  Hub Cluster (ArgoCD + ACM)                                     │
│                                                                 │
│  ┌──────────────┐  ┌───────────────┐                            │
│  │  dev-cluster │  │  prod-cluster │                            │
│  │  (HCP)       │  │  (HCP)        │                            │
│  │              │  │               │                            │
│  │  Politiky:   │  │  Politiky:    │                            │
│  │  • Web Term. │  │  • Web Term.  │                            │
│  │  • Quay      │  │               │                            │
│  └──────────────┘  └───────────────┘                            │
└─────────────────────────────────────────────────────────────────┘
```

## Nastavení

### 1. Zvolte Demo ID

Vyberte si unikátní ID pro vaši demo relaci (např. vaše jméno nebo tým). To umožňuje běh více ukázek paralelně na stejném clusteru:

```bash
export DEMO_ID=alice   # změňte na své jméno/id
export BASE_DOMAIN=$(oc get ingress.config cluster -o jsonpath='{.spec.domain}')
```

### 2. Bootstrap GitOps

```bash
# Instalace GitOps operátoru, RBAC a namespace (sdílené, spustit jednou na cluster) pomocí Kustomize
oc apply -k bootstrap/

# Zkopírování pull secretu hubu do namespace clusters (potřeba pro provisionování HCP)
oc get secret pull-secret -n openshift-config -o json \
  | jq 'del(.metadata.namespace,.metadata.resourceVersion,.metadata.uid,.metadata.creationTimestamp) | .metadata.name = "hcp-pull-secret"' \
  | oc apply -n clusters -f -

# Počkejte na GitOps operátor (~2-3 minuty)
watch oc get csv -n openshift-gitops
# Počkejte, až openshift-gitops-operator dosáhne stavu Succeeded
```

### 3. Vytvoření demo větve a nasazení ApplicationSetu

Každá demo relace používá vlastní větev. Šablona ApplicationSetu obsahuje zástupné hodnoty `DEMO_BRANCH` a `DEMO_ID`, které se nahradí vašimi hodnotami. Zástupná hodnota `BASE_DOMAIN` v šabloně HostedCluster se nahradí na větvi, aby ArgoCD převzal správnou ingress doménu hubu:

```bash
# Vytvoření demo větve z masteru
git checkout -b "demo/${DEMO_ID}"

# Nastavení base domény hub clusteru v šabloně HostedCluster
sed -i "s|BASE_DOMAIN|${BASE_DOMAIN}|g" base/clusters/hostedcluster.yaml
git add base/clusters/hostedcluster.yaml
git commit -m "Set base domain to ${BASE_DOMAIN}"
git push -u origin "demo/${DEMO_ID}"

# Nasazení ApplicationSetu s vaší větví a ID
sed "s|DEMO_BRANCH|demo/${DEMO_ID}|g; s|DEMO_ID|${DEMO_ID}|g" \
  bootstrap/03-root-applicationset.yaml | oc apply -f -

# Ověření — vaše aplikace budou mít prefix s vaším DEMO_ID
oc get applications.argoproj.io -n openshift-gitops -l "app.kubernetes.io/instance=${DEMO_ID}"
```

### 4. Čekání na provisionování clusterů (~15-20 minut)

```bash
watch oc get hostedclusters -n clusters
# Počkejte, až dev-cluster a prod-cluster dosáhnou PROGRESS=Completed

oc get managedclusters
# dev-cluster    true   https://...   True   True
# prod-cluster   true   https://...   True   True
```

### 5. Ověření výchozího stavu

```bash
# Dev: Web Terminal (v1.9.0) i Quay (v3.17.2)
oc get policy -n dev-policies
# web-terminal    enforce   Compliant
# quay-operator   enforce   Compliant

# Prod: pouze Web Terminal (v1.9.0)
oc get policy -n prod-policies
# web-terminal    enforce   Compliant
```

## Demo scénáře

Všechny změny se provádějí na větvi `demo/${DEMO_ID}`. ArgoCD se automaticky synchronizuje do ~3 minut od každého pushe. Kompletní soubory scénářů jsou v `scenarios/` — stačí je zkopírovat.

### Scénář 1: Promoce Quay do produkce

Přidání operátoru Quay do produkčního prostředí:

```bash
cp scenarios/scenario-1-quay-to-prod/kustomization.yaml environments/prod/policies/kustomization.yaml
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote Quay operator to production"
git push
```

Ověření (~3 minuty na sync ArgoCD):

```bash
oc get policy -n prod-policies
# web-terminal           enforce   Compliant
# quay-operator          enforce   Compliant
# environment-branding   enforce   Compliant
```

### Scénář 2: Upgrade Web Terminalu na dev (v1.9.0 → v1.12.1)

Rozšíření povolených verzí o kompletní upgrade cestu z v1.9.0 přes v1.12.1 (všechny meziverze z kanálu `fast`):

```bash
cp scenarios/scenario-2-web-term-1.12.1-dev/kustomization.yaml environments/dev/policies/kustomization.yaml
git add environments/dev/policies/kustomization.yaml
git commit -m "Upgrade web-terminal to v1.12.1 on dev"
git push
```

Sledování upgradu (~3-5 minut přes řetězec verzí v1.9.0 → v1.10.x → v1.11.x → v1.12.1):

```bash
watch oc get policy -n dev-policies
# web-terminal bude krátce ukazovat NonCompliant během upgradu, pak Compliant na v1.12.1

# Kontrola nainstalované verze
oc get policy dev-policies.web-terminal -n dev-cluster \
  -o jsonpath='{.status.details[0].history[0].message}' | grep -oE 'web-terminal\.[v0-9.]+'
```

> **Poznámka:** Pole versions musí obsahovat VŠECHNY meziverze (včetně pre-release `.p` buildů), aby OLM mohl projít upgrade grafem. Lze je vypsat pomocí:
> ```bash
> oc get packagemanifests -n openshift-marketplace web-terminal \
>   -o jsonpath='{range .status.channels[?(@.name=="fast")].entries[*]}- {.name}{"\n"}{end}' | sort -V
> ```

### Scénář 3: Promoce upgradu do produkce

Po ověření dev na v1.12.1 aplikujte stejný upgrade na prod:

```bash
cp scenarios/scenario-3-web-term-1.12.1-prod/kustomization.yaml environments/prod/policies/kustomization.yaml
git add environments/prod/policies/kustomization.yaml
git commit -m "Promote web-terminal v1.12.1 upgrade to production"
git push
```

## Volitelné: Instalace Compliance Operátoru přes ACM konzoli

Compliance Operátor můžete na spravovaný cluster nasadit ručně přes ACM konzoli. Na HCP (HyperShift) clusterech vyžaduje operátor **přepsání nodeSelectoru** — ve výchozím nastavení cílí na master uzly, které na HCP clusterech neexistují jako plánovatelné uzly.

1. V ACM konzoli přejděte na **Governance** → **Create policy**
2. Vyplňte detaily politiky:
   - **Name**: např. `compliance-operator`
   - **Namespace**: `dev-policies` (nebo `prod-policies`)
   - **Remediation**: `enforce`
3. Přidejte šablonu politiky → **OperatorPolicy** s:
   - **Operator name**: `compliance-operator`
   - **Namespace**: `openshift-compliance`
   - **Source**: `redhat-operators`
   - **Upgrade approval**: `Automatic`
4. Přepněte do **YAML editoru** a přidejte blok `config` pod `subscription` pro přepsání nodeSelectoru:
   ```yaml
   subscription:
     name: compliance-operator
     namespace: openshift-compliance
     source: redhat-operators
     sourceNamespace: openshift-marketplace
     config:
       nodeSelector:
         node-role.kubernetes.io/worker: ""
   ```
5. Nastavte **Placement** na cílení příslušného ClusterSetu (např. `dev` nebo `prod`)
6. **Submit**

> **Proč nodeSelector?** Výchozí deployment Compliance Operátoru cílí na uzly `node-role.kubernetes.io/master`. HCP clustery provozují svůj control plane na hubu — spravovaný cluster má pouze worker uzly. Bez tohoto přepsání se pod operátoru nikdy nenaplánuje a instalace vyprší s chybou `deployment "compliance-operator" exceeded its progress deadline`.

## Reset dema

Smazání demo větve a její znovuvytvoření z masteru pro návrat do výchozího stavu:

```bash
git checkout master
git branch -D "demo/${DEMO_ID}"
git push origin --delete "demo/${DEMO_ID}"

# Znovuvytvoření z čistého masteru
git checkout -b "demo/${DEMO_ID}"
git push -u origin "demo/${DEMO_ID}"

# ArgoCD se automaticky synchronizuje zpět do výchozího stavu:
# - Dev: web-terminal v1.9.0 + quay v3.17.2 + zelený banner
# - Prod: web-terminal v1.9.0 + červený banner (bez Quay)
```

> **Poznámka:** OLM neprovádí downgrade operátorů. Po resetu zůstanou operátory na clusterech ve svých upgradovaných verzích, ale politiky budou ukazovat Compliant, protože základní verze (v1.9.0) je stále v povoleném seznamu.

## Kompletní úklid

Odebrání všech GitOps-řízených prostředků z clusteru:

```bash
# Odebrání vašeho ApplicationSetu (kaskádově smaže všechny aplikace)
oc delete applicationset "${DEMO_ID}-acm-gitops" -n openshift-gitops

# Zničení HCP clusterů
hcp destroy cluster kubevirt --name dev-cluster --namespace clusters
hcp destroy cluster kubevirt --name prod-cluster --namespace clusters

# Úklid
oc delete managedclusterset dev prod
oc delete namespace dev-policies prod-policies

# Odebrání demo větve
git checkout master
git push origin --delete "demo/${DEMO_ID}"

# Odebrání GitOps operátoru (volitelné, sdílený prostředek)
oc delete subscription openshift-gitops-operator -n openshift-operators
```

## Struktura Kustomize

```
demo-acm-gitops/
├── bootstrap/                        # Manuálně: oc apply -k bootstrap/
│   ├── 01-gitops-operator.yaml      # GitOps operátor + namespace pro politiky
│   ├── 02-argocd-rbac.yaml          # ClusterRole pro ACM/HCP prostředky
│   ├── 03-root-applicationset.yaml  # Git directory generátor (zástupné DEMO_BRANCH/DEMO_ID)
│   └── create-secrets.sh            # Pomocník pro secrety HCP clusterů (fallback)
├── base/                             # Sdílené šablony (neaplikují se přímo)
│   ├── clusters/                    # HostedCluster, NodePool, ClusterSet, pull secret
│   └── policies/
│       ├── web-terminal/            # OperatorPolicy: kanál fast, v1.9.0
│       └── quay/                    # OperatorPolicy: stable-3.17, v3.17.2
└── environments/                     # Řízeno ArgoCD (auto-discovery)
    ├── dev/
    │   ├── clusters/                # dev-cluster, ClusterSet=dev
    │   └── policies/                # web-terminal + quay → dev-policies ns
    └── prod/
        ├── clusters/                # prod-cluster, ClusterSet=prod
        └── policies/                # pouze web-terminal → prod-policies ns
```

## Další zdroje

- [Dokumentace OpenShift GitOps](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/)
- [Dokumentace ArgoCD ApplicationSet](https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/)
- [Dokumentace ACM OperatorPolicy](https://access.redhat.com/documentation/en-us/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/governance/governance#operator-policy)
- [Dokumentace Hosted Control Planes](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_management_for_kubernetes/2.11/html/clusters/cluster_mce_overview#hosted-control-planes-intro)
