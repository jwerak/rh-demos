#!/usr/bin/env python3
"""Bootc desktop: registry on top, left-to-right build → laptop → deploy."""

import os
from graphviz import Digraph

ICON_DIR = os.path.expanduser("~/.agents/skills/generate-diagram/icons")
OUT_DIR = os.path.dirname(os.path.abspath(__file__))
ICON_W = "1.35"
ICON_H = "1.65"


def icon(name: str) -> str:
    return os.path.join(ICON_DIR, f"{name}.png")


dot = Digraph(
    "Bootc Desktop Build and Deploy",
    format="png",
    graph_attr={
        "rankdir": "TB",
        "bgcolor": "white",
        "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
        "fontsize": "16",
        "fontcolor": "#151515",
        "pad": "0.55",
        "nodesep": "0.85",
        "ranksep": "1.55",
        "splines": "line",
        "newrank": "true",
        "label": "Bootc Desktop Build and Deploy",
        "labelloc": "t",
    },
    node_attr={
        "shape": "box",
        "style": "rounded",
        "fontname": "Red Hat Text, Overpass, Liberation Sans, sans-serif",
        "fontsize": "11",
        "fontcolor": "#151515",
        "color": "#C7C7C7",
        "penwidth": "0",
        "labelloc": "b",
        "imagescale": "true",
        "fixedsize": "true",
        "width": ICON_W,
        "height": ICON_H,
    },
    edge_attr={
        "color": "#4D4D4D",
        "fontname": "Red Hat Text, Overpass, Liberation Sans, sans-serif",
        "fontsize": "10",
        "fontcolor": "#4D4D4D",
    },
)

stage = {
    "style": "rounded,dashed",
    "color": "#C7C7C7",
    "bgcolor": "#F2F2F2",
    "fontname": "Red Hat Display, Overpass, Liberation Sans, sans-serif",
    "fontsize": "12",
    "fontcolor": "#383838",
    "penwidth": "1.5",
}
stage_prod = {
    **stage,
    "color": "#EE0000",
    "bgcolor": "#FCE3E3",
    "fontcolor": "#A60000",
    "style": "rounded,bold",
}


def icon_node(graph: Digraph, name: str, label: str, icon_name: str) -> None:
    graph.node(name, label=label, image=icon(icon_name))


def spacer(graph: Digraph, name: str) -> None:
    graph.node(
        name,
        label="",
        shape="box",
        style="invis",
        width=ICON_W,
        height=ICON_H,
        fixedsize="true",
    )


# Top registry row — columns aligned with stages below.
with dot.subgraph(name="cluster_registry") as registry:
    registry.attr(
        label="Container registry",
        style="rounded,bold",
        color="#0066CC",
        bgcolor="#E7F1FA",
        fontname="Red Hat Display, Overpass, Liberation Sans, sans-serif",
        fontsize="13",
        fontcolor="#0066CC",
        penwidth="1.5",
    )
    with registry.subgraph() as top:
        top.attr(rank="same")
        icon_node(top, "upstream", "fedora-bootc", "image_mode")
        icon_node(top, "quay", "Quay / registry", "quay")
        icon_node(top, "base_tag", "Base image tag", "container_image")
        icon_node(top, "final_tag", "Final image tag", "container_image")
        spacer(top, "r1")
        spacer(top, "r2")
        spacer(top, "r3")
        for a, b in (
            ("upstream", "quay"),
            ("quay", "base_tag"),
            ("base_tag", "final_tag"),
            ("final_tag", "r1"),
            ("r1", "r2"),
            ("r2", "r3"),
        ):
            top.edge(a, b, style="invis", weight="200")

# Bottom stages left-to-right.
with dot.subgraph(name="cluster_build") as build:
    build.attr(label="1. Build machine", **stage)
    with build.subgraph() as row:
        row.attr(rank="same")
        icon_node(row, "containerfile", "Containerfile", "code")
        icon_node(row, "build_host", "Build machine", "server")
        icon_node(row, "base", "Base bootc\nimage", "image_mode")
        row.edge("containerfile", "build_host", style="invis", weight="200")
        row.edge("build_host", "base", style="invis", weight="200")

