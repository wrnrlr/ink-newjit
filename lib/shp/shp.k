/ lib/shp/shp.k — load shapefile extension
/
/ Build first:  zig build shp
/ Load with:    2: "lib/shp/shp.k"
/
/ Readers (each takes a path string):
/   ReadShp "f.shp"  → dict  `type`box`x`y[`z`m]`part`shape  (flat CSR geometry)
/   ReadShx "f.shx"  → dict  `offset`len                     (record index, bytes)
/   ReadDbf "f.dbf"  → table (one column per attribute field)
/   ReadPrj "f.prj"  → projection WKT string
/   ReadCpg "f.cpg"  → codepage / encoding name
/   ReadSbn "f.sbn"  → table `id`xmin`ymin`xmax`ymax (best-effort)
/
/ .shp and .dbf align by position: shp record i ↔ dbf row i.
/ Reconstruct feature i's rings from the CSR offsets:
/   p: shp`part                       / point-start of each ring (+sentinel)
/   s: shp`shape                      / part-start of each feature (+sentinel)
/   parts: s[i] + !s[i+1]-s[i]        / part indices of feature i
/   ring:  {(shp`x; shp`y)@\:p[x]+!p[x+1]-p[x]} parts   / each ring's (xs;ys)

so: "./zig-out/lib/libshp.dylib"
ReadShp: so 2: (`ReadShp; 1)
ReadShx: so 2: (`ReadShx; 1)
ReadDbf: so 2: (`ReadDbf; 1)
ReadPrj: so 2: (`ReadPrj; 1)
ReadCpg: so 2: (`ReadCpg; 1)
ReadSbn: so 2: (`ReadSbn; 1)
