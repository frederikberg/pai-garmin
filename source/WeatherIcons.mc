import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;

// The condition symbols, drawn from circles, bars and lines so they scale with the screen.
// A symbol fits a square of `size` pixels centred on (cx, cy); the shapes are laid out on a
// 24-unit grid.
module WeatherIcons {
    const SUN = 0xFFAA00;
    const MOON = 0xFFFFAA;
    const FAIR = 0xFFFFFF;
    const GREY = 0xAAAAAA;
    const DARK = 0x555555;
    const DROP = 0x55AAFF;
    const BOLT = 0xFFFF00;

    function draw(dc as Graphics.Dc, cx as Number, cy as Number, size as Number, symbol as String, night as Boolean) as Void {
        var u = size / 24.0;
        if (symbol.equals("clear")) {
            if (night) {
                moon(dc, cx, cy, 8 * u);
            } else {
                sun(dc, cx, cy, u);
            }
        } else if (symbol.equals("partly")) {
            if (night) {
                moon(dc, cx - 4 * u, cy - 3.5 * u, 6.5 * u);
            } else {
                sun(dc, cx - 4 * u, cy - 3.5 * u, 0.8 * u);
            }
            cloud(dc, cx + 2 * u, cy + 4 * u, 0.98 * u, Graphics.COLOR_BLACK);
            cloud(dc, cx + 2 * u, cy + 4 * u, 0.85 * u, FAIR);
        } else if (symbol.equals("fog")) {
            cloud(dc, cx, cy - 4 * u, 0.9 * u, GREY);
            dc.setColor(GREY, Graphics.COLOR_TRANSPARENT);
            dc.fillRoundedRectangle(cx - 8 * u, cy + 4.5 * u, 16 * u, 2 * u, u);
            dc.fillRoundedRectangle(cx - 6 * u, cy + 8.5 * u, 12 * u, 2 * u, u);
        } else if (symbol.equals("rain")) {
            cloud(dc, cx, cy - 4 * u, 0.95 * u, GREY);
            drop(dc, cx - 5 * u, cy, u);
            drop(dc, cx, cy, u);
            drop(dc, cx + 5 * u, cy, u);
        } else if (symbol.equals("sleet")) {
            cloud(dc, cx, cy - 4 * u, 0.95 * u, GREY);
            drop(dc, cx - 5 * u, cy, u);
            flake(dc, cx, cy + 7.5 * u, u);
            drop(dc, cx + 5 * u, cy, u);
        } else if (symbol.equals("snow")) {
            cloud(dc, cx, cy - 4 * u, 0.95 * u, GREY);
            flake(dc, cx - 5.5 * u, cy + 5.5 * u, u);
            flake(dc, cx, cy + 9 * u, u);
            flake(dc, cx + 5.5 * u, cy + 5.5 * u, u);
        } else if (symbol.equals("thunder")) {
            cloud(dc, cx, cy - 4 * u, 0.95 * u, GREY);
            dc.setColor(BOLT, Graphics.COLOR_TRANSPARENT);
            dc.fillPolygon([
                [cx + 1.5 * u, cy + 2.5 * u], [cx - 4 * u, cy + 7.5 * u], [cx - 0.8 * u, cy + 7.5 * u],
                [cx - 2.5 * u, cy + 12 * u], [cx + 4 * u, cy + 5.5 * u], [cx + 0.8 * u, cy + 5.5 * u],
                [cx + 3 * u, cy + 2.5 * u]
            ]);
        } else {
            // cloudy, and any symbol this build does not know
            cloud(dc, cx + 4.5 * u, cy - 4 * u, 0.6 * u, DARK);
            cloud(dc, cx - 1 * u, cy + 1.5 * u, 1.12 * u, Graphics.COLOR_BLACK);
            cloud(dc, cx - 1 * u, cy + 1.5 * u, u, GREY);
        }
    }

    // A disc with eight rays; s is the grid unit.
    function sun(dc as Graphics.Dc, cx as Numeric, cy as Numeric, s as Float) as Void {
        dc.setColor(SUN, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, 5.5 * s);
        var pen = (1.6 * s + 0.5).toNumber();
        dc.setPenWidth(pen < 2 ? 2 : pen);
        for (var k = 0; k < 8; k++) {
            var a = k * Math.PI / 4;
            var dx = Math.cos(a);
            var dy = Math.sin(a);
            dc.drawLine(cx + dx * 7.5 * s, cy + dy * 7.5 * s, cx + dx * 10.5 * s, cy + dy * 10.5 * s);
        }
        dc.setPenWidth(1);
    }

    // A crescent: a pale disc with a black disc cut out of its upper right.
    function moon(dc as Graphics.Dc, cx as Numeric, cy as Numeric, r as Float) as Void {
        dc.setColor(MOON, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx, cy, r);
        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx + 0.45 * r, cy - 0.3 * r, 0.82 * r);
    }

    // Three bumps on a rounded bar, 18.5 units wide and 13.5 high at s = 1, centred a little
    // below its top.
    function cloud(dc as Graphics.Dc, cx as Numeric, cy as Numeric, s as Float, color as Graphics.ColorType) as Void {
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.fillCircle(cx - 5 * s, cy + 1 * s, 4 * s);
        dc.fillCircle(cx + 1 * s, cy - 2 * s, 6 * s);
        dc.fillCircle(cx + 6 * s, cy + 1.5 * s, 3.5 * s);
        dc.fillRoundedRectangle(cx - 9 * s, cy, 18.5 * s, 5.5 * s, 2.7 * s);
    }

    function drop(dc as Graphics.Dc, x as Numeric, cy as Numeric, s as Float) as Void {
        dc.setColor(DROP, Graphics.COLOR_TRANSPARENT);
        var pen = (1.8 * s + 0.5).toNumber();
        dc.setPenWidth(pen < 2 ? 2 : pen);
        dc.drawLine(x + 1 * s, cy + 4.5 * s, x - 1 * s, cy + 10 * s);
        dc.setPenWidth(1);
    }

    function flake(dc as Graphics.Dc, x as Numeric, y as Numeric, s as Float) as Void {
        dc.setColor(FAIR, Graphics.COLOR_TRANSPARENT);
        var r = 1.7 * s;
        dc.fillCircle(x, y, r < 2 ? 2 : r);
    }
}
