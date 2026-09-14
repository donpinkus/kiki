"""Sample static poses out of animation clips for the posable-figure library.

    blender -b --python extract_poses.py -- \
        --anim  /path/to/animations.glb   # clips rigged to the figure skeleton
        --spec  poses.spec.json           # which clip/frame becomes which pose
        --out   ../../Kiki/Figure/Poses/figure_poses.json

Spec: {"poses": [{"id": "sit_chair", "name": "Sitting", "category": "Sitting",
                   "clip": "Sit_Idle", "frame": 12, "yaw": 0.0,
                   "mirror": false}]}

For every entry the clip is assigned to the armature, the frame is set, and the
scene is exported to a temporary GLB *at the current pose* (no animation
tracks). The pose file stores, per bone, the delta from the rig's own rest
orientation in the bone's parent-relative glTF frame:

    delta = inverse(rest_rotation) * posed_rotation

which is exactly what `FigureScene.apply` composes back (`local = bind · delta`),
so the numbers are independent of Blender's internal bone axes — both rest and
posed rotations come out of the same glTF exporter. Bones whose delta is
(numerically) identity are omitted.

`mirror: true` swaps `_l`/`_r` bones and mirrors each quaternion across the
figure's sagittal (YZ) plane — the rig is left/right symmetric.
"""
import argparse
import json
import math
import os
import struct
import sys
import tempfile

import bpy

IDENTITY_EPS = 0.99999985  # |w| above this → < ~0.06° → treated as identity


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser()
    p.add_argument("--anim", required=True)
    p.add_argument("--spec", required=True)
    p.add_argument("--out", required=True)
    return p.parse_args(argv)


def read_glb_json(path):
    with open(path, "rb") as f:
        b = f.read()
    length = struct.unpack("<I", b[12:16])[0]
    return json.loads(b[20:20 + length])


def node_rotations(gltf):
    """name -> (x, y, z, w) parent-relative rotation for every named node."""
    out = {}
    for n in gltf["nodes"]:
        name = n.get("name")
        if not name:
            continue
        r = n.get("rotation", [0.0, 0.0, 0.0, 1.0])
        out[name] = tuple(float(v) for v in r)
    return out


def q_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
        aw * bw - ax * bx - ay * by - az * bz,
    )


def q_inv(q):
    x, y, z, w = q
    n = x * x + y * y + z * z + w * w
    return (-x / n, -y / n, -z / n, w / n)


def q_norm(q):
    x, y, z, w = q
    n = math.sqrt(x * x + y * y + z * z + w * w) or 1.0
    q = (x / n, y / n, z / n, w / n)
    return q if q[3] >= 0 else tuple(-v for v in q)


def mirror_name(name):
    if name.endswith("_l"):
        return name[:-2] + "_r"
    if name.endswith("_r"):
        return name[:-2] + "_l"
    return name


def mirror_quat(q):
    # Reflection across the YZ plane (x → −x): rotation (x, y, z, w) → (x, −y, −z, w).
    x, y, z, w = q
    return (x, -y, -z, w)


def export_current(path):
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        export_skins=True,
        export_animations=False,
        export_rest_position_armature=False,  # current pose, not rest
        export_current_frame=True,
        export_image_format="NONE",
        export_materials="NONE",
        export_apply=False,
        export_yup=True,
    )


def export_rest(path):
    bpy.ops.export_scene.gltf(
        filepath=path,
        export_format="GLB",
        export_skins=True,
        export_animations=False,
        export_rest_position_armature=True,
        export_image_format="NONE",
        export_materials="NONE",
        export_apply=False,
        export_yup=True,
    )


def main():
    args = parse_args()
    with open(args.spec) as f:
        spec = json.load(f)

    bpy.ops.wm.read_factory_settings(use_empty=True)
    bpy.ops.import_scene.gltf(filepath=args.anim)
    armatures = [o for o in bpy.data.objects if o.type == "ARMATURE"]
    if not armatures:
        sys.exit("no armature in " + args.anim)
    arm = armatures[0]
    actions = {a.name: a for a in bpy.data.actions}
    print("clips:", sorted(actions))

    tmp = tempfile.mkdtemp(prefix="kiki-poses-")
    rest_path = os.path.join(tmp, "rest.glb")
    export_rest(rest_path)
    rest = node_rotations(read_glb_json(rest_path))
    print("rest bones:", len(rest))

    if arm.animation_data is None:
        arm.animation_data_create()

    poses = []
    for entry in spec["poses"]:
        clip = entry["clip"]
        if clip not in actions:
            # Allow prefix / case-insensitive matches for convenience.
            cands = [n for n in actions if n.lower().startswith(clip.lower())]
            if len(cands) != 1:
                sys.exit(f"clip {clip!r} not found; candidates: {cands}")
            clip = cands[0]
        arm.animation_data.action = actions[clip]
        bpy.context.scene.frame_set(int(entry["frame"]))
        bpy.context.view_layer.update()
        posed_path = os.path.join(tmp, f"{entry['id']}.glb")
        export_current(posed_path)
        posed = node_rotations(read_glb_json(posed_path))

        deltas = {}
        for name, r in rest.items():
            if name not in posed:
                continue
            d = q_norm(q_mul(q_inv(r), posed[name]))
            if abs(d[3]) >= IDENTITY_EPS:
                continue
            deltas[name] = d
        if entry.get("mirror"):
            deltas = {mirror_name(n): mirror_quat(q) for n, q in deltas.items()}

        pose = {
            "id": entry["id"],
            "name": entry["name"],
            "category": entry["category"],
            "joints": {n: [round(v, 6) for v in q] for n, q in sorted(deltas.items())},
        }
        if "yaw" in entry:
            pose["yaw"] = float(entry["yaw"])
        poses.append(pose)
        print(f"{entry['id']:24s} {clip}@{entry['frame']}: {len(deltas)} bones")

    with open(args.out, "w") as f:
        json.dump({"version": 1, "poses": poses}, f, indent=1)
    print("wrote", args.out, len(poses), "poses")


if __name__ == "__main__":
    main()
