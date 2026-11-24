package main

// trayPixels draws the tray icon (32x32, premultiplied BGRA, top-down): the two overlapping
// circles of the app logo plus a status dot in the lower right corner (0 grey, 1 green, 2 red).
func trayPixels(state int) []byte {
	const n, ss = 32, 4                                                                     // size, supersampling per axis
	dot := [3][3]float64{{0x90, 0x90, 0x90}, {0x2e, 0xb0, 0x3c}, {0xd8, 0x30, 0x30}}[state] // R, G, B
	out := make([]byte, n*n*4)
	in := func(x, y, cx, cy, r float64) bool { return (x-cx)*(x-cx)+(y-cy)*(y-cy) <= r*r }
	for py := 0; py < n; py++ {
		for px := 0; px < n; px++ {
			var a, r, g, b float64
			for sy := 0; sy < ss; sy++ {
				for sx := 0; sx < ss; sx++ {
					x, y := float64(px)+(float64(sx)+.5)/ss, float64(py)+(float64(sy)+.5)/ss
					var cr, cg, cb float64
					set := true
					switch {
					case in(x, y, 24.5, 24.5, 5.2):
						cr, cg, cb = dot[0], dot[1], dot[2]
					case in(x, y, 24.5, 24.5, 7.2):
						cr, cg, cb = 255, 255, 255
					case in(x, y, 12.2, 15, 11) && in(x, y, 19.8, 15, 11):
						cr, cg, cb = 255, 255, 255
					case in(x, y, 12.2, 15, 11):
						cr, cg, cb = 0x8b, 0x72, 0xf6
					case in(x, y, 19.8, 15, 11):
						cr, cg, cb = 0x2b, 0xc3, 0xf0
					default:
						set = false
					}
					if set {
						a++
						r, g, b = r+cr, g+cg, b+cb
					}
				}
			}
			if a == 0 {
				continue
			}
			i := (py*n + px) * 4
			total := float64(ss * ss)
			// premultiplied: colour sum / total, alpha = covered / total
			out[i], out[i+1], out[i+2], out[i+3] = byte(b/total), byte(g/total), byte(r/total), byte(a/total*255)
		}
	}
	return out
}
