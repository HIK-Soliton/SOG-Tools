package main

import (
	"bytes"
	"compress/flate"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"encoding/xml"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"math"
	"math/rand/v2"
	"mime"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/beevik/etree"
	dsig "github.com/russellhaering/goxmldsig"
	"golang.org/x/net/html"
)

const (
	samlStatusSuccess  = "urn:oasis:names:tc:SAML:2.0:status:Success"
	samlBindingPOST    = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
	samlBindingRedirect = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
	nameIDEmail        = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
	browserUserAgent   = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/139.0.0.0 Safari/537.36"
)

type args struct {
	Metadata               string
	Password               string
	UserID                 string
	Requests               int
	RPS                    float64
	Threads                int
	Binding                string
	SPHost                 string
	SPPort                 int
	ACSURL                 string
	EntityID               string
	LoginURL               string
	LoginMethod            string
	LoginPayloadFormat     string
	Timeout                time.Duration
	ResponseTimeout        time.Duration
	SkipResponseValidation bool
	InsecureTLS            bool
	Verbose                bool
}

type idpMetadata struct {
	EntityID            string
	SSORedirectURL      string
	SSOPostURL          string
	SigningCertificates []string
}

type samlRequestContext struct {
	RequestID    string
	RelayState   string
	UserID       string
	IssueInstant string
}

type testResult struct {
	UserID         string
	Success        bool
	Message        string
	ElapsedSeconds float64
}

type responseStore struct {
	mu        sync.Mutex
	responses map[string]chan map[string]string
}

func newResponseStore() *responseStore {
	return &responseStore{responses: map[string]chan map[string]string{}}
}

func (s *responseStore) register(relayState string) chan map[string]string {
	s.mu.Lock()
	defer s.mu.Unlock()
	ch := make(chan map[string]string, 1)
	s.responses[relayState] = ch
	return ch
}

func (s *responseStore) put(relayState string, payload map[string]string) {
	s.mu.Lock()
	ch := s.responses[relayState]
	s.mu.Unlock()
	if ch != nil {
		select {
		case ch <- payload:
		default:
		}
	}
}

func (s *responseStore) remove(relayState string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.responses, relayState)
}

type metadataXML struct {
	XMLName                xml.Name                 `xml:"EntityDescriptor"`
	EntityID               string                   `xml:"entityID,attr"`
	IDPSSODescriptor       metadataIDPSSODescriptor `xml:"IDPSSODescriptor"`
}

type metadataIDPSSODescriptor struct {
	SingleSignOnService []metadataSSOService `xml:"SingleSignOnService"`
	KeyDescriptor       []metadataKeyDesc    `xml:"KeyDescriptor"`
}

type metadataSSOService struct {
	Binding  string `xml:"Binding,attr"`
	Location string `xml:"Location,attr"`
}

type metadataKeyDesc struct {
	Use    string            `xml:"use,attr"`
	KeyInfo metadataKeyInfo  `xml:"KeyInfo"`
}

type metadataKeyInfo struct {
	X509Data metadataX509Data `xml:"X509Data"`
}

type metadataX509Data struct {
	Certificates []string `xml:"X509Certificate"`
}

type formData struct {
	Action string
	Method string
	Fields map[string]string
}

