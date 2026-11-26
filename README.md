# Project Report #2 — FIR ALU

这一阶段实现报告 1 中的运算数据通路，不包含系数存储、输入历史、异步 FIFO 或发射状态机。`rtl/fir_alu.v` 是 Verilog-2005 RTL；`tb/tb_fir_alu.v` 是自检测试平台。

## 接口和周期

- `clk` 接 FIR 的核心时钟 `clk2`；`rstn` 接核心域的低有效复位。ALU 不负责跨域或复位同步。
- 每个 `valid_in=1` 的上升沿接收一组 16 对 Q1.15 操作数。第 `j` 路对应 `x_in[16*j +: 16]` 和 `b_in[16*j +: 16]`，每路独立按 16-bit 有符号数解释。第 `g` 组对应 taps `16*g` 到 `16*g+15`。
- 同一样本的 `group_in` 必须按 0、1、2、3 顺序发出；允许无效拍，但不同样本的组不能交错。没有反压。每组使用 16 个 32-bit 乘积、四级加法树（33/34/35/36 bit），随后用 38-bit 累加器求完整结果，不截掉中间小数位。
- 若某组在边沿 `E` 输入，其组和在 `E+4` 锁存，`E+5` 更新累加器。对 tag 3，`E+5` 同时锁存总和，`E+6` 执行最近偶数舍入与饱和，并输出 Q7.9 `dout` 和一周期的 `valid_out`。无效拍保持上次的 `dout`。
- 沿用报告 1 的系统调度：每个样本先用一拍更新历史，再用四拍发射，因此每五个核心周期一个输出。这里的 **6 拍**从 ALU 接收最后一组起算；报告 1 的 **10 拍**从完整 FIR 的 FIFO 取样起算。500 MHz（2 ns）是目标，不是已验证的物理时序。

## 运行

在仓库根目录（和 `Makefile` 同一层）执行：

```sh
make test                       # Icarus：75 个定向用例 + 10,000 个随机输出
make test SEED=1234abcd         # 换随机种子，十六进制、不加 0x
make lint                       # Icarus Verilog-2005 + Verilator
make vcd RANDOM_SAMPLES=128     # 短波形测试，输出 build/fir_alu.vcd
```

测试平台用 64-bit 标量乘积求和和独立的舍入实现作参考，不依赖 RTL 内部信号，后续可以复用来比对保留同样接口的门级网表。定向用例覆盖 64 个 tap、正负半 LSB、极值、饱和和相消；随机阶段覆盖报告 1 的五拍调度、连续发射和随机空拍。另外检查复位是否取消待输出的结果，以及每个输出的有效周期和顺序。

`vcd` 生成 RTL 调试波形；`make activity` 另跑固定系数、滑动输入窗口、每 5 拍发射 4 组的功耗测试激励，预热 64 个样本后生成 `build/activity/fir_alu.vcd`。本地生成的 VCD 仍是 RTL 波形，不能当成课程网表的功耗数据。

## 课程机：综合、门级仿真和 PrimeTime

需要课程 Lab 3/4 的 `dc_shell`、`pt_shell`、QuestaSim（`vlib`、`vlog`、`vsim`），以及与目标 `.db` 对应的标准单元 Verilog 功能模型。`flow/run_course.sh` 默认采用 Lab 3 示例的 IBM typical 库（1.2 V，25 °C）。如本学期目录或库不同，用 `TARGET_DB` 指定完整路径，并从 Lab 4 `runsim.do` 取对应的 Verilog 模型路径。多个模型使用冒号分隔，不需要把受许可的库复制进项目或报告。

在实验机的 Terminal 登录 GitHub（需要能访问该私有仓库），并按课程 Lab 3/4 的说明加载 EDA 环境，然后运行：

```sh
git clone git@github.com:hexasix/fir-report2.git
cd fir-report2
make course SDF_SIM=1
```

SSH clone 需要实验机上的 SSH 认证；也可以通过 GitHub HTTPS 认证后克隆。脚本默认使用讲义中的 IBM `.db` 和 `ibm13rflpvt.v`，无需另传库文件。若课程环境使用了不同库路径，可传入 `TARGET_DB` 和 `CELL_MODELS`（多个 Verilog 模型用冒号分隔）。

默认输出在 `build/course_2.0ns_baseline/`。脚本按顺序运行 Design Compiler、带 pin-level scoreboard 的零延迟门级仿真、生成稳态门级 VCD、PrimeTime STA 和平均功耗分析。默认 2 ns 理想时钟、0.2 ns 最大输入／输出延迟预算；不含布线提取或时钟树。零延迟波形不包含由实际路径延迟产生的毛刺。可选使用 `SDF_SIM=1` 在功耗分析之后另跑 SDF 门级验证，不能用零延迟功能通过替代时序签核。

如果综合已经成功、只需重试门级仿真和 PrimeTime，且 ALU RTL、综合目标和库没有变，可以保留旧结果并运行：

```sh
make course REUSE_DC_FROM=build/course_2.0ns_baseline SDF_SIM=1
```

默认写入 `build/course_2.0ns_baseline_gate_retry/`。零延迟仿真用 `vlog +delay_mode_zero` 编译网表和标准单元模型，SDF 仿真另建工作库，不使用这个选项。

## 流水线优化候选

`COMPILE_PROFILE=pipeline` 启用三个乘积级（分块部分积、交叉项相加、合并）和两级 36 位末级归约。端口和定点结果不变，连续发射间隔不变；最后一组到输出从 6 拍增至 9 拍，完整 FIR 的 FIFO 取样到输出从 10 拍增至 13 拍。尚无此版本的课程库时序或功耗结果。

```sh
make test lint COMPILE_PROFILE=pipeline
make course COMPILE_PROFILE=pipeline TIMING_ONLY=1
```

先在 `build/course_2.0ns_pipeline/pt_summary.rpt` 看时序。这一步仅综合和 STA，不采集 VCD；基线目录不变。要对同一优化网表继续做门级功能验证和功耗分析，可以复用它：

```sh
make course COMPILE_PROFILE=pipeline REUSE_DC_FROM=build/course_2.0ns_pipeline
```

| 文件 | 看什么 |
|---|---|
| `fir_alu.nl.v`, `fir_alu.sdf`, `fir_alu.sdc` | 门级网表、延迟、约束 |
| `gate.log`, `activity.log`, `fir_alu.vcd` | 门级验证与门级活动波形 |
| `dc_area.rpt`, `dc_constraints.rpt` | 标准单元面积、综合约束违规 |
| `pt_setup.rpt`, `pt_hold.rpt`, `pt_summary.rpt`, `pt_check.rpt` | setup/hold 裕量、关键路径、约束完整性 |
| `pt_activity.rpt`, `pt_power.rpt` | 活动标注覆盖率、内部／开关／漏电功耗 |

基线跑完后，保留结果，用 `COMPILE_PROFILE=area` 在相同频率、同一库及同一激励下比较面积优化效果。若 2 ns 不满足，用 `CLOCK_NS` 改目标周期进行约束扫描，并明确区分目标频率和实测裕量。每次运行需使用新的 `RUN_DIR` 或不同默认目录，避免覆盖结果。可用 `POWER_SAMPLES=128` 快速试跑流程，但正式报告应使用默认 10,000 个稳态样本，并检查 VCD 标注覆盖率。
