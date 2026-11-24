package main

import (
	"image"
	"image/color"
	"image/png"
	"os"
	"testing"
)

func TestTrayPixels(t *testing.T) {
	for s := 0; s < 3; s++ {
		p := trayPixels(s)
		if len(p) != 32*32*4 {
			t.Fatal("size")
		}
		if p[3] != 0 { // top-left corner stays transparent
			t.Fatal("corner not transparent")
		}
		if p[(24*32+24)*4+3] != 255 { // status dot centre opaque
			t.Fatal("dot missing")
		}
		if dir := os.Getenv("ICON_PNG_DIR"); dir != "" { // optional preview
			img := image.NewNRGBA(image.Rect(0, 0, 32, 32))
			for i := 0; i < 32*32; i++ {
				a := p[i*4+3]
				if a == 0 {
					continue
				}
				f := 255 / float64(a)
				img.Pix[i*4], img.Pix[i*4+1], img.Pix[i*4+2], img.Pix[i*4+3] = byte(float64(p[i*4+2])*f), byte(float64(p[i*4+1])*f), byte(float64(p[i*4])*f), a
			}
			f, _ := os.Create(dir + "/icon" + string(rune('0'+s)) + ".png")
			_ = png.Encode(f, img)
			f.Close()
			_ = color.RGBA{}
		}
	}
}
