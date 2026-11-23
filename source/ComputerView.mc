import Toybox.Application.Storage;
import Toybox.Attention;
import Toybox.Graphics;
import Toybox.Lang;
import Toybox.System;
import Toybox.WatchUi;

// The Computer screen: opening it starts a call. The watch records each turn by itself, Start sends
// it, or cuts the answer and records again; Up and Down are the volume, Back hangs up. The screen
// shows what the call is doing as one word in a ring of the state's colour (CallScreen), and is
// drawn again only when that picture changes.
// Toybox.Audio exists on some products only; the menu offers this screen where it does (Home), and
// the checker skips the class so the other products build.
(:typecheck(false))
class ComputerView extends WatchUi.View {
    const START_VOLUME = 70;
    const VOLUME_STEP = 10;
    // where the volume is kept between openings
    const VOLUME_KEY = "volume";
    // the width of the ring that carries the state's colour
    const RING = 10;

    private var _client as CallClient;
    private var _speaker as Speaker;
    private var _recorder as Recorder;
    private var _keepCall as Boolean = false;
    private var _volume as Number = START_VOLUME;
    // the screen has been left some way other than the end of the hang-up
    private var _left as Boolean = false;
    // the app opened straight into this screen: leaving it ends the app
    private var _root as Boolean;
    private var _toMenu as Boolean = false;
    // the key of the face on screen
    private var _shown as String = "";

    function initialize(root as Boolean) {
        View.initialize();
        _root = root;
        var t0 = System.getTimer();
        var saved = Storage.getValue(VOLUME_KEY);
        if (saved instanceof Number && saved >= 0 && saved <= 100) {
            _volume = saved;
        }
        _client = build();
        _recorder = new Recorder(_client);
        var t1 = System.getTimer();
        _client.start();
        var t2 = System.getTimer();
        _speaker = new Speaker(_client, _volume);
        var t3 = System.getTimer();
        // how long each piece of the screen's start took: a stall of the watch shows here
        Trace.add("startup", {"setup_ms" => t1 - t0, "client_start_ms" => t2 - t1, "speaker_ms" => t3 - t2});
    }

    private function build() as CallClient {
        var io = new CallIo(method(:startCapture), method(:stopCapture), method(:play), method(:stopPlayback), method(:changed),
            method(:cue), method(:leave), method(:busy));
        return new CallClient(io, new CallEnv());
    }

    // Back from something that covered the screen (the hang-up had ended the call): a new call.
    function onShow() as Void {
        _keepCall = false;
        if (_client.closed() && !_toMenu) {
            _volume = _speaker.volume();
            _left = false;
            _client = build();
            _recorder = new Recorder(_client);
            _client.start();
            _speaker = new Speaker(_client, _volume);
        }
        WatchUi.requestUpdate();
    }

    // Leaving the screen ends the call, except for the menu opened on top of it.
    function onHide() as Void {
        if (!_keepCall) {
            _left = true;
            _client.hangUp();
        }
    }

    function keepCallWhileMenu() as Void {
        _keepCall = true;
    }

    function hangUp() as Void {
        _client.hangUp();
    }

    // A short buzz tells the press was taken; the server answers it a moment later.
    function press() as Void {
        _client.press();
    }

    function reconnect() as Void {
        _client.reconnect();
    }

    // Opened straight into this screen, the menu is reached from here.
    function isRoot() as Boolean {
        return _root;
    }

    // The call is hung up and the menu takes the place of this screen.
    function toMenu() as Void {
        _toMenu = true;
        _client.hangUp();
    }

    function wantsMenu() as Boolean {
        return _toMenu;
    }

    function louder() as Void {
        setVolume(_speaker.volume() + VOLUME_STEP);
    }

    function quieter() as Void {
        setVolume(_speaker.volume() - VOLUME_STEP);
    }

    private function setVolume(volume as Number) as Void {
        _speaker.setVolume(volume);
        Storage.setValue(VOLUME_KEY, _speaker.volume());
        _client.say("Volume " + _speaker.volume());
    }

