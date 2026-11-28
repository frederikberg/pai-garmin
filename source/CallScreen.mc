import Toybox.Graphics;
import Toybox.Lang;

// What the Computer screen shows at one moment. Two faces with the same key draw the same picture,
// so the screen is drawn again only when the key changes.
class Face {
    var headline as String = "";
    var color as Graphics.ColorType = Graphics.COLOR_WHITE;
    // what was heard or is being said, in Computer's call
    var body as String = "";
    // the session the call is with, in a session's call
    var who as String = "";
    var hint as String = "";
    var foot as String = "";

    function key() as String {
        return headline + "|" + color + "|" + body + "|" + who + "|" + hint + "|" + foot;
    }
}

// The call's state as one word in one colour: grey while the watch is not ready, green when he can
// speak, yellow while his turn is on its way or the answer is made, orange while the watch keeps a
// turn the server does not have yet, blue while the answer plays, red when something stopped. In Computer's call the words heard and spoken show under it; in a session's call
// only the session's name does.
module CallScreen {
    function face(c as CallClient) as Face {
        var f = new Face();
        var fatal = c.fatal;
        var stalled = c.stalled;
        var session = c.inSession();
        if (session) {
            f.who = c.sessionTitle.length() > 0 ? c.sessionTitle : "Session";
        }
        if (c.closed() || c.ending()) {
            f.headline = "Hanging up";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (fatal != null) {
            f.headline = "Unavailable";
            f.color = Graphics.COLOR_RED;
            f.body = fatal;
        } else if (stalled != null && !c.recording) {
            f.headline = "Not listening";
            f.color = Graphics.COLOR_RED;
            f.body = stalled;
            f.hint = "Start: try again";
        } else if (c.asking) {
            // a kept turn waits for his word; nothing is recorded meanwhile
            f.headline = "Kept turn";
            f.color = Graphics.COLOR_ORANGE;
            f.body = c.keptLabel();
            f.hint = "Start: send  Back: drop";
        } else if (c.leaving()) {
            // Back in a session's call: the call goes back to Computer
            f.headline = "To Computer";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (c.recording && !c.micLive) {
            // the microphone has not delivered yet: nothing he says now is recorded
            f.headline = "Wait";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (c.recording) {
            f.headline = "Speak";
            f.color = Graphics.COLOR_GREEN;
            f.hint = "Start: send";
        } else if (c.kept) {
            // he pressed, and the turn is on the watch until the server has it
            f.headline = "Kept";
            f.color = Graphics.COLOR_ORANGE;
            f.body = "Goes when the link is back";
        } else if (!c.hasCall()) {
            f.headline = "Connecting";
            f.color = Graphics.COLOR_LT_GRAY;
        } else if (c.sending()) {
            f.headline = "Sending";
            f.color = Graphics.COLOR_YELLOW;
        } else if (c.engine.equals("speaking") || c.playbackActive) {
            f.headline = "Speaking";
            f.color = Graphics.COLOR_BLUE;
            f.body = session ? "" : c.spoken;
            f.hint = "Start: interrupt";
        } else if (c.engine.equals("generating")) {
            f.headline = "Thinking";
            f.color = Graphics.COLOR_YELLOW;
            f.body = session ? "" : c.heard;
            f.hint = "Start: interrupt";
        } else {
            // a session that waits for what comes, or Computer after a press that had nothing to answer
            f.headline = session ? "Listening" : "Ready";
            f.hint = "Start: speak";
        }
        var notice = c.notice;
        if (notice != null) {
            // a notice is short-lived and says what just happened: it goes over the text and the name
            f.body = notice;
        }
        var keeping = c.keepingS();
        f.foot = keeping > 0 ? "no link · keeping " + (keeping / 60) + ":" + (keeping % 60).format("%02d") : c.linkTrouble();
        return f;
    }
}
