# 数据手套项目交接文档

> 给下一个 AI / 新对话窗口用。最后更新：2026-06-18  
> 主项目路径：`/Users/yefengdim/jianyujiuzhou/test/`  
> Godot 4.6 | ESP32 BLE 手套 | 右手 FPS 手模驱动

---

## 1. 项目目标

将 **ESP32 数据手套**（5 路 flex + IMU）实时驱动 **Godot 右手模型**，用于 FPS 视角手臂/手掌可视化。

数据链：

```
ESP32 (BLE CSV) → glove_ble_receiver.py → UDP 127.0.0.1:12345 → Godot Main.gd
```

---

## 2. 关键文件路径

| 路径 | 用途 |
|------|------|
| `/Users/yefengdim/jianyujiuzhou/test/Main.gd` | **核心逻辑**（UDP、校准、IMU、手指弯曲） |
| `/Users/yefengdim/jianyujiuzhou/test/test.tscn` | 主场景（F5 运行） |
| `/Users/yefengdim/jianyujiuzhou/test/assets/scene.gltf` | **当前手模**（已替换旧 FpsArmsHigh.fbx） |
| `/Users/yefengdim/jianyujiuzhou/test/CALIBRATION_REFERENCE.txt` | 校准参数备份（简版） |
| `/Users/yefengdim/Documents/Arduino/5yu9/glove_ble_receiver.py` | BLE → UDP 桥接脚本 |
| `/Users/yefengdim/jianyujiuzhou/test/project.godot` | Godot 工程配置 |

诊断脚本（headless 用，非运行时必需）：

- `_gltf_main_verify.gd`、`_gltf_inspect.gd`、`_snap_diagnostic.gd`、`_v15_verify.gd` 等

---

## 3. 数据格式

UDP 每包 CSV，12 个字段：

```
flex0,flex1,flex2,flex3,flex4, qw,qx,qy,qz, amx,amy,amz
```

- `flex0~4`：拇指 / 食指 / 中指 / 无名指 / 小指（原始 ADC 值，越大越直）
- `qw,qx,qy,qz`：ICM 四元数（w 在前）
- `amx,amy,amz`：加速度

---

## 4. 运行方式

**终端 1 — BLE 桥接：**

```bash
cd ~/Documents/Arduino/5yu9
source .venv/bin/activate   # 如有 venv
python3 glove_ble_receiver.py
```

**终端 2 / Godot：**

- 打开 `/Users/yefengdim/jianyujiuzhou/test/`
- F5 运行 `test.tscn`

**快捷键：**

| 键 | 功能 |
|----|------|
| C | 校准伸直（记录 IMU 零位 + flex_rest） |
| F | 校准握拳（记录 flex_closed，可选） |
| R | 清除校准 |
| M | 安装微调（mount 预设循环） |
| P | 打印全部骨骼名 |
| T | 演示模式（无 BLE 时 +/- 调弯拢 0–100%） |
| +/- | 演示模式下调节弯拢幅度 |

校准文件：`user://glove_calibration_test.json`，版本号 `CALIBRATION_VERSION = 16`

**推荐流程：** R → 伸直 1–2 秒 → C → 测试弯拢/握拳

---

## 5. 零位与坐标系（已验证，勿随意改动）

**右手零位手势（按 C 时）：**

- 掌心朝下 → 世界 **-Y**
- 手指朝前 → 世界 **-Z**
- 拇指朝身体左侧 → 世界 **-X**

**传感器 → 手部映射（ICM 平贴右手背）：**

```gdscript
_enu_to_godot_basis()   = Basis((1,0,0), (0,0,-1), (0,1,0))
_sensor_to_hand_basis() = Basis((-1,0,0), (0,0,-1), (0,1,0))
# Sensor X→拇指(-X), Y→指尖(-Z), Z→手背(+Y)
```

**四元数链：**

```
q_aligned = mount * (q_enu * q_raw * q_sensor_to_hand.inverse())
q_display = rest_inv * q_aligned
方向修正 v11: Quaternion.from_euler(Vector3(+euler.z, -euler.y, +euler.x))
```

**手腕旋转：** `hand_model.quaternion = model_align * get_calibrated_quat()`  
旋转中心：掌心几何中心（mesh AABB 过滤后中心）

**IMU 动作对应（v11 已验证准确）：**

| 动作 | 修正分量 |
|------|----------|
| 抬指尖 | +euler.x（经 X↔Z 互换后） |
| 水平转手腕 | -euler.y |
| 翻掌 | +euler.z |

