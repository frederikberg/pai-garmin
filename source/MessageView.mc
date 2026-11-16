import Toybox.Graphics;
import Toybox.Lang;
import Toybox.WatchUi;

// A heading, an optional large line, a paragraph and a hint. Enter runs the select action when one
// is set; Back leaves through the platform.
class MessageView extends WatchUi.View {
    private var _title as String;
    private var _headline as String? = null;
    private var _text as String = "";
    private var _hint as String? = null;
    private var _onSelect as Method() as Void or Null = null;

    function initialize(title as String) {
        View.initialize();
        _title = title;
    }

    function setTitle(title as String) as Void {
        _title = title;
    }

    function show(headline as String?, text as String, hint as String?, onSelect as Method() as Void or Null) as Void {
        _headline = headline;
        _text = text;
        _hint = hint;
        _onSelect = onSelect;
        WatchUi.requestUpdate();
    }

    function select() as Void {
        var action = _onSelect;
        if (action != null) {
            action.invoke();
        }
    }

    function onUpdate(dc as Graphics.Dc) as Void {
        Draw.background(dc);
        Draw.title(dc, _title);
        var headline = _headline;
        if (headline != null) {
            dc.setColor(Graphics.COLOR_RED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(dc.getWidth() / 2, dc.getHeight() * 40 / 100, Graphics.FONT_NUMBER_MEDIUM, headline,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER);
        }
        Draw.paragraph(dc, _text, headline == null ? 30 : 55, 80);
        var hint = _hint;
        if (hint != null) {
            Draw.hint(dc, hint);
        }
    }
}

class MessageDelegate extends WatchUi.BehaviorDelegate {
    private var _view as MessageView;

    function initialize(view as MessageView) {
        BehaviorDelegate.initialize();
        _view = view;
    }

    function onSelect() as Boolean {
        _view.select();
        return true;
    }
}
