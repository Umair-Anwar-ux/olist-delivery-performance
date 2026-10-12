# Executive summary: delivery performance and customer reviews

This summary covers 99,441 orders placed on the Olist marketplace in Brazil between September 2016 and October 2018. Delivery figures are based on the 96,470 orders that were delivered and have a delivery date. Unless stated otherwise, every number counts orders (not individual items). Money is in Brazilian reais, and "order value" means item price plus shipping, not profit.

The data is historical, so these findings show where to investigate and what to test. They don't prove what causes the problems.

## What we found

1. 6.8% of delivered orders arrived after the promised date (6,534 of 96,470). Comparing exact timestamps gives 8.1%; the difference is orders delivered on the promised day itself. Delivery promises are generous on average (a median of 23 days against a median actual delivery time of 10 days), so late orders are the unusual tail.

2. Lateness comes in waves. Three purchase months hold 21.6% of delivered orders but 48.3% of late orders: November 2017 at 12.4% (Black Friday), February 2018 at 14.1% and March 2018 at 19.0%. The February to March 2018 spike hit every region, with late rates between 15% and 27%. That points to a network-wide capacity or carrier problem rather than individual sellers.

3. The problem is geographic and concentrated on a few shipping routes.
   - Customers in the Northeast see 12.7% of orders arrive late (9,044 orders), against 5.9% to 6.5% in the South, Southeast and Center-West.
   - Rio de Janeiro is the largest single contributor: 12.1% late on 12,350 orders, 23% of all late orders, and about 659 more late orders than the marketplace average would predict.
   - The route from São Paulo sellers to Rio de Janeiro customers alone has 14.1% late on 8,188 orders, about 597 more than expected. São Paulo to Bahia, Espírito Santo, Ceará and Maranhão come next.
   - Product category matters little. Among categories with at least 500 orders, late rates only range from 4.3% to 8.1%.

4. Late orders lose their time in transit, not at the seller. Comparing median days for on-time and late orders, the seller takes 1.8 against 3.1 days to hand the parcel to the carrier, while the carrier takes 7.0 against 26.2 days to deliver it. Seller dispatch still plays a part: 28% of late orders were handed over after the seller's deadline, against 8% of on-time orders.

5. Late deliveries go with much worse reviews. Late orders average 2.27 stars against 4.29 for on-time orders (6,381 and 89,443 reviewed orders). 62% of late-order reviews give 1 or 2 stars, against 9% for on-time orders. Scores drop sharply within the first week of delay. The gap holds within every region, and when the peak months, the largest sellers or São Paulo are left out.

   There is an important caveat. 74.5% of reviews on late orders were written before the parcel arrived. If you compare only reviews written after delivery, the gap is 0.77 stars (1,630 late orders). Part of the measured damage is customers reviewing a parcel they haven't received yet.

6. Seller rankings need a minimum volume. A simple "highest late rate" list is made up entirely of sellers with fewer than 10 orders. Among sellers with at least 100 delivered orders, 36 are worse than chance would explain, and the worst 25 of these account for 68% of the excess late orders among large sellers.

7. Other context. 1.24% of orders were canceled or unavailable. The monthly share was between 0.9% and 3.5% through 2017, fell to between 0.3% and 0.9% from March to July 2018, and rose to 1.4% in August 2018. Most unavailable orders have no item records, so they can't be linked to a category. Credit card is the main payment method for 75% of orders, and bigger orders use more instalments: 46.5% of card orders in the top fifth by value are paid in 6 or more instalments. The Southeast generates 65% of delivered order value.

## Where to look first

Groups are ranked by excess late orders: how many more late orders they have than they would at the marketplace average. This takes both the late rate and the number of orders into account.

| Group | Delivered orders | Late rate | Excess late orders |
|---|---:|---:|---:|
| Route São Paulo to Rio de Janeiro | 8,188 | 14.1% | about 597 |
| Customers in Bahia | 3,256 | 12.2% | about 175 |
| Route São Paulo to Bahia | 2,313 | 12.8% | about 140 |
| Customers in Ceará, Maranhão and Alagoas | 1,279 / 717 / 397 | 13.8% / 17.4% / 21.4% | about 89 / 76 / 58 |
| The 15 worst sellers with at least 100 orders | 216 to 1,772 each | 8.5% to 19.0% | 14 to 52 each |

## Recommendations to test

1. Review carrier performance on the worst routes and pilot an alternative carrier or service level.
   - Target: São Paulo to Rio de Janeiro first, then São Paulo to Bahia, Ceará, Maranhão and Espírito Santo.
   - Why: late orders spend about 19 extra days in carrier transit, and those orders are concentrated on these routes.
   - Track: late rate per route, median and 90th percentile transit days, excess late orders.

2. Set delivery estimates by route and season. Add buffer days on high-risk routes and in known peak months, and shorten estimates where deliveries are consistently early.
   - Target: routes and states above 10% late, and orders placed in November and in February to March.
   - Why: an order is late when delivery takes longer than the promise. Promises are already about twice the actual time on average, but they still miss on specific routes and in peak months.
   - Track: late rate, days delivered early, review score, and conversion rate (not in this dataset, so it would need to be measured).

3. Agree a peak-period capacity plan with carriers before Black Friday and the post-holiday period.
   - Target: the whole network in November and February to March.
   - Why: the 2018 spike affected all regions at once, which suggests capacity rather than seller behaviour.
   - Track: monthly late rate in peak months against normal months, and 90th percentile transit days.

4. Run a dispatch programme for sellers: alerts first, then coaching, then ranking penalties for repeated late handovers.
   - Target: sellers with at least 100 orders whose late rate is worse than chance and who often hand over late. Two such sellers hand over late on 31% and 48% of orders.
   - Why: late handover is 3.5 times more common among late orders.
   - Track: share of orders handed over late, seller late rate, seller excess late orders.

5. Send the review survey after the order is confirmed delivered, and message customers when an order is running late. Run it as an A/B test.
   - Target: orders that haven't arrived by the promised date.
   - Why: 74.5% of late-order reviews are written before the parcel arrives, so better timing and communication may lift scores that reflect uncertainty.
   - Track: average review and share of 1 to 2 star reviews for late orders, share of reviews written before delivery, survey response rate.

Each idea should be tested in a controlled way (by route, by group of sellers, or as a time-limited pilot) before it is rolled out. The patterns above don't show that a change will move the numbers.

## Limitations

The data has no carrier names, costs, margins, discounts, returns or customer demographics. When an order has more than one seller (1.3% of orders), all its sellers share the same delivery result. The last few months may understate lateness because 1,107 orders were still in transit when the data ends. More detail is in [docs/methodology.md](../docs/methodology.md).
