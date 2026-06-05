# Demo Diagrams

Mermaid diagrams for the ACM GitOps demo. These render on GitHub and can be imported into draw.io (Extras → Edit Diagram → paste mermaid), Miro, or any Mermaid-compatible tool.

## 1. GitOps Architecture

```mermaid
graph TB
    subgraph git ["Git Repository (github.com/jwerak/rh-demos)"]
        master["master branch<br/><i>base state</i>"]
        demo["demo/&lt;id&gt; branch<br/><i>live changes</i>"]
        master -->|"git checkout -b"| demo
    end

    subgraph hub ["Hub Cluster (OCP 4.19 + ACM)"]
        subgraph argo ["OpenShift GitOps"]
            appset["ApplicationSet<br/><b>acm-gitops-&lt;id&gt;</b><br/><i>git directory generator</i>"]
            app_dc["App: dev-clusters"]
            app_dp["App: dev-policies"]
            app_pc["App: prod-clusters"]
            app_pp["App: prod-policies"]
        end

        subgraph acm ["ACM / MCE"]
            cs_dev["ClusterSet: dev"]
            cs_prod["ClusterSet: prod"]
            pol_dev["Policies: dev-policies"]
            pol_prod["Policies: prod-policies"]
        end

        subgraph hcp ["Hosted Control Planes"]
            dev_cp["dev-cluster<br/>control plane"]
            prod_cp["prod-cluster<br/>control plane"]
        end
    end

    subgraph workers ["KubeVirt Worker VMs"]
        dev_w["dev-cluster workers<br/>2× (2c / 8GB)"]
        prod_w["prod-cluster workers<br/>2× (2c / 8GB)"]
    end

    demo -->|"auto-sync<br/>~3 min"| appset
    appset --> app_dc & app_dp & app_pc & app_pp

    app_dc -->|"HostedCluster<br/>NodePool"| dev_cp
    app_pc -->|"HostedCluster<br/>NodePool"| prod_cp
    app_dp -->|"OperatorPolicy<br/>Placement"| pol_dev
    app_pp -->|"OperatorPolicy<br/>Placement"| pol_prod

    pol_dev -->|"enforce"| cs_dev
    pol_prod -->|"enforce"| cs_prod
    cs_dev --> dev_cp
    cs_prod --> prod_cp

    dev_cp --> dev_w
    prod_cp --> prod_w

    style git fill:#f5f5f5,stroke:#333
    style hub fill:#e8f4fd,stroke:#0066cc
    style argo fill:#d4edda,stroke:#28a745
    style acm fill:#fff3cd,stroke:#ffc107
    style hcp fill:#f8d7da,stroke:#dc3545
    style workers fill:#e2e3e5,stroke:#6c757d
    style master fill:#fff,stroke:#333
    style demo fill:#d4edda,stroke:#28a745,stroke-width:2px
```

## 2. Environment Comparison

```mermaid
graph LR
    subgraph dev ["DEV Environment 🟢"]
        direction TB
        dev_banner["🟢 ConsoleNotification<br/><b>DEV ENVIRONMENT</b><br/><i>green banner</i>"]
        dev_wt["Web Terminal<br/>v1.9.0 → v1.12.1"]
        dev_quay["Quay Operator<br/>v3.17.2"]
        dev_brand["Environment<br/>Branding"]
    end

    subgraph prod ["PROD Environment 🔴"]
        direction TB
        prod_banner["🔴 ConsoleNotification<br/><b>PRODUCTION ENVIRONMENT</b><br/><i>red banner</i>"]
        prod_wt["Web Terminal<br/>v1.9.0"]
        prod_brand["Environment<br/>Branding"]
        prod_quay["Quay Operator<br/><i>after promotion</i>"]
    end

    dev -->|"Scenario 1<br/>promote Quay"| prod
    dev -->|"Scenario 3<br/>promote upgrade"| prod

    style dev fill:#d4edda,stroke:#1cb933,stroke-width:2px
    style prod fill:#f8d7da,stroke:#dc291c,stroke-width:2px
    style prod_quay fill:#fff,stroke:#999,stroke-dasharray: 5 5
```

## 3. Promotion Flow (Sequence)

