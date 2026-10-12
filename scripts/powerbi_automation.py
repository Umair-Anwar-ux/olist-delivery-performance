"""Drive Power BI Desktop to build, export and verify the report (Windows only).

Commands
    python scripts/powerbi_automation.py build
        Opens powerbi/pbip/delivery_reviews.pbip, refreshes it from data/processed/*.csv,
        exports the report to PDF (reports/delivery_reviews_dashboard.pdf), renders each
        page to screenshots/powerbi_page<N>_<name>.png, and saves the report as
        powerbi/delivery_reviews.pbix (File > Save as > Power BI file).
    python scripts/powerbi_automation.py verify --adomd <AdomdClient.dll>
        Opens powerbi/delivery_reviews.pbix (data embedded, no refresh), captures a
        screenshot of the Desktop window, and reconciles every headline metric in
        reports/headline_metrics.json against DAX measures evaluated in the .pbix
        model -> reports/powerbi_reconciliation.md. Exits 1 on any mismatch.

Requires: Power BI Desktop, pip install pywinauto pillow pypdfium2.
The script clicks through Desktop's UI: leave the machine alone while it runs.
Every step can also be done by hand - see powerbi/README.md.
"""
from __future__ import annotations

import argparse
import glob
import json
import math
import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from PIL import ImageGrab
from pywinauto import Desktop

ROOT = Path(__file__).resolve().parents[1]
EXE = r"C:\Program Files\Microsoft Power BI Desktop\bin\PBIDesktop.exe"
PBIP = ROOT / "powerbi" / "pbip" / "delivery_reviews.pbip"
PBIX = ROOT / "powerbi" / "delivery_reviews.pbix"
PDF_OUT = ROOT / "reports" / "delivery_reviews_dashboard.pdf"
SHOTS = ROOT / "screenshots"
PAGE_FILES = ["powerbi_page1_business_overview.png", "powerbi_page2_delivery_operations.png",
              "powerbi_page3_customer_experience.png", "powerbi_page4_metric_definitions.png"]


# ----------------------------------------------------------------------------- UI helpers
def pbi_pids() -> set[int]:
    out = subprocess.run(["tasklist", "/FI", "IMAGENAME eq PBIDesktop.exe", "/FO", "CSV", "/NH"],
                         capture_output=True, text=True).stdout
    return {int(l.split('","')[1]) for l in out.splitlines() if l.startswith('"PBIDesktop')}


def windows():
    pids = pbi_pids()
    return [w for w in Desktop(backend="uia").windows() if w.process_id() in pids]


