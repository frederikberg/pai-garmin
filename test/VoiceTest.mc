import Toybox.Lang;
import Toybox.Test;

(:test)
function replyFormatsCycleAndWrap(logger as Logger) as Boolean {
    return Voice.nextOut("wav").equals("wav8") && Voice.nextOut("wav8").equals("wav")
        && Voice.nextOut("other").equals("wav");
}

(:test)
function turnUrlCarriesTheReplyFormat(logger as Logger) as Boolean {
    return Voice.turnUrl("https://example.com", "wav8").equals("https://example.com/api/watch/voice/turn?out=wav8");
}

(:test)
function failureCodesHaveShortText(logger as Logger) as Boolean {
    return Voice.codeText(401).equals("key rejected") && Voice.codeText(413).equals("clip too long")
        && Voice.codeText(-104).equals("no phone") && Voice.codeText(500).equals("error");
}
