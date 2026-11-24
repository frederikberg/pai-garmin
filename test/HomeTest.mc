import Toybox.Lang;
import Toybox.Test;

(:test)
function aShortHideKeepsACall(logger as Logger) as Boolean {
    return Home.keepOnReturn(true, 3000) && !Home.keepOnReturn(true, Home.KEEP_CALL_MS);
}

(:test)
function anyHideOutsideACallReturnsToTheMenu(logger as Logger) as Boolean {
    return !Home.keepOnReturn(false, 0) && !Home.keepOnReturn(false, 60000);
}
