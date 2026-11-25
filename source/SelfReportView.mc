import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Timer;
import Toybox.WatchUi;

// The faces of a self-report: a circle, two eyes and a mouth in the face's colour. Heavy is blue
// and frowns, okay is grey and flat, good is amber and smiles.
module Feel {
    function color(feel as String) as Graphics.ColorType {
        if ("heavy".equals(feel)) {
            return 0x60A5FA;
        }
        return "good".equals(feel) ? 0xFBBF24 : 0x9CA3AF;
    }

    function label(feel as String) as String {
        return "heavy".equals(feel) ? "Heavy" : ("good".equals(feel) ? "Good" : "Okay");
    }

    // The face centred on (cx, cy) with radius r.
    function draw(dc as Graphics.Dc, cx as Number, cy as Number, r as Number, feel as String) as Void {
        dc.setColor(color(feel), Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(r / 8 < 2 ? 2 : r / 8);
        dc.drawCircle(cx, cy, r);
        var eye = r / 9 < 1 ? 1 : r / 9;
        dc.fillCircle(cx - r * 36 / 100, cy - r * 25 / 100, eye + 1);
        dc.fillCircle(cx + r * 36 / 100, cy - r * 25 / 100, eye + 1);
        var mouth = r * 45 / 100;
        if ("good".equals(feel)) {
            dc.drawArc(cx, cy + r * 5 / 100, mouth, Graphics.ARC_COUNTER_CLOCKWISE, 215, 325);
        } else if ("heavy".equals(feel)) {
            dc.drawArc(cx, cy + r * 70 / 100, mouth, Graphics.ARC_COUNTER_CLOCKWISE, 35, 145);
        } else {
            dc.drawLine(cx - mouth * 7 / 10, cy + r * 40 / 100, cx + mouth * 7 / 10, cy + r * 40 / 100);
        }
        dc.setPenWidth(1);
    }
}

// A face as a menu icon.
class FeelIcon extends WatchUi.Drawable {
    private var _feel as String;

    function initialize(feel as String) {
        Drawable.initialize({});
        _feel = feel;
    }

    function draw(dc as Graphics.Dc) as Void {
        var size = dc.getWidth() < dc.getHeight() ? dc.getWidth() : dc.getHeight();
        Feel.draw(dc, dc.getWidth() / 2, dc.getHeight() / 2, size / 2 - 3, _feel);
    }
}

// The first screen of the Self-report sub-app: Skip, then the three faces. Skip has focus, so one
// Start goes straight to speaking.
module SelfReportMenu {
    function create() as [WatchUi.Menu2, WatchUi.Menu2InputDelegate] {
        var menu = new WatchUi.Menu2({:title => "Self-report"});
        menu.addItem(new WatchUi.MenuItem("Skip", null, "skip", null));
        for (var i = 0; i < SelfReport.FEELS.size(); i++) {
            var feel = SelfReport.FEELS[i];
            menu.addItem(new WatchUi.IconMenuItem(Feel.label(feel), null, feel, new FeelIcon(feel), null));
        }
        return [menu, new SelfReportMenuDelegate()];
    }
}

class SelfReportMenuDelegate extends WatchUi.Menu2InputDelegate {
    function initialize() {
        Menu2InputDelegate.initialize();
    }

    // The choice replaces this menu, so Back from the next screen returns to the sub-app list.
    function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        var view = new SelfReportView(id instanceof String && !"skip".equals(id) ? id : null);
        WatchUi.switchToView(view, new SelfReportDelegate(view), WatchUi.SLIDE_LEFT);
    }
}

// The recording screen: opening it starts the microphone, Start ends the recording and hands it to
// the Outbox, which keeps it on the watch and sends it; the server's answer buzzes and shows "Saved",
// and a few seconds later (or at Back) the screen returns to the sub-app list. A failed send says so,
// Start sends again at once, and the Outbox keeps trying by itself after the screen is gone.
// Toybox.Audio exists on some products only; the menu offers this sub-app where it does (Home),
// and the checker skips the class so the other products build.
(:typecheck(false))
class SelfReportView extends WatchUi.View {
    // how long "Saved" stays
    const DONE_MS = 3000;
    // how long the end of the microphone is waited for before the recording goes anyway
    const STOP_WAIT_MS = 1500;
    const RING = 10;

    private var _feel as String?;
    private var _flow as SelfReportFlow = new SelfReportFlow();
    private var _recorder as Recorder;
    // the recording is in the Outbox
    private var _kept as Boolean = false;
    // Start asked for the send the next answer is about: only that one sounds the error
    private var _asked as Boolean = false;
    private var _timer as Timer.Timer = new Timer.Timer();
    private var _id as String = SelfReport.uuid();
    private var _at as Time.Moment = Time.now();
    // the microphone's stop is in progress: nothing is sent from inside it
    private var _stopping as Boolean = false;
    private var _left as Boolean = false;

