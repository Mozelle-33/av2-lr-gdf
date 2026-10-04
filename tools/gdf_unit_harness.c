/*
 * Stress-test vectors for the GDF golden model / RTL, produced by AVM's own
 * C reference kernels (gdf_block.c) linked from libavm.a.
 *
 * Writes records in the same "GDFU" format as the instrumented decoder
 * (see avm/av2/common/tcas_instr.h) for random, extreme and structured
 * input windows over all table sets, bit depths and unit sizes.
 *
 * Build (WSL):
 *   gcc -O2 -o gdf_unit_harness tools/gdf_unit_harness.c \
 *       /root/build/avm-rel/libavm.a -lm -lpthread
 * Run:  ./gdf_unit_harness <out.bin> <num_units> [seed]
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* C kernels of the GDF in the AVM library (av2/common), called directly */
void gdf_set_lap_and_cls_unit_c(const int i_min, const int i_max,
                                const int j_min, const int j_max,
                                const uint16_t *rec_pnt, const int rec_stride,
                                const int bit_depth, uint16_t *const *gdf_lap_y,
                                const int gdf_lap_y_stride, uint32_t *gdf_cls_y,
                                const int gdf_cls_y_stride);
void gdf_inference_unit_c(const int i_min, const int i_max, const int j_min,
                          const int j_max, const int qp_idx,
                          const uint16_t *rec_pnt, const int rec_stride,
                          uint16_t *const *gdf_lap_pnt,
                          const int gdf_lap_stride, const uint32_t *gdf_cls_pnt,
                          const int gdf_cls_stride, int16_t *err_pnt,
                          const int err_stride, const int pxl_shift,
                          const int ref_dst_idx);
void gdf_compensation_unit_c(uint16_t *rec_pnt, const int rec_stride,
                             int16_t *err_pnt, const int err_stride,
                             const int err_shift, const int scale,
                             const int pxl_max, const int blk_height,
                             const int blk_width);

/* one unit of up to 64 x 64 samples with its apron of six; buffer strides */
#define UNIT 64
#define APRON 6
#define LAP_STRIDE (UNIT + 16)
#define CLS_STRIDE ((UNIT >> 1) + 16)
#define ERR_STRIDE (UNIT + 16)
#define WIN_STRIDE (UNIT + 2 * APRON + 32)

static uint64_t rng_state = 88172645463325252ull;
static uint32_t rnd(void) {
  rng_state ^= rng_state << 13;
  rng_state ^= rng_state >> 7;
  rng_state ^= rng_state << 17;
  return (uint32_t)(rng_state >> 16);
}
static int rnd_range(int lo, int hi) { return lo + (int)(rnd() % (uint32_t)(hi - lo + 1)); }

