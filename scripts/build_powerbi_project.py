"""Generate the Power BI project (PBIP: TMDL semantic model + PBIR report) for the dashboard.

Usage:
    python scripts/build_powerbi_project.py [--schemas DIR]

Writes powerbi/pbip/ (text-based, Git-friendly source of the report):
    delivery_reviews.pbip
    delivery_reviews.SemanticModel/   TMDL: 8 tables loaded from data/processed/*.csv,
                                      relationships, calculated columns, measures
    delivery_reviews.Report/          PBIR: 4 pages (overview, operations,
                                      customer experience, metric definitions)
and powerbi/measures.dax (readable copy of every measure, generated from MEASURES).

Open powerbi/pbip/delivery_reviews.pbip in Power BI Desktop, Refresh, then
File > Save as > Power BI file (*.pbix) -> powerbi/delivery_reviews.pbix
(scripts/export_powerbi_pbix.py automates those clicks).

--schemas DIR: folder of PBIR JSON schemas (as extracted from Power BI Desktop);
when given, every report JSON file is validated before it is written.
"""
from __future__ import annotations

import argparse
import csv
import json
import shutil
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data" / "processed"
OUT = ROOT / "powerbi" / "pbip"
NAME = "delivery_reviews"
THEME_SRC = ROOT / "powerbi" / "olist_theme.json"
BASE_THEME = "CY26SU09"
BASE_THEME_SRC = Path(r"C:\Program Files\Microsoft Power BI Desktop\bin\WebView2Resources"
                      r"\minerva\sharedresources\BaseThemes") / f"{BASE_THEME}.json"
S = "https://developer.microsoft.com/json-schemas/fabric/"
VERSIONS = {"visual": "2.13.0", "page": "2.1.0", "report": "3.3.0"}

BLUE, ORANGE, GREY, INK, INK2 = "#2A78D6", "#EB6834", "#8A8984", "#0B0B0B", "#52514E"


def tag(*parts: str) -> str:
    """Deterministic lineage tag / object id, so regenerating gives identical files."""
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "olist-delivery/" + "/".join(parts)))


# =============================================================================
# SEMANTIC MODEL
# =============================================================================
TABLES = {
    # table: (description, hidden columns)
    "fct_orders": ("Main fact. Grain: one row per order (99,441). Flags are 1/0; blank = not applicable.",
                   {"customer_id", "customer_unique_id"}),
    "fct_order_items": ("Grain: one row per order item (112,650). Count orders with the order-level measures, not rows.",
                        {"order_id", "product_id", "seller_id", "customer_id"}),
    "fct_payments": ("Grain: one row per payment record (103,886).", {"order_id"}),
    "dim_customer": ("One row per customer_id (one per order) with state and IBGE macro-region.", set()),
    "dim_seller": ("One row per seller with state and macro-region.", set()),
    "dim_product": ("One row per product with English category.", set()),
    "dim_date": ("Calendar 2016-09-01 to 2018-12-31. in_trend_window = complete months Jan-2017..Aug-2018.", set()),
}

INT_COLS = {"item_count", "seller_count", "category_count", "payment_count", "max_installments", "review_score",
            "review_count", "days_vs_estimate", "order_item_id", "payment_sequential", "payment_installments",
            "product_photos_qty", "product_weight_g", "product_length_cm", "product_height_cm", "product_width_cm",
            "year", "quarter", "month", "iso_day_of_week", "items", "in_trend_window", "used_voucher",
            "review_has_comment", "review_created_before_delivery"}
DATE_COLS = {"purchase_date", "purchase_month", "date", "month_start"}


def column_type(col: str) -> tuple[str, str]:
    """(TMDL dataType, Power Query type) inferred from the column naming convention."""
    if col.startswith(("is_", "has_")) or col in INT_COLS:
        return "int64", "Int64.Type"
    if col.endswith("_brl") or col.startswith(("days_", "hours_")):
        return "double", "type number"
    if col in DATE_COLS:
        return "dateTime", "type date"
    if col.endswith(("_timestamp", "_date", "_at")):
        return "dateTime", "type datetime"
    return "string", "type text"


CALC_COLUMNS = {
    "fct_orders": [
        ("Delivery Outcome", "string",
         'SWITCH ( TRUE (), ISBLANK ( fct_orders[is_late] ), "Not in delivery KPI", fct_orders[is_late] = 1, "Late", "On time" )',
         "Late / On time for delivery-KPI orders; other orders are 'Not in delivery KPI'."),
        ("Review Stars", "string",
         'IF ( ISBLANK ( fct_orders[review_score] ), BLANK (), FORMAT ( fct_orders[review_score], "0" ) & " star" )',
         "Review score as a category label (1-5)."),
    ],
    "fct_order_items": [
        ("Lane", "string",
         'RELATED ( dim_seller[seller_state] ) & " -> " & RELATED ( fct_orders[customer_state] )',
         "Shipping lane: seller state -> customer state."),
    ],
}