    function initialize(feel as String?) {
        View.initialize();
        _feel = feel;
        _recorder = new Recorder(self);
        _flow.micStarted(_recorder.start());
        if (_flow.state == SelfReportFlow.BROKEN) {
            cue(CallLogic.CUE_ERROR);
        }
        Trace.add("self_report_start", {"feel" => feel == null ? "skip" : feel, "state" => _flow.state});
        Home.target = self;
    }

    function onShow() as Void {
        if (!_left) {
            Home.target = self;
        }
    }

    // Start.
    function press() as Void {
        var action = _flow.press();
        if (action == SelfReportFlow.PRESS_STOP) {
            stopRecording();
        } else if (action == SelfReportFlow.PRESS_SEND) {
            upload();
        }
        Home.redraw();
    }

    // Back: leaves. A recording still running is dropped, which is what Back during it means; one
    // that ended is in the Outbox and goes on its own.
    function back() as Boolean {
        if (_flow.state == SelfReportFlow.STOPPING && _flow.audio.size() > 0) {
            // Start already ended it: the rest of the stop is not waited for
            keep();
            Outbox.send();
        }
        _left = true;
        cleanup();
        return false;
    }

    // The watch hides the screen for a notification and the watch face too: the recording goes on.
    // Only the screen closing (Back, leave, a reset) ends it; a reset keeps what was recorded.
    function onHide() as Void {
        if (!_left && !Home.resetting) {
            return;
        }
        if (!_left) {
            keepRecording();
        }
        _left = true;
        if (Home.target == self) {
            Home.target = null;
        }
        cleanup();
    }

    // The app has been hidden for Home.KEEP_MS: what was recorded so far is kept and sent like a
    // finished recording; the screen closes when the app is back.
    function hiddenTooLong() as Void {
        if (_flow.state == SelfReportFlow.SPEAK) {
            Trace.add("self_report_kept", {"bytes" => _flow.audio.size()});
            // as Start: the microphone's last data is waited for, then it goes to the Outbox
            press();
        }
    }

    private function keepRecording() as Void {
        if (_kept || !(_flow.capturing() || _flow.state == SelfReportFlow.STOPPING)) {
            return;
        }
        if (_flow.capturing()) {
            _stopping = true;
            _recorder.stop();
            _stopping = false;
        }
        if (_flow.audio.size() > 0) {
            Trace.add("self_report_kept", {"bytes" => _flow.audio.size()});
            _flow.sending();
            keep();
            Outbox.listener = method(:onUploaded);
            Outbox.listenerId = _id;
            Outbox.send();
        }
    }

    private function cleanup() as Void {
        _timer.stop();
        if (_flow.capturing()) {
            _stopping = true;
            _recorder.stop();
            _stopping = false;
        }
        if (_id.equals(Outbox.listenerId)) {
            Outbox.listener = null;
            Outbox.listenerId = null;
        }
    }

    private function keep() as Void {
        if (!_kept) {
            _kept = true;
            Outbox.put(_id, _feel, _at, _flow.audio);
        }
    }

    // A window of the recording, from the Recorder.
    function chunk(data as ByteArray) as Void {
        if (_left) {
            return;
        }
        var kept = _flow.data(data);
        if (kept == SelfReportFlow.DATA_FIRST) {
            // the microphone delivers: speak now
            Trace.add("self_report_mic_live", {"since_launch_ms" => System.getTimer() - Trace.bornAt});
            cue(CallLogic.CUE_YOUR_TURN);
            Home.redraw();
        } else if (kept == SelfReportFlow.DATA_FULL && _flow.full()) {
            Trace.add("self_report_full", {"bytes" => _flow.audio.size()});
            stopRecording();
            Home.redraw();
        }
    }

    function captureEnded() as Void {
        _flow.captureEnded();
        if (!_stopping && !_left) {
            sendWhenReady(false);
        }
    }

    function captureFailed(code as Number) as Void {
        if (_flow.capturing() || _flow.state == SelfReportFlow.STOPPING) {
            Trace.add("self_report_capture_error", {"code" => code});
            _timer.stop();
            _flow.broken("Microphone error " + code);
            cue(CallLogic.CUE_ERROR);
            Home.redraw();
        }
    }

    // The microphone may hand over its last data and say it stopped before stop() returns, and a
    // request issued from inside that gets no answer in the simulator: the send goes out from here.
    private function stopRecording() as Void {
        _stopping = true;
        _recorder.stop();
        _stopping = false;
        _timer.start(method(:onStopWait), STOP_WAIT_MS, false);
        sendWhenReady(false);
    }

