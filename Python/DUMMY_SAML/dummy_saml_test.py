"""SAML SP-Initiated authentication test runner.

Place IdP metadata as OneGateCloudMetadata.xml in the same directory by default.
The script starts a local SP ACS endpoint, generates AuthnRequest messages,
submits login payloads to the IdP, receives SAMLResponse, and validates it.
"""

from __future__ import annotations

import argparse
import base64
import concurrent.futures
import dataclasses
import html.parser
import http.server
import json
import logging
import queue
import random
import socketserver
import threading
import time
import urllib.parse
import uuid
import zlib
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from xml.etree import ElementTree

try:
    import requests
except ImportError as import_error:  # pragma: no cover
    raise SystemExit("requests is required. Install dependencies with: pip install -r requirements.txt") from import_error


LOGGER = logging.getLogger("dummy_saml_test")
SAML_PROTOCOL = "urn:oasis:names:tc:SAML:2.0:protocol"
SAML_ASSERTION = "urn:oasis:names:tc:SAML:2.0:assertion"
SAML_STATUS = "urn:oasis:names:tc:SAML:2.0:status"
SAML_BINDING_POST = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST"
SAML_BINDING_REDIRECT = "urn:oasis:names:tc:SAML:2.0:bindings:HTTP-Redirect"
NAME_ID_EMAIL = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
BROWSER_USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/139.0.0.0 Safari/537.36"
)


@dataclasses.dataclass(frozen=True)
class IdpMetadata:
    entity_id: str
    sso_redirect_url: str | None
    sso_post_url: str | None
    signing_certificates: list[str]


@dataclasses.dataclass(frozen=True)
class SamlRequestContext:
    request_id: str
    relay_state: str
    user_id: str
    issue_instant: str


@dataclasses.dataclass
class TestResult:
    user_id: str
    success: bool
    message: str
    elapsed_seconds: float


class SamlResponseStore:
    def __init__(self) -> None:
        self._responses: dict[str, queue.Queue[dict[str, str]]] = {}
        self._lock = threading.Lock()

    def register(self, relay_state: str) -> queue.Queue[dict[str, str]]:
        response_queue: queue.Queue[dict[str, str]] = queue.Queue(maxsize=1)
        with self._lock:
            self._responses[relay_state] = response_queue
        return response_queue

    def put(self, relay_state: str, payload: dict[str, str]) -> None:
        with self._lock:
            response_queue = self._responses.get(relay_state)
        if response_queue is not None:
            response_queue.put(payload)

    def remove(self, relay_state: str) -> None:
        with self._lock:
            self._responses.pop(relay_state, None)


class HtmlSamlFormParser(html.parser.HTMLParser):
    def __init__(self, base_url: str) -> None:
        super().__init__()
        self.base_url = base_url
        self.forms: list[dict[str, Any]] = []
        self.fields: dict[str, str] = {}
        self._current_form: dict[str, Any] | None = None

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = {name.lower(): value or "" for name, value in attrs}
        if tag.lower() == "form":
            self._current_form = {
                "action": urllib.parse.urljoin(self.base_url, attributes.get("action", self.base_url)),
                "method": attributes.get("method", "post").lower(),
                "fields": {},
            }
            return

        if tag.lower() == "input":
            input_name = attributes.get("name")
            if input_name:
                self.fields[input_name] = attributes.get("value", "")
                if self._current_form is not None:
                    self._current_form["fields"][input_name] = attributes.get("value", "")

    def handle_endtag(self, tag: str) -> None:
        if tag.lower() == "form" and self._current_form is not None:
            self.forms.append(self._current_form)
            self._current_form = None


