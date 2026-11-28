import Toybox.Application.Storage;
import Toybox.Lang;
import Toybox.System;
import Toybox.Time;
import Toybox.Time.Gregorian;

// The turns spoken to Computer that the server has not finished. A turn has an id of its own, made
// when its recording starts, and its audio is cut into numbered parts, one request each. A part
// stays here until the server has confirmed it: in memory while the link keeps up, in the watch's
// storage once it does not (beside the self-report's parts, under the same budget), so a turn
// outlives the call it was spoken in, and the app. Only a finished turn (taken by the server, or
// dropped by the wearer) leaves; a dropped one stays as a note until the server has heard of it.
module Kept {
    const KEY = "turns";
    // the longest part
    const PART_MAX = 6144;
    // a storage write that took longer is always logged
    const SLOW_WRITE_MS = 200;

    // Oldest first: id, at (wall-clock seconds when the recording began), ms (how long he spoke),
    // parts (cut so far, numbered from 0), sent (how many the server has: the next one it needs),
    // stored (the parts from sent up to this number are in storage, later ones in memory), pressed
    // (wall-clock seconds of his press, absent before it), out (true once a part of it went out, so
    // the server may know the turn) and drop (true once he dropped it).
    var turns as Array<Dictionary<String, Object?>> = [];
    // parts kept in memory only, by key
    var held as Dictionary<String, ByteArray> = {};
    var loaded as Boolean = false;
    // the list is in storage
    var onDisk as Boolean = false;

    // The turns an earlier run kept. The parts it held in memory only went with it.
    function load() as Void {
        if (loaded) {
            return;
        }
        loaded = true;
        var value = Storage.getValue(KEY);
        if (value instanceof Array) {
            for (var i = 0; i < value.size(); i++) {
                var r = value[i];
                if (r instanceof Dictionary && r["id"] instanceof String) {
                    var turn = r as Dictionary<String, Object?>;
                    for (var f = 0; f < 5; f++) {
                        var field = ["at", "ms", "parts", "sent", "stored"][f];
                        if (!(turn[field] instanceof Number)) {
                            turn[field] = 0;
                        }
                    }
                    if (num(turn, "stored") < num(turn, "sent")) {
                        turn["stored"] = num(turn, "sent");
                    }
                    turn["parts"] = num(turn, "stored");
                    turns.add(turn);
                }
            }
        }
        onDisk = turns.size() > 0;
    }

    function num(turn as Dictionary<String, Object?>, field as String) as Number {
        return turn[field] as Number;
    }

    // A turn's recording begins.
    function open() as Dictionary<String, Object?> {
        load();
        var turn = {"id" => SelfReport.uuid(), "at" => Time.now().value(), "ms" => 0, "parts" => 0, "sent" => 0, "stored" => 0} as Dictionary<String, Object?>;
        turns.add(turn);
        return turn;
    }

    function isDrop(turn as Dictionary<String, Object?>) as Boolean {
        var drop = turn["drop"];
        return drop instanceof Boolean && drop;
    }

    // The oldest turn that still has to go, or null.
    function waiting() as Dictionary<String, Object?>? {
        load();
        for (var i = 0; i < turns.size(); i++) {
            if (!isDrop(turns[i])) {
                return turns[i];
            }
        }
        return null;
    }

    // The id of a dropped turn the server has not heard of yet, or null.
    function dropId() as String? {
        load();
        for (var i = 0; i < turns.size(); i++) {
            if (isDrop(turns[i])) {
                return turns[i]["id"] as String;
            }
        }
        return null;
    }

    function find(id as String) as Dictionary<String, Object?>? {
        for (var i = 0; i < turns.size(); i++) {
            if (id.equals(turns[i]["id"])) {
                return turns[i];
            }
        }
        return null;
    }

    // The parts the server has not confirmed.
    function unsent(turn as Dictionary<String, Object?>) as Number {
        return num(turn, "parts") - num(turn, "sent");
    }

    // The next part of the turn, kept in memory; the answer is its number.
    function add(turn as Dictionary<String, Object?>, bytes as ByteArray) as Number {
        var n = num(turn, "parts");
        held[key(turn, n)] = bytes;
        turn["parts"] = n + 1;
        return n;
    }

    function partOf(turn as Dictionary<String, Object?>, n as Number) as ByteArray? {
        var part = held[key(turn, n)];
        if (part != null) {
            return part;
        }
        var value = Storage.getValue(key(turn, n));
        return value instanceof ByteArray ? value : null;
    }