func parseArgs() (*args, error) {
	a := &args{}
	scriptDir, err := os.Getwd()
	if err != nil {
		return nil, err
	}
	flag.StringVar(&a.Metadata, "metadata", filepath.Join(scriptDir, "OneGateCloudMetadata.xml"), "IdP metadata file path")
	flag.StringVar(&a.Password, "password", "", "Password for login")
	flag.StringVar(&a.UserID, "user-id", "", "Fixed login user ID")
	flag.IntVar(&a.Requests, "requests", 0, "Total request count")
	flag.Float64Var(&a.RPS, "rps", 0, "Requests per second")
	flag.IntVar(&a.Threads, "threads", 0, "Worker thread count")
	flag.StringVar(&a.Binding, "binding", "redirect", "redirect or post")
	flag.StringVar(&a.SPHost, "sp-host", "127.0.0.1", "Local SP host")
	flag.IntVar(&a.SPPort, "sp-port", 8001, "Local SP port")
	flag.StringVar(&a.ACSURL, "acs-url", "", "ACS URL")
	flag.StringVar(&a.EntityID, "entity-id", "", "SP EntityID")
	flag.StringVar(&a.LoginURL, "login-url", "", "Login endpoint override")
	flag.StringVar(&a.LoginMethod, "login-method", "POST", "POST or PUT")
	flag.StringVar(&a.LoginPayloadFormat, "login-payload-format", "json", "json or form")
	timeoutSeconds := flag.Float64("timeout", 30.0, "HTTP timeout seconds")
	responseTimeoutSeconds := flag.Float64("response-timeout", 30.0, "ACS response timeout seconds")
	flag.BoolVar(&a.SkipResponseValidation, "skip-response-validation", false, "Skip SAMLResponse validation")
	flag.BoolVar(&a.InsecureTLS, "insecure-tls", false, "Disable TLS verification")
	flag.BoolVar(&a.Verbose, "verbose", false, "Verbose logging")
	flag.Parse()

	a.Binding = strings.ToLower(a.Binding)
	a.LoginMethod = strings.ToUpper(a.LoginMethod)
	a.LoginPayloadFormat = strings.ToLower(a.LoginPayloadFormat)
	a.Timeout = time.Duration(*timeoutSeconds * float64(time.Second))
	a.ResponseTimeout = time.Duration(*responseTimeoutSeconds * float64(time.Second))

	if a.Password == "" || a.Requests <= 0 || a.RPS <= 0 || a.Threads <= 0 {
		return nil, fmt.Errorf("--password, --requests, --rps, --threads are required")
	}
	if a.Binding != "redirect" && a.Binding != "post" {
		return nil, fmt.Errorf("--binding must be redirect or post")
	}
	if a.LoginMethod != "POST" && a.LoginMethod != "PUT" {
		return nil, fmt.Errorf("--login-method must be POST or PUT")
	}
	if a.LoginPayloadFormat != "json" && a.LoginPayloadFormat != "form" {
		return nil, fmt.Errorf("--login-payload-format must be json or form")
	}
	return a, nil
}

func parseIDPMetadata(path string) (*idpMetadata, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var doc metadataXML
	if err := xml.Unmarshal(b, &doc); err != nil {
		return nil, err
	}
	m := &idpMetadata{EntityID: doc.EntityID}
	for _, sso := range doc.IDPSSODescriptor.SingleSignOnService {
		switch sso.Binding {
		case samlBindingRedirect:
			m.SSORedirectURL = sso.Location
		case samlBindingPOST:
			m.SSOPostURL = sso.Location
		}
	}
	for _, kd := range doc.IDPSSODescriptor.KeyDescriptor {
		if kd.Use != "" && kd.Use != "signing" {
			continue
		}
		for _, cert := range kd.KeyInfo.X509Data.Certificates {
			cert = strings.TrimSpace(cert)
			if cert != "" {
				m.SigningCertificates = append(m.SigningCertificates, cert)
			}
		}
	}
	if m.EntityID == "" {
		return nil, errors.New("IdP metadata does not contain entityID")
	}
	if m.SSORedirectURL == "" && m.SSOPostURL == "" {
		return nil, errors.New("IdP metadata does not contain Redirect or POST SSO URL")
	}
	if len(m.SigningCertificates) == 0 {
		return nil, errors.New("IdP metadata does not contain signing certificates")
	}
	return m, nil
}

func randomUserID() string {
	return fmt.Sprintf("soliton%06d", rand.IntN(100000)+1)
}

func selectUserID(a *args) string {
	if a.UserID != "" {
		return a.UserID
	}
	return randomUserID()
}