static void fill_window(uint16_t *win, int rows, int cols, int maxv, int pattern) {
  const int base = rnd_range(0, maxv);
  const int amp = rnd_range(1, maxv);
  const int dir = rnd_range(0, 3);
  for (int r = 0; r < rows; r++) {
    for (int c = 0; c < cols; c++) {
      int v;
      switch (pattern) {
        case 0: v = rnd_range(0, maxv); break;                       // uniform
        case 1: v = (rnd() & 1) ? maxv : 0; break;                   // salt/pepper
        case 2: v = base + (r * 3 - c * 2) + rnd_range(-4, 4); break;  // ramp + noise
        case 3: {                                                    // step edge
          const int t = dir == 0 ? c : dir == 1 ? r : dir == 2 ? r + c : r - c;
          v = (t > rows / 2 ? base : base - amp) + rnd_range(-2, 2);
          break;
        }
        default: v = ((r + c) & 1) ? maxv : 0; break;               // checkerboard
      }
      if (v < 0) v = 0;
      if (v > maxv) v = maxv;
      win[r * WIN_STRIDE + c] = (uint16_t)v;
    }
  }
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: %s <out.bin> <num_units> [seed] [stripe]\n", argv[0]);
    return 1;
  }
  FILE *f = fopen(argv[1], "wb");
  if (!f) return 1;
  const int n = atoi(argv[2]);
  if (argc > 3) rng_state ^= (uint64_t)strtoull(argv[3], NULL, 10) * 0x9E3779B97F4A7C15ull;
  // "stripe" mode: windows obey AV2 7.20.2 (only 2 lines outside the stripe:
  // rows -6..-3 repeat row -2, rows h+2..h+5 repeat row h+1) and bit depths
  // are restricted to the Main profile (8/10 bit) - the RTL test set.
  const int stripe = argc > 4 && !strcmp(argv[4], "stripe");

  static uint16_t win[(UNIT + 2 * APRON + 8) * WIN_STRIDE];
  static uint16_t lap_mem[4][((UNIT >> 1) + 2) * LAP_STRIDE];
  static uint32_t cls[((UNIT >> 1) + 2) * CLS_STRIDE];
  static int16_t err[UNIT * ERR_STRIDE];
  static uint16_t lr[UNIT * UNIT], out[UNIT * UNIT];
  uint16_t *lap[4] = { lap_mem[0], lap_mem[1], lap_mem[2], lap_mem[3] };
  const int bitdepths[3] = { 8, 10, 12 };

  for (int t = 0; t < n; t++) {
    const int pattern = t % 5;
    const int bd = bitdepths[rnd_range(0, stripe ? 1 : 2)];
    const int h = (t % 7 == 0) ? 2 * rnd_range(1, 32) : (rnd() & 1 ? 64 : 56);
    const int w = (t % 11 == 0) ? 2 * rnd_range(1, 32) : 64;
    const int qp_idx = rnd_range(0, 5);
    const int ref_dst_idx = rnd_range(0, 5);
    const int scale_val = rnd_range(1, 4);
    const int pxl_shift = 10 - (bd < 10 ? bd : 10);
    const int err_shift = 2 + 10 - bd;
    const int in_max = (1 << (bd < 10 ? bd : 10)) - 1;  // guided frame <= 10 bit
    const int pxl_max = (1 << bd) - 1;

    memset(win, 0, sizeof(win));
    fill_window(win, h + 2 * APRON, w + 2 * APRON, in_max, pattern);
    if (stripe) {
      for (int r = 0; r < APRON - 2; r++)
        memcpy(win + r * WIN_STRIDE, win + (APRON - 2) * WIN_STRIDE, 2 * WIN_STRIDE);
      for (int r = APRON + h + 2; r < h + 2 * APRON; r++)
        memcpy(win + r * WIN_STRIDE, win + (APRON + h + 1) * WIN_STRIDE, 2 * WIN_STRIDE);
    }
    const uint16_t *base = win + APRON * WIN_STRIDE + APRON;
    gdf_set_lap_and_cls_unit_c(0, h, 0, w, base - WIN_STRIDE - 1, WIN_STRIDE, bd,
                               lap, LAP_STRIDE, cls, CLS_STRIDE);
    gdf_inference_unit_c(0, h, 0, w, qp_idx, base, WIN_STRIDE, lap, LAP_STRIDE,
                         cls, CLS_STRIDE, err, ERR_STRIDE, pxl_shift, ref_dst_idx);
    for (int i = 0; i < h * w; i++) lr[i] = (uint16_t)rnd_range(0, pxl_max);
    memcpy(out, lr, sizeof(uint16_t) * h * w);
    gdf_compensation_unit_c(out, w, err, ERR_STRIDE, err_shift, scale_val, pxl_max, h, w);

    const int32_t hdr[16] = { t, pattern, 0, 0, bd, 0, h, 0, w, qp_idx,
                              ref_dst_idx, pxl_shift, scale_val, err_shift, 0, APRON };
    fwrite("GDFU", 1, 4, f);
    fwrite(hdr, sizeof(hdr), 1, f);
    for (int r = 0; r < h + 2 * APRON; r++) fwrite(win + r * WIN_STRIDE, 2, w + 2 * APRON, f);
    for (int r = 0; r < h; r++) fwrite(err + r * ERR_STRIDE, 2, w, f);
    fwrite(lr, 2, (size_t)h * w, f);
    fwrite(out, 2, (size_t)h * w, f);
  }
  fclose(f);
  fprintf(stderr, "wrote %d units to %s\n", n, argv[1]);
  return 0;
}
