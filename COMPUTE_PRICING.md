# Compute Price Analysis

_Last updated: 2026-05-28_

Cost analysis for the MCCFR training infrastructure. Goal: cut the monthly
burn while keeping enough headroom for 1B–3B-iter parallel-RBM runs.

## Workload profile (measured)

From the v5 1B-iter run and the in-progress v6 ε ablations on the current
Hostkey EPYC 9354 box:

| Resource    | Observed peak            | Notes                                                   |
|-------------|--------------------------|---------------------------------------------------------|
| CPU         | 32 cores @ 100% (phase 2)| Bandwidth-bound past 32 threads; SMT gave ~no gain      |
| Single-core | ~400 iter/sec (phase 1)  | Phase-1 cluster discovery is serial — hard bottleneck   |
| RAM         | 225 GB (1B run)          | Scales ~linearly with info-set count                    |
| Disk        | 1.7 TB (1B, pre-cleanup) | ~8.5 TB linear extrapolation for a 5B run               |
| Wall (1B)   | ~7 days                  | Phase 1 ≈ 3.5 h; rest is phase-2 + Slumbot eval         |

**Implication:** the workload needs **32 cores, ~256–384 GB RAM, ~4 TB NVMe**
for 1B-class runs. The current 755 GB / 3.5 TB box is over-provisioned on RAM
(~3× headroom) — that's where the money is being wasted.

A bigger box does **not** help much: phase 1 is serial (single-core bound) and
phase 2 is memory-bandwidth bound at 32 threads. Right-sizing down is the win.

## Current spend

- **Hostkey EPYC 9354**, 755 GB RAM, 3.5 TB NVMe, ~$1.96/hr ≈ **~$1,100–1,400/mo**.

## Provider comparison (2026-05-28)

| Provider / SKU                  | CPU                | RAM   | NVMe          | Monthly      | Setup fee   | Notes |
|---------------------------------|--------------------|-------|---------------|--------------|-------------|-------|
| **Hostkey (current)**           | EPYC 9354 (32c)    | 755GB | 3.5TB         | ~$1,100      | paid        | Over-provisioned RAM |
| Hostkey custom (Vardan quote)   | EPYC 9354 (32c)    | 384GB | 7.68+3.84TB   | **$1,338**   | —           | *More* than current, custom-build markup |
| Hostkey custom (Vardan quote)   | EPYC 9354 (32c)    | 256GB | 7.68+3.84TB   | **$1,094**   | —           | ~Same as current; no real saving |
| **Hetzner AX162-R (FI)**        | EPYC 9454P (48c)   | 256GB | 2×1.92TB      | **$285** (€266)| **$1,108** (€1,033) | Cheapest recurring; 48c is an upgrade; setup fee is the catch |
| OVH Scale-a2                    | EPYC 9254 (24c)    | 128GB | NVMe          | $553         | —           | Too few cores, too little RAM |
| Latitude.sh rs4.metal.large     | EPYC 9354P (32c)   | 768GB | 16.96TB       | $2,351       | —           | Massively over-spec, too expensive |

### Caveats discovered during research

- **Hostkey's "from €299/mo" banner is marketing.** The 768GB / 7.68TB spec
  shown next to it is hero text, not the included config — RAM and storage are
  priced as add-ons. The real cost of that config is close to Vardan's
  $1,094–1,338 custom quote. Do not treat €299 as a real 768GB price.
- **Hetzner charges a one-off setup fee (~€1,033 on AX162-R-FI)** on top of the
  monthly. Easy to miss; it changes the year-1 math materially.
- **Hetzner raised prices ~17% on 2026-04-01.** Watch for further hikes
  (community price tracker: hetzexit.org).

## Cost projection: Hostkey vs Hetzner AX162-R

| | Year 1 total | Year 2+ | One-off setup |
|---|---|---|---|
| Hostkey (current)   | ~$13,200 | ~$13,200 | $0 (paid) |
| Hetzner AX162-R     | ~$4,528  | ~$3,420  | $1,108    |
| **Savings vs Hostkey** | **~$8,700** | **~$9,800/yr** | — |

Setup-fee payback period ≈ **6 weeks** of running. Beyond ~2 months of continued
training, Hetzner wins by ~$815/mo.

## Options

1. **Stay on current Hostkey** — zero risk, zero migration, but the
   ~$1,100/mo bleed continues. Fine if the paper ships within a few weeks.
2. **Hostkey re-spec (Vardan)** — saves at most ~$6/mo (256GB) or costs *more*
   (384GB). Not worth the effort.
3. **Migrate to Hetzner AX162-R** — eat the ~$1,108 setup fee + a few days of
   dual-running, then save ~$815/mo. Best long-run economics; the 48-core
   9454P is a modest CPU upgrade. **Recommended if training continues > ~2 months.**

## Migration sequencing (if option 3)

1. Drop `run_500M_t32_eps50_v6` from the Hostkey queue (saves unspent compute).
2. Let the in-flight ε=20 run finish + Slumbot-eval on Hostkey.
3. Provision Hetzner AX162-R; rebuild the Rust binary there (toolchain + rsync
   of `rust/rbm_mccfr`).
4. Re-stand-up the chainer + auto-harvest cron pointed at the new host.
5. Re-queue ε=50 (and any larger runs) on Hetzner.
6. Decommission the Hostkey box once results are confirmed mirrored to git.

## Not yet quoted (candidates if more shopping wanted)

- Leaseweb, DataPacket, Vultr Bare Metal, ip-projects.de, Unihost — some
  advertise no setup fee, which would beat Hetzner's year-1 math.

## Sources

- Hetzner AX162-R: https://www.hetzner.com/dedicated-rootserver/ax162-r/
- Hetzner AX162-R-FI price (€266/mo + €1,033 setup): https://looking.house/companies/hetzner-com/dedicated-servers/ax162-r-fi
- Hetzner 2026-04-01 price adjustment: https://www.hetzner.com/pressroom/statement-price-adjustment/
- Hetzner price tracker / alternatives: https://hetzexit.org/
- Hostkey 4th-gen EPYC SKUs: https://hostkey.com/dedicated-servers/4th-gen-amd-intel/
- OVH Scale: https://www.ovhcloud.com/en/bare-metal/scale/
- Latitude.sh pricing: https://www.latitude.sh/pricing