```mermaid
sequenceDiagram
    actor User
    participant Git as Git Branch<br/>demo/<id>
    participant Argo as ArgoCD
    participant ACM as ACM Hub
    participant Dev as dev-cluster
    participant Prod as prod-cluster

    Note over Git,Prod: Initial State: Dev has Web Terminal + Quay, Prod has Web Terminal only

    rect rgb(232, 244, 253)
        Note right of User: Scenario 1: Promote Quay to Prod
        User->>Git: cp scenario-1 → prod/policies<br/>git push
        Git->>Argo: webhook / poll (~3 min)
        Argo->>ACM: sync prod-policies
        ACM->>Prod: deploy Quay OperatorPolicy
        Prod-->>ACM: Compliant ✓
    end

    rect rgb(212, 237, 218)
        Note right of User: Scenario 2: Upgrade Web Terminal on Dev
        User->>Git: cp scenario-2 → dev/policies<br/>git push
        Git->>Argo: sync
        Argo->>ACM: update dev-policies
        ACM->>Dev: expand versions array
        Note over Dev: OLM upgrade chain<br/>v1.9.0 → v1.10.x → v1.11.x → v1.12.1
        Dev-->>ACM: NonCompliant → Compliant ✓
    end

    rect rgb(255, 243, 205)
        Note right of User: Scenario 3: Promote Upgrade to Prod
        User->>Git: cp scenario-3 → prod/policies<br/>git push
        Git->>Argo: sync
        Argo->>ACM: update prod-policies
        ACM->>Prod: expand versions array
        Note over Prod: OLM upgrade chain<br/>v1.9.0 → ... → v1.12.1
        Prod-->>ACM: Compliant ✓
    end

    rect rgb(248, 215, 218)
        Note right of User: Reset
        User->>Git: delete branch<br/>recreate from master
        Git->>Argo: sync to base state
        Argo->>ACM: revert policies
        Note over Dev,Prod: Policies revert to v1.9.0<br/>(operators stay at upgraded version)
    end
```

## 4. Kustomize Overlay Structure

```mermaid
graph TB
    subgraph base ["base/ (shared templates)"]
        b_clusters["clusters/<br/>HostedCluster, NodePool<br/>ClusterSet, pull-secret"]
        b_wt["policies/web-terminal/<br/>OperatorPolicy<br/>v1.9.0, fast channel"]
        b_quay["policies/quay/<br/>OperatorPolicy<br/>v3.17.2, stable-3.17"]
        b_brand["policies/branding/<br/>ConfigurationPolicy<br/>ConsoleNotification"]
    end

    subgraph envs ["environments/ (overlays)"]
        subgraph dev_env ["dev/"]
            dev_c["clusters/<br/>kustomization.yaml<br/><i>name=dev-cluster</i><br/><i>clusterset=dev</i>"]
            dev_p["policies/<br/>kustomization.yaml<br/><i>ns=dev-policies</i><br/><i>🟢 green banner</i>"]
        end
        subgraph prod_env ["prod/"]
            prod_c["clusters/<br/>kustomization.yaml<br/><i>name=prod-cluster</i><br/><i>clusterset=prod</i>"]
            prod_p["policies/<br/>kustomization.yaml<br/><i>ns=prod-policies</i><br/><i>🔴 red banner</i>"]
        end
    end

    subgraph scenarios ["scenarios/ (complete files for cp)"]
        s1["scenario-1-quay-to-prod/<br/><i>adds quay to prod</i>"]
        s2["scenario-2-web-term-1.12.1-dev/<br/><i>upgrade versions on dev</i>"]
        s3["scenario-3-web-term-1.12.1-prod/<br/><i>upgrade versions on prod</i>"]
    end

    b_clusters --> dev_c & prod_c
    b_wt --> dev_p & prod_p
    b_quay --> dev_p
    b_brand --> dev_p & prod_p

    s1 -.->|"cp"| prod_p
    s2 -.->|"cp"| dev_p
    s3 -.->|"cp"| prod_p

    style base fill:#f5f5f5,stroke:#333
    style envs fill:#e8f4fd,stroke:#0066cc
    style scenarios fill:#fff3cd,stroke:#ffc107
    style dev_env fill:#d4edda,stroke:#1cb933
    style prod_env fill:#f8d7da,stroke:#dc291c
```

## 5. Branch Strategy

```mermaid
gitGraph
    commit id: "base state"
    commit id: "branding + scenarios"
    branch demo/alice
    checkout demo/alice
    commit id: "Scenario 1: Quay → prod"
    commit id: "Scenario 2: WT upgrade dev"
    commit id: "Scenario 3: WT upgrade prod"
    checkout main
    branch demo/bob
    checkout demo/bob
    commit id: "Bob: Quay → prod"
    commit id: "Bob: WT upgrade"
```

> Multiple users work on independent branches. Each branch has its own ApplicationSet and ArgoCD Applications. Reset = delete branch, recreate from master.
