# DataGlove Test — Godot 手套工程

Godot 4 数据手套可视化测试项目，使用 `assets/scene.gltf` 右手手模与 v16 手指绑定。

## 快速开始

1. 用 Godot 4 打开本目录（`project.godot`）
2. 运行 `test.tscn`（F5）
3. 校准：按 **R** 进入校准，按 **C** 确认

## 手模与绑定

- 模型：`assets/scene.gltf`（右手 rig，已替换 `FpsArmsHigh.fbx`）
- 手腕：`hand.R_02`
- 手指链：`{finger}_base.R` → `{finger}_01.R` → `{finger}_02.R` → `{finger}_03.R`
- 校准参数备份见 `CALIBRATION_REFERENCE.txt`

## 开发分支

功能开发请基于 `feature/glove-scene-gltf` 分支，通过 Pull Request 合并到 `main`。