def main_window(timeout: float = 240):
    """Largest visible Power BI window (restores it if minimized)."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        for w in windows():
            if w.window_text() and not w.is_visible() and w.rectangle().width() == 0:
                try:
                    w.restore(); w.set_focus(); time.sleep(2)
                except Exception:
                    pass
        ws = [w for w in windows() if w.is_visible() and w.rectangle().width() > 800]
        if ws:
            return max(ws, key=lambda w: w.rectangle().width() * w.rectangle().height())
        time.sleep(2)
    raise TimeoutError("Power BI Desktop window not found")


def find(win, title, control_type=None, timeout: float = 10):
    t0 = time.time()
    while time.time() - t0 < timeout:
        for el in win.descendants(control_type=control_type) if control_type else win.descendants():
            if (el.window_text() or "") == title:
                return el
        time.sleep(1)
    return None


def dialogs(win):
    return [c for c in win.children() if c.element_info.control_type == "Window"]


def click_banner_and_wait(name: str, max_wait: float = 900, max_clicks: int = 4) -> bool:
    """Click a notification-bar button ('Refresh now', 'Apply changes') until no such bar remains.

    Opening a project can show two bars in turn ('calculated objects need to be refreshed',
    then 'some tables have incomplete or no data'), each with its own 'Refresh now'.
    """
    clicks, t0 = 0, time.time()
    while time.time() - t0 < max_wait:
        w = main_window(30)
        if dialogs(w):                       # refresh / apply progress dialog still open
            time.sleep(5)
            continue
        b = find(w, name, "Button", timeout=3)
        if not b:
            if clicks:
                print(f"  {name}: done in {time.time() - t0:.0f}s ({clicks} click(s))")
            return clicks > 0
        if clicks >= max_clicks:
            raise TimeoutError(f"'{name}' still shown after {clicks} clicks")
        b.invoke()
        clicks += 1
        time.sleep(20)
    raise TimeoutError(f"{name} did not finish")


def open_in_desktop(path: Path):
    if pbi_pids():
        raise SystemExit("Close Power BI Desktop before running this script.")
    subprocess.Popen([EXE, str(path)])
    time.sleep(20)
    w = main_window(300)
    w.maximize()
    time.sleep(10)
    return w


def backstage(tab: str):
    w = main_window(30)
    find(w, "File", "TabItem", timeout=10).select()
    time.sleep(4)
    find(main_window(30), tab, "TabItem", timeout=10).select()
    time.sleep(4)
    return main_window(30)


def window_shot(path: Path):
    w = main_window(30)
    w.set_focus()
    time.sleep(1)
    r = w.rectangle()
    ImageGrab.grab(bbox=(max(r.left, 0), max(r.top, 0), r.right, r.bottom), all_screens=True).save(path)


def close_desktop():
    for pid in pbi_pids():
        subprocess.run(["taskkill", "/PID", str(pid), "/F"], capture_output=True)
    time.sleep(5)


# ----------------------------------------------------------------------------- build
def export_pdf_and_screenshots():
    started = time.time()
    w = backstage("Export")
    find(w, "Export to PDF", "Button", timeout=10).invoke()
    pdf = None
    for _ in range(120):          # Desktop writes the PDF to %TEMP%\Power BI Desktop\print-job-*
        time.sleep(5)
        cands = [p for p in glob.glob(os.path.join(os.environ["TEMP"], "Power BI Desktop", "print-job-*", "*.pdf"))
                 if os.path.getmtime(p) > started]
        if cands and not dialogs(main_window(30)):
            pdf = max(cands, key=os.path.getmtime)
            break
    if not pdf:
        raise TimeoutError("PDF export did not appear")
    time.sleep(3)
    shutil.copy(pdf, PDF_OUT)
    import pypdfium2 as pdfium
    doc = pdfium.PdfDocument(str(PDF_OUT))
    SHOTS.mkdir(exist_ok=True)
    for i, name in enumerate(PAGE_FILES[: len(doc)]):
        doc[i].render(scale=2.0).to_pil().save(SHOTS / name)
        print(f"  screenshots/{name}")
    print(f"  {PDF_OUT.relative_to(ROOT)} ({len(doc)} pages)")


def save_as_pbix():
    if PBIX.exists():
        PBIX.unlink()
    w = backstage("Save as")
    find(w, "Browse this device", "Button", timeout=10).click_input()
    time.sleep(4)
    dlg = next(c for c in dialogs(main_window(30)) if c.window_text() in ("Save As", "Save as"))
    combo = next(el for el in dlg.descendants(control_type="ComboBox") if el.window_text() == "Save as type:")
    combo.expand(); time.sleep(1)
    next(li for li in combo.descendants(control_type="ListItem")
         if li.window_text().startswith("Power BI file (*.pbix)")).select()
    time.sleep(1)
    next(el for el in dlg.descendants(control_type="Edit") if el.window_text() == "File name:").set_edit_text(str(PBIX))
    next(b for b in dlg.descendants(control_type="Button") if b.window_text() == "Save").click_input()
    for _ in range(120):
        time.sleep(3)
        if PBIX.exists() and PBIX.stat().st_size > 0 and not dialogs(main_window(30)):
            break
    time.sleep(10)
    print(f"  {PBIX.relative_to(ROOT)} ({PBIX.stat().st_size / 1e6:.1f} MB)")


def build():
    print("Opening", PBIP.relative_to(ROOT))
    open_in_desktop(PBIP)
    if not click_banner_and_wait("Refresh now"):
        raise SystemExit("Expected the 'Refresh now' bar after opening the project.")
    click_banner_and_wait("Apply changes")
    print("Exporting PDF and page images")
    export_pdf_and_screenshots()
    print("Saving .pbix")
    save_as_pbix()
    close_desktop()


# ----------------------------------------------------------------------------- verify
# headline metric -> DAX expression evaluated in the .pbix model
DAX_CHECKS = {
    "total_orders": "[Total Orders]",
    "delivery_kpi_orders": "[Delivered Orders]",
    "late_orders": "[Late Orders]",
    "late_rate": "[Late Rate %]",
    "late_rate_timestamp_rule": "[Late Rate % (Timestamp Rule)]",
    "reviewed_on_time_orders": "CALCULATE ( [Reviewed Orders], fct_orders[is_late] == 0 )",
    "reviewed_late_orders": "CALCULATE ( [Reviewed Orders], fct_orders[is_late] = 1 )",
    "avg_review_on_time": "[Avg Review Score (On Time)]",
    "avg_review_late": "[Avg Review Score (Late)]",
    "avg_review_delivered": "[Avg Review Score (Delivered)]",
    "avg_review_all_orders": "[Avg Review Score]",
    "late_reviews_created_before_delivery_share": "[Late Reviews Written Before Delivery %]",
    "avg_review_late_post_delivery_reviews": "[Avg Review Score (Late, Written After Delivery)]",
    "canceled_orders": "[Canceled Orders]",
    "unavailable_orders": "[Unavailable Orders]",
    "lifecycle_valid_orders": "CALCULATE ( [Total Orders], fct_orders[is_lifecycle_valid] = 1 )",
    "median_hours_purchase_to_approval": "[Median Hours Purchase to Approval]",
    "median_days_approval_to_carrier": "[Median Days Approval to Carrier]",
    "median_days_carrier_to_customer": "[Median Days Carrier to Customer]",
    "p90_days_carrier_to_customer": "PERCENTILEX.INC ( FILTER ( fct_orders, NOT ISBLANK ( fct_orders[days_carrier_to_customer] ) ), fct_orders[days_carrier_to_customer], 0.9 )",
    "median_days_purchase_to_delivery": "[Median Days Purchase to Delivery]",
    "median_days_promised": "CALCULATE ( MEDIAN ( fct_orders[days_purchase_to_estimate] ), fct_orders[is_delivery_kpi_eligible] = 1 )",
    "delivered_order_value_brl": "[Delivered Order Value (BRL)]",
    "total_items_plus_freight_brl": "SUM ( fct_orders[order_value_brl] )",
    "total_payments_brl": "[Payments (BRL)]",
    "orders_main_payment_credit_card": "CALCULATE ( [Total Orders], fct_orders[main_payment_type] = \"credit_card\" )",
    "orders_main_payment_boleto": "CALCULATE ( [Total Orders], fct_orders[main_payment_type] = \"boleto\" )",
    "orders_main_payment_voucher": "CALCULATE ( [Total Orders], fct_orders[main_payment_type] = \"voucher\" )",
    "orders_main_payment_debit_card": "CALCULATE ( [Total Orders], fct_orders[main_payment_type] = \"debit_card\" )",
    "northeast_late_rate": "CALCULATE ( [Late Rate %], dim_customer[customer_region] = \"Northeast\" )",
    "rj_excess_late_orders": "CALCULATE ( [Excess Late Orders], dim_customer[customer_state] = \"RJ\" )",
    "sp_to_rj_lane_excess_late_orders": "CALCULATE ( [Excess Late Orders], fct_order_items[Lane] = \"SP -> RJ\" )",
    "sp_to_rj_lane_delivered_orders": "CALCULATE ( [Delivered Orders], fct_order_items[Lane] = \"SP -> RJ\" )",
    "bed_bath_table_delivered_orders": "CALCULATE ( [Delivered Orders], dim_product[category] = \"bed_bath_table\" )",
    "median_days_carrier_to_customer_on_time_valid_lifecycle": "CALCULATE ( [Median Days Carrier to Customer (Valid Lifecycle)], fct_orders[is_late] == 0 )",
    "median_days_carrier_to_customer_late_valid_lifecycle": "CALCULATE ( [Median Days Carrier to Customer (Valid Lifecycle)], fct_orders[is_late] = 1 )",
    "median_days_approval_to_carrier_on_time_valid_lifecycle": "CALCULATE ( [Median Days Approval to Carrier (Valid Lifecycle)], fct_orders[is_late] == 0 )",
    "median_days_approval_to_carrier_late_valid_lifecycle": "CALCULATE ( [Median Days Approval to Carrier (Valid Lifecycle)], fct_orders[is_late] = 1 )",
}


def run_dax(adomd: Path, query: str) -> list[dict]:
    out = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                          str(ROOT / "scripts" / "dax_query.ps1"), "-AdomdDll", str(adomd), "-Query", query],
                         capture_output=True, text=True)
    if out.returncode != 0:
        raise RuntimeError(out.stderr or out.stdout)
    rows = json.loads(out.stdout)["rows"]
    return rows if isinstance(rows, list) else [rows]


def reconcile(adomd: Path) -> bool:
    sql = json.loads((ROOT / "reports" / "headline_metrics.json").read_text(encoding="utf-8"))["metrics"]
    names = list(DAX_CHECKS)
    query = "EVALUATE ROW ( " + ", ".join(f'"{n}", {DAX_CHECKS[n]}' for n in names) + " )"
    row = run_dax(adomd, query)[0]
    values = {k.strip("[]"): v for k, v in row.items()}
    lines = ["# Power BI reconciliation: .pbix model vs SQLite headline metrics", "",
             "Generated by `scripts/powerbi_automation.py verify`. Each DAX expression was evaluated in "
             "`powerbi/delivery_reviews.pbix` (opened in Power BI Desktop) and compared with "
             "`reports/headline_metrics.json` from the SQLite build. Tolerance: relative 1e-9.", "",
             "| metric | DAX expression | SQLite | Power BI | status |", "|---|---|---:|---:|---|"]
    bad = []
    for n in names:
        s, p = sql.get(n), values.get(n)
        ok = s is not None and p is not None and math.isclose(float(s), float(p), rel_tol=1e-9, abs_tol=1e-9)
        if not ok:
            bad.append(n)
        lines.append(f"| {n} | `{DAX_CHECKS[n]}` | {s:,.6g} | {'' if p is None else f'{float(p):,.6g}'} | "
                     f"{'match' if ok else '**MISMATCH**'} |")
    lines += ["", f"**{len(names) - len(bad)} of {len(names)} metrics match.**"]
    (ROOT / "reports" / "powerbi_reconciliation.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  {len(names) - len(bad)}/{len(names)} metrics match -> reports/powerbi_reconciliation.md")
    if bad:
        print("  mismatches:", bad)
    return not bad


def verify(adomd: Path) -> None:
    if not PBIX.exists():
        raise SystemExit("powerbi/delivery_reviews.pbix not found - run the build command first.")
    print("Opening", PBIX.relative_to(ROOT))
    open_in_desktop(PBIX)
    expected = ("Business Overview", "Delivery Operations", "Customer Experience", "Metric Definitions")
    pages = []
    for _ in range(12):            # page tabs appear in the UI tree only after the report renders
        pages = [p for p in expected if find(main_window(30), p, "TabItem", timeout=2)]
        if len(pages) == len(expected):
            break
        time.sleep(5)
    print("  report pages found:", pages)
    window_shot(SHOTS / "powerbi_desktop_window.png")
    print("  screenshots/powerbi_desktop_window.png")
    ok = reconcile(adomd)
    close_desktop()
    if len(set(pages)) < 3 or not ok:
        sys.exit(1)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("command", choices=["build", "verify"])
    ap.add_argument("--adomd", type=Path, help="path to Microsoft.AnalysisServices.AdomdClient.dll (verify)")
    a = ap.parse_args()
    if a.command == "build":
        build()
    else:
        if not a.adomd or not a.adomd.exists():
            raise SystemExit("verify needs --adomd <Microsoft.AnalysisServices.AdomdClient.dll> (see powerbi/README.md)")
        verify(a.adomd)
