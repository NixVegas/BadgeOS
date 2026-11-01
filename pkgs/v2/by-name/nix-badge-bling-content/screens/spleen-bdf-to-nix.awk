# Spleen BDF (Frederic Cambus, BSD-2-Clause) -> Nix glyph table for printable ASCII, in
# the same shape as gallant-bdf-to-nix.awk. Run with `-v width=W -v height=H`.
BEGIN {
    if (width == 0 || height == 0) {
        print "spleen-bdf-to-nix.awk: need -v width=W -v height=H" > "/dev/stderr";
        exit 1;
    }
    enc = -1; inbits = 0; nrows = 0;
    # Each row is padded to whole bytes; shift out the low padding bits.
    hexdigits = int((width + 7) / 8) * 2;
    totbits = hexdigits * 4;
    shift = 1;
    for (i = 0; i < totbits - width; i++) shift = shift * 2;   # 2^(totbits-width)

    print "# GENERATED from Spleen " width "x" height ".bdf (fcambus/spleen, BSD-2-Clause). Do not edit.";
    print "# See LICENSE.spleen. width=" width " height=" height ", row-major (bit " (width - 1) " = leftmost col).";
    print "{";
    print "  width = " width ";";
    print "  height = " height ";";
    print "  glyphs = {";
}

/^ENCODING /    { enc = $2 + 0; next }
/^BITMAP/       { if (enc >= 32 && enc <= 126) { inbits = 1; nrows = 0; delete rows } next }
/^ENDCHAR/ {
    if (inbits && enc >= 32 && enc <= 126) {
        line = "    \"" enc "\" = [";
        for (i = 0; i < nrows; i++) {
            w = hex2dec(rows[i]);
            rowW = int(w / shift);
            line = line " " rowW;
        }
        line = line " ];";
        print line;
    }
    inbits = 0;
    next
}
{
    if (inbits) {
        rows[nrows] = $0;
        nrows++;
    }
}

END {
    print "  };";
    print "}";
}

# POSIX awk has no strtonum.
function hex2dec(s,    n, k, c, d) {
    n = 0;
    s = toupper(s);
    for (k = 1; k <= length(s); k++) {
        c = substr(s, k, 1);
        if      (c >= "0" && c <= "9") d = c + 0;
        else if (c == "A") d = 10;
        else if (c == "B") d = 11;
        else if (c == "C") d = 12;
        else if (c == "D") d = 13;
        else if (c == "E") d = 14;
        else if (c == "F") d = 15;
        else continue;   # skip any stray whitespace/CR
        n = n * 16 + d;
    }
    return n;
}
