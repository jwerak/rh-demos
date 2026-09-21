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
    "red_10": "#FCE3E3",
    "red_60": "#A60000",
}

graph_attr = {
    "bgcolor": "white",
    "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
    "fontsize": "16",
    "fontcolor": "#151515",
    "pad": "0.6",
    "nodesep": "1.0",
    "ranksep": "0.9",
    "splines": "spline",
}

node_attr = {
    "fontname": "Red Hat Text, Overpass, Liberation Sans, sans-serif",
    "fontsize": "12",
    "fontcolor": "#151515",
}

edge_attr = {
    "color": RH["gray_60"],
    "fontname": "Red Hat Text, Overpass, Liberation Sans, sans-serif",
    "fontsize": "10",
    "fontcolor": RH["gray_60"],
}

cluster_ocp = {
    "style": "rounded,bold",
    "color": RH["red"],
    "bgcolor": RH["red_10"],
    "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
    "fontsize": "14",
    "fontcolor": RH["red_60"],
    "penwidth": "2",
}

cluster_default = {
    "style": "rounded,dashed",
    "color": RH["gray_30"],
    "bgcolor": "#FFFFFF",
    "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
    "fontsize": "13",
    "fontcolor": RH["gray_70"],
    "penwidth": "1.5",
}

cluster_teal = {
    **cluster_default,
    "color": RH["teal_60"],
    "bgcolor": "#EAF6F6",
    "fontcolor": RH["teal_60"],
    "style": "rounded,bold",
}

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

with Diagram(
    "Self-Service VM Portal — Architecture",
    show=False,
    outformat="png",
    filename=os.path.join(SCRIPT_DIR, "virt_portal_architecture"),
    direction="LR",
    graph_attr=graph_attr,
    node_attr=node_attr,
    edge_attr=edge_attr,
):
    user = Custom("Developer", icon("laptop"))

    with Cluster("OpenShift Cluster", graph_attr=cluster_ocp):

        with Cluster("Identity", graph_attr=cluster_default):
            keycloak = Custom("Keycloak\n(OIDC)", icon("sso"))

        with Cluster("Developer Portal", graph_attr=cluster_default):
            rhdh = Custom("Developer Hub\n(RHDH 1.10)", icon("developer_hub"))
            sonataflow = Custom("SonataFlow\n(Approval)", icon("openshift_serverless"))

        with Cluster("GitOps", graph_attr=cluster_default):
            gitlab = Custom("GitLab CE", icon("code"))
            argocd = Custom("ArgoCD", icon("openshift_gitops"))

        with Cluster("VM Environments (dev / staging / prod)", graph_attr=cluster_teal):
            ocpvirt = Custom("OpenShift\nVirtualization", icon("openshift_virt"))
            vm_dev = Custom("vm-dev", icon("virtual_server"))
            vm_staging = Custom("vm-staging", icon("virtual_server"))
            vm_prod = Custom("vm-prod", icon("virtual_server"))

    keycloak >> Edge(color=RH["gray_60"], style="dashed", label="OIDC") >> rhdh

    user >> Edge(color=RH["red"], style="bold", label="order VM") >> rhdh

    rhdh >> Edge(color=RH["purple_50"], label="approval") >> sonataflow
    rhdh >> Edge(color=RH["teal_60"], style="bold", label="scaffold\nrepo") >> gitlab

    gitlab >> Edge(color=RH["teal_60"], label="SCM\ndiscovery") >> argocd
    argocd >> Edge(color=RH["red"], style="bold", label="sync") >> ocpvirt

    ocpvirt - Edge(color=RH["teal_50"], style="dashed") - vm_dev
    ocpvirt - Edge(color=RH["teal_50"], style="dashed") - vm_staging
    ocpvirt - Edge(color=RH["teal_50"], style="dashed") - vm_prod