---

## 6. Flex 弯曲映射（v12+ 每指独立）

**默认伸直值（DEFAULT_FLEX_OPEN，按 C 后写入 flex_rest）：**

```
拇指 988 | 食指 907 | 中指 925 | 无名指 829 | 小指 961
```

**默认握拳值（可按 F 重录）：**

```
拇指 680 | 食指 422 | 中指 624 | 无名指 540 | 小指 535
```

**公式（校准后）：**

```
delta = flex_raw - flex_rest
bend  = clamp(-delta / (span * bend_range_ratio), 0, 1)
```

- 死区：`max(18, span * 0.06)` 每指独立
- `flex_bend_range_ratios = [1.0, 1.0, 0.68, 0.68, 0.80]`

---

## 7. 手模演进（重要背景）

### 7.1 旧模型 FpsArmsHigh.fbx（已弃用）

- 骨骼：`RightHandThumb1`…`4` 等
- **致命缺陷**：bone1（掌指节）极长 ~95mm，bone2/3 仅 **6mm / 1.5mm**
- 导致无论怎么调参，弯拢时关节挤成一团或指尖交叠
- `finger_side_curl_fans` 对食指几乎无效（fan 0→-1 指尖只动 0.3mm）

### 7.2 新模型 scene.gltf（当前，v16）

- 路径：`assets/scene.gltf`
- 右手专用 `.R` 命名，69 骨骼，1 个 skinned mesh
- **Deform 链**（驱动网格，每指 4 段）：

```
thumb/index/middle/ring/pinky_base.R → _01.R → _02.R → _03.R
```

- **不驱动 / 自动隐藏**：`*_Ctrl*`、`*_end_*`、`*_tip*`、`pulse.R`（前臂残段）
- 手腕：`hand.R_02`（前缀匹配 `hand.R`）
- MCP（掌指）：各指 `*_base.R`

**骨段长度示例（食指，米）：**

```
base 0.123 | 01 0.012 | 02 0.167 | 03 0.020
```

比旧模型合理得多；02 段为主弯段。

**Headless 验证已通过：**

- 五指链 4 段全部解析
- 链式权重按骨长自动归一化（每指不同）
- bend=0/0.5/1 指尖有位移

---

## 8. 手指弯曲逻辑（当前 v16）

### 核心函数

- `_build_finger_chains()` — 按 `_FINGER_DEFORM_CHAINS` 前缀匹配 deform 骨
- `_weights_from_bone_lengths()` — 运行时按骨长分配权重
- `_finger_spread_phase(bend)` — 展开 = bend 线性
- `_finger_curl_phase(bend)` — smoothstep 慢起步（`finger_curl_ease_power=2`）
- `_apply_finger_poses()` — 施加骨骼 pose

### MCP 合成顺序

```gdscript
# seg==0 (base/MCP): flex_rot * abduct_rot（先弯后展）
# seg>0: 仅 flexion
abduction *= lerpf(1.0, finger_abduct_curl_mix, curl_phase)  # 默认 0.55
```

### 当前参数（待手套实测微调）

```gdscript
finger_curl_deg = 95
finger_fist_splay_deg = [0, 12, 0, 15, 22]
finger_curl_ease_power = 2.0
finger_abduct_curl_mix = 0.55
finger_mcp_boost_max = 1.20
finger_column_blends = [0.35, -0.42, 0.58, 0.72, 0.82]
finger_curl_scales = [1.0, 1.0, 1.0, 0.96, 0.92]
```

食指在 `_finger_abduction_rad()` 里对自动检测符号**取反**（`sign = -sign`），否则推向中指。

### 弯曲目标

- 掌心 hub + 各指 MCP 列方向（`finger_column_blends`），非共用腕心
- 短骨段（< 8mm）继承上一节弯曲轴（`_MIN_CHILD_LEN_FOR_AXIS`）

---

## 9. 历史问题与尝试（避免重复踩坑）

| 阶段 | 现象 | 尝试 | 结果 |
|------|------|------|------|
| 握拳终点 | 中指/无名指 OK，食/小指调参后尚可 | `finger_fist_splay_deg` + 食指符号取反 | 终点 OK |
| 半弯过程 | 四指尖叠在一起 | power 曲线提前展开/延后弯拢 | **用户否定** |
| 两阶段阈值 | bend<28% 只展不弯 | `finger_spread_first_ratio` | 0.28 处 MCP 突变侧倾 |
| v14 MCP 只展不弯 | 消除侧倾 | MCP flex=0，权重堆 PIP | **关节挤成一团**（PIP 127°） |
| v15 骨长权重 | 恢复 MCP 主弯 | flex×abduct + smoothstep | 理论正确，但旧模型骨太短 |
| **v16 scene.gltf** | 换模型重绑 | deform 链 + 骨长权重 | headless OK，**待用户实机确认** |

