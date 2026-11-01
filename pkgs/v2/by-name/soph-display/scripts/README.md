# #80 bring-up harness

Everything needed to take the ported vendor VIP stack from `soph-display-load`
to pixels on HDMI. These are bench tools, not packaged outputs — build them
against the vendor middleware (`sophgo/cvi_mpi`) and copy to the badge.

| file | what it is |
|---|---|
| `mw-golden.sh` | the whole recipe, in order. Run this. |
| `dsiup.c` | replaces the vendor `sample_dsi`: `SET_DEV_CFG` / `SET_HS_SETTLE` / `ENABLE` on `/dev/cvi-mipi-tx`. Defaults to **2 lanes** — the D2/D3 physical pair is dead on badge #1, and 4-lane locks sync but shows nothing. |
| `pk.c` | `/dev/mem` peek/poke. `devmem` is not installed. The kernel refuses a register a driver has claimed unless it was booted with `iomem=relaxed` (typed at the boot prompt). |
| `lt-land1281.sh` | LT8912B 720p60, `hactive` = **1281**. 1280 shears 1.345 px/row. |
| `lt-dds.sh` | re-applies the bridge DDS block once video is already flowing — mainline does this last, in `lt8912_bridge_enable`. Worth ~2x on brightness stability. |
| `vofeed.c` | NV21 colour bars straight into the VO layer, skipping VDEC. The display half on its own, with no decoder in the picture. |
| `h264pump.sh` | the falsifiable A/B: runs the harness once with `BLVO_PUMP=0` and once with `1`. This is what measured 0/0/0 vs 453/986/1954. |
| `h264live.sh` | single live run for looking at: full display recipe FIRST, then one pump producer. Ordering matters -- the harness teardown clears `DISP_CFG` bit7 `TGEN_EN`. |
| `vpu-reset.sh` | recovers the VPU after a warm reboot. The codec island does not survive `systemctl reboot` — the WAVE core hangs at `PC=0x104` and takes H.264 down with it, and the driver cannot even be unloaded. Reloads the codec stack, whose `cv181x_vcodec` probe pulses `RST_H264C`/`RST_JPEG`/`RST_H265C`; with `iomem=relaxed` it pulses them through `pk` first, for a driver too stuck to unload. |
| `badge_landscape_vo.c` | the H.264 half: feeds an Annex-B stream to VDEC and pumps the decoded frames into VO. Needs the vendor middleware (`libsys`/`libvo`/`libvdec`) on the badge. `BLVO_PUMP=0` reproduces the stall (DecodedFrame pinned at 0), `BLVO_BIND=1` shows that `CVI_SYS_Bind` does not fix it. |

Order matters and is not obvious; `mw-golden.sh` encodes it. The two steps that
look optional and are not: `DISP_CFG` bit18 `SHRD_SEL` must be set *before* any
vendor `sclr_disp_*` call (otherwise every read-modify-write reads a consumed
shadow bank and writes zeros back), and the sync-polarity clear must come
*after* `dsiup` (which sets the bits for its LT9611 profile).

See [The HDMI link](https://badge.nix.vegas/hdmi.html) for each fault and its fix.
