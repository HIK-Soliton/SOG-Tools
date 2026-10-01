package main

import (
	"io"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"strings"
	"testing"
)

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

func TestRewriteMTLSURL(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "tenant host",
			input: "https://tenant.ids-dev.solitonsys.jp/idp/sso?binding=redirect",
			want:  "https://tenant.ids-dev-s.solitonsys.jp/idp/sso?binding=redirect",
		},
		{
			name:  "host with port",
			input: "https://tenant.ids-dev.solitonsys.jp:8443/idp/sso",
			want:  "https://tenant.ids-dev-s.solitonsys.jp:8443/idp/sso",
		},
		{
			name:  "base domain",
			input: "https://ids-dev.solitonsys.jp/idp/sso",
			want:  "https://ids-dev-s.solitonsys.jp/idp/sso",
		},
		{
			name:  "already mTLS domain",
			input: "https://tenant.ids-dev-s.solitonsys.jp/idp/sso",
			want:  "https://tenant.ids-dev-s.solitonsys.jp/idp/sso",
		},
		{
			name:  "different domain",
			input: "https://login.example.com/idp/sso",
			want:  "https://login.example.com/idp/sso",
		},
		{
			name:  "non-TLS URL",
			input: "http://tenant.ids-dev.solitonsys.jp/idp/sso",
			want:  "http://tenant.ids-dev.solitonsys.jp/idp/sso",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := rewriteMTLSURL(test.input); got != test.want {
				t.Errorf("rewriteMTLSURL(%q) = %q, want %q", test.input, got, test.want)
			}
		})
	}
}

func TestSubmitRequestRewritesBeforeCookieJar(t *testing.T) {
	var capturedRequest *http.Request
	transport := &mtlsDomainTransport{base: roundTripFunc(func(request *http.Request) (*http.Response, error) {
		capturedRequest = request
		return &http.Response{
			StatusCode: http.StatusOK,
			Header:     http.Header{"Set-Cookie": []string{"session=active; Path=/"}},
			Body:       io.NopCloser(strings.NewReader("ok")),
			Request:    request,
		}, nil
	})}
	jar, err := cookiejar.New(nil)
	if err != nil {
		t.Fatal(err)
	}
	client := &http.Client{Transport: transport, Jar: jar}
	headers := map[string]string{
		"Origin":  "https://tenant.ids-dev.solitonsys.jp",
		"Referer": "https://tenant.ids-dev.solitonsys.jp/idp/login",
	}

	response, err := submitRequest(client, http.MethodGet, "https://tenant.ids-dev.solitonsys.jp/idp/sso", headers, nil, "")
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()

	if got, want := capturedRequest.URL.Host, "tenant.ids-dev-s.solitonsys.jp"; got != want {
		t.Fatalf("request host = %q, want %q", got, want)
	}
	if got, want := capturedRequest.Header.Get("Origin"), "https://tenant.ids-dev-s.solitonsys.jp"; got != want {
		t.Errorf("Origin = %q, want %q", got, want)
	}
	if got, want := capturedRequest.Header.Get("Referer"), "https://tenant.ids-dev-s.solitonsys.jp/idp/login"; got != want {
		t.Errorf("Referer = %q, want %q", got, want)
	}

	mtlsURL, _ := url.Parse("https://tenant.ids-dev-s.solitonsys.jp/idp/sso")
	if cookies := jar.Cookies(mtlsURL); len(cookies) != 1 || cookies[0].Name != "session" {
		t.Errorf("cookies for rewritten host = %v, want session cookie", cookies)
	}
	originalURL, _ := url.Parse("https://tenant.ids-dev.solitonsys.jp/idp/sso")
	if cookies := jar.Cookies(originalURL); len(cookies) != 0 {
		t.Errorf("cookies for original host = %v, want none", cookies)
	}
}

func TestRewriteMTLSRedirect(t *testing.T) {
	request, err := http.NewRequest(http.MethodGet, "https://tenant.ids-dev.solitonsys.jp/idp/next", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Referer", "https://tenant.ids-dev.solitonsys.jp/idp/login")

	if err := rewriteMTLSRedirect(request, nil); err != nil {
		t.Fatal(err)
	}
	if got, want := request.URL.Host, "tenant.ids-dev-s.solitonsys.jp"; got != want {
		t.Errorf("redirect host = %q, want %q", got, want)
	}
	if got, want := request.Header.Get("Referer"), "https://tenant.ids-dev-s.solitonsys.jp/idp/login"; got != want {
		t.Errorf("redirect Referer = %q, want %q", got, want)
	}
	if err := rewriteMTLSRedirect(request, make([]*http.Request, 10)); err == nil {
		t.Error("expected redirect limit error")
	}
}