**已证实结论：**

1. `finger_side_curl_fans` 对旧 FPS 食指模型无效，别再用
2. MCP 上 `abduct * flex`（旧顺序）会在弯拢起始时侧倾甩动
3. MCP flex=0 在骨长畸形的模型上必然挤关节
4. 半弯交叠的根本原因是骨段长度 + 共用弯曲面，不是单纯调曲线能修

---

## 10. 当前待办 / 未验证项

- [ ] **用户在 scene.gltf 上实机测试**：慢弯、握拳、半弯是否还交叠/侧倾
- [ ] 按新手套重新 **R → C**（v16 会忽略旧校准；若 F 录错握拳值会导致中指/无名指不弯）
- [ ] 微调 `finger_fist_splay_deg`、`finger_curl_deg`（若终点或过程偏差）
- [ ] 食指展开符号是否还需取反（新模型 auto sign 可能不同）
- [x] Git：`test/` 独立仓库 https://github.com/yefengdizhou-cloud/test.git，PR #1 已开
- [x] 无手套测试：运行时按 **T** 进入演示模式，**+/-** 调节弯拢 0–100%

**2026-06-19 修复：** 旧校准若 `flex_closed >= flex_rest`（尤其中指/无名指），`_flex_to_bend` 会把弯曲归零；已加加载校验 + 修正 `effective_span < 1` 误判。

---

## 11. Git / 仓库状态

```
仓库根：/Users/yefengdim/jianyujiuzhou/test/  （独立 Git 仓库）
远程：  https://github.com/yefengdizhou-cloud/test.git
分支：  feature/glove-scene-gltf（PR #1 → main）
父目录：/Users/yefengdim/jianyujiuzhou 仍可能有其他未跟踪子目录
```

建议：在 `test/` 仓库用 feature branch + PR；`HANDOFF_DATA_GLOVE.md` 随功能更新一并提交。

---

## 12. Headless 测试命令

```bash
/Applications/Godot.app/Contents/MacOS/Godot --headless \
  --path /Users/yefengdim/jianyujiuzhou/test \
  -s res://_gltf_main_verify.gd
```

---

## 13. 给下一个 AI 的操作守则

**可以改：**

- `finger_*` 弯拢/展开参数（小步调）
- `finger_fist_splay_deg`、`finger_column_blends`
- scene.gltf 相关骨骼前缀映射

**慎改 / 先问用户：**

- IMU 四元数链（v11 已验证）
- `get_calibrated_quat()` 里的 euler 修正
- `_enu_to_godot_basis` / `_sensor_to_hand_basis`

**不要做：**

- 回退到 FpsArmsHigh.fbx（骨段畸形）
- 再用 `finger_side_curl_fans` 或 power 曲线补丁
- 未经请求就 git commit / push

**调参优先级（若弯拢仍有问题）：**

1. 确认用的是 scene.gltf deform 链（非 Ctrl 骨）
2. 查骨长权重是否合理（控制台打印 `weight sets`）
3. 调 `finger_fist_splay_deg` 分离邻指
4. 调 `finger_curl_deg` / `finger_abduct_curl_mix`
5. 最后才考虑改弯曲时序逻辑

---

## 14. 版本时间线

| 版本 | 内容 |
|------|------|
| v11 | IMU 方向修正定稿 |
| v12 | 每指独立 flex_rest / flex_closed |
| v13 | 两阶段展开/弯拢（后发现问题） |
| v14 | MCP 只展不弯（导致关节挤压） |
| v15 | 骨长权重 + flex×abduct（旧模型上仍不理想） |
| **v16** | **scene.gltf 手模 + deform 链重绑 + 骨长自动权重** |

---

## 15. 对话上下文索引

完整历史对话 transcript：

```
/Users/yefengdim/.cursor/projects/empty-window/agent-transcripts/5ceab0fe-e9ec-4930-a926-abc00bd723e1/5ceab0fe-e9ec-4930-a926-abc00bd723e1.jsonl
```

可先搜关键词：`finger_splay`、`scene.gltf`、`CALIBRATION_VERSION`、`半弯`、`侧倾`。