# (name, folder, format, DAX, description). Single source of truth for the model and measures.dax.
MEASURES = [
    ("Total Orders", "1 Volume", "#,0", "COUNTROWS ( fct_orders )",
     "All orders placed, every status. Grain: order."),
    ("Delivered Orders", "1 Volume", "#,0",
     "CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_delivery_kpi_eligible] = 1 )",
     "Delivery-KPI population: status delivered AND a delivery timestamp (denominator of the late rate)."),
    ("Orders (Trend Window)", "1 Volume", "#,0",
     "CALCULATE ( [Total Orders], dim_date[in_trend_window] = 1 )",
     "Total Orders restricted to the complete months Jan-2017..Aug-2018 (used by monthly charts)."),
    ("Late Orders", "2 Delivery", "#,0",
     "CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_late] = 1 )",
     "Delivered on a later calendar date than the estimated delivery date."),
    ("On-Time Orders", "2 Delivery", "#,0",
     "CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_late] == 0 )",
     "Delivered on or before the estimated date. Strict == so blank (not in KPI) is not counted as 0."),
    ("Late Rate %", "2 Delivery", "0.0%", "DIVIDE ( [Late Orders], [Delivered Orders] )",
     "Late Orders / Delivered Orders. Order grain."),
    ("Late Rate % (Timestamp Rule)", "2 Delivery", "0.0%",
     "DIVIDE ( CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_late_timestamp_rule] = 1 ), [Delivered Orders] )",
     "Sensitivity: delivery timestamp > estimated timestamp (midnight), so same-day deliveries count as late."),
    ("Late Rate % (Trend Window)", "2 Delivery", "0.0%",
     "CALCULATE ( [Late Rate %], dim_date[in_trend_window] = 1 )",
     "Late Rate % restricted to the complete months Jan-2017..Aug-2018."),
    ("Marketplace Late Rate %", "2 Delivery", "0.0%",
     "CALCULATE ( [Late Rate %], REMOVEFILTERS ( dim_customer ), REMOVEFILTERS ( dim_seller ), "
     "REMOVEFILTERS ( dim_product ), REMOVEFILTERS ( fct_order_items ) )",
     "Late rate for the same period ignoring customer, seller, product and lane filters."),
    ("Excess Late Orders", "2 Delivery", "#,0",
     "[Late Orders] - [Delivered Orders] * [Marketplace Late Rate %]",
     "Late orders above what the group would have at the marketplace rate (rate x volume)."),
    ("Carrier Handoff Late %", "2 Delivery", "0.0%",
     "DIVIDE ( CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_carrier_handoff_late] = 1 ), "
     "CALCULATE ( COUNTROWS ( fct_orders ), NOT ISBLANK ( fct_orders[is_carrier_handoff_late] ) ) )",
     "Share of delivered orders handed to the carrier after the seller shipping deadline."),
    ("Median Hours Purchase to Approval", "3 Lifecycle", "0.0",
     "MEDIAN ( fct_orders[hours_purchase_to_approval] )",
     "Median hours from purchase to payment approval (delivered orders, valid sequence)."),
    ("Median Days Approval to Carrier", "3 Lifecycle", "0.0",
     "MEDIAN ( fct_orders[days_approval_to_carrier] )",
     "Median days from approval to carrier hand-off (delivered orders, valid sequence)."),
    ("Median Days Carrier to Customer", "3 Lifecycle", "0.0",
     "MEDIAN ( fct_orders[days_carrier_to_customer] )",
     "Median days in carrier transit (delivered orders, valid sequence)."),
    ("Median Days Approval to Carrier (Valid Lifecycle)", "3 Lifecycle", "0.0",
     "CALCULATE ( MEDIAN ( fct_orders[days_approval_to_carrier] ), fct_orders[is_lifecycle_valid] = 1 )",
     "Median approval -> carrier days over orders whose three stage timestamps are all present and in order."),
    ("Median Days Carrier to Customer (Valid Lifecycle)", "3 Lifecycle", "0.0",
     "CALCULATE ( MEDIAN ( fct_orders[days_carrier_to_customer] ), fct_orders[is_lifecycle_valid] = 1 )",
     "Median carrier -> customer days over orders whose three stage timestamps are all present and in order."),
    ("Median Days Purchase to Delivery", "3 Lifecycle", "0.0",
     "MEDIAN ( fct_orders[days_purchase_to_delivery] )",
     "Median days from purchase to delivery (delivery-KPI orders)."),
    ("Reviewed Orders", "4 Reviews", "#,0", "COUNT ( fct_orders[review_score] )",
     "Orders with a review (one review per order)."),
    ("Avg Review Score", "4 Reviews", "0.00", "AVERAGE ( fct_orders[review_score] )",
     "Average 1-5 score over reviewed orders in the current filter (all statuses)."),
    ("Avg Review Score (Delivered)", "4 Reviews", "0.00",
     "CALCULATE ( [Avg Review Score], fct_orders[is_delivery_kpi_eligible] = 1 )",
     "Average score of reviewed delivery-KPI orders."),
    ("Avg Review Score (On Time)", "4 Reviews", "0.00",
     "CALCULATE ( [Avg Review Score], fct_orders[is_late] == 0 )",
     "Average score of reviewed on-time orders."),
    ("Avg Review Score (Late)", "4 Reviews", "0.00",
     "CALCULATE ( [Avg Review Score], fct_orders[is_late] = 1 )",
     "Average score of reviewed late orders."),
    ("Review Gap (Late - On Time)", "4 Reviews", "0.00",
     "[Avg Review Score (Late)] - [Avg Review Score (On Time)]",
     "Association only - not proof that delay causes the lower score."),
    ("Low Review Share %", "4 Reviews", "0.0%",
     "DIVIDE ( CALCULATE ( [Reviewed Orders], fct_orders[review_score] <= 2 ), [Reviewed Orders] )",
     "Share of reviewed orders with 1 or 2 stars."),
    ("Late Reviews Written Before Delivery %", "4 Reviews", "0.0%",
     "DIVIDE ( CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_late] = 1, fct_orders[review_created_before_delivery] = 1 ), "
     "CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[is_late] = 1, fct_orders[has_review] = 1 ) )",
     "Review-timing caveat: share of late-order reviews created before the parcel arrived."),
    ("Avg Review Score (Late, Written After Delivery)", "4 Reviews", "0.00",
     "CALCULATE ( [Avg Review Score], fct_orders[is_late] = 1, fct_orders[review_created_before_delivery] == 0 )",
     "Average score of late orders whose review was written after delivery."),
    ("Canceled Orders", "5 Status", "#,0",
     "CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[order_status] = \"canceled\" )", "Status canceled."),
    ("Unavailable Orders", "5 Status", "#,0",
     "CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[order_status] = \"unavailable\" )", "Status unavailable."),
    ("Canceled or Unavailable %", "5 Status", "0.00%",
     "DIVIDE ( [Canceled Orders] + [Unavailable Orders], [Total Orders] )",
     "(Canceled + unavailable) / all orders."),
    ("Canceled or Unavailable % (Trend Window)", "5 Status", "0.00%",
     "CALCULATE ( [Canceled or Unavailable %], dim_date[in_trend_window] = 1 )",
     "Canceled or Unavailable % restricted to complete months."),
    ("Delivered Order Value (BRL)", "6 Value", "R$ #,0",
     "CALCULATE ( SUM ( fct_orders[order_value_brl] ), fct_orders[status_group] = \"delivered\" )",
     "Item price + freight of delivered orders, BRL. Gross merchandise value - NOT profit or Olist revenue."),
    ("Item Value (BRL)", "6 Value", "R$ #,0", "SUM ( fct_order_items[item_value_brl] )",
     "Item price + freight at item grain - use under category/seller filters."),
    ("Avg Delivered Order Value (BRL)", "6 Value", "R$ #,0.00",
     "DIVIDE ( [Delivered Order Value (BRL)], CALCULATE ( COUNTROWS ( fct_orders ), fct_orders[status_group] = \"delivered\" ) )",
     "Delivered order value / delivered orders."),
    ("Payments (BRL)", "6 Value", "R$ #,0", "SUM ( fct_payments[payment_value_brl] )",
     "Sum of payment records, BRL (can include instalment interest and vouchers)."),
]