func generateContext(userID string) samlRequestContext {
	return samlRequestContext{
		RequestID:    "_" + strconv.FormatInt(time.Now().UnixNano(), 16) + strconv.Itoa(rand.IntN(100000)),
		RelayState:   strconv.FormatInt(time.Now().UnixNano(), 16) + strconv.Itoa(rand.IntN(100000)),
		UserID:       userID,
		IssueInstant: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
	}
}

func buildAuthnRequestXML(ctx samlRequestContext, entityID, acsURL, destination string) ([]byte, error) {
	doc := etree.NewDocument()
	root := doc.CreateElement("samlp:AuthnRequest")
	root.CreateAttr("xmlns:samlp", "urn:oasis:names:tc:SAML:2.0:protocol")
	root.CreateAttr("xmlns:saml", "urn:oasis:names:tc:SAML:2.0:assertion")
	root.CreateAttr("ID", ctx.RequestID)
	root.CreateAttr("Version", "2.0")
	root.CreateAttr("IssueInstant", ctx.IssueInstant)
	root.CreateAttr("Destination", destination)
	root.CreateAttr("AssertionConsumerServiceURL", acsURL)
	root.CreateAttr("ProtocolBinding", samlBindingPOST)
	issuer := root.CreateElement("saml:Issuer")
	issuer.SetText(entityID)
	nameIDPolicy := root.CreateElement("samlp:NameIDPolicy")
	nameIDPolicy.CreateAttr("Format", nameIDEmail)
	nameIDPolicy.CreateAttr("AllowCreate", "true")

	doc.Indent(0)
	return doc.WriteToBytes()
}

func encodeRedirectSAMLRequest(xmlBytes []byte) (string, error) {
	var buf bytes.Buffer
	writer, err := flate.NewWriter(&buf, flate.DefaultCompression)
	if err != nil {
		return "", err
	}
	if _, err := writer.Write(xmlBytes); err != nil {
		_ = writer.Close()
		return "", err
	}
	if err := writer.Close(); err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(buf.Bytes()), nil
}

func encodePostSAMLRequest(xmlBytes []byte) string {
	return base64.StdEncoding.EncodeToString(xmlBytes)
}

func buildSPMetadata(entityID, acsURL string) ([]byte, error) {
	doc := etree.NewDocument()
	root := doc.CreateElement("EntityDescriptor")
	root.CreateAttr("xmlns", "urn:oasis:names:tc:SAML:2.0:metadata")
	root.CreateAttr("entityID", entityID)
	sp := root.CreateElement("SPSSODescriptor")
	sp.CreateAttr("protocolSupportEnumeration", "urn:oasis:names:tc:SAML:2.0:protocol")
	sp.CreateAttr("AuthnRequestsSigned", "false")
	sp.CreateAttr("WantAssertionsSigned", "true")
	nameID := sp.CreateElement("NameIDFormat")
	nameID.SetText(nameIDEmail)
	acs := sp.CreateElement("AssertionConsumerService")
	acs.CreateAttr("Binding", samlBindingPOST)
	acs.CreateAttr("Location", acsURL)
	acs.CreateAttr("index", "0")
	acs.CreateAttr("isDefault", "true")
	doc.Indent(0)
	return doc.WriteToBytes()
}

func startSPServer(host string, port int, store *responseStore, metadataXML []byte) (*http.Server, error) {
	mux := http.NewServeMux()
	mux.HandleFunc("/metadata", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/samlmetadata+xml; charset=utf-8")
		_, _ = w.Write(metadataXML)
	})
	mux.HandleFunc("/acs", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		if err := r.ParseForm(); err != nil {
			http.Error(w, "bad form", http.StatusBadRequest)
			return
		}
		relayState := r.Form.Get("RelayState")
		samlResponse := r.Form.Get("SAMLResponse")
		if samlResponse == "" {
			http.Error(w, "SAMLResponse is missing", http.StatusBadRequest)
			return
		}
		store.put(relayState, map[string]string{"RelayState": relayState, "SAMLResponse": samlResponse})
		_, _ = w.Write([]byte("SAMLResponse received."))
	})

	ln, err := net.Listen("tcp", net.JoinHostPort(host, strconv.Itoa(port)))
	if err != nil {
		return nil, err
	}

	srv := &http.Server{Handler: mux}
	go func() {
		if err := srv.Serve(ln); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Printf("SP server error: %v", err)
		}
	}()
	return srv, nil
}