    // The turn and the parts it holds in memory go to storage: the parts first, so the list never
    // names one the storage lacks. The first time the storage is full, the reserve the self-report
    // keeps makes room. False when the storage did not take everything; what it refused stays in
    // memory.
    function persist(turn as Dictionary<String, Object?>) as Boolean {
        var t0 = System.getTimer();
        var written = 0;
        var bytes = 0;
        var ok = true;
        for (var n = num(turn, "stored"); n < num(turn, "parts") && ok; n++) {
            var part = held[key(turn, n)];
            if (part != null) {
                ok = write(key(turn, n), part);
                if (!ok && Storage.getValue(Outbox.RESERVE_KEY) != null) {
                    Outbox.deviceFull(false);
                    ok = write(key(turn, n), part);
                }
                if (ok) {
                    held.remove(key(turn, n));
                    written += 1;
                    bytes += part.size();
                }
            }
            if (ok) {
                turn["stored"] = n + 1;
            }
        }
        save();
        var ms = System.getTimer() - t0;
        var line = {"parts" => written, "bytes" => bytes, "ms" => ms, "kept_bytes" => stored(), "ok" => ok};
        if (ms > SLOW_WRITE_MS || !ok) {
            Trace.add("turn_stored", line);
        } else if (written > 0) {
            Trace.debug("turn_stored", line);
        }
        return ok;
    }

    function write(k as String, bytes as ByteArray) as Boolean {
        try {
            Storage.setValue(k, bytes);
        } catch (ex) {
            return false;
        }
        return true;
    }

    // The server has the parts before next: they go. A count beyond what was cut (parts an earlier
    // run sent from memory) moves the turn up to it.
    function confirm(turn as Dictionary<String, Object?>, next as Number) as Void {
        var sent = num(turn, "sent");
        if (next <= sent) {
            return;
        }
        var stored = num(turn, "stored");
        for (var n = sent; n < next; n++) {
            held.remove(key(turn, n));
        }
        free(turn, sent, next < stored ? next : stored);
        turn["sent"] = next;
        if (next > stored) {
            turn["stored"] = next;
        }
        if (next > num(turn, "parts")) {
            turn["parts"] = next;
        }
    }

    // Stored parts from to to go: one at once, more a few at a time (the self-report's sweep).
    function free(turn as Dictionary<String, Object?>, from as Number, to as Number) as Void {
        if (to - from == 1) {
            Storage.deleteValue(key(turn, from));
        } else if (to > from) {
            Outbox.discard(turn["id"] as String, from, to);
        }
    }

    // The turn is finished: the server took it, or never saw it.
    function forget(turn as Dictionary<String, Object?>) as Void {
        clear(turn);
        var rest = [] as Array<Dictionary<String, Object?>>;
        for (var i = 0; i < turns.size(); i++) {
            if (turns[i] != turn) {
                rest.add(turns[i]);
            }
        }
        turns = rest;
        if (onDisk) {
            save();
        }
    }

    // He dropped the turn: its audio goes now, and a note stays until the server has heard of it.
    // A turn of which nothing went out never left the watch and is forgotten.
    function drop(turn as Dictionary<String, Object?>) as Void {
        if (!(turn["out"] instanceof Boolean)) {
            forget(turn);
            return;
        }
        clear(turn);
        turn["drop"] = true;
        save();
    }

    function clear(turn as Dictionary<String, Object?>) as Void {
        for (var n = num(turn, "sent"); n < num(turn, "parts"); n++) {
            held.remove(key(turn, n));
        }
        free(turn, num(turn, "sent"), num(turn, "stored"));
        turn["stored"] = num(turn, "sent");
        turn["parts"] = num(turn, "sent");
    }

    // The bytes the stored parts take, counting each as a full part.
    function stored() as Number {
        var n = 0;
        for (var i = 0; i < turns.size(); i++) {
            var parts = num(turns[i], "stored") - num(turns[i], "sent");
            n += parts > 0 ? parts : 0;
        }
        return n * PART_MAX;
    }

    // The storage has room for more of a turn, under the budget it shares with the self-reports.
    function hasRoom() as Boolean {
        Outbox.load();
        return Outbox.stored() + 3 * Outbox.PART_BYTES <= Outbox.budget;
    }

    function save() as Void {
        try {
            if (turns.size() > 0) {
                Storage.setValue(KEY, turns as Array<Storage.ValueType>);
            } else if (onDisk) {
                Storage.deleteValue(KEY);
            }
            onDisk = turns.size() > 0;
        } catch (ex) {
        }
        Home.showKept();
    }

    function key(turn as Dictionary<String, Object?>, n as Number) as String {
        return Outbox.partKey(turn["id"] as String, n);
    }

    // When he said it and for how long, on two lines: "said 13:10", "for 1:04".
    function label(turn as Dictionary<String, Object?>) as String {
        var at = Gregorian.info(new Time.Moment(num(turn, "at")), Time.FORMAT_SHORT);
        var s = num(turn, "ms") / 1000;
        return "said " + at.hour.format("%02d") + ":" + at.min.format("%02d") + "\nfor " + (s / 60) + ":" + (s % 60).format("%02d");
    }
}
