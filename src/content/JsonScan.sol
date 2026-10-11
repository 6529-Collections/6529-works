// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title JsonScan
/// @notice A strict JSON (RFC 8259) scanner over memory. It validates what it reads and reports
///         where each value sits, so the caller can copy a validated span verbatim; it never
///         decodes a value and never reverts: a document that is not acceptable gives `ok` false.
/// @dev A span is `start << 128 | end` (end exclusive) over the scanned bytes; zero means absent,
///      and a span is never empty. What is rejected, beyond RFC 8259:
///      - object keys with a backslash (a key must read the same to every parser, so `name`
///        is never a second `name`);
///      - `\u0000`, a lone surrogate escape (`\uD800` to `\uDFFF` not in a high-low pair), because
///        parsers differ on them (serde_json and PostgreSQL reject them);
///      - a number of more than 24 bytes or with an exponent of more than two digits, so every
///        number is a finite binary64 (`1e400` is one parsers read differently) and the digits
///        are bounded;
///      - more than `MAX_VALUES` units: every string, number, literal, array and object below
///        the top-level object is one, every key one more (two at the top level, where it is
///        also hashed and matched), every backslash escape one (a surrogate pair is two); and
///        nesting deeper than `MAX_DEPTH`. A unit costs 1,000 to 1,500 gas whatever it is, so
///        this bounds the cost of a document, whatever its bytes;
///      - a duplicate key of a requested top-level member, and more elements than a caller's `max`;
///      - in {records}, an element that has more than eight members or two with the same key.
///      The caller checks UTF-8 separately (`Utf8`), and bounds the size of the text.
///
///      {object} is the only function that validates. {members}, {elements} and {records}
///      navigate a value of a document {object} has accepted: they skip values without checking
///      them again, so the walk costs about what the check did, and they are safe, but not
///      meaningful, on any other text: they never read outside the bytes and give `ok` false
///      when the text is not what they look for. Strings are scanned a word at a time where
///      they hold no quote, backslash or control byte, so a long plain string costs about 5 gas
///      a byte; a unit costs 1,000 to 1,500 gas, which `MAX_VALUES` bounds. White space costs
///      about 40 gas a byte, which the caller's bound on the size of the text bounds.
library JsonScan {
    uint256 internal constant MAX_DEPTH = 8;
    uint256 internal constant MAX_VALUES = 1_024;
    uint256 private constant ONES =
        0x0101010101010101010101010101010101010101010101010101010101010101;
    uint256 private constant LOW7 =
        0x7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f7f;
    uint256 private constant HIGH =
        0x8080808080808080808080808080808080808080808080808080808080808080;

    /// @notice Validates `json` as one JSON object and returns the span of the value of each of
    ///         `keys` (hashes of the key text without quotes), in order; zero for a key that is not
    ///         there. `spans` always has one entry per key.
    function object(bytes memory json, bytes32[] memory keys)
        internal
        pure
        returns (bool ok, uint256[] memory spans)
    {
        spans = new uint256[](keys.length);
        ok = _run(0, json, 0, keys, spans) != 0;
    }

    /// @notice The spans of the members `keys` of the object whose value starts at `start` inside
    ///         `json`, a document {object} accepted.
    function members(bytes memory json, uint256 start, bytes32[] memory keys)
        internal
        pure
        returns (bool ok, uint256[] memory spans)
    {
        spans = new uint256[](keys.length);
        ok = _run(1, json, start, keys, spans) != 0;
    }

    /// @notice The spans of the elements of the array whose value starts at `start` inside `json`,
    ///         a document {object} accepted. At most `max` elements; more give `ok` false.
    function elements(bytes memory json, uint256 start, uint256 max)
        internal
        pure
        returns (bool ok, uint256[] memory spans)
    {
        spans = new uint256[](max);
        uint256 found = _run(2, json, start, new bytes32[](0), spans);
        ok = found != 0;
        assembly ("memory-safe") {
            // `found` is one more than the count, or zero.
            mstore(spans, sub(found, iszero(iszero(found))))
        }
    }

    /// @notice The elements of the array whose value starts at `start` inside `json`, each of which
    ///         has to be an object (a document {object} accepted), with the spans of the members
    ///         `keys` of each: for element `i`, `spans[i * (keys.length + 1)]` is its own span and
    ///         the next `keys.length` entries are those of its members, as in {members}. At most
    ///         `max` elements; more give `ok` false.
    function records(bytes memory json, uint256 start, bytes32[] memory keys, uint256 max)
        internal
        pure
        returns (bool ok, uint256[] memory spans)
    {
        uint256 stride = keys.length + 1;
        spans = new uint256[](max * stride);
        uint256 found = _run(3, json, start, keys, spans);
        ok = found != 0;
        assembly ("memory-safe") {
            // `found` is one more than the count, or zero.
            mstore(spans, mul(sub(found, iszero(iszero(found))), stride))
        }
    }

    /// @notice A copy of the bytes of `span`.
    function slice(bytes memory json, uint256 span) internal pure returns (bytes memory out) {
        uint256 start = span >> 128;
        uint256 length = (span & type(uint128).max) - start;
        out = new bytes(length);
        assembly ("memory-safe") {
            mcopy(add(out, 0x20), add(add(json, 0x20), start), length)
        }
    }

    /// @dev Mode 0 validates the document and fills `spans` for the top-level members `keys`;
    ///      mode 1 does that for the object at `start` without validating; mode 2 fills `spans`
    ///      with the elements of the array at `start`, and mode 3 with the objects that are its
    ///      elements and their members. Returns zero for failure, otherwise one (modes 0 and 1)
    ///      or the element count plus one (modes 2 and 3).
    function _run(
        uint256 mode,
        bytes memory json,
        uint256 start,
        bytes32[] memory keys,
        uint256[] memory spans
    ) private pure returns (uint256 r) {
        assembly ("memory-safe") {
            // Space, tab, line feed, carriage return (0x100002600 has their bits).
            function ws(p, e) -> q {
                q := p
                for { } lt(q, e) { q := add(q, 1) } {
                    if iszero(and(lt(byte(0, mload(q)), 33), shr(byte(0, mload(q)), 0x100002600))) {
                        break
                    }
                }
            }

            // Index (0-31) of the first non-zero byte of the non-zero word m.
            function firstFlag(m) -> idx {
                if iszero(shr(128, m)) {
                    idx := 16
                    m := shl(128, m)
                }
                if iszero(shr(192, m)) {
                    idx := add(idx, 8)
                    m := shl(64, m)
                }
                if iszero(shr(224, m)) {
                    idx := add(idx, 4)
                    m := shl(32, m)
                }
                if iszero(shr(240, m)) {
                    idx := add(idx, 2)
                    m := shl(16, m)
                }
                if iszero(shr(248, m)) { idx := add(idx, 1) }
            }

            // The value of the four hex digits at p, or 0x10000 if one is not a hex digit.
            function hex4(p) -> v {
                for { let k := 0 } lt(k, 4) { k := add(k, 1) } {
                    let d := byte(0, mload(add(p, k)))
                    let n := sub(d, 0x30)
                    if iszero(lt(n, 10)) {
                        // A letter a-f in either case (`@` and a backtick are one below `a`).
                        let l := sub(or(d, 0x20), 0x61)
                        n := 0x10000
                        if lt(l, 6) { n := add(l, 10) }
                    }
                    v := or(shl(4, v), n)
                }
            }

            // The pointer after the escape whose backslash is just before p, or zero: one of
            // `"\/bfnrt`, or `u` and four hex digits that are not NUL and not a lone surrogate.
            // Each escape (a surrogate pair is two) counts as a value against the budget.
            function escape(p, e, ctx) -> q {
                let n := add(mload(ctx), 1)
                mstore(ctx, n)
                if or(gt(n, 1024), iszero(lt(p, e))) { leave }
                let c := byte(0, mload(p))
                p := add(p, 1)
                if or(
                    or(or(eq(c, 0x22), eq(c, 0x5c)), or(eq(c, 0x2f), eq(c, 0x62))),
                    or(or(eq(c, 0x66), eq(c, 0x6e)), or(eq(c, 0x72), eq(c, 0x74)))
                ) {
                    q := p
                    leave
                }
                if iszero(eq(c, 0x75)) { leave }
                if lt(sub(e, p), 4) { leave }
                let v := hex4(p)
                p := add(p, 4)
                // A bad digit, or NUL.
                if or(iszero(lt(v, 0x10000)), iszero(v)) { leave }
                if or(lt(v, 0xd800), iszero(lt(v, 0xe000))) {
                    q := p
                    leave
                }
                // A surrogate: a high one, followed by `\u` and a low one.
                if iszero(lt(v, 0xdc00)) { leave }
                if lt(sub(e, p), 6) { leave }
                if iszero(eq(shr(240, mload(p)), 0x5c75)) { leave }
                let w := hex4(add(p, 2))
                if and(iszero(lt(w, 0xdc00)), lt(w, 0xe000)) {
                    q := add(p, 6)
                    mstore(ctx, add(n, 1))
                    if gt(add(n, 1), 1024) { q := 0 }
                }
            }

            // The pointer after the string that opens at p, or zero. Mode 0: a value, 1: an
            // object key (no backslash), 2: a string of a validated document, skipped without
            // checking (only quotes and backslashes matter).
            function str(p, e, kind, ctx) -> q {
                if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x22))) { leave }
                p := add(p, 1)
                // OR-ed into the control-byte test, so that mode 2 never flags one.
                let off := 0
                if eq(kind, 2) { off := not(0) }
                // Short strings are cheaper bytewise: the first 8 bytes are, whatever follows.
                let near := add(p, 8)
                for { } lt(p, e) { } {
                    let wordEnd := add(p, 32)
                    if lt(p, near) { wordEnd := near }
                    if and(iszero(lt(p, near)), iszero(lt(sub(e, p), 32))) {
                        // Each of y, z, w has a zero byte exactly where the word has '"', '\' or
                        // a byte below 0x20; ((v & LOW7) + LOW7) | v has the top bit set in the
                        // others.
                        let x := mload(p)
                        let y := xor(x, mul(ONES, 0x22))
                        let z := xor(x, mul(ONES, 0x5c))
                        let w := or(and(x, mul(ONES, 0xe0)), off)
                        let flags :=
                            and(
                                not(
                                    and(
                                        and(
                                            or(add(and(y, LOW7), LOW7), y),
                                            or(add(and(z, LOW7), LOW7), z)
                                        ),
                                        or(add(and(w, LOW7), LOW7), w)
                                    )
                                ),
                                HIGH
                            )
                        if iszero(flags) {
                            p := wordEnd
                            continue
                        }
                        // Jump to the first flagged byte; the rest of the word is bytewise.
                        p := add(p, firstFlag(flags))
                    }
                    if gt(wordEnd, e) { wordEnd := e }
                    for { } lt(p, wordEnd) { } {
                        let c := byte(0, mload(p))
                        p := add(p, 1)
                        // The usual byte: above the quote and not a backslash.
                        if and(gt(c, 0x22), iszero(eq(c, 0x5c))) { continue }
                        if eq(c, 0x22) {
                            q := p
                            leave
                        }
                        if eq(c, 0x5c) {
                            if eq(kind, 2) {
                                p := add(p, 1)
                                continue
                            }
                            if kind { leave }
                            p := escape(p, e, ctx)
                            if iszero(p) { leave }
                            continue
                        }
                        if and(lt(c, 0x20), iszero(eq(kind, 2))) { leave }
                    }
                }
            }

            // The pointer after the digits at p (any number, also none).
            function digits(p, e) -> q {
                q := p
                for { } lt(q, e) { q := add(q, 1) } {
                    if gt(sub(byte(0, mload(q)), 0x30), 9) { break }
                }
            }

            // `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`: the pointer after it, or zero.
            // At most 24 bytes and an exponent of at most two digits, so every number is a finite
            // binary64 (parsers disagree about 1e400) and the digits are bounded.
            function num(p, e) -> q {
                let t0 := p
                if and(lt(p, e), eq(byte(0, mload(p)), 0x2d)) { p := add(p, 1) }
                if iszero(lt(p, e)) { leave }
                let c := byte(0, mload(p))
                if eq(c, 0x30) { p := add(p, 1) }
                if iszero(eq(c, 0x30)) {
                    if or(lt(c, 0x31), gt(c, 0x39)) { leave }
                    p := digits(add(p, 1), e)
                }
                if and(lt(p, e), eq(byte(0, mload(p)), 0x2e)) {
                    c := digits(add(p, 1), e)
                    if eq(c, add(p, 1)) { leave }
                    p := c
                }
                if and(lt(p, e), eq(or(byte(0, mload(p)), 0x20), 0x65)) {
                    p := add(p, 1)
                    if lt(p, e) {
                        c := byte(0, mload(p))
                        if or(eq(c, 0x2b), eq(c, 0x2d)) { p := add(p, 1) }
                    }
                    c := digits(p, e)
                    if or(eq(c, p), gt(sub(c, p), 2)) { leave }
                    p := c
                }
                if gt(sub(p, t0), 24) { leave }
                q := p
            }

            // The pointer after `len` bytes of text that are `word`, or zero.
            function lit(p, e, len, word) -> q {
                if gt(add(p, len), e) { leave }
                if eq(shr(sub(256, shl(3, len)), mload(p)), word) { q := add(p, len) }
            }

            // Records the value [vs, ve) under the key whose hash is h, if it is a requested
            // one: returns zero for a second value of the same key.
            function capture(ctx, sp, h, vs, ve) -> ok {
                ok := 1
                let ks := mload(add(ctx, 0x20))
                for { let k := 0 } lt(k, mload(ks)) { k := add(k, 1) } {
                    if eq(mload(add(add(ks, 0x20), shl(5, k))), h) {
                        let slot := add(add(sp, 0x20), shl(5, k))
                        if mload(slot) {
                            ok := 0
                            leave
                        }
                        let b0 := mload(add(ctx, 0x60))
                        mstore(slot, or(shl(128, sub(vs, b0)), sub(ve, b0)))
                    }
                }
            }

            // The pointer after the value at p, or zero; it counts the value, and checks depth
            // (the object at the top has `depth` 8).
            function value(p, e, depth, ctx) -> q {
                let n := add(mload(ctx), 1)
                mstore(ctx, n)
                if or(gt(n, 1024), iszero(lt(p, e))) { leave }
                switch byte(0, mload(p))
                case 0x22 { q := str(p, e, 0, ctx) }
                case 0x7b { if depth { q := obj(p, e, sub(depth, 1), ctx) } }
                case 0x5b { if depth { q := arr(p, e, sub(depth, 1), ctx) } }
                case 0x74 { q := lit(p, e, 4, 0x74727565) }
                case 0x66 { q := lit(p, e, 5, 0x66616c7365) }
                case 0x6e { q := lit(p, e, 4, 0x6e756c6c) }
                default { q := num(p, e) }
            }

            // The pointer after the array at p, or zero.
            function arr(p, e, depth, ctx) -> q {
                p := ws(add(p, 1), e)
                if iszero(lt(p, e)) { leave }
                if eq(byte(0, mload(p)), 0x5d) {
                    q := add(p, 1)
                    leave
                }
                for { } 1 { } {
                    p := value(p, e, depth, ctx)
                    if iszero(p) { leave }
                    p := ws(p, e)
                    if iszero(lt(p, e)) { leave }
                    let c := byte(0, mload(p))
                    p := add(p, 1)
                    if eq(c, 0x5d) {
                        q := p
                        leave
                    }
                    if iszero(eq(c, 0x2c)) { leave }
                    p := ws(p, e)
                }
            }

            // The pointer after the object at p, or zero. The top-level object (`depth` 8)
            // collects the members the caller asked for.
            function obj(p, e, depth, ctx) -> q {
                p := ws(add(p, 1), e)
                if iszero(lt(p, e)) { leave }
                if eq(byte(0, mload(p)), 0x7d) {
                    q := add(p, 1)
                    leave
                }
                for { } 1 { } {
                    let at := p
                    p := str(p, e, 1, ctx)
                    if iszero(p) { leave }
                    // A key counts as a value, and two at the top level, where it is also hashed
                    // and matched.
                    mstore(ctx, add(mload(ctx), add(1, eq(depth, 8))))
                    if gt(mload(ctx), 1024) { leave }
                    let h := 0
                    if eq(depth, 8) { h := keccak256(add(at, 1), sub(sub(p, at), 2)) }
                    p := ws(p, e)
                    if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x3a))) { leave }
                    at := ws(add(p, 1), e)
                    p := value(at, e, depth, ctx)
                    if iszero(p) { leave }
                    if eq(depth, 8) {
                        if iszero(capture(ctx, mload(add(ctx, 0x40)), h, at, p)) { leave }
                    }
                    p := ws(p, e)
                    if iszero(lt(p, e)) { leave }
                    let c := byte(0, mload(p))
                    p := add(p, 1)
                    if eq(c, 0x7d) {
                        q := p
                        leave
                    }
                    if iszero(eq(c, 0x2c)) { leave }
                    p := ws(p, e)
                }
            }

            // The pointer after the value at p of a validated document, or zero. Nothing is
            // checked, but nothing outside [p, e) is read.
            function skip(p, e, ctx) -> q {
                if iszero(lt(p, e)) { leave }
                let c := byte(0, mload(p))
                if eq(c, 0x22) {
                    q := str(p, e, 2, ctx)
                    leave
                }
                if or(eq(c, 0x7b), eq(c, 0x5b)) {
                    let d := 0
                    for { let t := p } lt(t, e) { } {
                        c := byte(0, mload(t))
                        if eq(c, 0x22) {
                            t := str(t, e, 2, ctx)
                            if iszero(t) { leave }
                            continue
                        }
                        t := add(t, 1)
                        if or(eq(c, 0x7b), eq(c, 0x5b)) { d := add(d, 1) }
                        if or(eq(c, 0x7d), eq(c, 0x5d)) {
                            d := sub(d, 1)
                            if iszero(d) {
                                q := t
                                leave
                            }
                        }
                    }
                    leave
                }
                // A number or a literal: up to the next delimiter.
                q := p
                for { } lt(q, e) { q := add(q, 1) } {
                    c := byte(0, mload(q))
                    if or(
                        or(eq(c, 0x2c), eq(c, 0x7d)),
                        or(eq(c, 0x5d), and(lt(c, 33), shr(c, 0x100002600)))
                    ) { break }
                }
            }

            // The pointer after the object at p of a validated document, or zero, with the
            // members the caller asked for captured in `sp`.
            // With `distinct`, at most 8 members, all with different keys.
            function navObj(p, e, ctx, sp, distinct) -> q {
                if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x7b))) { leave }
                p := ws(add(p, 1), e)
                if iszero(lt(p, e)) { leave }
                if eq(byte(0, mload(p)), 0x7d) {
                    q := add(p, 1)
                    leave
                }
                for { let m := 0 } 1 { } {
                    let at := p
                    p := str(p, e, 2, ctx)
                    if iszero(p) { leave }
                    let h := keccak256(add(at, 1), sub(sub(p, at), 2))
                    if distinct {
                        if gt(m, 7) { leave }
                        for { let k := 0 } lt(k, m) { k := add(k, 1) } {
                            if eq(mload(add(add(ctx, 0x80), shl(5, k))), h) { leave }
                        }
                        mstore(add(add(ctx, 0x80), shl(5, m)), h)
                        m := add(m, 1)
                    }
                    p := ws(p, e)
                    if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x3a))) { leave }
                    at := ws(add(p, 1), e)
                    p := skip(at, e, ctx)
                    if iszero(p) { leave }
                    if iszero(capture(ctx, sp, h, at, p)) { leave }
                    p := ws(p, e)
                    if iszero(lt(p, e)) { leave }
                    let c := byte(0, mload(p))
                    p := add(p, 1)
                    if eq(c, 0x7d) {
                        q := p
                        leave
                    }
                    if iszero(eq(c, 0x2c)) { leave }
                    p := ws(p, e)
                }
            }

            // Modes 2 and 3: the elements of the array at p, by `skip`. Mode 3: an array of
            // objects, each captured as an element span and the spans of its members. The count
            // plus one, or zero.
            function navElements(p, e, ctx, objects) -> cnt {
                if iszero(and(lt(p, e), eq(byte(0, mload(p)), 0x5b))) { leave }
                p := ws(add(p, 1), e)
                if iszero(lt(p, e)) { leave }
                if eq(byte(0, mload(p)), 0x5d) {
                    cnt := 1
                    leave
                }
                let sp := mload(add(ctx, 0x40))
                // Slots an element takes: its own span, then the spans of its members.
                let stride := 1
                if objects { stride := add(1, mload(mload(add(ctx, 0x20)))) }
                let max := div(mload(sp), stride)
                for { let n := 0 } 1 { } {
                    // Too many.
                    if eq(n, max) { leave }
                    let at := p
                    let slot := add(add(sp, 0x20), shl(5, mul(n, stride)))
                    switch objects
                    case 0 { p := skip(at, e, ctx) }
                    default { p := navObj(at, e, ctx, slot, 1) }
                    if iszero(p) { leave }
                    mstore(
                        slot,
                        or(shl(128, sub(at, mload(add(ctx, 0x60)))), sub(p, mload(add(ctx, 0x60))))
                    )
                    n := add(n, 1)
                    p := ws(p, e)
                    if iszero(lt(p, e)) { leave }
                    let c := byte(0, mload(p))
                    p := add(p, 1)
                    if eq(c, 0x5d) {
                        cnt := add(n, 1)
                        leave
                    }
                    if iszero(eq(c, 0x2c)) { leave }
                    p := ws(p, e)
                }
            }

            // ctx: the value count, the keys, the spans, the start of the text, and room for the
            // key hashes of the members of one element (eight).
            let ctx := mload(0x40)
            mstore(0x40, add(ctx, 0x180))
            let base := add(json, 0x20)
            let e := add(base, mload(json))
            mstore(ctx, 0)
            mstore(add(ctx, 0x20), keys)
            mstore(add(ctx, 0x40), spans)
            mstore(add(ctx, 0x60), base)
            switch mode
            case 0 {
                let p := ws(base, e)
                if and(lt(p, e), eq(byte(0, mload(p)), 0x7b)) {
                    let q := obj(p, e, 8, ctx)
                    if q { r := eq(ws(q, e), e) }
                }
            }
            case 1 { r := iszero(iszero(navObj(add(base, start), e, ctx, spans, 0))) }
            default { r := navElements(add(base, start), e, ctx, eq(mode, 3)) }
        }
    }
}