def parse_idp_metadata(metadata_path: Path) -> IdpMetadata:
    metadata_xml = ElementTree.parse(metadata_path).getroot()
    entity_id = metadata_xml.attrib.get("entityID", "")
    sso_redirect_url: str | None = None
    sso_post_url: str | None = None
    signing_certificates: list[str] = []

    for sso_service in metadata_xml.findall(".//{*}SingleSignOnService"):
        binding = sso_service.attrib.get("Binding")
        location = sso_service.attrib.get("Location")
        if binding == SAML_BINDING_REDIRECT:
            sso_redirect_url = location
        elif binding == SAML_BINDING_POST:
            sso_post_url = location

    for key_descriptor in metadata_xml.findall(".//{*}KeyDescriptor"):
        key_use = key_descriptor.attrib.get("use", "signing")
        if key_use not in ("signing", ""):
            continue
        for certificate in key_descriptor.findall(".//{*}X509Certificate"):
            if certificate.text:
                signing_certificates.append(certificate.text.strip())

    if not entity_id:
        raise ValueError("IdP metadata does not contain entityID.")
    if not sso_redirect_url and not sso_post_url:
        raise ValueError("IdP metadata does not contain SingleSignOnService for Redirect or POST binding.")
    if not signing_certificates:
        raise ValueError("IdP metadata does not contain signing X509Certificate.")

    return IdpMetadata(entity_id, sso_redirect_url, sso_post_url, signing_certificates)


def now_saml_timestamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def random_user_id() -> str:
    return f"soliton{random.randint(1, 100000):06d}"


def select_user_id(args: argparse.Namespace) -> str:
    return args.user_id or random_user_id()


def generate_authn_request(entity_id: str, acs_url: str, destination: str) -> SamlRequestContext:
    request_id = "_" + uuid.uuid4().hex
    relay_state = uuid.uuid4().hex
    issue_instant = now_saml_timestamp()
    user_id = ""
    return SamlRequestContext(request_id, relay_state, user_id, issue_instant)


def build_authn_request_xml(context: SamlRequestContext, entity_id: str, acs_url: str, destination: str) -> bytes:
    authn_request = ElementTree.Element(
        f"{{{SAML_PROTOCOL}}}AuthnRequest",
        {
            "ID": context.request_id,
            "Version": "2.0",
            "IssueInstant": context.issue_instant,
            "Destination": destination,
            "AssertionConsumerServiceURL": acs_url,
            "ProtocolBinding": SAML_BINDING_POST,
        },
    )
    issuer = ElementTree.SubElement(authn_request, f"{{{SAML_ASSERTION}}}Issuer")
    issuer.text = entity_id
    ElementTree.SubElement(
        authn_request,
        f"{{{SAML_PROTOCOL}}}NameIDPolicy",
        {"Format": NAME_ID_EMAIL, "AllowCreate": "true"},
    )
    ElementTree.register_namespace("samlp", SAML_PROTOCOL)
    ElementTree.register_namespace("saml", SAML_ASSERTION)
    return ElementTree.tostring(authn_request, encoding="utf-8", xml_declaration=True)


def encode_redirect_saml_request(authn_request_xml: bytes) -> str:
    compressor = zlib.compressobj(wbits=-15)
    compressed = compressor.compress(authn_request_xml) + compressor.flush()
    return base64.b64encode(compressed).decode("ascii")


def encode_post_saml_request(authn_request_xml: bytes) -> str:
    return base64.b64encode(authn_request_xml).decode("ascii")


def decode_redirect_saml_request(saml_request: str) -> str:
    return zlib.decompress(base64.b64decode(saml_request), -15).decode("utf-8")


def build_sp_metadata(entity_id: str, acs_url: str) -> bytes:
    descriptor = ElementTree.Element(
        "EntityDescriptor",
        {
            "xmlns": "urn:oasis:names:tc:SAML:2.0:metadata",
            "entityID": entity_id,
        },
    )
    sp_descriptor = ElementTree.SubElement(
        descriptor,
        "SPSSODescriptor",
        {
            "protocolSupportEnumeration": SAML_PROTOCOL,
            "AuthnRequestsSigned": "false",
            "WantAssertionsSigned": "true",
        },
    )
    ElementTree.SubElement(sp_descriptor, "NameIDFormat").text = NAME_ID_EMAIL
    ElementTree.SubElement(
        sp_descriptor,
        "AssertionConsumerService",
        {
            "Binding": SAML_BINDING_POST,
            "Location": acs_url,
            "index": "0",
            "isDefault": "true",
        },
    )
    return ElementTree.tostring(descriptor, encoding="utf-8", xml_declaration=True)


