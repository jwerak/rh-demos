# Demo Diagrams

Mermaid diagrams for the ACM GitOps demo. These render on GitHub and can be imported into draw.io (Extras > Edit Diagram > paste mermaid), Miro, or any Mermaid-compatible tool.

## 1. GitOps Architecture

```mermaid
graph TB
    subgraph git ["Git Repository"]
        master["master branch\n(base state)"]
        demo["demo/DEMO_ID branch\n(live changes)"]
        master -->|git checkout -b| demo
    end

    subgraph hub ["Hub Cluster - OCP 4.19 + ACM"]
        subgraph argo ["OpenShift GitOps"]
            appset["ApplicationSet\nacm-gitops-DEMO_ID\ngit directory generator"]
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
            dev_cp["dev-cluster\ncontrol plane"]
            prod_cp["prod-cluster\ncontrol plane"]
        end
    end

    subgraph workers ["KubeVirt Worker VMs"]
        dev_w["dev-cluster workers\n2x 2c / 8GB"]
        prod_w["prod-cluster workers\n2x 2c / 8GB"]
    end

    demo -->|"auto-sync ~3 min"| appset
    appset --> app_dc & app_dp & app_pc & app_pp

    app_dc -->|"HostedCluster\nNodePool"| dev_cp
    app_pc -->|"HostedCluster\nNodePool"| prod_cp
    app_dp -->|"OperatorPolicy\nPlacement"| pol_dev
    app_pp -->|"OperatorPolicy\nPlacement"| pol_prod

    pol_dev -->|enforce| cs_dev
    pol_prod -->|enforce| cs_prod
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
    subgraph dev ["DEV Environment"]
        direction TB
        dev_banner["ConsoleNotification\nDEV ENVIRONMENT\ngreen banner"]
        dev_wt["Web Terminal\nv1.9.0 -- upgrades to v1.12.1"]
        dev_quay["Quay Operator\nv3.17.2"]
        dev_brand["Environment Branding"]
    end

    subgraph prod ["PROD Environment"]
        direction TB
        prod_banner["ConsoleNotification\nPRODUCTION ENVIRONMENT\nred banner"]
        prod_wt["Web Terminal\nv1.9.0"]
        prod_brand["Environment Branding"]
        prod_quay["Quay Operator\n(added via promotion)"]
    end

    dev -->|"Scenario 1\npromote Quay"| prod
    dev -->|"Scenario 3\npromote upgrade"| prod

    style dev fill:#d4edda,stroke:#1cb933,stroke-width:2px
    style prod fill:#f8d7da,stroke:#dc291c,stroke-width:2px
    style prod_quay fill:#fff,stroke:#999,stroke-dasharray: 5 5
```

## 3. Promotion Flow

```mermaid
sequenceDiagram
    actor User
    participant Git as Git Branch
    participant Argo as ArgoCD
    participant ACM as ACM Hub
    participant Dev as dev-cluster
    participant Prod as prod-cluster

    Note over Git,Prod: Initial State -- Dev: Web Terminal + Quay, Prod: Web Terminal only

    rect rgb(232, 244, 253)
        Note right of User: Scenario 1 -- Promote Quay to Prod
        User->>Git: cp scenario-1, git push
        Git->>Argo: poll ~3 min
        Argo->>ACM: sync prod-policies
        ACM->>Prod: deploy Quay OperatorPolicy
        Prod-->>ACM: Compliant
    end

    rect rgb(212, 237, 218)
        Note right of User: Scenario 2 -- Upgrade Web Terminal on Dev
        User->>Git: cp scenario-2, git push
        Git->>Argo: sync
        Argo->>ACM: update dev-policies
        ACM->>Dev: expand versions array
        Note over Dev: OLM upgrade chain v1.9.0 to v1.12.1
        Dev-->>ACM: Compliant
    end

    rect rgb(255, 243, 205)
        Note right of User: Scenario 3 -- Promote Upgrade to Prod
        User->>Git: cp scenario-3, git push
        Git->>Argo: sync
        Argo->>ACM: update prod-policies
        ACM->>Prod: expand versions array
        Note over Prod: OLM upgrade chain v1.9.0 to v1.12.1
        Prod-->>ACM: Compliant
    end

    rect rgb(248, 215, 218)
        Note right of User: Reset
        User->>Git: delete branch, recreate from master
        Git->>Argo: sync to base state
        Argo->>ACM: revert policies
        Note over Dev,Prod: Policies revert to v1.9.0 (operators stay upgraded)
    end
```

## 4. Kustomize Overlay Structure

```mermaid
graph TB
    subgraph base ["base - shared templates"]
        b_clusters["clusters/\nHostedCluster, NodePool\nClusterSet, pull-secret"]
        b_wt["policies/web-terminal/\nOperatorPolicy\nv1.9.0, fast channel"]
        b_quay["policies/quay/\nOperatorPolicy\nv3.17.2, stable-3.17"]
        b_brand["policies/branding/\nConfigurationPolicy\nConsoleNotification"]
    end

    subgraph envs ["environments - overlays"]
        subgraph dev_env ["dev/"]
            dev_c["clusters/\nname=dev-cluster\nclusterset=dev"]
            dev_p["policies/\nns=dev-policies\ngreen banner"]
        end
        subgraph prod_env ["prod/"]
            prod_c["clusters/\nname=prod-cluster\nclusterset=prod"]
            prod_p["policies/\nns=prod-policies\nred banner"]
        end
    end

    subgraph scenarios ["scenarios - complete files for cp"]
        s1["scenario-1-quay-to-prod\nadds quay to prod"]
        s2["scenario-2-web-term-1.12.1-dev\nupgrade versions on dev"]
        s3["scenario-3-web-term-1.12.1-prod\nupgrade versions on prod"]
    end

    b_clusters --> dev_c & prod_c
    b_wt --> dev_p & prod_p
    b_quay --> dev_p
    b_brand --> dev_p & prod_p

    s1 -.->|cp| prod_p
    s2 -.->|cp| dev_p
    s3 -.->|cp| prod_p

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
    commit id: "Scenario 1: Quay to prod"
    commit id: "Scenario 2: WT upgrade dev"
    commit id: "Scenario 3: WT upgrade prod"
    checkout main
    branch demo/bob
    checkout demo/bob
    commit id: "Bob: Quay to prod"
    commit id: "Bob: WT upgrade"
```

Multiple users work on independent branches. Each branch has its own ApplicationSet and ArgoCD Applications. Reset = delete branch, recreate from master.
