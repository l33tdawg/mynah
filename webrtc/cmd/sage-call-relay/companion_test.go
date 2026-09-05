package main

import (
	"net/http/httptest"
	"strings"
	"testing"
)

func TestCompanionConfigNeedsALiveToken(t *testing.T) {
	r := testRelay()
	for _, known := range []bool{false, true} {
		if known {
			r.appliances["test-token"] = &appliance{}
		}
		w := httptest.NewRecorder()
		r.routes().ServeHTTP(w, httptest.NewRequest("GET", "/test-token/connect", nil))
		if known && (w.Code != 200 || !strings.Contains(w.Body.String(), "mynah.g2.v1")) {
			t.Fatal(w.Code, w.Body.String())
		}
		if !known && w.Code != 404 {
			t.Fatal("unknown token accepted")
		}
		if w.Header().Get("Cache-Control") != "no-store" {
			t.Fatal("capability response can be cached")
		}
		if w.Header().Get("Access-Control-Allow-Origin") != "*" {
			t.Fatal("WebView cannot read config")
		}
	}
}

func TestCompanionCORSDoesNotExposeApplianceEndpoints(t *testing.T) {
	r := testRelay()
	w := httptest.NewRecorder()
	r.routes().ServeHTTP(w, httptest.NewRequest("OPTIONS", "/token/offer", nil))
	if w.Code != 204 || w.Header().Get("Access-Control-Allow-Headers") != "Content-Type" {
		t.Fatal("offer preflight failed")
	}
	w = httptest.NewRecorder()
	r.routes().ServeHTTP(w, httptest.NewRequest("OPTIONS", "/appliance/listen", nil))
	if w.Header().Get("Access-Control-Allow-Origin") != "" {
		t.Fatal("appliance credentials exposed to WebViews")
	}
}

func TestGlassesPairingAndCallsDoNotRevokeEachOther(t *testing.T) {
	r := testRelay()
	register := func(token, kind string) {
		req := httptest.NewRequest("POST", "/appliance/listen", strings.NewReader(`{"token":"`+token+`","kind":"`+kind+`"}`))
		req.Header.Set("Authorization", authorised())
		w := httptest.NewRecorder()
		r.routes().ServeHTTP(w, req)
		if w.Code != 204 {
			t.Fatalf("register: %d %s", w.Code, w.Body.String())
		}
	}
	register("glasses", "g2")
	register("call1", "")
	register("call2", "")
	if r.appliances["glasses"] == nil || r.appliances["call2"] == nil || r.appliances["call1"] != nil {
		t.Fatal("call rotation disturbed G2 pairing")
	}
	register("replacement", "g2")
	if r.appliances["glasses"] != nil || r.appliances["replacement"] == nil || r.appliances["call2"] == nil {
		t.Fatal("G2 rotation disturbed call")
	}
}
