import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Time;
import Toybox.WatchUi;

// The Alarm sub-app: "+ New" first, then the armed alarms by fire time. Enter creates or edits
// through the time picker; holding Up on an alarm opens its delete menu. Every change goes to the
// server and the list is read again afterwards, so the screen always shows the server's state.
class AlarmListView extends WatchUi.View {
    // index 0 is "+ New", index n is _alarms[n - 1]
    private var _selected as Number = 0;
    private var _alarms as Array<Alarm> = [];
    // shown instead of the list while loading, saving or after a failure
    private var _message as String? = "Loading...";
    private var _retry as Boolean = false;
    private var _call as Call? = null;
    private var _started as Boolean = false;
    private var _editing as Alarm? = null;
    // fire time (epoch seconds) of the alarm just saved: the list selects it once it is loaded
    private var _focusAt as Number? = null;
    // the alarm an edit replaces once its successor is saved
    private var _replaced as Alarm? = null;

    function initialize() {
        View.initialize();
    }

    function onShow() as Void {
        if (!_started) {
            _started = true;
            reload();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, "Alarm");
        var message = _message;
        if (message != null) {
            Draw.paragraph(dc, message, 30, 80);
            if (_retry) {
                Draw.hint(dc, "Enter: retry");
            }
            return;
        }
        var now = Time.now();
        var rowHeight = dc.getHeight() / 5;
        for (var offset = -1; offset <= 1; offset++) {
            var index = _selected + offset;
            if (index < 0 || index > _alarms.size()) {
                continue;
            }
            var chosen = offset == 0;
            dc.setColor(chosen ? (index == 0 ? Graphics.COLOR_GREEN : Graphics.COLOR_WHITE) : Graphics.COLOR_LT_GRAY, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() / 2 + offset * rowHeight, chosen ? Graphics.FONT_MEDIUM : Graphics.FONT_SMALL,
                label(index, now), Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        if (_selected > 0) {
            Draw.hint(dc, "Hold Up: delete");
        }
    }

    private function label(index as Number, now as Time.Moment) as String {
        if (index == 0) {
            return "+ New";
        }
        var at = _alarms[index - 1].fireAt;
        return AlarmTime.hhmm(at) + " " + AlarmTime.dayLabel(at, now);
    }

    // Keys act on the list only; a message or a request in flight owns the screen.
    private function listActive() as Boolean {
        return _message == null && _call == null;
    }

    function step(delta as Number) as Void {
        if (listActive()) {
            var moved = _selected + delta;
            _selected = moved < 0 ? 0 : (moved > _alarms.size() ? _alarms.size() : moved);
            WatchUi.requestUpdate();
        }
    }

    function activate() as Void {
        if (_call != null) {
            return;
        }
        if (_message != null) {
            if (_retry) {
                reload();
            }
        } else if (_selected == 0) {
            var next = (AlarmTime.hour(Time.now()) + 1) % 24;
            TimeEntryView.open("New alarm", next, 0, method(:onCreatePicked));
        } else {
            var alarm = _alarms[_selected - 1];
            _editing = alarm;
            TimeEntryView.open("Edit alarm", AlarmTime.hour(alarm.fireAt), AlarmTime.minute(alarm.fireAt), method(:onEditPicked));
        }
    }

    function openDelete() as Void {
        if (!listActive() || _selected == 0) {
            return;
        }
        var alarm = _alarms[_selected - 1];
        var menu = new WatchUi.Menu2({:title => AlarmTime.hhmm(alarm.fireAt)});
        menu.addItem(new WatchUi.MenuItem("Delete", null, :delete, null));
        WatchUi.pushView(menu, new DeleteDelegate(self, alarm), WatchUi.SLIDE_UP);
    }

    function close() as Void {
        cancel();
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    function onCreatePicked(hour as Number, minute as Number) as Void {
        _replaced = null;
        save(hour, minute);
    }

    // The server has no edit the watch can call, so an edit saves the new time first and then
    // deletes the old alarm: a failure in between leaves a duplicate, never a lost alarm.
    function onEditPicked(hour as Number, minute as Number) as Void {
        _replaced = _editing;
        save(hour, minute);
    }

    private function save(hour as Number, minute as Number) as Void {
        var at = AlarmTime.nextOccurrence(Time.now(), hour, minute);
        _focusAt = at.value();
        begin("Saving...", Api.create(at), method(:onSaved));
    }

    function remove(alarm as Alarm) as Void {
        begin("Deleting...", Api.remove(alarm.id), method(:onChanged));
    }

    function onSaved(outcome as Outcome) as Void {
        var old = _replaced;
        _replaced = null;
        if (outcome.isOk() && old != null) {
            begin("Saving...", Api.remove(old.id), method(:onChanged));
        } else {
            onChanged(outcome);
        }
    }

    function onChanged(outcome as Outcome) as Void {
        if (outcome.isOk()) {
            reload();
        } else {
            fail(outcome.text());
        }
    }

    function reload() as Void {
        begin("Loading...", Api.alarms(), method(:onLoaded));
    }

    function onLoaded(outcome as Outcome) as Void {
        var state = outcome.state;
        if (state == null) {
            fail(outcome.isOk() ? "Unexpected answer" : outcome.text());
            return;
        }
        _call = null;
        _alarms = state.alarms;
        var focus = _focusAt;
        _focusAt = null;
        for (var i = 0; focus != null && i < _alarms.size(); i++) {
            if (_alarms[i].fireAt.value() == focus) {
                _selected = i + 1;
            }
        }
        _selected = _selected > _alarms.size() ? _alarms.size() : _selected;
        _message = null;
        WatchUi.requestUpdate();
    }

    private function begin(message as String, request as Request, callback as Method(outcome as Outcome) as Void) as Void {
        cancel();
        _message = message;
        _retry = false;
        var call = new Call(callback);
        _call = call;
        WatchUi.requestUpdate();
        call.send(request);
    }

    private function fail(message as String) as Void {
        _call = null;
        _focusAt = null;
        _message = message;
        _retry = true;
        WatchUi.requestUpdate();
    }

    private function cancel() as Void {
        var call = _call;
        if (call != null) {
            call.cancel();
            _call = null;
        }
    }
}

class AlarmListDelegate extends WatchUi.BehaviorDelegate {
    private var _view as AlarmListView;

    function initialize(view as AlarmListView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.activate();
        return true;
    }

    function onNextPage() as Boolean {
        _view.step(1);
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.step(-1);
        return true;
    }

    // Up held.
    function onMenu() as Boolean {
        _view.openDelete();
        return true;
    }

    function onBack() as Boolean {
        _view.close();
        return true;
    }
}

// The menu of one alarm: its only entry deletes it.
class DeleteDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as AlarmListView;
    private var _alarm as Alarm;

    function initialize(view as AlarmListView, alarm as Alarm) {
        Menu2InputDelegate.initialize();
        _view = view;
        _alarm = alarm;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        _view.remove(_alarm);
    }
}