def q(name: str) -> str:
    """Quote a TMDL object name when needed."""
    return name if name.replace("_", "").isalnum() else "'" + name.replace("'", "''") + "'"


def table_tmdl(table: str) -> str:
    desc, hidden = TABLES[table]
    with open(DATA / f"{table}.csv", encoding="utf-8", newline="") as fh:
        cols = next(csv.reader(fh))
    lines = [f"/// {desc}", f"table {table}", f"\tlineageTag: {tag(table)}"]
    if table == "dim_date":
        lines.append("\tdataCategory: Time")
    lines.append("")
    for name, dtype, expr, cdesc in CALC_COLUMNS.get(table, []):
        lines += [f"\t/// {cdesc}", f"\tcolumn {q(name)} = {expr}", f"\t\tdataType: {dtype}",
                  "\t\tsummarizeBy: none", f"\t\tlineageTag: {tag(table, name)}", ""]
    types = []
    for c in cols:
        dtype, mtype = column_type(c)
        types.append(f'{{"{c}", {mtype}}}')
        lines += [f"\tcolumn {c}", f"\t\tdataType: {dtype}"]
        if mtype == "type date":
            lines.append("\t\tformatString: yyyy-mm-dd")
        elif dtype == "dateTime":
            lines.append("\t\tformatString: yyyy-mm-dd hh:nn:ss")
        if table == "dim_date" and c == "date":
            lines.append("\t\tisKey")
        if table == "dim_date" and c == "year_month":
            lines.append("\t\tsortByColumn: month_start")
        if c in hidden:
            lines.append("\t\tisHidden")
        lines += ["\t\tsummarizeBy: none", f"\t\tsourceColumn: {c}", f"\t\tlineageTag: {tag(table, c)}", ""]
    m = [
        "let",
        f'    Source = Csv.Document(File.Contents(DataFolder & "{table}.csv"), [Delimiter = ",", Encoding = 65001, QuoteStyle = QuoteStyle.Csv]),',
        "    Promoted = Table.PromoteHeaders(Source, [PromoteAllScalars = true]),",
        "    // SQLite NULLs are exported as empty cells: turn them into real nulls before typing",
        '    EmptyToNull = Table.TransformColumns(Promoted, List.Transform(Table.ColumnNames(Promoted), (c) => {c, each if _ = "" then null else _})),',
        f'    Typed = Table.TransformColumnTypes(EmptyToNull, {{{", ".join(types)}}}, "en-US")',
        "in",
        "    Typed",
    ]
    lines += [f"\tpartition {table} = m", "\t\tmode: import", "\t\tsource ="]
    lines += ["\t\t\t\t" + l for l in m]
    return "\n".join(lines) + "\n"


def measures_tmdl() -> str:
    lines = ["/// Measure table. Every report metric is defined here (see docs/methodology.md).",
             "table _Measures", f"\tlineageTag: {tag('_Measures')}", ""]
    for name, folder, fmt, dax, desc in MEASURES:
        lines += [f"\t/// {desc}", f"\tmeasure {q(name)} = {dax}", f"\t\tformatString: {fmt}",
                  f"\t\tdisplayFolder: {folder}", f"\t\tlineageTag: {tag('measure', name)}", ""]
    lines += ["\tcolumn Value", "\t\tdataType: int64", "\t\tisHidden", "\t\tsummarizeBy: none",
              "\t\tsourceColumn: Value", f"\t\tlineageTag: {tag('_Measures', 'Value')}", "",
              "\tpartition _Measures = m", "\t\tmode: import", "\t\tsource =",
              "\t\t\t\tlet", "\t\t\t\t    Source = #table(type table [Value = Int64.Type], {})",
              "\t\t\t\tin", "\t\t\t\t    Source"]
    return "\n".join(lines) + "\n"