    function onStopWait() as Void {
        sendWhenReady(true);
    }

    private function sendWhenReady(patient as Boolean) as Void {
        if (_flow.readyToSend(patient)) {
            upload();
        }
    }

    private function upload() as Void {
        _timer.stop();
        _flow.sending();
        keep();
        Outbox.listener = method(:onUploaded);
        Outbox.listenerId = _id;
        _asked = true;
        // Start asks for it now, whatever retry was planned
        Outbox.retryAt = 0;
        Outbox.send();
        Home.redraw();
    }

    // An answer from the Outbox: about this recording, or a failure of an older one it waits behind.
    function onUploaded(outcome as Outcome) as Void {
        var mine = _kept && Outbox.holds(_id);
        if (outcome.isOk() && mine) {
            // an older one went through; this one follows
            return;
        }
        var asked = _asked;
        _asked = false;
        _flow.result(outcome.isOk(), outcome.isOk() ? "" : outcome.text() + (mine ? ". Kept on the watch, it goes by itself" : ""));
        if (outcome.isOk()) {
            cue(CallLogic.CUE_SENT);
            _timer.start(method(:leave), DONE_MS, false);
        } else if (asked) {
            cue(CallLogic.CUE_ERROR);
        }
        Home.redraw();
    }

    // Back to the sub-app list.
    function leave() as Void {
        if (!_left) {
            _left = true;
            if (Home.target == self) {
                Home.target = null;
            }
            cleanup();
            Home.close(self);
        }
    }

    // A buzz, and for an error the error tone too (the microphone is off then).
    function cue(kind as Number) as Void {
        Trace.add("buzz", {"cue" => CallLogic.cueName(kind)});
        if (Home.covered) {
            // a hidden app may not vibrate or sound
            return;
        }
        if (Attention has :vibrate) {
            var pattern = CallLogic.buzz(kind);
            var profile = [] as Array<Attention.VibeProfile>;
            for (var i = 0; i < pattern.size(); i++) {
                profile.add(new Attention.VibeProfile(pattern[i][0], pattern[i][1]));
            }
            Attention.vibrate(profile);
        }
        if (kind == CallLogic.CUE_ERROR && Attention has :playTone) {
            Attention.playTone(Attention.TONE_ERROR);
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var state = _flow.state;
        var headline = "Wait";
        var color = Graphics.COLOR_LT_GRAY;
        var hint = "";
        if (state == SelfReportFlow.SPEAK) {
            headline = "Speak";
            color = Graphics.COLOR_GREEN;
            hint = "Start: send";
        } else if (state == SelfReportFlow.STOPPING || state == SelfReportFlow.SENDING) {
            headline = "Sending";
            color = Graphics.COLOR_YELLOW;
        } else if (state == SelfReportFlow.DONE) {
            headline = "Saved";
            color = Graphics.COLOR_GREEN;
            hint = "Back: list";
        } else if (state == SelfReportFlow.FAILED) {
            headline = "Not sent";
            color = Graphics.COLOR_RED;
            hint = "Start: try again";
        } else if (state == SelfReportFlow.BROKEN) {
            headline = "Unavailable";
            color = Graphics.COLOR_RED;
        }
        Draw.background(dc);
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(RING);
        dc.drawCircle(w / 2, h / 2, (w < h ? w : h) / 2 - RING / 2);
        dc.setPenWidth(1);
        // nothing near the top edge: the watch draws its own microphone sign there while it records
        var notice = _flow.notice;
        var feel = _feel;
        var text = notice.length() > 0;
        Draw.fitted(dc, text ? 32 : 40, headline, [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]);
        if (text) {
            Draw.paragraph(dc, notice, 44, 76);
        } else if (feel != null) {
            Feel.draw(dc, w / 2, h * 62 / 100, h * 9 / 100, feel);
        }
        if (hint.length() > 0) {
            Draw.hint(dc, hint);
        }
    }
}

class SelfReportDelegate extends WatchUi.BehaviorDelegate {
    private var _view as SelfReportView;
    // the press being handled is the Start button's: a tap on the screen maps to the same select
    private var _startDown as Boolean = false;

    function initialize(view as SelfReportView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onKeyPressed(evt as WatchUi.KeyEvent) as Boolean {
        _startDown = evt.getKey() == WatchUi.KEY_ENTER;
        return false;
    }

    function onSelect() as Boolean {
        if (_startDown) {
            _startDown = false;
            _view.press();
        }
        return true;
    }

    // A tap (a sleeve, sweat) is not a press: only the button acts.
    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        _startDown = false;
        return true;
    }

    function onBack() as Boolean {
        return _view.back();
    }
}