func buildLoginPayload(userID, password string) map[string]string {
	return map[string]string{"userid": userID, "password": password, "rememberMe": "on"}
}

func buildLoginHeaders(loginURL, refererURL string) map[string]string {
	u, _ := url.Parse(loginURL)
	origin := ""
	if u != nil {
		origin = u.Scheme + "://" + u.Host
	}
	return map[string]string{
		"Accept":           "application/json, text/javascript, */*; q=0.01",
		"Origin":           origin,
		"Referer":          refererURL,
		"User-Agent":       browserUserAgent,
		"X-Requested-With": "XMLHttpRequest",
	}
}

func normalizeLoginURL(loginURL string) string {
	u, err := url.Parse(loginURL)
	if err != nil {
		return loginURL
	}
	if strings.TrimRight(u.Path, "/") == "/idp/login" {
		u.Path = "/idp/api/password"
		u.RawQuery = ""
		u.Fragment = ""
	}
	return u.String()
}

func parseJSONSuccess(body []byte) bool {
	var v map[string]any
	if err := json.Unmarshal(body, &v); err != nil {
		return false
	}
	passwordChangeFlag, okA := v["passwordChangeFlag"].(bool)
	isAuthFinished, okB := v["isAuthFinished"].(bool)
	return okA && okB && !passwordChangeFlag && isAuthFinished
}

func raiseForStatus(resp *http.Response) error {
	if resp.StatusCode >= 200 && resp.StatusCode < 400 {
		return nil
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1024))
	return fmt.Errorf("http status=%d body=%s", resp.StatusCode, strings.ReplaceAll(string(body), "\n", " "))
}

func parseFormsAndFields(htmlText string, baseURL string) ([]formData, map[string]string) {
	forms := []formData{}
	allFields := map[string]string{}
	tokenizer := html.NewTokenizer(strings.NewReader(htmlText))
	var current *formData
	for {
		tt := tokenizer.Next()
		switch tt {
		case html.ErrorToken:
			return forms, allFields
		case html.StartTagToken, html.SelfClosingTagToken:
			tok := tokenizer.Token()
			tag := strings.ToLower(tok.Data)
			attrs := map[string]string{}
			for _, a := range tok.Attr {
				attrs[strings.ToLower(a.Key)] = a.Val
			}
			if tag == "form" {
				action := attrs["action"]
				if action == "" {
					action = baseURL
				}
				if u, err := url.Parse(baseURL); err == nil {
					if ref, err := u.Parse(action); err == nil {
						action = ref.String()
					}
				}
				method := strings.ToLower(attrs["method"])
				if method == "" {
					method = "post"
				}
				fd := formData{Action: action, Method: method, Fields: map[string]string{}}
				current = &fd
				continue
			}
			if tag == "input" {
				name := attrs["name"]
				if name == "" {
					continue
				}
				value := attrs["value"]
				allFields[name] = value
				if current != nil {
					current.Fields[name] = value
				}
			}
		case html.EndTagToken:
			tok := tokenizer.Token()
			if strings.ToLower(tok.Data) == "form" && current != nil {
				forms = append(forms, *current)
				current = nil
			}
		}
	}
}

func findFormWithField(forms []formData, field string) *formData {
	for _, f := range forms {
		if _, ok := f.Fields[field]; ok {
			clone := f
			return &clone
		}
	}
	return nil
}