RELATIONSHIPS = [
    # (from many-side column, to one-side column, bidirectional?)
    ("fct_orders.purchase_date", "dim_date.date", False),
    ("fct_orders.customer_id", "dim_customer.customer_id", False),
    ("fct_order_items.order_id", "fct_orders.order_id", True),   # category/seller slicers reach orders
    ("fct_order_items.product_id", "dim_product.product_id", False),
    ("fct_order_items.seller_id", "dim_seller.seller_id", False),
    ("fct_payments.order_id", "fct_orders.order_id", False),
]


def write_semantic_model(base: Path) -> None:
    d = base / "definition"
    (d / "tables").mkdir(parents=True, exist_ok=True)
    write_json(base / "definition.pbism", {"$schema": S + "item/semanticModel/definitionProperties/1.0.0/schema.json",
                                           "version": "4.2", "settings": {}})
    (d / "database.tmdl").write_text("database\n\tcompatibilityLevel: 1600\n", encoding="utf-8")
    refs = "\n".join(f"ref table {t}" for t in ["_Measures", *TABLES])
    (d / "model.tmdl").write_text(
        "model Model\n\tculture: en-US\n\tdefaultPowerBIDataSourceVersion: powerBI_V3\n"
        "\tsourceQueryCulture: en-US\n\tdataAccessOptions\n\t\tlegacyRedirects\n\t\treturnErrorValuesAsNull\n\n"
        + refs + "\n", encoding="utf-8")
    folder = DATA.as_posix().replace("/", "\\") + "\\"
    (d / "expressions.tmdl").write_text(
        "/// Folder holding the CSVs exported by scripts/build_database.py (must end with a backslash).\n"
        f'expression DataFolder = "{folder}" meta [IsParameterQuery = true, Type = "Text", IsParameterQueryRequired = true]\n'
        f"\tlineageTag: {tag('DataFolder')}\n", encoding="utf-8")
    for t in TABLES:
        (d / "tables" / f"{t}.tmdl").write_text(table_tmdl(t), encoding="utf-8")
    (d / "tables" / "_Measures.tmdl").write_text(measures_tmdl(), encoding="utf-8")
    rel = []
    for f, t, both in RELATIONSHIPS:
        rel += [f"relationship {tag('rel', f, t)}", f"\tfromColumn: {f}", f"\ttoColumn: {t}"]
        if both:
            rel.append("\tcrossFilteringBehavior: bothDirections")
        rel.append("")
    (d / "relationships.tmdl").write_text("\n".join(rel), encoding="utf-8")


# =============================================================================
# REPORT (PBIR)
# =============================================================================
def lit(v):
    if isinstance(v, bool):
        s = "true" if v else "false"
    elif isinstance(v, int):
        s = f"{v}L"
    elif isinstance(v, float):
        s = f"{v}D"
    else:
        s = "'" + str(v).replace("'", "''") + "'"
    return {"expr": {"Literal": {"Value": s}}}


def col(entity, prop):
    return {"Column": {"Expression": {"SourceRef": {"Entity": entity}}, "Property": prop}}


def meas(prop):
    return {"Measure": {"Expression": {"SourceRef": {"Entity": "_Measures"}}, "Property": prop}}


def proj(field, display=None):
    ent = field[next(iter(field))]["Expression"]["SourceRef"]["Entity"]
    prop = field[next(iter(field))]["Property"]
    p = {"field": field, "queryRef": f"{ent}.{prop}", "nativeQueryRef": prop}
    if display:
        p["displayName"] = display
    return p


def color(hex_):
    return {"solid": {"color": lit(hex_)}}


def min_filter(name, measure, minimum):
    """Visual-level filter: [measure] >= minimum (keeps small samples out of rankings)."""
    return {"filters": [{
        "name": name, "field": meas(measure), "type": "Advanced",
        "filter": {"Version": 2, "From": [{"Name": "m", "Entity": "_Measures", "Type": 0}],
                   "Where": [{"Condition": {"Comparison": {
                       "ComparisonKind": 2,
                       "Left": {"Measure": {"Expression": {"SourceRef": {"Source": "m"}}, "Property": measure}},
                       "Right": {"Literal": {"Value": f"{minimum}L"}}}}}]},
        "howCreated": "User"}]}


def visual(name, vtype, x, y, w, h, roles=None, title=None, objects=None, sort=None, filters=None, z=0):
    v = {"visualType": vtype}
    if roles:
        v["query"] = {"queryState": {r: {"projections": ps} for r, ps in roles.items()}}
        if sort:
            field, direction = sort
            v["query"]["sortDefinition"] = {"sort": [{"field": field, "direction": direction}], "isDefaultSort": False}
    if objects:
        v["objects"] = objects
    vco = {}
    if title is not None:
        vco["title"] = [{"properties": {"show": lit(True), "text": lit(title), "fontSize": lit(11.0),
                                        "bold": lit(True), "fontColor": color(INK)}}]
    else:
        vco["title"] = [{"properties": {"show": lit(False)}}]
    v["visualContainerObjects"] = vco
    doc = {"$schema": S + "item/report/definition/visualContainer/2.13.0/schema.json", "name": name,
           "position": {"x": x, "y": y, "z": z, "width": w, "height": h, "tabOrder": z}, "visual": v}
    if filters:
        doc["filterConfig"] = filters
    return doc