def make_acs_handler(store: SamlResponseStore, metadata_xml: bytes) -> type[http.server.BaseHTTPRequestHandler]:
    class AcsHandler(http.server.BaseHTTPRequestHandler):
        def do_GET(self) -> None:  # noqa: N802
            parsed_path = urllib.parse.urlparse(self.path)
            if parsed_path.path == "/metadata":
                self.send_response(200)
                self.send_header("Content-Type", "application/samlmetadata+xml; charset=utf-8")
                self.send_header("Content-Length", str(len(metadata_xml)))
                self.end_headers()
                self.wfile.write(metadata_xml)
                return
            self.send_error(404)

        def do_POST(self) -> None:  # noqa: N802
            parsed_path = urllib.parse.urlparse(self.path)
            if parsed_path.path != "/acs":
                self.send_error(404)
                return

            content_length = int(self.headers.get("Content-Length", "0"))
            raw_body = self.rfile.read(content_length).decode("utf-8")
            form_values = urllib.parse.parse_qs(raw_body)
            relay_state = form_values.get("RelayState", [""])[0]
            saml_response = form_values.get("SAMLResponse", [""])[0]

            if saml_response:
                store.put(relay_state, {"SAMLResponse": saml_response, "RelayState": relay_state})
                response_body = b"SAMLResponse received."
                self.send_response(200)
            else:
                response_body = b"SAMLResponse is missing."
                self.send_response(400)

            self.send_header("Content-Type", "text/plain; charset=utf-8")
            self.send_header("Content-Length", str(len(response_body)))
            self.end_headers()
            self.wfile.write(response_body)

        def log_message(self, format_text: str, *args: Any) -> None:
            LOGGER.debug("ACS: " + format_text, *args)

    return AcsHandler


class ThreadedHttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def start_sp_server(host: str, port: int, store: SamlResponseStore, metadata_xml: bytes) -> ThreadedHttpServer:
    handler = make_acs_handler(store, metadata_xml)
    server = ThreadedHttpServer((host, port), handler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()
    return server


def build_login_payload(user_id: str, password: str) -> dict[str, str]:
    return {"userid": user_id, "password": password, "rememberMe": "on"}


def build_login_headers(login_url: str, referer_url: str) -> dict[str, str]:
    parsed_url = urllib.parse.urlparse(login_url)
    origin = f"{parsed_url.scheme}://{parsed_url.netloc}"
    return {
        "Accept": "application/json, text/javascript, */*; q=0.01",
        "Origin": origin,
        "Referer": referer_url,
        "User-Agent": BROWSER_USER_AGENT,
        "X-Requested-With": "XMLHttpRequest",
    }


def submit_login(
    session: requests.Session,
    args: argparse.Namespace,
    login_url: str,
    referer_url: str,
    payload: dict[str, str],
) -> requests.Response:
    headers = build_login_headers(login_url, referer_url)
    if args.login_payload_format == "json":
        return session.request(args.login_method, login_url, json=payload, headers=headers, timeout=args.timeout)
    return session.request(args.login_method, login_url, data=payload, headers=headers, timeout=args.timeout)


def normalize_login_url(login_url: str) -> str:
    parsed_url = urllib.parse.urlparse(login_url)
    if parsed_url.path.rstrip("/") == "/idp/login":
        return urllib.parse.urlunparse(parsed_url._replace(path="/idp/api/password", params="", query="", fragment=""))
    return login_url


def parse_json_success(response: requests.Response) -> bool:
    try:
        response_json = response.json()
    except ValueError:
        return False
    return response_json.get("passwordChangeFlag") is False and response_json.get("isAuthFinished") is True


def raise_for_status_with_body(response: requests.Response) -> None:
    try:
        response.raise_for_status()
    except requests.HTTPError as http_error:
        body = response.text.replace("\r", " ").replace("\n", " ")[:500]
        raise requests.HTTPError(f"{http_error}; response body: {body}", response=response) from http_error


def find_form_with_field(html_text: str, base_url: str, field_name: str) -> dict[str, Any] | None:
    parser = HtmlSamlFormParser(base_url)
    parser.feed(html_text)
    for form in parser.forms:
        if field_name in form["fields"]:
            return form
    return None


def parse_hidden_fields(html_text: str, base_url: str) -> dict[str, str]:
    parser = HtmlSamlFormParser(base_url)
    parser.feed(html_text)
    fields = dict(parser.fields)
    for form in parser.forms:
        fields.update(form["fields"])
    return fields


def continue_saml_flow(
    session: requests.Session,
    sso_url: str,
    login_page_html: str,
    login_page_url: str,
    args: argparse.Namespace,
) -> requests.Response:
    hidden_fields = parse_hidden_fields(login_page_html, login_page_url)
    saml_request = hidden_fields.get("SAMLRequest")
    relay_state = hidden_fields.get("RelayState")
    if not saml_request:
        raise ValueError("Login page does not contain SAMLRequest hidden field.")
    LOGGER.debug("Continuing SAML flow by POSTing hidden SAMLRequest to %s", sso_url)
    LOGGER.debug("Hidden SAMLRequest length: %s", len(saml_request))
    LOGGER.debug("Hidden RelayState: %s", relay_state or "")
    try:
        hidden_request_xml = ElementTree.fromstring(decode_redirect_saml_request(saml_request))
        LOGGER.debug("Hidden SAMLRequest ID: %s", hidden_request_xml.attrib.get("ID"))
    except Exception as decode_error:  # noqa: BLE001
        LOGGER.debug("Could not decode hidden SAMLRequest: %s", decode_error)
    headers = build_login_headers(sso_url, login_page_url)
    headers["Accept"] = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    return session.post(
        sso_url,
        data={"SAMLRequest": saml_request, "RelayState": relay_state or ""},
        headers=headers,
        allow_redirects=True,
        timeout=args.timeout,
    )


def retry_redirect_saml_flow(
    session: requests.Session,
    sso_url: str,
    saml_request: str,
    relay_state: str,
    args: argparse.Namespace,
) -> requests.Response:
    LOGGER.debug("Retrying SAML flow with original Redirect Binding URL.")
    return session.get(
        sso_url,
        params={"SAMLRequest": saml_request, "RelayState": relay_state},
        headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
        allow_redirects=True,
        timeout=args.timeout,
    )


def submit_saml_response_form(session: requests.Session, html_text: str, base_url: str) -> bool:
    form = find_form_with_field(html_text, base_url, "SAMLResponse")
    if not form:
        return False
    if form["method"] == "get":
        session.get(form["action"], params=form["fields"], timeout=30)
    else:
        session.post(form["action"], data=form["fields"], timeout=30)
    return True


def verify_saml_response(
    saml_response_b64: str,
    metadata: IdpMetadata,
    request_context: SamlRequestContext,
    expected_audience: str,
    expected_acs_url: str,
) -> None:
    try:
        from signxml import XMLVerifier
    except ImportError as import_error:  # pragma: no cover
        raise RuntimeError("signxml is required for SAMLResponse signature verification.") from import_error

    xml_bytes = base64.b64decode(saml_response_b64)
    verification_errors: list[str] = []
    for certificate_body in metadata.signing_certificates:
        certificate_pem = to_pem_certificate(certificate_body)
        try:
            XMLVerifier().verify(xml_bytes, x509_cert=certificate_pem)
            break
        except Exception as verify_error:  # noqa: BLE001
            verification_errors.append(str(verify_error))
    else:
        raise ValueError("SAMLResponse signature verification failed: " + " | ".join(verification_errors[:3]))

    response_xml = ElementTree.fromstring(xml_bytes)
    response_in_response_to = response_xml.attrib.get("InResponseTo")
    response_destination = response_xml.attrib.get("Destination")
    if response_in_response_to and response_in_response_to != request_context.request_id:
        raise ValueError(f"Unexpected InResponseTo: {response_in_response_to}")
    if response_destination and response_destination != expected_acs_url:
        raise ValueError(f"Unexpected Response Destination: {response_destination}")

    status_code = response_xml.find(".//{*}StatusCode")
    if status_code is None or status_code.attrib.get("Value") != f"{SAML_STATUS}:Success":
        raise ValueError("SAMLResponse status is not Success.")

    audience_values = [node.text for node in response_xml.findall(".//{*}Audience") if node.text]
    if audience_values and expected_audience not in audience_values:
        raise ValueError(f"Expected audience not found: {expected_audience}")

    recipient_values = [node.attrib.get("Recipient") for node in response_xml.findall(".//{*}SubjectConfirmationData")]
    if recipient_values and expected_acs_url not in recipient_values:
        raise ValueError(f"Expected recipient not found: {expected_acs_url}")


def to_pem_certificate(certificate_body: str) -> str:
    compact = "".join(certificate_body.split())
    lines = [compact[index:index + 64] for index in range(0, len(compact), 64)]
    return "-----BEGIN CERTIFICATE-----\n" + "\n".join(lines) + "\n-----END CERTIFICATE-----\n"


def run_single_test(
    args: argparse.Namespace,
    metadata: IdpMetadata,
    store: SamlResponseStore,
    entity_id: str,
    acs_url: str,
) -> TestResult:
    started_at = time.perf_counter()
    sso_url = metadata.sso_redirect_url if args.binding == "redirect" else metadata.sso_post_url
    if not sso_url:
        return TestResult("", False, f"IdP metadata does not provide {args.binding} binding SSO URL.", 0.0)

    request_context = dataclasses.replace(generate_authn_request(entity_id, acs_url, sso_url), user_id=select_user_id(args))
    response_queue = store.register(request_context.relay_state)
    session = requests.Session()
    session.verify = not args.insecure_tls
    session.headers.update(
        {
            "User-Agent": BROWSER_USER_AGENT,
            "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
        }
    )

    try:
        authn_request_xml = build_authn_request_xml(request_context, entity_id, acs_url, sso_url)
        encoded_saml_request = encode_redirect_saml_request(authn_request_xml)
        if args.binding == "redirect":
            start_response = session.get(
                sso_url,
                params={
                    "SAMLRequest": encoded_saml_request,
                    "RelayState": request_context.relay_state,
                },
                headers={"Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"},
                allow_redirects=True,
                timeout=args.timeout,
            )
        else:
            start_response = session.post(
                sso_url,
                data={
                    "SAMLRequest": encode_post_saml_request(authn_request_xml),
                    "RelayState": request_context.relay_state,
                },
                allow_redirects=True,
                timeout=args.timeout,
            )
        raise_for_status_with_body(start_response)

        login_url = normalize_login_url(args.login_url or find_login_form_action(start_response.text, start_response.url) or start_response.url)
        LOGGER.debug("SAML start final URL: %s", start_response.url)
        LOGGER.debug("Login URL: %s", login_url)
        login_response = submit_login(
            session,
            args,
            login_url,
            start_response.url,
            build_login_payload(request_context.user_id, args.password),
        )
        raise_for_status_with_body(login_response)

        if parse_json_success(login_response):
            LOGGER.debug("Login API returned success for %s", request_context.user_id)

        saml_continue_response = continue_saml_flow(session, sso_url, start_response.text, start_response.url, args)
        raise_for_status_with_body(saml_continue_response)

        if not submit_saml_response_form(session, saml_continue_response.text, saml_continue_response.url):
            if args.binding == "redirect":
                saml_continue_response = retry_redirect_saml_flow(
                    session,
                    sso_url,
                    encoded_saml_request,
                    request_context.relay_state,
                    args,
                )
                raise_for_status_with_body(saml_continue_response)
            if not submit_saml_response_form(session, saml_continue_response.text, saml_continue_response.url):
                body = saml_continue_response.text.replace("\r", " ").replace("\n", " ")[:500]
                raise ValueError(f"SAMLResponse form was not found at {saml_continue_response.url}; response body: {body}")
        try:
            saml_payload = response_queue.get(timeout=args.response_timeout)
        except queue.Empty as queue_error:
            raise TimeoutError("Timed out waiting for SAMLResponse at ACS.") from queue_error
        verify_saml_response(saml_payload["SAMLResponse"], metadata, request_context, entity_id, acs_url)
        return TestResult(request_context.user_id, True, "ok", time.perf_counter() - started_at)
    except Exception as test_error:  # noqa: BLE001
        return TestResult(request_context.user_id, False, str(test_error), time.perf_counter() - started_at)
    finally:
        store.remove(request_context.relay_state)


def find_login_form_action(html_text: str, base_url: str) -> str | None:
    parser = HtmlSamlFormParser(base_url)
    parser.feed(html_text)
    for form in parser.forms:
        fields = {field_name.lower() for field_name in form["fields"].keys()}
        if "userid" in fields or "password" in fields:
            return form["action"]
    return None


def pace_submissions(total_requests: int, requests_per_second: float) -> list[float]:
    if requests_per_second <= 0:
        return [0.0 for _ in range(total_requests)]
    interval = 1.0 / requests_per_second
    return [index * interval for index in range(total_requests)]


def parse_args() -> argparse.Namespace:
    script_dir = Path(__file__).resolve().parent
    parser = argparse.ArgumentParser(description="Run SP-Initiated SAML authentication tests against an IdP.")
    parser.add_argument("--metadata", type=Path, default=script_dir / "OneGateCloudMetadata.xml")
    parser.add_argument("--password", required=True, help="Password used for randomly selected soliton000001-soliton100000 users.")
    parser.add_argument("--user-id", default=None, help="Fixed login user ID. If omitted, soliton000001-soliton100000 is selected randomly.")
    parser.add_argument("--requests", type=int, required=True, help="Total authentication request count.")
    parser.add_argument("--rps", type=float, required=True, help="Authentication requests per second.")
    parser.add_argument("--threads", type=int, required=True, help="Worker thread count.")
    parser.add_argument("--binding", choices=("redirect", "post"), default="redirect")
    parser.add_argument("--sp-host", default="127.0.0.1")
    parser.add_argument("--sp-port", type=int, default=8000)
    parser.add_argument("--acs-url", default=None, help="ACS URL written into AuthnRequest and SP metadata. Defaults to http://<sp-host>:<sp-port>/acs.")
    parser.add_argument("--entity-id", default=None)
    parser.add_argument("--login-url", default=None, help="Optional override if the login endpoint cannot be inferred from the IdP page.")
    parser.add_argument("--login-method", default="POST", choices=("POST", "PUT"))
    parser.add_argument("--login-payload-format", choices=("json", "form"), default="json")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--response-timeout", type=float, default=30.0)
    parser.add_argument("--insecure-tls", action="store_true", help="Disable TLS certificate verification for test environments.")
    parser.add_argument("--verbose", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO, format="%(asctime)s %(levelname)s %(message)s")

    metadata = parse_idp_metadata(args.metadata)
    local_acs_url = f"http://{args.sp_host}:{args.sp_port}/acs"
    acs_url = args.acs_url or local_acs_url
    entity_id = args.entity_id or f"http://{args.sp_host}:{args.sp_port}/metadata"
    sp_metadata_xml = build_sp_metadata(entity_id, acs_url)
    store = SamlResponseStore()
    server = start_sp_server(args.sp_host, args.sp_port, store, sp_metadata_xml)

    LOGGER.info("IdP entityID: %s", metadata.entity_id)
    LOGGER.info("SP entityID: %s", entity_id)
    LOGGER.info("SP ACS URL: %s", acs_url)
    LOGGER.info("SP metadata URL: http://%s:%s/metadata", args.sp_host, args.sp_port)

    results: list[TestResult] = []
    start_time = time.perf_counter()
    schedules = pace_submissions(args.requests, args.rps)

    try:
        with concurrent.futures.ThreadPoolExecutor(max_workers=args.threads) as executor:
            futures: list[concurrent.futures.Future[TestResult]] = []
            for scheduled_offset in schedules:
                sleep_seconds = start_time + scheduled_offset - time.perf_counter()
                if sleep_seconds > 0:
                    time.sleep(sleep_seconds)
                futures.append(executor.submit(run_single_test, args, metadata, store, entity_id, acs_url))

            for future in concurrent.futures.as_completed(futures):
                result = future.result()
                results.append(result)
                if not result.success:
                    LOGGER.warning("FAIL user=%s elapsed=%.3fs error=%s", result.user_id, result.elapsed_seconds, result.message)
                else:
                    LOGGER.info("OK user=%s elapsed=%.3fs", result.user_id, result.elapsed_seconds)
    finally:
        server.shutdown()
        server.server_close()

    success_count = sum(1 for result in results if result.success)
    failure_count = len(results) - success_count
    summary = {
        "total": len(results),
        "success": success_count,
        "failure": failure_count,
        "elapsedSeconds": round(time.perf_counter() - start_time, 3),
    }
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0 if failure_count == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
