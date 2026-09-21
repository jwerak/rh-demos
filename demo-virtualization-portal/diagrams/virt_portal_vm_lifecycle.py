import os
from diagrams import Diagram, Cluster, Edge
from diagrams.custom import Custom

ICON_DIR = os.path.expanduser("~/.agents/skills/generate-diagram/icons")

def icon(name):
    return os.path.join(ICON_DIR, f"{name}.png")

RH = {
    "red": "#EE0000",
    "gray_60": "#4D4D4D",
    "gray_30": "#C7C7C7",
    "gray_10": "#F2F2F2",
    "gray_70": "#383838",
    "teal_50": "#37A3A3",
    "teal_60": "#147878",
    "purple_50": "#5E40BE",
    "purple_60": "#3D2785",
    "orange_50": "#CA6C0F",
    "red_10": "#FCE3E3",
    "red_60": "#A60000",
    "green_60": "#3D7317",
    "danger_50": "#F0561D",
}

graph_attr = {
    "bgcolor": "white",
    "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
    "fontsize": "16",
    "fontcolor": "#151515",
    "pad": "0.6",
    "nodesep": "0.8",
    "ranksep": "1.0",
    "splines": "spline",
}

node_attr = {
    "fontname": "Red Hat Text, Overpass, Liberation Sans, sans-serif",
    "fontsize": "11",
    "fontcolor": "#151515",
}

edge_attr = {
    "color": RH["gray_60"],
    "fontname": "Red Hat Text, Overpass, Liberation Sans, sans-serif",
    "fontsize": "10",
    "fontcolor": RH["gray_60"],
}

cluster_default = {
    "style": "rounded,dashed",
    "color": RH["gray_30"],
    "bgcolor": RH["gray_10"],
    "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
    "fontsize": "13",
    "fontcolor": RH["gray_70"],
    "penwidth": "1.5",
}

cluster_accent = {
    **cluster_default,
    "color": RH["red"],
    "bgcolor": RH["red_10"],
    "fontcolor": RH["red_60"],
    "style": "rounded,bold",
}

cluster_purple = {
    **cluster_default,
    "color": RH["purple_60"],
    "bgcolor": "#F0EBF8",
    "fontcolor": RH["purple_60"],
    "style": "rounded,bold",
}

cluster_teal = {
    **cluster_default,
    "color": RH["teal_60"],
    "bgcolor": "#EAF6F6",
    "fontcolor": RH["teal_60"],
    "style": "rounded,bold",
}

cluster_green = {
    **cluster_default,
    "color": RH["green_60"],
    "bgcolor": "#EEF5E8",
    "fontcolor": RH["green_60"],
    "style": "rounded,bold",
}

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

with Diagram(
    "VM Lifecycle — Order, Edit & Approve",
    show=False,
    outformat="png",
    filename=os.path.join(SCRIPT_DIR, "virt_portal_vm_lifecycle"),
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    developer = Custom("Developer", icon("laptop"))

    with Cluster("RHDH Software Templates", graph_attr=cluster_accent):
        create = Custom("Create VM", icon("developer_hub"))
        resize = Custom("Resize VM", icon("developer_hub"))
        decom = Custom("Decommission\nVM", icon("developer_hub"))

    with Cluster("GitLab CE", graph_attr=cluster_default):
        new_repo = Custom("New Repo\n+ Merge Request", icon("code"))
        edit_mr = Custom("Update MR\n(resize / decom)", icon("code"))

    with Cluster("SonataFlow Approval Workflow", graph_attr=cluster_purple):
        workflow = Custom("Dual-Approval\nPoll Loop", icon("openshift_serverless"))

        with Cluster("Required Approvers", graph_attr={
            **cluster_default,
            "bgcolor": "#FFFFFF",
        }):
            app_owner = Custom("App Owner", icon("secured"))
            sec_admin = Custom("Security\nAdmin", icon("secured"))

        auto_merge = Custom("Auto-Merge\nMR", icon("orchestration"))

    with Cluster("GitOps Deployment", graph_attr=cluster_green):
        argocd = Custom("ArgoCD\n(SCM Provider)", icon("openshift_gitops"))
        ocpvirt = Custom("OpenShift\nVirtualization", icon("openshift_virt"))

    with Cluster("VM Environments", graph_attr=cluster_teal):
        vm_dev = Custom("vm-dev", icon("virtual_server"))
        vm_staging = Custom("vm-staging", icon("virtual_server"))
        vm_prod = Custom("vm-prod", icon("virtual_server"))

    # Developer picks a template
    developer >> Edge(color=RH["red"], style="bold") >> create
    developer >> Edge(color=RH["orange_50"], style="bold") >> resize
    developer >> Edge(color=RH["danger_50"], style="bold") >> decom

    # Create VM: scaffolds new repo + MR
    create >> Edge(color=RH["teal_60"], label="scaffold\nrepo + MR") >> new_repo

    # Resize / Decommission: MR on existing repo
    resize >> Edge(color=RH["teal_60"], label="update\nMR") >> edit_mr
    decom >> Edge(color=RH["teal_60"]) >> edit_mr

    # Both MR paths trigger the approval workflow
    new_repo >> Edge(color=RH["purple_50"], label="trigger\nworkflow") >> workflow
    edit_mr >> Edge(color=RH["purple_50"]) >> workflow

    # Workflow notifies approvers and polls
    workflow >> Edge(color=RH["purple_50"], label="notify +\npoll") >> app_owner
    workflow >> Edge(color=RH["purple_50"]) >> sec_admin

    # Both approve → auto-merge
    app_owner >> Edge(color=RH["green_60"], label="approve") >> auto_merge
    sec_admin >> Edge(color=RH["green_60"], label="approve") >> auto_merge

    # Merged MR → ArgoCD syncs
    auto_merge >> Edge(color=RH["teal_60"], style="bold", label="MR\nmerged") >> argocd
    argocd >> Edge(color=RH["red"], style="bold", label="sync") >> ocpvirt

    # OCP Virt manages environments
    ocpvirt - Edge(color=RH["teal_50"], style="dashed") - vm_dev
    ocpvirt - Edge(color=RH["teal_50"], style="dashed") - vm_staging
    ocpvirt - Edge(color=RH["teal_50"], style="dashed") - vm_prod