def textbox(name, x, y, w, h, runs_by_paragraph, z=0):
    paragraphs = []
    for runs in runs_by_paragraph:
        paragraphs.append({"textRuns": [{"value": text, "textStyle": style} for text, style in runs]})
    return {"$schema": S + "item/report/definition/visualContainer/2.13.0/schema.json", "name": name,
            "position": {"x": x, "y": y, "z": z, "width": w, "height": h, "tabOrder": z},
            "visual": {"visualType": "textbox",
                       "objects": {"general": [{"properties": {"paragraphs": paragraphs}}]},
                       "visualContainerObjects": {"background": [{"properties": {"show": lit(False)}}]}}}


AXES = {"categoryAxis": [{"properties": {"showAxisTitle": lit(False), "fontSize": lit(8.0)}}],
        "valueAxis": [{"properties": {"showAxisTitle": lit(False), "fontSize": lit(8.0)}}]}
H1 = {"fontWeight": "bold", "fontSize": "20pt", "color": INK}
SUB = {"fontSize": "10pt", "color": INK2}
BODY = {"fontSize": "10pt", "color": INK}
BOLD = {"fontSize": "10pt", "color": INK, "fontWeight": "bold"}
SMALL = {"fontSize": "8pt", "color": INK2}


def header(page, title, subtitle):
    return [textbox(f"{page}_title", 20, 8, 1240, 64, [[(title, H1)], [(subtitle, SUB)]], z=0)]


def card(name, x, y, w, h, measure, label, units=1.0, decimals=None, z=1):
    lbl = {"labelDisplayUnits": lit(units), "fontSize": lit(24.0), "color": color(INK)}
    if decimals is not None:
        lbl["labelPrecision"] = lit(decimals)
    return visual(name, "card", x, y, w, h, roles={"Values": [proj(meas(measure), label)]},
                  objects={"labels": [{"properties": lbl}],
                           "categoryLabels": [{"properties": {"show": lit(True), "fontSize": lit(10.0), "color": color(INK2)}}]},
                  z=z)


def bar_like(name, vtype, x, y, w, h, category, values, title, fill=BLUE, tooltips=None, sort=None,
             labels=True, filters=None, z=1):
    roles = {"Category": [proj(category)], "Y": [proj(meas(v), d) for v, d in values]}
    if tooltips:
        roles["Tooltips"] = [proj(meas(t)) for t in tooltips]
    objects = {"dataPoint": [{"properties": {"fill": color(fill)}}],
               "labels": [{"properties": {"show": lit(labels), "fontSize": lit(8.0)}}],
               **AXES}
    if len(values) > 1:
        objects["legend"] = [{"properties": {"show": lit(True), "position": lit("Top")}}]
    return visual(name, vtype, x, y, w, h, roles=roles, title=title, objects=objects, sort=sort, filters=filters, z=z)


def table(name, x, y, w, h, columns, title, sort=None, filters=None, totals=True, font=9.0, z=1):
    objects = {"columnHeaders": [{"properties": {"wordWrap": lit(True), "fontSize": lit(font)}}],
               "values": [{"properties": {"fontSize": lit(font)}}]}
    if not totals:   # a total row of rankings (e.g. summed excess late orders) is misleading
        objects["total"] = [{"properties": {"totals": lit(False)}}]
    return visual(name, "tableEx", x, y, w, h, roles={"Values": [proj(c, d) for c, d in columns]},
                  title=title, sort=sort, filters=filters, z=z, objects=objects)


def line(name, x, y, w, h, category, measure, display, title, fill, tooltips=(), labels=False, z=1):
    """Line chart; the series colour is set with a selector on the measure's queryRef."""
    return visual(name, "lineChart", x, y, w, h,
                  roles={"Category": [proj(category)], "Y": [proj(meas(measure), display)],
                         "Tooltips": [proj(meas(t)) for t in tooltips]},
                  title=title, sort=(category, "Ascending"), z=z,
                  objects={"dataPoint": [{"properties": {"fill": color(fill)},
                                          "selector": {"metadata": f"_Measures.{measure}"}}],
                           "labels": [{"properties": {"show": lit(labels), "fontSize": lit(7.0)}}],
                           **AXES})


def slicer(name, x, y, w, h, field, title, mode, z=1):
    return visual(name, "slicer", x, y, w, h, roles={"Values": [proj(field)]}, title=None, z=z,
                  objects={"data": [{"properties": {"mode": lit(mode)}}],
                           "header": [{"properties": {"show": lit(True), "text": lit(title), "fontSize": lit(10.0)}}]})


