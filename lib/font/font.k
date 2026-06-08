/ lib/font/font.k — load font extension
/
/ Build first:  zig build font
/ Load with:    2: "lib/font/font.k"

so: "./zig-out/lib/libfont.dylib"
fontLoad:    so 2: (`fontLoad;    1)   / "path" → handle (int)
fontMetrics: so 2: (`fontMetrics; 1)   / F[handle;size] → F[ascent;descent;lgap]
fontShape:   so 2: (`fontShape;   1)   / "text" → I glyph IDs
fontOutline: so 2: (`fontOutline; 1)   / F[handle;glyph_id;size] → L of F contours
