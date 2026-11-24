import Toybox.Communications;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.WatchUi;

// The Weather sub-app in up to six pages (WeatherPages.list): the twelve-hour symbol above the
// next hour and the next twelve hours as two rows, the rain as bars, the temperature, the UV
// index, four days, and the radar picture half an hour ahead. Down and Up page, Enter asks again,
// Back leaves.
class WeatherView extends WatchUi.View {
    private var _call as Call? = null;
    private var _state as WeatherState? = null;
    // what the screen says when there is no state to show
    private var _message as String = "Loading...";
    private var _updating as Boolean = false;
    // the last refresh failed and the answer on screen is the one from before
    private var _stale as Boolean = false;
    private var _page as Number = WeatherPages.ROWS;
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
        if (WeatherText.keepsOver(_state, state, Time.now())) {
            _stale = true;
        } else {
            _state = state;
            _stale = false;
            // the picture link belongs to one answer and expires with it
            _picture = null;
            _pictureFailed = false;
            if (state == null) {
                _message = outcome.isOk() ? "Unexpected answer" : outcome.text();
            }
        }
        _page = pages().indexOf(_page) >= 0 ? _page : WeatherPages.ROWS;
        if (_page == WeatherPages.RADAR && _picture == null && !_pictureFailed) {
            loadPicture();
        }
        WatchUi.requestUpdate();
    }

    // Down; from the last page back to the first.
    function nextPage() as Void {
        var all = pages();
        turnTo(all[(all.indexOf(_page) + 1) % all.size()]);
    }

    // Up; from the first page to the last.
    function previousPage() as Void {
        var all = pages();
        turnTo(all[(all.indexOf(_page) + all.size() - 1) % all.size()]);
    }

    private function turnTo(page as Number) as Void {
        if (page == _page) {
            return;
        }
        _page = page;
        if (_page == WeatherPages.RADAR && _picture == null && !_pictureFailed) {
            loadPicture();
        }
        WatchUi.requestUpdate();
    }

    private function pages() as Array<Number> {
        var state = _state;
        return state == null ? [WeatherPages.ROWS] as Array<Number> : WeatherPages.list(state);
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
        if (_page == WeatherPages.HOURS) {
            drawHours(dc, state.later);
        } else if (_page == WeatherPages.RADAR) {
            drawPicture(dc, state);
        } else if (_page == WeatherPages.TEMP) {
            drawTemp(dc, state.conditions);
        } else if (_page == WeatherPages.UV) {
            drawUv(dc, state);
        } else if (_page == WeatherPages.DAYS) {
            drawDays(dc, state.conditions);
        } else {
            drawRows(dc, state);
        }
        drawPageDots(dc);
    }

    private function drawRows(dc as Graphics.Dc, state as WeatherState) as Void {
        drawSummary(dc, state.conditions);
        row(dc, 39, WeatherText.nowLine(state.now), WeatherText.nowCaption(state.now), state.now);
        row(dc, 61, WeatherText.laterLine(state.later), WeatherText.laterCaption(state.later), state.later);
        bottom(dc, 82, WeatherText.footer(state, Time.now()));
    }

    // The 12-hour symbol with the highest temperature over the lowest beside it.
    private function drawSummary(dc as Graphics.Dc, c as Conditions) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        var max = c.tempMax;
        var min = c.tempMin;
        if (!c.known() || max == null || min == null) {
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            fitted(dc, 20, "no forecast", [Graphics.FONT_XTINY]);
            return;
        }
        smooth(dc, true);
        WeatherIcons.draw(dc, w * 36 / 100, h * 20 / 100, w * 20 / 100, c.symbol, c.night);
        smooth(dc, false);
        var x = w * 56 / 100;
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h * 13 / 100, Graphics.FONT_MEDIUM, ConditionsText.degrees(max), Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, h * 27 / 100, Graphics.FONT_SMALL, ConditionsText.degrees(min), Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(x - 2, h * 205 / 1000, x + w * 17 / 100, h * 205 / 1000);
    }

    private function smooth(dc as Graphics.Dc, on as Boolean) as Void {
        if (dc has :setAntiAlias) {
            dc.setAntiAlias(on);
        }
    }

    // Twelve temperature bars between the lowest and highest hour, with the symbol above and the
    // hour and temperature below every third.
    private function drawTemp(dc as Graphics.Dc, c as Conditions) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 13, "Temperature", [Graphics.FONT_XTINY]);
        var hours = c.hours;
        if (hours.size() == 0) {
            return;
        }
        var lo = hours[0].temp;
        var hi = lo;
        for (var i = 1; i < hours.size(); i++) {
            var t = hours[i].temp;
            lo = t < lo ? t : lo;
            hi = t > hi ? t : hi;
        }
        var left = w * 16 / 100;
        var span = w * 68 / 100;
        var top = h * 34 / 100;
        var bottom = h * 60 / 100;
        var slot = span / hours.size();
        var gap = slot > 6 ? 2 : 1;
        var floor = (bottom - top) / 4;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(left, bottom, left + slot * hours.size(), bottom);
        for (var i = 0; i < hours.size(); i++) {
            var hour = hours[i];
            var x = left + i * slot;
            var tall = hi == lo ? (bottom - top) / 2 : floor + (bottom - top - floor) * (hour.temp - lo) / (hi - lo);
            dc.setColor(hour.temp <= 0 ? 0xAAFFFF : 0xFFAA00, Graphics.COLOR_TRANSPARENT);
            dc.fillRectangle(x + gap / 2, bottom - tall, slot - gap, tall);
            if (i % 3 == 0) {
                smooth(dc, true);
                WeatherIcons.draw(dc, x + slot / 2, h * 24 / 100, w * 10 / 100, hour.symbol, hour.night);
                smooth(dc, false);
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + slot / 2, h * 66 / 100, Graphics.FONT_XTINY, AlarmTime.hhmm(hour.start).substring(0, 2) as String,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + slot / 2, h * 75 / 100, Graphics.FONT_TINY, ConditionsText.degrees(hour.temp),
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
        var now = c.tempNow;
        bottom(dc, 86, now == null ? "" : "now " + ConditionsText.degrees(now));
    }

    // The UV index now as a headline in its band's colour, and twelve bars on a fixed scale.
    private function drawUv(dc as Graphics.Dc, state as WeatherState) as Void {
        var c = state.conditions;
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 12, "UV index", [Graphics.FONT_XTINY]);
        var now = c.uvNow;
        dc.setColor(now == null || ConditionsText.uvWhole(now) == 0 ? Graphics.COLOR_LT_GRAY : ConditionsText.uvColor(now), Graphics.COLOR_TRANSPARENT);
        fitted(dc, 24, ConditionsText.uvLine(c), [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]);
        var hours = c.hours;
        var left = w * 16 / 100;
        var span = w * 68 / 100;
        var top = h * 35 / 100;
        var bottom = h * 60 / 100;
        var slot = hours.size() == 0 ? span : span / hours.size();
        var gap = slot > 6 ? 2 : 1;
        dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
        dc.drawLine(left, bottom, left + slot * hours.size(), bottom);
        for (var i = 0; i < hours.size(); i++) {
            var hour = hours[i];
            var x = left + i * slot;
            var value = hour.uv;
            if (value != null) {
                var uv = value > 11 ? 11.0 : value;
                var tall = ((bottom - top) * uv / 11).toNumber();
                dc.setColor(ConditionsText.uvWhole(value) == 0 ? Graphics.COLOR_DK_GRAY : ConditionsText.uvColor(value), Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(x + gap / 2, bottom - (tall < 2 ? 2 : tall), slot - gap, tall < 2 ? 2 : tall);
            }
            if (i % 3 == 0) {
                dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawText(x + slot / 2, h * 66 / 100, Graphics.FONT_XTINY, AlarmTime.hhmm(hour.start).substring(0, 2) as String,
                    Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 75, ConditionsText.uvCaption(c), [Graphics.FONT_XTINY]);
        bottom(dc, 84, WeatherText.footer(state, Time.now()));
    }

    // One row a day: its name, symbol, highest and lowest temperature and the chance of rain.
    private function drawDays(dc as Graphics.Dc, c as Conditions) as Void {
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, 10, "Daily", [Graphics.FONT_XTINY]);
        var days = c.days;
        var mid = Graphics.TEXT_JUSTIFY_VCENTER;
        for (var i = 0; i < days.size() && i < 4; i++) {
            var day = days[i];
            var y = h * (24 + 17 * i) / 100;
            if (i > 0) {
                dc.setColor(Graphics.COLOR_DK_GRAY, Graphics.COLOR_TRANSPARENT);
                dc.drawLine(w * 12 / 100, y - h * 17 / 200, w * 90 / 100, y - h * 17 / 200);
            }
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 12 / 100, y, Graphics.FONT_TINY, day.name, Graphics.TEXT_JUSTIFY_LEFT | mid);
            smooth(dc, true);
            WeatherIcons.draw(dc, w * 37 / 100, y, w * 11 / 100, day.symbol, false);
            smooth(dc, false);
            dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 58 / 100, y, Graphics.FONT_SMALL, ConditionsText.degrees(day.tempMax), Graphics.TEXT_JUSTIFY_RIGHT | mid);
            dc.setColor(Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w * 75 / 100, y, Graphics.FONT_TINY, ConditionsText.degrees(day.tempMin), Graphics.TEXT_JUSTIFY_RIGHT | mid);
            var chance = day.chance;
            if (chance != null) {
                dc.setColor(chance < 10 ? Graphics.COLOR_LT_GRAY : 0x55AAFF, Graphics.COLOR_TRANSPARENT);
                dc.drawText(w * 90 / 100, y, Graphics.FONT_XTINY, chance + "%", Graphics.TEXT_JUSTIFY_RIGHT | mid);
            }
        }
        bottom(dc, 89, "Open-Meteo");
    }

    // A headline in the verdict's colour with its caption under it; y is the headline's centre in percent.
    private function row(dc as Graphics.Dc, y as Number, line as String, caption as String, outlook as Outlook) as Void {
        dc.setColor(outlook.known() ? Verdict.color(outlook.verdict) : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, y, line, [Graphics.FONT_MEDIUM, Graphics.FONT_SMALL, Graphics.FONT_TINY]);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        fitted(dc, y + 10, caption, [Graphics.FONT_XTINY]);
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
        bottom(dc, 88, WeatherText.chance(later) + " at most");
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
        bottom(dc, 9, at == null ? "Radar" : "Radar " + AlarmTime.hhmm(at));
    }

    // Small dots on the left edge, one per page, the current one filled.
    private function drawPageDots(dc as Graphics.Dc) as Void {
        var all = pages();
        var count = all.size();
        if (count < 2) {
            return;
        }
        var x = dc.getWidth() * 6 / 100;
        var step = dc.getHeight() * 6 / 100;
        var y0 = dc.getHeight() / 2 - step * (count - 1) / 2;
        for (var i = 0; i < count; i++) {
            dc.setColor(all[i] == _page ? Graphics.COLOR_WHITE : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            if (all[i] == _page) {
                dc.fillCircle(x, y0 + i * step, 4);
            } else {
                dc.drawCircle(x, y0 + i * step, 3);
            }
        }
    }

    // A page's last line (the radar page's first): that a request runs, or that the answer on screen
    // is out of date, else the page's own text.
    private function bottom(dc as Graphics.Dc, y as Number, text as String) as Void {
        var state = _state;
        var stale = _stale && !_updating && state != null;
        dc.setColor(stale ? 0xFFAA00 : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
        fitted(dc, y, _updating ? "Updating..." : stale && state != null ? WeatherText.staleNote(state.arrivedAt) : text, [Graphics.FONT_XTINY]);
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