def pages() -> dict[str, tuple[str, list[dict]]]:
    p = {}
    # ---------------------------------------------------------------- page 1
    v = header("overview", "Business Overview",
               "All orders (one row per order), purchases Sep-2016 to Oct-2018. Monthly charts use complete months "
               "Jan-2017 to Aug-2018. Late = delivered on a later calendar date than the estimate.")
    cards = [("Total Orders", "Total orders (all statuses)", 1.0, None),
             ("Delivered Orders", "Delivered orders (delivery KPI)", 1.0, None),
             ("Late Rate %", "Late-delivery rate", 1.0, None),
             ("Avg Review Score (Delivered)", "Avg review score, delivered (1-5)", 1.0, 2),
             ("Delivered Order Value (BRL)", "Delivered order value, BRL (not profit)", 1000000.0, 2)]
    for i, (m, label, units, dec) in enumerate(cards):
        v.append(card(f"overview_card{i + 1}", 20 + i * 250, 80, 238, 100, m, label, units, dec, z=1 + i))
    v.append(bar_like("overview_orders_month", "clusteredColumnChart", 20, 192, 800, 250,
                      col("dim_date", "year_month"), [("Orders (Trend Window)", "Orders")],
                      "Orders placed per month (purchase month)", fill=BLUE, labels=False,
                      sort=(col("dim_date", "year_month"), "Ascending"), z=10))
    v.append(line("overview_late_month", 20, 450, 800, 235, col("dim_date", "year_month"),
                  "Late Rate % (Trend Window)", "Late-delivery rate",
                  "Late-delivery rate per month (late / delivered orders, by purchase month)", ORANGE,
                  tooltips=("Delivered Orders", "Late Orders"), labels=True, z=11))
    v.append(bar_like("overview_value_region", "clusteredBarChart", 832, 192, 428, 493,
                      col("dim_customer", "customer_region"), [("Delivered Order Value (BRL)", "Delivered order value (BRL)")],
                      "Delivered order value by customer region (BRL, not profit)", fill=BLUE,
                      tooltips=["Delivered Orders", "Avg Delivered Order Value (BRL)"],
                      sort=(meas("Delivered Order Value (BRL)"), "Descending"), z=12))
    v.append(textbox("overview_footer", 20, 690, 1240, 26, [[(
        "Source: Olist public dataset (Kaggle) via SQLite build (data/processed/olist.db). Order value = item price + "
        "freight in BRL; it is gross merchandise value, not profit. See the Metric Definitions page.", SMALL)]], z=20))
    p["overview"] = ("Business Overview", v)

    # ---------------------------------------------------------------- page 2
    v = header("operations", "Delivery Operations",
               "Delivered orders only. Rankings need minimum volumes (lanes 300, categories 500, sellers 100 delivered "
               "orders). Excess late = late orders above the marketplace rate.")
    v += [slicer("operations_slicer_date", 20, 76, 300, 64, col("dim_date", "date"), "Purchase date", "Between"),
          slicer("operations_slicer_region", 332, 76, 220, 64, col("dim_customer", "customer_region"), "Customer region", "Dropdown", z=2),
          slicer("operations_slicer_category", 564, 76, 260, 64, col("dim_product", "category"), "Product category", "Dropdown", z=3),
          slicer("operations_slicer_seller", 836, 76, 424, 64, col("dim_seller", "seller_id"), "Seller", "Dropdown", z=4)]
    v.append(bar_like("operations_state", "clusteredColumnChart", 20, 150, 760, 262,
                      col("dim_customer", "customer_state"), [("Late Rate %", "Late-delivery rate")],
                      "Late-delivery rate by customer state (hover for sample size)", fill=ORANGE,
                      tooltips=["Delivered Orders", "Late Orders", "Excess Late Orders"],
                      sort=(meas("Late Rate %"), "Descending"), z=10))
    v.append(table("operations_lanes", 792, 150, 468, 262,
                   [(col("fct_order_items", "Lane"), "Lane (seller -> customer state)"),
                    (meas("Delivered Orders"), "Delivered"), (meas("Late Rate %"), "Late %"),
                    (meas("Excess Late Orders"), "Excess late"),
                    (meas("Median Days Carrier to Customer"), "Median carrier days")],
                   "Shipping lanes by excess late orders (>= 300 delivered orders)",
                   sort=(meas("Excess Late Orders"), "Descending"),
                   filters=min_filter("lanes_min_volume", "Delivered Orders", 300), totals=False, z=11))
    v.append(table("operations_sellers", 20, 422, 610, 278,
                   [(col("dim_seller", "seller_id"), "Seller"), (col("dim_seller", "seller_state"), "State"),
                    (meas("Delivered Orders"), "Delivered"), (meas("Late Rate %"), "Late %"),
                    (meas("Excess Late Orders"), "Excess late"), (meas("Carrier Handoff Late %"), "Late hand-off %")],
                   "Sellers by excess late orders (>= 100 delivered orders)",
                   sort=(meas("Excess Late Orders"), "Descending"),
                   filters=min_filter("sellers_min_volume", "Delivered Orders", 100), totals=False, font=8.0, z=12))
    v.append(table("operations_categories", 642, 422, 320, 278,
                   [(col("dim_product", "category"), "Category"), (meas("Delivered Orders"), "Delivered"),
                    (meas("Late Rate %"), "Late %"), (meas("Excess Late Orders"), "Excess late")],
                   "Categories by excess late orders (>= 500 delivered orders)",
                   sort=(meas("Excess Late Orders"), "Descending"),
                   filters=min_filter("categories_min_volume", "Delivered Orders", 500), totals=False, font=8.0, z=13))
    v.append(bar_like("operations_lifecycle", "clusteredBarChart", 974, 422, 286, 278,
                      col("fct_orders", "Delivery Outcome"),
                      [("Median Days Approval to Carrier (Valid Lifecycle)", "Approval -> carrier (days)"),
                       ("Median Days Carrier to Customer (Valid Lifecycle)", "Carrier -> customer (days)")],
                      "Median days per stage (all stage timestamps valid)", fill=BLUE, z=14))
    p["operations"] = ("Delivery Operations", v)

    # ---------------------------------------------------------------- page 3
    v = header("experience", "Customer Experience",
               "Reviewed orders, one review per order. Differences between on-time and late orders are associations, "
               "not proof that delay causes lower scores.")
    v.append(bar_like("experience_distribution", "clusteredColumnChart", 20, 80, 400, 300,
                      col("fct_orders", "Review Stars"), [("Reviewed Orders", "Reviewed orders")],
                      "Review-score distribution (all reviewed orders)", fill=BLUE,
                      sort=(col("fct_orders", "Review Stars"), "Ascending"), z=10))
    v.append(bar_like("experience_ontime_late", "clusteredColumnChart", 432, 80, 400, 300,
                      col("fct_orders", "Delivery Outcome"), [("Avg Review Score (Delivered)", "Avg review score")],
                      "Average review score: on time vs late (delivered orders)", fill=ORANGE,
                      tooltips=["Reviewed Orders", "Low Review Share %"], z=11))
    v.append(card("experience_card_before", 844, 80, 416, 96, "Late Reviews Written Before Delivery %",
                  "Late-order reviews written BEFORE the parcel arrived", z=12))
    v.append(card("experience_card_after", 844, 184, 416, 96, "Avg Review Score (Late, Written After Delivery)",
                  "Avg score of late orders reviewed after delivery", decimals=2, z=13))
    v.append(textbox("experience_caveat", 844, 288, 416, 92, [[(
        "Review-timing caveat: Olist appears to send the survey around the estimated date, so most late-order "
        "reviews rate a parcel that has not arrived. The on-time vs late gap shrinks for reviews written after "
        "delivery. Treat the gap as an association.", BODY)]], z=14))
    v.append(table("experience_region", 20, 392, 330, 300,
                   [(col("dim_customer", "customer_region"), "Customer region"), (meas("Delivered Orders"), "Delivered"),
                    (meas("Late Rate %"), "Late %"), (meas("Avg Review Score (Delivered)"), "Avg review")],
                   "Late rate and review score by region", sort=(meas("Late Rate %"), "Descending"), z=15))
    v.append(table("experience_category", 362, 392, 410, 300,
                   [(col("dim_product", "category"), "Category"), (meas("Delivered Orders"), "Delivered"),
                    (meas("Late Rate %"), "Late %"), (meas("Avg Review Score (Delivered)"), "Avg review")],
                   "Late rate and review score by category (>= 1,000 delivered orders)",
                   sort=(meas("Late Rate %"), "Descending"),
                   filters=min_filter("experience_category_min", "Delivered Orders", 1000), z=16))
    v.append(line("experience_status_trend", 784, 392, 476, 300, col("dim_date", "year_month"),
                  "Canceled or Unavailable % (Trend Window)", "Canceled or unavailable %",
                  "Canceled + unavailable share of all orders, by month", GREY,
                  tooltips=("Canceled Orders", "Unavailable Orders", "Orders (Trend Window)"), z=17))
    p["experience"] = ("Customer Experience", v)

    # ---------------------------------------------------------------- page 4
    v = header("definitions", "Metric Definitions",
               "Every measure lives in the _Measures table (hover a field for its description). Totals below must equal "
               "reports/headline_metrics.json from the SQLite build.")
    v.append(table("definitions_reconcile_a", 20, 80, 1240, 96,
                   [(meas(m), None) for m in ["Total Orders", "Delivered Orders", "Late Orders", "Late Rate %",
                                              "Late Rate % (Timestamp Rule)", "Canceled Orders", "Unavailable Orders",
                                              "Delivered Order Value (BRL)"]],
                   "Reconciliation totals (no filters applied)", z=10))
    v.append(table("definitions_reconcile_b", 20, 182, 1240, 96,
                   [(meas(m), d) for m, d in [("Avg Review Score (On Time)", "Avg review, on time"),
                                              ("Avg Review Score (Late)", "Avg review, late"),
                                              ("Late Reviews Written Before Delivery %", "Late reviews before delivery"),
                                              ("Median Hours Purchase to Approval", "Median hours to approval"),
                                              ("Median Days Approval to Carrier", "Median days to carrier"),
                                              ("Median Days Carrier to Customer", "Median days carrier transit"),
                                              ("Median Days Purchase to Delivery", "Median days to delivery")]],
                   "Reconciliation: reviews and lifecycle medians", z=11))
    defs = [
        [("Grain. ", BOLD), ("fct_orders has one row per order; order measures count its rows. Category, seller and lane "
                             "filters reach orders through the order<->item relationship, so an order is counted once.", BODY)],
        [("Delivered orders (delivery-KPI population). ", BOLD),
         ("Status = delivered AND a customer delivery timestamp (96,470 of 99,441). Shipped, canceled, unavailable, "
          "invoiced, processing, created, approved and 8 delivered orders without a date are excluded.", BODY)],
        [("Late delivery. ", BOLD),
         ("Delivered on a later CALENDAR DATE than the estimated delivery date. The estimate is stored at midnight "
          "(a date, not a time), so the literal timestamp rule - shown as Late Rate % (Timestamp Rule) - also counts "
          "same-day deliveries as late.", BODY)],
        [("Excess late orders. ", BOLD),
         ("Late orders - delivered orders x marketplace late rate: how many late orders a group adds above the average. "
          "Used to prioritise groups because it combines rate and volume.", BODY)],
        [("Lifecycle stages. ", BOLD),
         ("Medians over delivered orders whose two timestamps exist and are in order (1,350 orders handed to the carrier "
          "before approval and 23 delivered before carrier hand-off are excluded from those stages).", BODY)],
        [("Reviews. ", BOLD),
         ("One review per order (most recently answered). Averages ignore orders without a review. Late vs on-time "
          "differences are associations; many late-order reviews are written before delivery.", BODY)],
        [("Order value. ", BOLD),
         ("Item price + freight in BRL for delivered orders. It is gross merchandise value - not Olist revenue and not "
          "profit (the dataset has no cost data). Payments (BRL) can differ (instalment interest, vouchers).", BODY)],
        [("Refresh. ", BOLD),
         ("Rebuild the CSVs with python scripts/build_database.py, then Home > Refresh. The DataFolder parameter "
          "(Transform data > Edit parameters) points to data/processed/.", BODY)],
    ]
    v.append(textbox("definitions_text", 20, 290, 1240, 420, defs, z=12))
    p["definitions"] = ("Metric Definitions", v)
    return p


