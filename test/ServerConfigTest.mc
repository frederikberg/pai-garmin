import Toybox.Lang;
import Toybox.Test;

(:test)
function pastedSettingsAreCleanedUp(logger as Logger) as Boolean {
    return ServerConfig.trim("  abc \n").equals("abc")
        && ServerConfig.trim("abc").equals("abc")
        && ServerConfig.trim(" \n").equals("")
        && ServerConfig.cleanUrl(" https://pai.example.com/\n").equals("https://pai.example.com")
        && ServerConfig.cleanUrl("").equals("");
}

(:test)
function settingsAreCompleteWithAWebAddressAndAKey(logger as Logger) as Boolean {
    return ServerConfig.isComplete("https://pai.example.com", "k")
        && ServerConfig.isComplete("http://192.168.1.2:8000", "k")
        && !ServerConfig.isComplete("https://pai.example.com", "")
        && !ServerConfig.isComplete("pai.example.com", "k")
        && !ServerConfig.isComplete("", "");
}

(:test)
function settingsStartEmpty(logger as Logger) as Boolean {
    return !ServerConfig.isSet();
}
