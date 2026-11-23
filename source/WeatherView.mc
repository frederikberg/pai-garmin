import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// The Weather sub-app in three pages: the next hour and the next twelve hours as two rows, the
// twelve hours as bars, and the radar picture half an hour ahead. Down and Up page, Enter asks
// again, Back leaves.
class WeatherView extends WatchUi.View {
    // the pages, in the order Down walks them
    enum {
        PAGE_ROWS,
        PAGE_HOURS,
        PAGE_RADAR
    }

    private var _call as Call? = null;
    private var _state as WeatherState? = null;
    // what the screen says when there is no state to show
    private var _message as String = "Loading...";
    private var _updating as Boolean = false;
    private var _page as Number = PAGE_ROWS;
    // the radar picture of the current answer, fetched when its page is first shown
    private var _picture as WatchUi.BitmapResource or Graphics.BitmapReference or Null = null;
    private var _pictureLoading as Boolean = false;
    private var _pictureFailed as Boolean = false;

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
        if (_call == null) {
            refresh();
        }
    }

    function onHide() as Void {
        var call = _call;
        if (call != null) {
            call.cancel();
            _call = null;
            _updating = false;
        }
    }

    // Enter: ask the server again, keeping the old answer on screen until the new one arrives.
    function refresh() as Void {
        if (_call != null) {
            return;
        }
        _updating = true;
        if (_state == null) {
            _message = "Loading...";
        }
        var call = new Call(method(:onOutcome));
        _call = call;
        WatchUi.requestUpdate();
        call.send(Api.weather());
    }

    function onOutcome(outcome as Outcome) as Void {
        _call = null;
        _updating = false;
        var data = outcome.data;
        var state = data == null ? null : WeatherState.fromData(data);
        if (state != null) {
            _state = state;
        } else {
            _state = null;
            _message = outcome.isOk() ? "Unexpected answer" : outcome.text();
        }
        // the picture link belongs to one answer and expires with it
        _picture = null;
        _pictureFailed = false;
        _page = _page < pageCount() ? _page : PAGE_ROWS;
        if (_page == PAGE_RADAR) {
            loadPicture();
        }
        WatchUi.requestUpdate();
    }

    // Down; from the last page back to the first.
    function nextPage() as Void {
        turnTo((_page + 1) % pageCount());
    }

    // Up; from the first page to the last.
    function previousPage() as Void {
        turnTo((_page + pageCount() - 1) % pageCount());
    }

    private function turnTo(page as Number) as Void {
        if (page == _page) {
            return;
        }
        _page = page;
        if (_page == PAGE_RADAR && _picture == null && !_pictureFailed) {
            loadPicture();
        }
        WatchUi.requestUpdate();
    }

    // The rows only while there is no answer to page through; the radar page only with a picture.
    private function pageCount() as Number {
        var state = _state;
        if (state == null || WeatherText.problem(state) != null) {
            return 1;
        }
        return state.picturePath == null ? 2 : 3;
    }

    private function loadPicture() as Void {
        var state = _state;
        var path = state == null ? null : state.picturePath;
        if (path == null || _pictureLoading) {
            return;
        }
        _pictureLoading = true;
        var size = pictureSize();
        Communications.makeImageRequest(ServerConfig.url() + path + "&size=" + size, null,
            {:maxWidth => size, :maxHeight => size}, method(:onPicture));
    }

    function onPicture(responseCode as Number, data as WatchUi.BitmapResource or Graphics.BitmapReference or Null) as Void {
        _pictureLoading = false;
        _picture = responseCode == 200 ? data : null;
        _pictureFailed = _picture == null;
        if (_pictureFailed) {
            System.println("radar picture: " + responseCode);
        }
        WatchUi.requestUpdate();
    }

    // The picture is square; this size keeps its labels at the top and bottom edge inside a round screen.
    private function pictureSize() as Number {
        var settings = System.getDeviceSettings();
        return settings.screenWidth * 77 / 100;
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        var state = _state;
        var problem = state == null ? _message : WeatherText.problem(state);
        if (state == null || problem != null) {
            Draw.title(dc, "Weather");
            Draw.paragraph(dc, problem == null ? "" : problem, 30, 80);
            if (_call == null) {
                Draw.hint(dc, "Enter: retry");
            }
            return;
        }
        if (_page == PAGE_HOURS) {
            drawHours(dc, state.later);
        } else if (_page == PAGE_RADAR) {
            drawPicture(dc, state);
        } else {
            drawRows(dc, state);
        }
        drawPageDots(dc);
    }

    private function drawRows(dc as Graphics.Dc, state as WeatherState) as Void {
        row(dc, 26, WeatherText.nowLine(state.now), WeatherText.nowCaption(state.now), state.now);
        row(dc, 55, WeatherText.laterLine(state.later), WeatherText.laterCaption(state.later), state.later);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 81, WeatherText.footer(state, Time.now()), [Graphics.FONT_XTINY]);
        fitted(dc, 89, _updating ? "Updating..." : "Down: hours", [Graphics.FONT_XTINY]);
    }

    // A headline in the verdict's colour with its caption under it; y is the headline's centre in percent.
    private function row(dc as Graphics.Dc, y as Number, line as String, caption as String, outlook as Outlook) as Void {
        dc.setColor(outlook.known() ? Verdict.color(outlook.verdict) : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, y, line, [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY]);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        fitted(dc, y + 11, caption, [Graphics.FONT_XTINY]);
    }

    // Twelve bars, as tall as each hour's chance and coloured by how hard it rains, with every
    // third hour named under them.
    private function drawHours(dc as Graphics.Dc, later as LaterOutlook) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 15, "Next 12 hours", [Graphics.FONT_XTINY]);
        var hours = later.hours;
        if (hours.size() == 0) {
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            fitted(dc, 50, WeatherText.reasonText(later), [Graphics.FONT_SMALL]);
            return;
        }
        var left = w * 16 / 100;
        var span = w * 68 / 100;
        var top = h * 27 / 100;
        var bottom = h * 62 / 100;
        var slot = span / hours.size();
        var gap = slot > 6 ? 2 : 1;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(left, bottom, left + slot * hours.size(), bottom);
        for (var i = 0; i < hours.size(); i++) {
            var hour = hours[i];
            var x = left + i * slot;
            var tall = (bottom - top) * hour.chance / 100;
            dc.setColor(intensityColor(hour.intensity), Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x + gap / 2, bottom - (tall < 2 ? 2 : tall), slot - gap, tall < 2 ? 2 : tall);
            if (i % 3 == 0) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + slot / 2, h * 68 / 100, Graphics.FONT_XTINY, AlarmTime.hhmm(hour.start).substring(0, 2) as String,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 78, WeatherText.laterCaption(later), [Graphics.FONT_XTINY]);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 88, _updating ? "Updating..." : WeatherText.chance(later) + " at most", [Graphics.FONT_XTINY]);
    }

    // The picture centred, with when its frame is above it.
    private function drawPicture(dc as Graphics.Dc, state as WeatherState) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var picture = _picture;
        if (picture != null) {
            dc.drawBitmap((w - picture.getWidth()) / 2, (h - picture.getHeight()) / 2, picture);
        } else {
            dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawCircle(w / 2, h / 2, pictureSize() / 2);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            fitted(dc, 47, _pictureFailed ? "No picture" : "Loading radar...", [Graphics.FONT_TINY, Graphics.FONT_XTINY]);
            fitted(dc, 56, _pictureFailed ? "Enter: refresh" : "", [Graphics.FONT_XTINY]);
        }
        var at = state.pictureAt;
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 9, at == null ? "Radar" : "Radar " + AlarmTime.hhmm(at), [Graphics.FONT_XTINY]);
    }

    // Small dots on the left edge, one per page, the current one filled.
    private function drawPageDots(dc as Graphics.Dc) as Void {
        var count = pageCount();
        if (count < 2) {
            return;
        }
        var x = dc.getWidth() * 6 / 100;
        var step = dc.getHeight() * 6 / 100;
        var y0 = dc.getHeight() / 2 - step * (count - 1) / 2;
        for (var i = 0; i < count; i++) {
            dc.setColor(i == _page ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (i == _page) {
                dc.fillCircle(x, y0 + i * step, 4);
            } else {
                dc.drawCircle(x, y0 + i * step, 3);
            }
        }
    }

    private function fitted(dc as Graphics.Dc, y as Number, text as String, fonts as Array<Graphics.FontType>) as Void {
        Draw.fitted(dc, y, text, fonts);
    }

    private function intensityColor(intensity as String) as Graphics.ColorType {
        if (intensity.equals("heavy")) {
            return 0x0055FF;
        } else if (intensity.equals("moderate")) {
            return 0x55AAFF;
        } else if (intensity.equals("light")) {
            return 0xAAFFFF;
        }
        return Graphics.COLOR_DK_GRAY;
    }
}

class WeatherDelegate extends WatchUi.BehaviorDelegate {
    private var _view as WeatherView;

    function initialize(view as WeatherView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.refresh();
        return true;
    }

    function onNextPage() as Boolean {
        _view.nextPage();
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.previousPage();
        return true;
    }
}
