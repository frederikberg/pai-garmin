import Toybox.Communications;
import Toybox.Lang;

// The parts of a voice turn that need no audio hardware: the reply formats the watch can ask for,
// the request's address and the wording of a failure.
module Voice {
    // The reply formats of the `out` query parameter; the first is the server's default.
    const OUTS = ["wav", "wav8", "opus"];

    // The format after out in the cycle the Up hold walks.
    function nextOut(out as String) as String {
        for (var i = 0; i < OUTS.size(); i++) {
            if (OUTS[i].equals(out)) {
                return OUTS[(i + 1) % OUTS.size()];
            }
        }
        return OUTS[0];
    }

    function turnUrl(base as String, out as String) as String {
        return base + Api.VOICE + "?out=" + out;
    }

    // Short text for the screen: the HTTP codes the route answers and the transport failures seen on
    // the phone link, else the bare code.
    function codeText(code as Number) as String {
        if (code == 200) {
            return "ok";
        } else if (code == 400) {
            return "empty clip";
        } else if (code == 401) {
            return "key rejected";
        } else if (code == 413) {
            return "clip too long";
        } else if (code == 502) {
            return "speech failed";
        } else if (code == 503) {
            return "not configured";
        } else if (code == Communications.BLE_CONNECTION_UNAVAILABLE) {
            return "no phone";
        }
        return "error";
    }
}
