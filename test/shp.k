/ test/shp.k — shapefile reader checks (run against the NYC taxi_zones fixture)
/
/ Build first:  zig build shp
/ Fixture:      unzip -o data/taxi_zones.zip -d data/taxi_zones
/ Run:          ink test/shp.k
/
/ NOTE on column names: ink treats `_` as the Drop verb, so a column whose name
/ contains an underscore can't be written as a bare symbol. Use a quoted symbol:
/   dbf`"Shape_Area"   (not  dbf`Shape_Area)

2: "lib/shp/shp.k"
chk: {[ok;msg] `0 0: msg," .. ",$[ok;"PASS";"FAIL"]}

B: "data/taxi_zones/taxi_zones/taxi_zones."

/ ── ReadShp: flat CSR polygon geometry ───────────────────────────────────────
shp: ReadShp B,"shp"
chk[(`polygon)~shp`type; "shp type=polygon"]
chk[(`type`box`x`y`part`shape)~!shp; "shp keys"]
chk[263 = -1+#shp`shape; "263 features"]
chk[98192 = #shp`x; "98192 points total"]
chk[1 = (shp`shape)1; "feature 0 has 1 part"]
chk[232 = (shp`part)1; "feature 0 ring has 232 points"]
chk[(933100 192536)~_((shp`x)0;(shp`y)0); "feature 0 point 0"]

/ x and y are single contiguous buffers (one part-offset and shape-offset index)
chk[(#shp`x) = (#shp`y); "x/y aligned"]
chk[(#shp`x) = *|shp`part; "part sentinel = #x"]  / last/max part offset = #x

/ ── ReadDbf: attribute table ─────────────────────────────────────────────────
dbf: ReadDbf B,"dbf"
chk[263 = #dbf`OBJECTID; "dbf 263 rows"]
chk[1 = (dbf`OBJECTID)0; "OBJECTID[0]=1"]
chk[(`"Newark Airport")~(dbf`zone)0; "zone[0]=Newark Airport (interned)"]
chk[(`EWR)~(dbf`borough)0; "borough[0]=EWR"]
chk[`I~@dbf`OBJECTID; "OBJECTID is I"]
chk[`F~@dbf`"Shape_Area"; "Shape_Area is F"]
chk[`S~@dbf`zone; "zone is S (symbols)"]

/ shp record i aligns with dbf row i
chk[(#dbf`OBJECTID) = -1+#shp`shape; "shp/dbf row counts agree"]

/ ── ReadShx: byte offsets ────────────────────────────────────────────────────
shx: ReadShx B,"shx"
chk[263 = #shx`offset; "shx 263 records"]
chk[100 = (shx`offset)0; "record 0 header at byte 100"]
chk[3760 = (shx`len)0; "record 0 content = 3760 bytes"]

/ ── ReadPrj / ReadCpg: sidecar text ──────────────────────────────────────────
chk["PROJCS"~6#ReadPrj B,"prj"; "prj is WKT (PROJCS...)"]
chk["UTF-8"~ReadCpg B,"cpg"; "cpg=UTF-8"]

`0 0: "done"