func findLoginFormAction(forms []formData) string {
	for _, f := range forms {
		hasUserID := false
		hasPassword := false
		for k := range f.Fields {
			lk := strings.ToLower(k)
			if lk == "userid" {
				hasUserID = true
			}
			if lk == "password" {
				hasPassword = true
			}
		}
		if hasUserID || hasPassword {
			return f.Action
		}
	}
	return ""
}

func submitRequest(client *http.Client, method, target string, headers map[string]string, body io.Reader, contentType string) (*http.Response, error) {
	req, err := http.NewRequest(method, target, body)
	if err != nil {
		return nil, err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if contentType != "" {
		req.Header.Set("Content-Type", contentType)
	}
	return client.Do(req)
}

func submitSAMLResponseForm(client *http.Client, htmlText, baseURL string, timeout time.Duration) (bool, error) {
	forms, _ := parseFormsAndFields(htmlText, baseURL)
	form := findFormWithField(forms, "SAMLResponse")
	if form == nil {
		return false, nil
	}
	values := url.Values{}
	for k, v := range form.Fields {
		values.Set(k, v)
	}
	method := strings.ToUpper(form.Method)
	if method == "GET" {
		u, err := url.Parse(form.Action)
		if err != nil {
			return false, err
		}
		u.RawQuery = values.Encode()
		resp, err := submitRequest(client, http.MethodGet, u.String(), map[string]string{}, nil, "")
		if err != nil {
			return false, err
		}
		defer resp.Body.Close()
		return true, nil
	}
	resp, err := submitRequest(client, http.MethodPost, form.Action, map[string]string{}, strings.NewReader(values.Encode()), "application/x-www-form-urlencoded")
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	_ = timeout
	return true, nil
}

func pemCertFromBase64(body string) ([]byte, error) {
	clean := strings.Join(strings.Fields(body), "")
	der, err := base64.StdEncoding.DecodeString(clean)
	if err != nil {
		return nil, err
	}
	p := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	return p, nil
}

func verifySAMLResponse(samlResponseB64 string, metadata *idpMetadata, reqCtx samlRequestContext, expectedAudience, expectedACSURL string) error {
	xmlBytes, err := base64.StdEncoding.DecodeString(samlResponseB64)
	if err != nil {
		return err
	}

	doc := etree.NewDocument()
	if err := doc.ReadFromBytes(xmlBytes); err != nil {
		return err
	}

	verificationErrors := []string{}
	verified := false
	for _, certBody := range metadata.SigningCertificates {
		pemCert, err := pemCertFromBase64(certBody)
		if err != nil {
			verificationErrors = append(verificationErrors, err.Error())
			continue
		}
		block, _ := pem.Decode(pemCert)
		if block == nil {
			verificationErrors = append(verificationErrors, "failed to decode PEM")
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			verificationErrors = append(verificationErrors, err.Error())
			continue
		}
		store := &dsig.MemoryX509CertificateStore{Roots: []*x509.Certificate{cert}}
		ctx := dsig.NewDefaultValidationContext(store)
		if _, err := ctx.Validate(doc.Root()); err == nil {
			verified = true
			break
		} else {
			verificationErrors = append(verificationErrors, err.Error())
		}
	}
	if !verified {
		if len(verificationErrors) > 3 {
			verificationErrors = verificationErrors[:3]
		}
		return fmt.Errorf("SAMLResponse signature verification failed: %s", strings.Join(verificationErrors, " | "))
	}

	root := doc.Root()
	if root == nil {
		return errors.New("empty SAMLResponse")
	}
	if v := root.SelectAttrValue("InResponseTo", ""); v != "" && v != reqCtx.RequestID {
		return fmt.Errorf("unexpected InResponseTo: %s", v)
	}
	if v := root.SelectAttrValue("Destination", ""); v != "" && v != expectedACSURL {
		return fmt.Errorf("unexpected Response Destination: %s", v)
	}

	statusCode := ""
	for _, e := range root.FindElements(".//{*}StatusCode") {
		statusCode = e.SelectAttrValue("Value", "")
		if statusCode != "" {
			break
		}
	}
	if statusCode != samlStatusSuccess {
		return fmt.Errorf("SAMLResponse status is not Success: %s", statusCode)
	}

	audiences := []string{}
	for _, e := range root.FindElements(".//{*}Audience") {
		text := strings.TrimSpace(e.Text())
		if text != "" {
			audiences = append(audiences, text)
		}
	}
	if len(audiences) > 0 {
		found := false
		for _, a := range audiences {
			if a == expectedAudience {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("expected audience not found: %s", expectedAudience)
		}
	}

	recipients := []string{}
	for _, e := range root.FindElements(".//{*}SubjectConfirmationData") {
		r := e.SelectAttrValue("Recipient", "")
		if r != "" {
			recipients = append(recipients, r)
		}
	}
	if len(recipients) > 0 {
		found := false
		for _, r := range recipients {
			if r == expectedACSURL {
				found = true
				break
			}
		}
		if !found {
			return fmt.Errorf("expected recipient not found: %s", expectedACSURL)
		}
	}
	return nil
}

func runSingleTest(a *args, metadata *idpMetadata, store *responseStore, entityID, acsURL string, transport *http.Transport) testResult {
	started := time.Now()
	ssoURL := metadata.SSORedirectURL
	if a.Binding == "post" {
		ssoURL = metadata.SSOPostURL
	}
	if ssoURL == "" {
		return testResult{Success: false, Message: "SSO URL not found for selected binding"}
	}

	ctx := generateContext(selectUserID(a))
	ch := store.register(ctx.RelayState)
	defer store.remove(ctx.RelayState)

	jar, _ := cookiejar.New(nil)
	client := &http.Client{Timeout: a.Timeout, Transport: transport, Jar: jar}

	xmlReq, err := buildAuthnRequestXML(ctx, entityID, acsURL, ssoURL)
	if err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	encodedRedirect, err := encodeRedirectSAMLRequest(xmlReq)
	if err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}

	var startResp *http.Response
	if a.Binding == "redirect" {
		u, _ := url.Parse(ssoURL)
		q := u.Query()
		q.Set("SAMLRequest", encodedRedirect)
		q.Set("RelayState", ctx.RelayState)
		u.RawQuery = q.Encode()
		startResp, err = submitRequest(client, http.MethodGet, u.String(), map[string]string{"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", "User-Agent": browserUserAgent}, nil, "")
	} else {
		values := url.Values{}
		values.Set("SAMLRequest", encodePostSAMLRequest(xmlReq))
		values.Set("RelayState", ctx.RelayState)
		startResp, err = submitRequest(client, http.MethodPost, ssoURL, map[string]string{"User-Agent": browserUserAgent}, strings.NewReader(values.Encode()), "application/x-www-form-urlencoded")
	}
	if err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	defer startResp.Body.Close()
	if err := raiseForStatus(startResp); err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	startBody, _ := io.ReadAll(startResp.Body)
	startURL := startResp.Request.URL.String()

	forms, _ := parseFormsAndFields(string(startBody), startURL)
	loginURL := a.LoginURL
	if loginURL == "" {
		loginURL = findLoginFormAction(forms)
	}
	if loginURL == "" {
		loginURL = startURL
	}
	loginURL = normalizeLoginURL(loginURL)

	payload := buildLoginPayload(ctx.UserID, a.Password)
	loginHeaders := buildLoginHeaders(loginURL, startURL)
	var loginResp *http.Response
	if a.LoginPayloadFormat == "json" {
		body, _ := json.Marshal(payload)
		loginResp, err = submitRequest(client, a.LoginMethod, loginURL, loginHeaders, bytes.NewReader(body), "application/json")
	} else {
		values := url.Values{}
		for k, v := range payload {
			values.Set(k, v)
		}
		loginResp, err = submitRequest(client, a.LoginMethod, loginURL, loginHeaders, strings.NewReader(values.Encode()), "application/x-www-form-urlencoded")
	}
	if err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	defer loginResp.Body.Close()
	if err := raiseForStatus(loginResp); err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	loginBody, _ := io.ReadAll(loginResp.Body)
	if parseJSONSuccess(loginBody) {
		log.Printf("DEBUG login API success user=%s", ctx.UserID)
	}

	_, hiddenFields := parseFormsAndFields(string(startBody), startURL)
	hiddenRequest := hiddenFields["SAMLRequest"]
	hiddenRelay := hiddenFields["RelayState"]
	if hiddenRequest == "" {
		return testResult{UserID: ctx.UserID, Success: false, Message: "Login page does not contain SAMLRequest hidden field", ElapsedSeconds: time.Since(started).Seconds()}
	}
	continueValues := url.Values{}
	continueValues.Set("SAMLRequest", hiddenRequest)
	continueValues.Set("RelayState", hiddenRelay)
	continueHeaders := buildLoginHeaders(ssoURL, startURL)
	continueHeaders["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
	continueResp, err := submitRequest(client, http.MethodPost, ssoURL, continueHeaders, strings.NewReader(continueValues.Encode()), "application/x-www-form-urlencoded")
	if err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	defer continueResp.Body.Close()
	if err := raiseForStatus(continueResp); err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	continueBody, _ := io.ReadAll(continueResp.Body)
	continueURL := continueResp.Request.URL.String()

	posted, err := submitSAMLResponseForm(client, string(continueBody), continueURL, a.Timeout)
	if err != nil {
		return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
	}
	if !posted && a.Binding == "redirect" {
		u, _ := url.Parse(ssoURL)
		q := u.Query()
		q.Set("SAMLRequest", encodedRedirect)
		q.Set("RelayState", ctx.RelayState)
		u.RawQuery = q.Encode()
		retryResp, err := submitRequest(client, http.MethodGet, u.String(), map[string]string{"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"}, nil, "")
		if err != nil {
			return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
		}
		defer retryResp.Body.Close()
		retryBody, _ := io.ReadAll(retryResp.Body)
		posted, err = submitSAMLResponseForm(client, string(retryBody), retryResp.Request.URL.String(), a.Timeout)
		if err != nil {
			return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
		}
	}
	if !posted {
		ct := continueResp.Header.Get("Content-Type")
		mediaType, _, _ := mime.ParseMediaType(ct)
		msg := fmt.Sprintf("SAMLResponse form not found at %s content-type=%s", continueURL, mediaType)
		return testResult{UserID: ctx.UserID, Success: false, Message: msg, ElapsedSeconds: time.Since(started).Seconds()}
	}

	select {
	case payload := <-ch:
		if !a.SkipResponseValidation {
			if err := verifySAMLResponse(payload["SAMLResponse"], metadata, ctx, entityID, acsURL); err != nil {
				return testResult{UserID: ctx.UserID, Success: false, Message: err.Error(), ElapsedSeconds: time.Since(started).Seconds()}
			}
		}
		return testResult{UserID: ctx.UserID, Success: true, Message: "ok", ElapsedSeconds: time.Since(started).Seconds()}
	case <-time.After(a.ResponseTimeout):
		return testResult{UserID: ctx.UserID, Success: false, Message: "Timed out waiting for SAMLResponse at ACS", ElapsedSeconds: time.Since(started).Seconds()}
	}
}

func paceSubmissions(total int, rps float64) []time.Duration {
	offsets := make([]time.Duration, total)
	interval := time.Duration(float64(time.Second) / rps)
	for i := 0; i < total; i++ {
		offsets[i] = time.Duration(i) * interval
	}
	return offsets
}

func percentile(values []float64, p float64) float64 {
	if len(values) == 0 {
		return 0
	}
	sorted := make([]float64, len(values))
	copy(sorted, values)
	sort.Float64s(sorted)
	idx := int(float64(len(sorted)-1) * p)
	if idx < 0 {
		idx = 0
	}
	if idx >= len(sorted) {
		idx = len(sorted) - 1
	}
	return sorted[idx]
}

func main() {
	a, err := parseArgs()
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
	if a.Verbose {
		log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	} else {
		log.SetOutput(io.Discard)
	}

	metadata, err := parseIDPMetadata(a.Metadata)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	localACSURL := fmt.Sprintf("http://%s:%d/acs", a.SPHost, a.SPPort)
	acsURL := a.ACSURL
	if acsURL == "" {
		acsURL = localACSURL
	}
	entityID := a.EntityID
	if entityID == "" {
		entityID = fmt.Sprintf("http://%s:%d/metadata", a.SPHost, a.SPPort)
	}

	spMetadataXML, err := buildSPMetadata(entityID, acsURL)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	store := newResponseStore()
	server, err := startSPServer(a.SPHost, a.SPPort, store, spMetadataXML)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		_ = server.Shutdown(ctx)
	}()

	fmt.Printf("IdP entityID: %s\n", metadata.EntityID)
	fmt.Printf("SP entityID: %s\n", entityID)
	fmt.Printf("SP ACS URL: %s\n", acsURL)
	fmt.Printf("SP metadata URL: http://%s:%d/metadata\n", a.SPHost, a.SPPort)

	transport := &http.Transport{
		MaxConnsPerHost:     a.Threads,
		MaxIdleConns:        a.Threads,
		MaxIdleConnsPerHost: a.Threads,
		TLSClientConfig:     &tls.Config{InsecureSkipVerify: a.InsecureTLS},
	}

	type job struct {
		idx int
	}
	jobs := make(chan job)
	results := make(chan testResult, a.Requests)

	var wg sync.WaitGroup
	for i := 0; i < a.Threads; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for range jobs {
				results <- runSingleTest(a, metadata, store, entityID, acsURL, transport)
			}
		}()
	}

	startTime := time.Now()
	offsets := paceSubmissions(a.Requests, a.RPS)
	for i, off := range offsets {
		target := startTime.Add(off)
		now := time.Now()
		if target.After(now) {
			time.Sleep(target.Sub(now))
		}
		jobs <- job{idx: i}
	}
	close(jobs)
	wg.Wait()
	close(results)

	allResults := make([]testResult, 0, a.Requests)
	for r := range results {
		allResults = append(allResults, r)
		if !r.Success {
			fmt.Fprintf(os.Stderr, "FAIL user=%s elapsed=%.3fs error=%s\n", r.UserID, r.ElapsedSeconds, r.Message)
		}
	}
	elapsed := time.Since(startTime).Seconds()
	success := 0
	elapsedPerReq := make([]float64, 0, len(allResults))
	for _, r := range allResults {
		if r.Success {
			success++
		}
		elapsedPerReq = append(elapsedPerReq, r.ElapsedSeconds)
	}
	failure := len(allResults) - success
	avgReqElapsed := 0.0
	for _, v := range elapsedPerReq {
		avgReqElapsed += v
	}
	if len(elapsedPerReq) > 0 {
		avgReqElapsed /= float64(len(elapsedPerReq))
	}
	summary := map[string]any{
		"total":                       len(allResults),
		"success":                     success,
		"failure":                     failure,
		"elapsedSeconds":              round3(elapsed),
		"averageRequestsPerSecond":    round3(float64(len(allResults)) / elapsed),
		"averageRequestElapsedSeconds": round3(avgReqElapsed),
		"p95RequestElapsedSeconds":    round3(percentile(elapsedPerReq, 0.95)),
	}
	enc := json.NewEncoder(os.Stdout)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", "  ")
	_ = enc.Encode(summary)

	if failure > 0 {
		os.Exit(1)
	}
}

func round3(v float64) float64 {
	return math.Round(v*1000) / 1000
}
