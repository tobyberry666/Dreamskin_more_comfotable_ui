import argparse, json, pathlib, time
from playwright.sync_api import sync_playwright

parser = argparse.ArgumentParser()
parser.add_argument("--base", default="http://127.0.0.1:9336")
parser.add_argument("--output", default="../verification")
args = parser.parse_args()
out = pathlib.Path(args.output).resolve()
out.mkdir(parents=True, exist_ok=True)
errors = []
results = {}
with sync_playwright() as p:
    browser = p.chromium.launch(channel="msedge", headless=True)
    page = browser.new_page(viewport={"width":1440,"height":1060}, device_scale_factor=1)
    api_responses = []
    page.on("pageerror", lambda error: errors.append(str(error)))
    page.on("response", lambda r: api_responses.append({"url":r.url,"status":r.status}) if "/api/" in r.url else None)
    page.goto(args.base, wait_until="domcontentloaded")
    results["page_title"] = page.title()
    page.locator("#service").filter(has_text="已连接").wait_for(timeout=15000)
    try:
        page.locator("#grid .card").first.wait_for(timeout=20000)
    except Exception:
        page.screenshot(path=str(out / "gallery-failure.png"), full_page=True)
        print(json.dumps({"errors":errors,"text":page.locator("body").inner_text()},ensure_ascii=False))
        raise
    results["online_cards"] = page.locator("#grid .card").count()
    page.locator("#theme-link").fill("https://dreamskin.cc/themes/ver_636b0ac227d23f7bf741")
    page.locator("#lookup").click()
    try:
        page.locator("#link-result").get_by_text("雨过青瓷", exact=True).wait_for(timeout=20000)
    except Exception:
        page.screenshot(path=str(out / "gallery-failure.png"), full_page=True)
        print(json.dumps({"errors":errors,"api":api_responses,"text":page.locator("body").inner_text()},ensure_ascii=False))
        raise
    results["lookup"] = page.locator("#link-result").inner_text()
    page.screenshot(path=str(out / "gallery-online.png"), full_page=True)
    started = time.perf_counter()
    page.locator("#nav-saved").click()
    page.locator("#grid .card").first.wait_for(timeout=10000)
    results["saved_tab_ms"] = round((time.perf_counter()-started)*1000)
    results["saved_cards"] = page.locator("#grid .card").count()
    results["saved_text"] = page.locator("#grid").inner_text()
    page.screenshot(path=str(out / "gallery-saved.png"), full_page=True)
    page.set_viewport_size({"width":390,"height":844})
    results["narrow_overflow"] = page.evaluate("document.documentElement.scrollWidth > innerWidth")
    page.screenshot(path=str(out / "gallery-narrow.png"), full_page=True)
    assert not results["narrow_overflow"], "narrow screen horizontal overflow"
    results["page_errors"] = errors
    assert not errors, str(errors)
    browser.close()
(out / "ui-check.json").write_text(json.dumps(results,ensure_ascii=False,indent=2),encoding="utf-8")
print(json.dumps(results,ensure_ascii=False,indent=2))
