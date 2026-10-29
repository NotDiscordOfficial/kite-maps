# Highway Radar Android data investigation

Static analysis of the supplied APKPure Highway Radar 3.2 (update 7) XAPK, SHA-256 `446c8f8d9d829850b9ed0c618a1d78e0ee982af88ae05423b3214d74c9748de2`. This is the Android app; the iOS version may differ.

Using Androguard on `classes.dex`, method `Lcc/d;->c` constructs `https://tiles.cmbe.cc/heat_map/get/{c}/{a}/{b}.webp`. `Lcc/d;->b` appends `?tag=dilate-{d}` when d is nonzero. The meaning of those fields is inferred from the successful sample, not proven by tracing their producers. `Lcc/b;->b` constructs `https://tiles.cmbe.cc/cameras_v2/get/8/{a}/{b}.excam`. Other methods construct risk and road graph URLs. These observations do not establish permissions or a supported public API.

A single request for `/heat_map/get/10/841/607.webp`, corresponding to a Web Mercator tile around Perth, returned HTTP 200 and a 256x256 RGB WebP. Its pixels are predominantly grayscale and black; it is not a transparent coloured map overlay. Actual visualization requires tracing the Android colour ramp, threshold and opacity, and ensuring tiles are aligned and converted correctly. A request for the analogous camera tile `/cameras_v2/get/8/210/151.excam` returned the text `Not found`; availability and format are unverified. Do not interpret that response as an empty camera database.

The app contains settings for heat-map color, dilation, opacity and transparent threshold. Their exact mapping and units remain to be traced. Risks of a naive implementation include drawing an opaque grayscale rectangle, assuming the wrong map projection or representing missing data as zero. No data from Highway Radar is currently integrated in Kite. Server access, terms, stability and geographic coverage remain unverified.

Kite's existing Waze heat map is collected on-device over time and should not be presented as Highway Radar's year-long history. Live Waze reports are a separate data source.