    // Back: the hang-up goes to the server first, then the screen leaves; a second Back leaves at once.
    // In a session's call it asks for Computer instead.
    function back() as Boolean {
        if (_client.inSession() && !_client.closed()) {
            // in a session's call Back returns to Computer; the call goes on
            _client.back();
            return true;
        }
        if (_client.closed()) {
            _left = true;
            return false;
        }
        _client.hangUp();
        WatchUi.requestUpdate();
        return true;
    }

    // The hang-up is over.
    // Only if the screen is still the one on top: a second Back or an alarm may have left it already.
    function leave() as Void {
        if (!_left) {
            _left = true;
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
        }
    }

    // A signal. The turn signals are buzzes only: no sound plays while the microphone runs. The error
    // adds the system's error tone, since the microphone is off then.
    function cue(kind as Number) as Boolean {
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
        return true;
    }

    function busy() as Boolean {
        return _speaker.busy();
    }

    // the client's audio side
    function startCapture() as Number {
        return _recorder.start();
    }

    function stopCapture() as Void {
        _recorder.stop();
    }

    function play(n as Number, ms as Number, pcm as ByteArray) as Void {
        _speaker.play(n, ms, pcm);
    }

    function stopPlayback() as Void {
        _speaker.stop();
    }

    // The client's state moved: the screen is drawn again when that changes what it shows.
    function changed() as Void {
        if (!CallScreen.face(_client).key().equals(_shown)) {
            WatchUi.requestUpdate();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        var face = CallScreen.face(_client);
        _shown = face.key();
        Draw.background(dc);
        var w = dc.getWidth();
        var h = dc.getHeight();
        dc.setColor(face.color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(RING);
        dc.drawCircle(w / 2, h / 2, (w < h ? w : h) / 2 - RING / 2);
        dc.setPenWidth(1);
        Draw.title(dc, face.title);
        dc.setColor(face.color, Graphics.COLOR_TRANSPARENT);
        var text = face.body.length() > 0;
        Draw.fitted(dc, text ? 32 : 45, face.headline, [Graphics.FONT_LARGE, Graphics.FONT_MEDIUM, Graphics.FONT_SMALL]);
        if (text) {
            Draw.paragraph(dc, face.body, 44, 76);
        }
        if (face.foot.length() > 0) {
            dc.setColor(Graphics.COLOR_ORANGE, Graphics.COLOR_TRANSPARENT);
            dc.drawText(w / 2, h * 79 / 100, Graphics.FONT_XTINY, face.foot, Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        if (face.hint.length() > 0) {
            Draw.hint(dc, face.hint);
        }
    }
}

class ComputerDelegate extends WatchUi.BehaviorDelegate {
    private var _view as ComputerView;

    function initialize(view as ComputerView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.press();
        return true;
    }

    // A tap (a sleeve, sweat) is not a press: only the button sends or cuts.
    function onTap(evt as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    function onPreviousPage() as Boolean {
        _view.louder();
        return true;
    }

    function onNextPage() as Boolean {
        _view.quieter();
        return true;
    }

    // The Up hold: a fresh start for the call, and the way to the menu when the app opened here.
    function onMenu() as Boolean {
        var menu = new WatchUi.Menu2({:title => "Computer"});
        menu.addItem(new WatchUi.MenuItem("New call", null, :reconnect, null));
        if (_view.isRoot()) {
            menu.addItem(new WatchUi.MenuItem("Menu", "Weather, Alarm", :menu, null));
        }
        _view.keepCallWhileMenu();
        WatchUi.pushView(menu, new ComputerMenuDelegate(_view), WatchUi.SLIDE_LEFT);
        return true;
    }

    function onBack() as Boolean {
        return _view.back();
    }
}

class ComputerMenuDelegate extends WatchUi.Menu2InputDelegate {
    private var _view as ComputerView;

    function initialize(view as ComputerView) {
        Menu2InputDelegate.initialize();
        _view = view;
    }

    function onSelect(item as WatchUi.MenuItem) as Void {
        if (item.getId() == :menu) {
            _view.toMenu();
        } else {
            _view.reconnect();
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}
