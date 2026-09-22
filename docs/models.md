---
sidebar_position: 9
---

# 3D model conversion

The app reads 3DS, DAE, FBX, GLB, glTF, OBJ, PLY, STL, USDA, USDC, and USDZ. It writes FBX, GLB, PLY, STL, and USDZ on the routes below. It bundles its model helper. End users need no other converter or network connection.

## Formats and settings

| Input | Direct outputs |
| --- | --- |
| 3DS, DAE, glTF | FBX, GLB, PLY, STL |
| FBX | GLB, PLY, STL |
| GLB | FBX, PLY, STL |
| OBJ | FBX, GLB, PLY, STL, USDZ |
| PLY | FBX, GLB, STL, USDZ |
| STL | FBX, GLB, PLY, USDZ |
| USDA, USDC | PLY, STL, USDZ |
| USDZ | PLY, STL |

The route planner can connect other outputs through PLY or GLB. For example, DAE-to-USDZ uses PLY. An intermediate format limits which model features can survive that route.

Settings select binary or text PLY/STL output. Another setting embeds textures in GLB and FBX. All three toggles currently default to on. The detailed default-setting comparison is still in progress.

With texture embedding off, GLB and FBX refer to a generated folder beside the model. PLY also uses a separate folder when it has a texture reference. Keep this folder with the model when moving or sharing it. USDZ includes its textures. STL stores a triangle surface and cannot keep materials or textures.

The app resolves companion files beside the original source. This also works when automatic conversion reads a retained snapshot after a rename. Missing or out-of-folder Assimp resources fail before publication. Native USD file access is restricted by the helper process profile. Existing outputs and resource folders are never overwritten.

Automatic conversion records the generated texture files and their hashes. Undo refuses a changed texture. It moves unmodified generated textures beside the retained converted copy, then restores the original filename and bytes. Original companion files remain in place. The journal can restore a generated texture folder after an interrupted move. Ambiguous file states still need review.

## Checks and limits

The helper reads its output back. It compares triangle count, world positions, transforms, and winding. It allows position differences up to 0.00002 times the largest absolute source coordinate, with a minimum scale of one. This check covers the surface, not complete material or animation fidelity.

Each input or companion file has a 128 MiB limit. Resources have a combined 512 MiB limit and a 2,048-file limit. The surface check permits one million triangles, 100,000 nodes, and a node depth of 256. Decoded textures have a 32-million-pixel limit. A conversion has a two-minute process limit. Model data is held in memory; these file limits are not a hard heap limit.

Point clouds, line-only models, advanced materials, animation, skinning, USD composition, and unusual texture formats still need broader coverage. Native USD behavior also needs verification on macOS 14. These open checks mean the current format coverage is not full model-feature parity.

## Build and test

On an Apple Silicon Mac with Xcode, Python 3.12 or later, and CMake:

```sh
python3 tools/build-models.py
python3 tools/check-models.py
swift test
python3 tools/build-app.py
python3 tools/check-app.py
```

The helper uses static Assimp 6.0.5 and Draco 1.5.7. ModelIO and SceneKit supply the native USD path. Only required Assimp readers and writers are built. Source checksums, build options, and upstream notices are retained. A small upstream PLY patch fixes its UV and color declarations. The original adapter also retains the root node under a new parent because the FBX writer otherwise drops that root's transform.

The check generates original tetrahedra, textures, a transformed scene, and source files for all eleven inputs. It covers all 39 direct routes. Independent checks read PLY and STL data, GLB texture data, and USDZ archives. A pinned development-only ufbx reader checks FBX world positions and embedded or external texture bytes. The Swift check covers publication to another folder, option flow, automatic conversion, changed-texture refusal, Undo, and interrupted resource moves.

`python3 tools/check-models.py --performance` measures three OBJ-to-GLB runs for an original grid with 80,000 triangles. The 2,279,109-byte source becomes a 1,446,016-byte GLB. For the packaged helper on the development Mac, median time is 0.19 seconds and median peak resident memory is 71,237,632 bytes. These warm runs follow the functional checks, with no other build or check jobs running. This includes the helper's output check. It excludes the app and other helpers. See `research/model-performance.json` for the samples and binary hash.