def write_report(base: Path, validator) -> int:
    d = base / "definition"
    write_json(base / "definition.pbir", {"$schema": S + "item/report/definitionProperties/2.0.0/schema.json",
                                          "version": "4.0",
                                          "datasetReference": {"byPath": {"path": f"../{NAME}.SemanticModel"}}})
    theme_name = "olist_theme.json"
    docs = {
        "version.json": {"$schema": S + "item/report/definition/versionMetadata/1.0.0/schema.json", "version": "2.0.0"},
        "report.json": {
            "$schema": S + "item/report/definition/report/3.3.0/schema.json",
            "themeCollection": {
                "baseTheme": {"name": BASE_THEME, "reportVersionAtImport": VERSIONS, "type": "SharedResources"},
                "customTheme": {"name": theme_name, "reportVersionAtImport": VERSIONS, "type": "RegisteredResources"}},
            "resourcePackages": [
                {"name": "SharedResources", "type": "SharedResources",
                 "items": [{"name": BASE_THEME, "path": f"BaseThemes/{BASE_THEME}.json", "type": "BaseTheme"}]},
                {"name": "RegisteredResources", "type": "RegisteredResources",
                 "items": [{"name": theme_name, "path": theme_name, "type": "CustomTheme"}]}],
            "settings": {"useStylableVisualContainerHeader": True, "defaultDrillFilterOtherVisuals": True,
                         "allowChangeFilterTypes": True, "useEnhancedTooltips": True}},
    }
    all_pages = pages()
    docs["pages/pages.json"] = {"$schema": S + "item/report/definition/pagesMetadata/1.1.0/schema.json",
                                "pageOrder": list(all_pages), "activePageName": next(iter(all_pages))}
    for pid, (display, visuals) in all_pages.items():
        docs[f"pages/{pid}/page.json"] = {"$schema": S + "item/report/definition/page/2.1.0/schema.json",
                                          "name": pid, "displayName": display, "displayOption": "FitToPage",
                                          "height": 720, "width": 1280}
        for vis in visuals:
            docs[f"pages/{pid}/visuals/{vis['name']}/visual.json"] = vis
    for rel, obj in docs.items():
        if validator:
            validator(obj)
        write_json(d / rel, obj)
    res = base / "StaticResources"
    (res / "SharedResources" / "BaseThemes").mkdir(parents=True, exist_ok=True)
    (res / "RegisteredResources").mkdir(parents=True, exist_ok=True)
    if BASE_THEME_SRC.exists():
        shutil.copy(BASE_THEME_SRC, res / "SharedResources" / "BaseThemes" / f"{BASE_THEME}.json")
    shutil.copy(THEME_SRC, res / "RegisteredResources" / theme_name)
    return len(docs)


