# Executive summary: delivery performance and customer reviews

**Scope.** 99,441 orders placed on the Olist marketplace (Brazil), Sep-2016 to Oct-2018. Delivery metrics use the **96,470 delivered orders** that have a delivery date. Order grain throughout, unless stated. Values in BRL. Order value means items + freight, which is not profit.
**Nature of evidence.** Observational. The findings show *where* to investigate and *what* to test. They don't prove causes.

## What we found

1. **6.8% of delivered orders arrived after the promised date** (6,534 of 96,470).
   Under a strict timestamp rule the rate is 8.1%; the gap is orders delivered on the promised day itself. Promises are generous on average (median promise 23 days vs a median actual of 10 days), so late orders are the tail.

2. **Lateness is episodic, not constant.** Three purchase months hold 21.6% of delivered orders but 48.3% of late orders:
   Nov-2017 at 12.4% (Black Friday volume), and Feb-2018 and Mar-2018 at 14.1% and 19.0%. The Feb–Mar 2018 spike hit **every region** (15–27% late), which points to a network-wide capacity or carrier issue rather than individual sellers.

3. **The problem is geographic and concentrated in a few shipping lanes.**
   * Northeast customers: 12.7% late (n = 9,044) vs 5.9–6.5% in the South, Southeast and Center-West.
   * **Rio de Janeiro** is the largest single contributor: 12.1% late on 12,350 orders, 23% of all late orders, about **659 late orders above the marketplace rate**.
   * The **SP → RJ lane** alone shows 14.1% late on 8,188 orders (≈ 597 excess late orders). SP → BA, SP → ES, SP → CE and SP → MA follow.
   * Product category matters little. Late rates for categories with ≥ 500 orders range only from 4.3% to 8.1%.

4. **Late orders lose their time in transit, not at the seller.** Median days, on-time vs late orders:
   seller hand-off to the carrier takes 1.8 vs 3.1 days, while **carrier transit takes 7.0 vs 26.2 days**. Seller dispatch is still a secondary factor: 28% of late orders were handed to the carrier after the seller's deadline, vs 8% of on-time orders.

5. **Late deliveries are strongly associated with worse reviews.**
   Average score is 2.27 for late orders vs 4.29 for on-time orders (n = 6,381 vs 89,443). 62% of late-order reviews give 1–2 stars, against 9% for on-time orders.
   The score drops sharply within the first week of delay. The gap holds within every region and when peak months, the largest sellers or São Paulo are excluded.
   **Caveat:** 74.5% of late-order reviews were written *before* the parcel arrived. Comparing only reviews written after delivery, the gap is −0.77 points (n = 1,630). Part of the measured damage is customers reviewing a parcel that hasn't arrived yet.

6. **Seller rankings need a volume filter.** A naive "highest late rate" list is made up entirely of sellers with fewer than 10 orders. Among sellers with ≥ 100 delivered orders, 36 are above the range expected by chance. The top 25 of these account for 68% of the excess late orders among high-volume sellers.

7. **Other context.** 1.24% of orders were canceled or unavailable. The monthly share ran at 0.9–3.5% through 2017, fell to 0.3–0.9% from Mar to Jul 2018, then rose to 1.4% in Aug-2018. Most unavailable orders have no item records, so they can't be attributed to a category. Credit card is the main payment method for 75% of orders. Instalment use rises with order value: 46.5% of top-quintile card orders use 6+ instalments. The Southeast generates 65% of delivered order value.

## Where to look first (priority by excess late orders)

| Group | Delivered orders | Late rate | Excess late orders |
|---|---:|---:|---:|
| Lane SP → RJ | 8,188 | 14.1% | ≈ 597 |
| Customer state BA | 3,256 | 12.2% | ≈ 175 |
| Lane SP → BA | 2,313 | 12.8% | ≈ 140 |
| Customer state CE / MA / AL | 1,279 / 717 / 397 | 13.8% / 17.4% / 21.4% | ≈ 89 / 76 / 58 |
| Top 15 high-volume sellers (≥ 100 orders) | 216–1,772 each | 8.5–19.0% | 14–52 each |

## Recommendations to test

| # | What to test | Target group | Expected mechanism | KPIs to monitor |
|---|---|---|---|---|
| 1 | **Carrier performance review and pilot of an alternative carrier or service level** on the worst lanes | SP → RJ first, then SP → BA / CE / MA / ES | Late orders lose ~19 extra days in carrier transit, and the gap is concentrated on these lanes | Lane late rate; median and p90 carrier→customer days; excess late orders |
| 2 | **Lane- and season-aware delivery estimates.** Add buffer days on high-risk lanes and in known peak months; tighten where delivery is consistently early | Lanes and states with late rate > 10%; Nov and Feb–Mar purchase windows | Late = actual > promise. Promises are already 2× actual on average but miss on specific lanes and peaks, so recalibrating the promise reduces broken promises | Late rate; days early (over-promising); review score; *conversion rate* (not in this dataset, must be tracked) |
| 3 | **Peak-period capacity plan** with carriers before Black Friday and the post-holiday period | Whole network, Nov and Feb–Mar | The Feb–Mar 2018 spike affected all regions at once, which suggests capacity rather than seller behaviour | Monthly late rate in peak vs baseline months; carrier→customer p90 |
| 4 | **Seller dispatch SLA programme**: alerts, coaching, then ranking penalties for repeated late hand-off | High-volume sellers (≥ 100 orders) above the chance band with high carrier-hand-off lateness (for example two sellers at 31% and 48% late hand-off) | Late hand-off is 3.5× more common in late orders | Carrier hand-off late %; seller late rate; seller excess late orders |
| 5 | **Send the review survey after confirmed delivery**, plus proactive delay notifications, as an A/B test | Orders not yet delivered at the estimated date | 74.5% of late-order reviews are submitted before arrival; better timing and communication may reduce scores driven by uncertainty | Avg review and 1–2★ share for late orders; % reviews before delivery; review response rate |

Each recommendation should run as a controlled test (A/B by lane, seller cohort or time-boxed pilot) before rollout. The associations above don't show that the change will move the KPI.

## Limitations
No carrier identity, costs, margins, discounts, returns or customer demographics in the data. Seller attribution is approximate for the 1.3% of multi-seller orders. Recent months may understate lateness because 1,107 orders were still in transit at the data cut-off. Full details are in [docs/methodology.md](../docs/methodology.md).
