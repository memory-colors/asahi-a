# Gotchas (each one cost time)

* **LD_PRELOAD on a test command line also hits `timeout`/`env`**: write `timeout N env LD_PRELOAD=... dolphin` (preload inside). The shim scrubs LD_PRELOAD in a constructor so children don't inherit it.
* **Mangled names:** count the identifier length (`setAlternateBackground` = 22). A wrong name builds fine and silently hooks nothing - `build.sh` preflight and `tests/verify.sh` catch it.
* Setting a palette on the QGraphicsView does not reach item text (the scene's palette is separate). Hook `textColor` / `paint` instead.
* Restoring the viewport palette fires DolphinView's own PaletteChange filter -> `updatePalette` again: keep the re-entrancy guard in `opaque_updatePalette`.
* A QSS block marker like `/* NAME BEGIN (text)` must close its comment on that line or the whole block becomes one comment and does nothing.
* Editing the live conf with a naive regex: `\s*` swallows the newline after an EMPTY override value and corrupts the next line (use `[ \t]*`).
* **Never assume the conf holds defaults** - the user experiments live with the Knomadic rows; read it first, scratch copies inherit live values.
* Knomadic runs `/bin/bash <script> ...`: a Python script as a row target silently fails; use the shell entry point `dolphin-color.sh`.
* `dolphin-view-color.sh`-style symlinked wrappers: overwriting the symlink overwrote the real script (exec-itself loop). The wrappers are gone; there is one script.
* QStyleSheetStyle swallows `drawPrimitive(PE_IndicatorBranch)` (no widget) - that is why Dolphin shows no expand arrows under a stylesheet and `arrows.cpp` exists.
* Dolphin is single-instance: a still-running old process keeps the old shim/QSS and new launches join it. Quit all windows before testing a change.
* "Raise the dimming" was meant as LESS dim once: confirm direction on ambiguous dim/strength requests.
* Hover / current / inactive states are not testable from a static screenshot; the dye harness drives them with synthetic events (`sethover` only works once the window is at DYE_SIZE).
* The disk-usage text is a QToolButton: styling `KCapacityBar`'s pinned pen (or hooking `QPainter::setPen`) does nothing visible.
* Offscreen renders: the breadcrumb strip differs run to run (elision/animation); `tests/compare.py` ignores y < 22.

## Known quirks kept on purpose (from the 2026-10-14 code review)
* **Flat hover alpha:** `items.cpp` reads the hover fill with `QImage::pixel()` (unpremultiplied) and writes it into a premultiplied buffer, so the collapsed outline pixels are slightly brighter than strictly correct. The look was approved on both machines ("so gorgeous"), so it is NOT changed; if hover ever needs to be exact, use `qPremultiply(fillPx)` and re-check the look.
* **`paneInactive()`** walks the parent chain with `inherits("DolphinView")` per painted item (cheap string compares, measured negligible); cache the view pointer if profiling ever says otherwise.

## Parked experiment: DOLPHIN_ROWCACHE=1 (row pixmap cache for scrolling)
User A/B on Asahi (2026-10-14): scrolling felt like an improvement, but (1) hover and selection looked STALE and (2) the inactive pane did not re-dim after switching panes. Left default-off.
Likely causes / next steps if revisited: Dolphin changes `m_selected` / `m_current` / hover state without calling `QGraphicsItem::update()` on the row, so the cached pixmap is not invalidated -> hook the exported setters (`KItemListWidget::setSelected`, `setCurrent`, `setHovered`) to call `update()` (or reset the cache) after the original; the pane switch is not re-arming the caches -> also reset caches from `DolphinView::setActive` (not only `updatePalette`, whose timing relative to the active flag is unverified). Cached rows also need `widget` substituted when null (already done in `dim_itemPaint`).

* **URL bar edit-mode text color:** QSS `color` does NOT reach the location editor (`KLineEdit` inside `KUrlComboBox`; tried `QLineEdit`, `KLineEdit`, `KUrlComboBox KLineEdit`, `DolphinUrlNavigator QLineEdit` - none changed the text). `urlbar.cpp` sets the QLineEdit palette (Text/WindowText) from the runtime conf `urltext=` before each navigator paint. Test it with `GRAB_EDIT=1` (tools/grab.cpp puts the bar in edit mode through the exported `KUrlNavigator::setUrlEditable`).
