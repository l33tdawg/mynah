package main

import (
	"embed"
	"net/http"
	"strings"
)

// Source: g2/public. Refresh these copies when updating the companion notice.
//
//go:embed g2-pages/*.html
var g2Pages embed.FS

func serveG2Page(w http.ResponseWriter, req *http.Request) {
	name := strings.TrimPrefix(req.URL.Path, "/g2/")
	if name != "privacy.html" && name != "terms.html" {
		http.NotFound(w, req)
		return
	}
	page, err := g2Pages.ReadFile("g2-pages/" + name)
	if err != nil {
		http.NotFound(w, req)
		return
	}
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.Header().Set("Referrer-Policy", "no-referrer")
	w.Header().Set("Content-Security-Policy", "default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; frame-ancestors 'none'")
	w.Write(page)
}