with dot.subgraph(name="cluster_laptop") as laptop:
    laptop.attr(label="2. Laptop + videos", **stage)
    with laptop.subgraph() as row:
        row.attr(rank="same")
        icon_node(row, "dev_laptop", "Laptop", "laptop")
        icon_node(row, "videos", "videos/", "storage")
        icon_node(row, "final", "Final bootc\n+ videos", "container_image")
        row.edge("dev_laptop", "videos", style="invis", weight="200")
        row.edge("videos", "final", style="invis", weight="200")

with dot.subgraph(name="cluster_deploy") as deploy:
    deploy.attr(label="3. Test or production", **stage_prod)
    with deploy.subgraph() as row:
        row.attr(rank="same")
        icon_node(row, "qcow", "qcow2", "virtual_storage")
        icon_node(row, "vm", "libvirt VM\n(test)", "virtual_server")
        icon_node(row, "iso", "ISO +\nkickstart", "storage")
        icon_node(row, "bare", "Physical\nsystem", "server")
        icon_node(row, "monitor", "Monitor\nvideo loop", "platform")
        row.edge("qcow", "vm", style="invis", weight="200")
        row.edge("vm", "iso", style="invis", weight="200")
        row.edge("iso", "bare", style="invis", weight="200")
        row.edge("bare", "monitor", style="invis", weight="200")

# One shared rank for the whole bottom flow.
with dot.subgraph() as band:
    band.attr(rank="same")
    for name in (
        "containerfile",
        "build_host",
        "base",
        "dev_laptop",
        "videos",
        "final",
        "qcow",
        "vm",
        "iso",
        "bare",
        "monitor",
    ):
        band.node(name)

# Column alignment: registry node directly above matching flow node.
for top_node, bottom_node in (
    ("upstream", "containerfile"),
    ("quay", "build_host"),
    ("base_tag", "base"),
    ("final_tag", "final"),
    ("r1", "qcow"),
    ("r2", "iso"),
    ("r3", "monitor"),
):
    dot.edge(top_node, bottom_node, style="invis", weight="1")

# Invisible LR backbone across stages.
for a, b in (
    ("base", "dev_laptop"),
    ("final", "qcow"),
):
    dot.edge(a, b, style="invis", weight="50")


def up(src: str, dst: str, xlabel: str, style: str = "solid") -> None:
    """Vertical registry link: attach north↔south so the line stays short."""
    dot.edge(
        f"{src}:n",
        f"{dst}:s",
        color="#0066CC",
        style=style,
        xlabel=xlabel,
        constraint="false",
        weight="1000",
        minlen="1",
    )


def down(src: str, dst: str, xlabel: str, style: str = "solid") -> None:
    dot.edge(
        f"{src}:s",
        f"{dst}:n",
        color="#0066CC",
        style=style,
        xlabel=xlabel,
        constraint="false",
        weight="1000",
        minlen="1",
    )


# Stage 1
dot.edge("containerfile", "build_host", color="#4D4D4D", label="build-base")
dot.edge("build_host", "base", color="#4D4D4D")
down("upstream", "base", "1. pull")
up("base", "base_tag", "2. push")

# Stage 2
dot.edge("base", "dev_laptop", color="#4D4D4D", label="reuse base")
down("base_tag", "dev_laptop", "pull", style="dashed")
dot.edge("dev_laptop", "final", color="#4D4D4D", label="build + videos")
dot.edge("videos", "final", color="#4D4D4D", style="dashed")
up("final", "final_tag", "3. push")

# Stage 3
dot.edge("final", "qcow", color="#EE0000", style="bold", label="test")
dot.edge("qcow", "vm", color="#147878", label="import")
dot.edge("final", "iso", color="#EE0000", style="bold", label="prod", constraint="false")
down("final_tag", "iso", "pull / reuse", style="dashed")
dot.edge("iso", "bare", color="#147878", label="kickstart")
dot.edge("bare", "monitor", color="#EE0000", style="bold", label="video loop")

out = os.path.join(OUT_DIR, "bootc_build_deploy")
dot.render(out, cleanup=True)
print(f"wrote {out}.png")