def write_json(path: Path, obj) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(obj, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def make_validator(schema_dir: Path | None):
    if not schema_dir:
        return None
    import jsonschema
    from referencing import Registry, Resource
    resources = []
    for f in schema_dir.rglob("schema.json"):
        sch = json.loads(f.read_text(encoding="utf-8"))
        resources.append((sch["$id"], Resource.from_contents(sch)))
    registry = Registry().with_resources(resources)

    def validate(obj):
        jsonschema.Draft7Validator(registry.contents(obj["$schema"]), registry=registry).validate(obj)
    return validate


def write_measures_dax() -> None:
    lines = ["// =============================================================================",
             "// Power BI measures - generated by scripts/build_powerbi_project.py (do not edit by hand).",
             "// They live in the _Measures table of powerbi/pbip/delivery_reviews.SemanticModel.",
             "// Flags in the model are 1/0 integers exported from SQLite; blank = not applicable.",
             "// `== 0` (strict) is used so BLANK is never treated as 0 / FALSE.",
             "// ============================================================================="]
    folder = None
    for name, fold, fmt, dax, desc in MEASURES:
        if fold != folder:
            lines += ["", f"// ---------- [{fold}] ----------"]
            folder = fold
        lines += [f"// {desc}  (format: {fmt})", f"{name} =", f"    {dax}", ""]
    (ROOT / "powerbi" / "measures.dax").write_text("\n".join(lines), encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--schemas", type=Path, help="folder with PBIR JSON schemas for validation")
    args = ap.parse_args()
    if not (DATA / "fct_orders.csv").exists():
        raise SystemExit("Run python scripts/build_database.py first (CSV exports missing).")
    for sub in (f"{NAME}.Report", f"{NAME}.SemanticModel"):
        if (OUT / sub).exists():
            shutil.rmtree(OUT / sub)
    write_json(OUT / f"{NAME}.pbip", {"$schema": S + "pbip/pbipProperties/1.0.0/schema.json", "version": "1.0",
                                      "artifacts": [{"report": {"path": f"{NAME}.Report"}}],
                                      "settings": {"enableAutoRecovery": True}})
    write_semantic_model(OUT / f"{NAME}.SemanticModel")
    n = write_report(OUT / f"{NAME}.Report", make_validator(args.schemas))
    write_measures_dax()
    (OUT / ".gitignore").write_text("# Power BI Desktop local cache files\n**/.pbi/localSettings.json\n**/.pbi/cache.abf\n",
                                    encoding="utf-8")
    print(f"PBIP written to {OUT.relative_to(ROOT)}: {len(TABLES) + 1} tables, {len(MEASURES)} measures, "
          f"{len(RELATIONSHIPS)} relationships, {n} report files"
          + (" (schema-validated)" if args.schemas else ""))


if __name__ == "__main__":
    main()
