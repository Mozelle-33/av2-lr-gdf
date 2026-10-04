// Verilator testbench for gdf_selftest: runs the ROM stream for N loops and
// prints the snapshot (the same record the FPGA returns over JTAG).
// Usage: Vgdf_selftest [loops=2] [inject=0]   (run in the ROM directory)
#include <cstdint>
#include <cstdio>
#include <cstdlib>

#include "Vgdf_selftest.h"
#include "verilated.h"

int main(int argc, char** argv) {
  Verilated::commandArgs(argc, argv);
  const int loops = argc > 1 ? atoi(argv[1]) : 2;
  const int inject = argc > 2 ? atoi(argv[2]) : 0;
  // reset for eight cycles, then run until the requested number of loops
  Vgdf_selftest* t = new Vgdf_selftest;
  t->rst_in = 1;
  t->inject = inject;
  auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
  for (int i = 0; i < 8; i++) tick();
  t->rst_in = 0;
  uint64_t cyc = 0;
  uint32_t last = 0;
  while (cyc < 200000000ull) {
    tick();
    cyc++;
    // snapshot word 6 = loop counter: a new value means a finished loop
    const uint32_t lp = t->snapshot[6];
    if (lp != last) {
      last = lp;
      const uint32_t w7 = t->snapshot[7];
      printf("loop %u: magic %04x ver %02x flags %02x seg_ok %u seg_bad %u groups %u "
             "run_cycles %u loop_cycles %u bad_total %u (cycle %llu)\n",
             lp, w7 >> 16, (w7 >> 8) & 0xFF, w7 & 0xFF, t->snapshot[5], t->snapshot[4],
             t->snapshot[3], t->snapshot[2], t->snapshot[1], t->snapshot[0],
             (unsigned long long)cyc);
      fflush(stdout);
      if ((int)lp >= loops) break;
    }
  }
  delete t;
  return 0;
}
