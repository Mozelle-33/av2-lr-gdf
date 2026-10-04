# Joint loop-restoration and guided-detail-filter stage for AV2

RTL, test benches, bit-exact models, vector tools and flow scripts of the
hardware stage described in

> Y. Guo, "A Joint Loop-Restoration and Guided-Detail-Filter Architecture for AV2."

The stage implements, bit-exactly with the AV2 reference decoder (AVM 1.0.0),
the last in-loop filter stage of AV2 for 8- and 10-bit 4:2:0 video: the luma
loop restoration (PC-Wiener and Wiener-NS), the chroma loop restoration
(cross-component Wiener-NS) and the guided detail filter (GDF).

## Contents

| Path | Contents |
|---|---|
| `rtl/gdf_core.v` | The stage (`gdf_core`, with the chroma unit `gdf_lrc`). Parameters: `VS` column scan, `PCW`/`LR` luma LR on the shared front end, `CH` chroma LR, `FIP` fast inner product (FPGA), `MSTG` pipeline (1: ASIC, 2: FPGA), `MACF IDXF LA` ablation variants, `NB GC` samples per cycle |
| `rtl/gdf_selftest.v` | On-chip self-test: replays segments from block ROM and compares CRC-32 signatures |
| `rtl/pcw_class.hex`, `rtl/pcw_sel.hex` | Class ROM and filter-selector ROM of the luma LR (from the normative tables, `tools/make_pcw_rom.py`) |
| `tb/` | Verilator test benches (`tb_gdf.cpp`: vector replay with bit-exact checks; `tb_selftest.cpp`) |
| `analysis/` | Bit-exact Python models (`gdf_golden.py`, `pcw_golden.py`, `lr_golden.py`, `lrc_golden.py`), dump readers, coverage and table analyses |
| `tools/` | Test-vector generators from decoder dumps (units, full-width stripes, chroma), stress-vector generators, ROM builders |
| `scripts/` | Build, decode and regression scripts (`verify_*.sh`) |
| `asic/` | Yosys synthesis of all configurations; `asic/pnr`: OpenROAD place and route with memory macros, sign-off at three corners, gate-level simulation and power; `asic/macros`: macro generator (bsg_fakeram + CACTI) |
| `fpga/` | Vivado out-of-context builds, SAIF-based power, self-test bitstream scripts |
| `patches/avm_v1.0.0_tcas_instr.patch` | Instrumentation of the AVM 1.0.0 decoder (dumps of every GDF unit, LR stripe and chroma stripe; the decoded video is unchanged) |
| `vectors/` | Synthetic stress vectors (GDF, luma LR, chroma LR) |

## Interface of `gdf_core` (column scan, `VS = 1`)

A segment is a section of a stripe: `seg_h` rows (up to 64) and `seg_nch`
strips of four luma columns (up to 4096 columns). Pass `c` reads strip `c`
(picture columns `4c-6 .. 4c-3`) top to bottom, one word per cycle:

* `in_data`: a row pair of 2 x 4 luma samples (10 bit each);
* `in_c_data`: one row of two columns of U and V (and an extra row in the
  first and last cycle of a pass);
* side bits of the output group `c-3`: `in_tskip` (transform-skip flag of a
  4x4 block), `in_gdf` (GDF on in its block), `in_lr` (luma LR on,
  coefficient bank), `in_c_lr` (chroma LR on and bank, U and V).

Outputs: `out_y` (eight restored luma samples of band `out_band`, group
`out_group`), `out_c_y` (four restored chroma samples), and for test
`out_err`, `out_corr`, `out_pcw`. Configuration writes (`cfg_we`, `cfg_addr`,
`cfg_wdata`) load the GDF table set, the mode, the PC-Wiener `Q` table, the
luma coefficient banks and the chroma taps; the address map is in the header
of `rtl/gdf_core.v`.

## Reproducing the results

The flows run under Linux (developed in WSL, Ubuntu 22.04) with Verilator,
Yosys 0.44, OpenROAD (with the OpenROAD-flow-scripts Nangate45 platform),
Python 3 with NumPy, and Vivado for the FPGA part. Paths in the scripts
(`/mnt/g/AV2` for this tree, `/root/work` for outputs, `/root/build` for the
decoder builds) are those of the development machine.

1. Reference decoder: check out AVM `v1.0.0`, apply
   `patches/avm_v1.0.0_tcas_instr.patch`, build a release decoder and an
   instrumented one (`-DCMAKE_C_FLAGS=-DTCAS_INSTR=1`), see
   `scripts/build_avm.sh`. The normative GDF tables of the AV2 specification
   attachments go to `analysis/gdf_tables/`.
2. Bitstreams and dumps: `scripts/encode_*.sh`, `scripts/decode_*.sh` (the test
   sequences are not redistributed here).
3. RTL regressions: `scripts/verify_final.sh` (all filters and pipelines),
   `verify_4k.sh`, `verify_wide_ch.sh` (complete stage on full-width stripes
   with chroma), `verify_gdfoff.sh` (GDF block switch), `verify_lr_stress.sh`,
   `verify_ablation.sh`, `verify_scal.sh`.
   The stress vectors in `vectors/` need no decoder:
   `VS=1 bash scripts/sim.sh vectors/gdf_stress.vec`, and for the LR sets
   `python3 tools/make_lr_vectors.py lr.vec vectors/lr_stress.lrdump` and
   `VS=1 PCW=1 LR=1 CH=1 MAXCH=256 AW=8 bash scripts/sim.sh <file.vec>`.
4. ASIC: `asic/run_all_r4.sh` (synthesis of all configurations),
   `asic/pnr/run_pnr_mac.sh` and `asic/pnr/run_post_mac.sh` (layout with
   macros, hold ECO, sign-off, gate-level simulation and power).
5. FPGA: `fpga/ooc/run_r4_ooc.ps1`, `fpga/power/run_power_joint.ps1`,
   `fpga/selftest/build.tcl`.

## License

Apache License 2.0 (`LICENSE`); `NOTICE` lists the material derived from
third-party works. The AVM reference software, bsg_fakeram, CACTI, the cell
libraries and the tools are third-party works under their own licenses and are
not part of this repository.
