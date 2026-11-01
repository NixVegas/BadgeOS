# Sun Gallant 12x22 BDF (illumos Gallant19.bdf, CDDL, Copyright 2006 Sun Microsystems)
# -> Nix glyph table for printable ASCII. Each BITMAP row is a 16-bit word whose top 12
# bits are the columns; the output keeps them as a 12-bit int, bit 11 = leftmost.
BEGIN {
    enc = -1; inbits = 0; nrows = 0;
    print "# GENERATED from Gallant19.bdf (Sun Gallant 12x22, CDDL). Do not edit.";
    print "# See LICENSE.gallant. width=12 height=22, row-major (bit 11 = leftmost col).";
    print "{";
    print "  width = 12;";
    print "  height = 22;";
    print "  glyphs = {";
}

/^ENCODING /    { enc = $2 + 0; next }
/^BITMAP/       { if (enc >= 32 && enc <= 126) { inbits = 1; nrows = 0; delete rows } next }
/^ENDCHAR/ {
    if (inbits && enc >= 32 && enc <= 126) {
        line = "    \"" enc "\" = [";
        for (i = 0; i < nrows; i++) {
            w = hex2dec(rows[i]);
            row12 = int(w / 16);   # >> 4
            line = line " " row12;
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
