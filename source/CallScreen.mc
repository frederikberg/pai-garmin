import Toybox.Graphics;
import Toybox.Lang;

// What the Computer screen shows at one moment. Two faces with the same key draw the same picture,
// so the screen is drawn again only when the key changes.
class Face {
    var title as String = "Computer";
    var headline as String = "";
    var color as Graphics.ColorType = Graphics.COLOR_WHITE;
    var body as String = "";
    var hint as String = "";
    var foot as String = "";

    function key() as String {
        return title + "|" + headline + "|" + color + "|" + body + "|" + hint + "|" + foot;
    }
}

// The call's state as one word in one colour: grey while the watch is not ready, green when he can
// speak, yellow while his turn is on its way or the answer is made, blue while it plays, red when
// something stopped.
module CallScreen {
    function face(c as CallClient) as Face {
        var f = new Face();
        var fatal = c.fatal;
        var ended = c.endedReason;
        var stalled = c.stalled;
        if (c.closed()) {
            f.headline = "Hanging up";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (fatal != null) {
            f.headline = "Unavailable";
            f.color = Graphics.COLOR_RED;
            f.body = fatal;
        } else if (ended != null) {
            f.headline = "Call ended";
            f.color = Graphics.COLOR_RED;
            f.body = ended;
            f.hint = "Start: new call";
        } else if (stalled != null && !c.recording) {
            f.headline = "Not listening";
            f.color = Graphics.COLOR_RED;
            f.body = stalled;
            f.hint = "Start: try again";
        } else if (c.recording && !c.micLive) {
            // the microphone has not delivered yet: nothing he says now is recorded
            f.headline = "Wait";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (c.recording) {
            f.headline = "Speak";
            f.color = Graphics.COLOR_GREEN;
            f.hint = "Start: send";
        } else if (!c.hasCall()) {
            f.headline = "Connecting";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (c.sending()) {
            f.headline = "Sending";
            f.color = Graphics.COLOR_YELLOW;
        } else if (c.engine.equals("speaking") || c.playbackActive) {
            f.headline = "Speaking";
            f.color = Graphics.COLOR_BLUE;
            f.body = c.heard;
            f.hint = "Start: interrupt";
        } else if (c.engine.equals("generating")) {
            f.headline = "Thinking";
            f.color = Graphics.COLOR_YELLOW;
            f.body = c.heard;
            f.hint = "Start: interrupt";
        } else {
            f.headline = "Ready";
            f.hint = "Start: speak";
        }
        var notice = c.notice;
        if (notice != null) {
            // a notice is short-lived and says what just happened: it goes over what the server heard
            f.body = notice;
        }
        f.foot = c.linkTrouble();
        return f;
    }
}
