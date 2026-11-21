package main

import "strings"

// decodeLatin1 maps every byte to the Unicode code point of the same value
// (ISO 8859-1); close enough to Windows-1252 for umlauts.
func decodeLatin1(b []byte) string {
	var sb strings.Builder
	for _, c := range b {
		sb.WriteRune(rune(c))
	}
	return sb.String()
}
