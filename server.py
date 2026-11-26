#!/usr/bin/env python3
"""HTTPS server for iPadOS UVC Cam PWA with automatic self-signed cert generation."""

import functools
import http.server
import ipaddress
import os
import plistlib
import re
import socket
import ssl
import subprocess
import sys
import tempfile
import uuid
from pathlib import Path

BASE_DIR = Path(__file__).resolve().parent
CERT_PATH = BASE_DIR / "cert.pem"
KEY_PATH = BASE_DIR / "key.pem"
PORT = int(os.environ.get("UVC_CAM_PORT", "8443"))


def detect_local_ips() -> list[str]:
    """Collect active non-loopback IPv4 addresses of this Mac for SAN & display."""
    ips: set[str] = set()
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.connect(("8.8.8.8", 80))
        ips.add(sock.getsockname()[0])
        sock.close()
    except OSError:
        pass

    try:
        for info in socket.getaddrinfo(socket.gethostname(), None, socket.AF_INET):
            addr = info[4][0]
            if not addr.startswith("127."):
                ips.add(addr)
    except OSError:
        pass

    if sys.platform == "darwin":
        try:
            ifconfig_out = subprocess.check_output(
                ["ifconfig"],
                stderr=subprocess.DEVNULL,
                text=True,
            )
            for addr in re.findall(r"\binet (\d+\.\d+\.\d+\.\d+)\b", ifconfig_out):
                if not addr.startswith("127."):
                    ips.add(addr)
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass

        for iface in ("en0", "en1", "en2", "en9", "en10"):
            try:
                out = subprocess.check_output(
                    ["ipconfig", "getifaddr", iface],
                    stderr=subprocess.DEVNULL,
                    text=True,
                ).strip()
                if out and not out.startswith("127."):
                    ips.add(out)
            except (subprocess.CalledProcessError, FileNotFoundError):
                pass

    valid = []
    for ip in ips:
        try:
            ipaddress.ip_address(ip)
            valid.append(ip)
        except ValueError:
            pass
    # Prefer normal LAN/Wi-Fi IPs first, link-local (169.254.x.x) after
    valid.sort(key=lambda ip: (ip.startswith("169.254."), ip))
    return valid


def cert_contains_all_ips(local_ips: list[str]) -> bool:
    """Return True if the existing certificate already includes all local IPs in SAN."""
    if not (CERT_PATH.exists() and KEY_PATH.exists()):
        return False
    try:
        out = subprocess.check_output(
            ["openssl", "x509", "-in", str(CERT_PATH), "-noout", "-text"],
            stderr=subprocess.DEVNULL,
            text=True,
        )
        return all(f"IP Address:{ip}" in out for ip in local_ips)
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def ensure_certificate(local_ips: list[str]) -> None:
    """Create or refresh a self-signed X.509 certificate with all local IP SANs."""
    if cert_contains_all_ips(local_ips):
        return

    san_entries = ["DNS:localhost", "IP:127.0.0.1"] + [f"IP:{ip}" for ip in local_ips]
    san_line = ",".join(san_entries)

    openssl_cfg = f"""[req]
default_bits = 2048
prompt = no
default_md = sha256
x509_extensions = v3_ca
distinguished_name = dn

[dn]
CN = UVC Cam Local Server

[v3_ca]
subjectKeyIdentifier = hash
authorityKeyIdentifier = keyid:always,issuer
basicConstraints = critical,CA:TRUE
keyUsage = critical,digitalSignature,keyEncipherment,keyCertSign
extendedKeyUsage = serverAuth
subjectAltName = {san_line}
"""
    with tempfile.NamedTemporaryFile("w", suffix=".cnf", delete=False) as tmp:
        tmp.write(openssl_cfg)
        cfg_path = tmp.name

    try:
        subprocess.run(
            [
                "openssl",
                "req",
                "-x509",
                "-nodes",
                "-days",
                "825",
                "-newkey",
                "rsa:2048",
                "-keyout",
                str(KEY_PATH),
                "-out",
                str(CERT_PATH),
                "-config",
                cfg_path,
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
    finally:
        try:
            os.unlink(cfg_path)
        except OSError:
            pass


def build_mobileconfig(host_header: str, local_ips: list[str]) -> bytes:
    """Build an iPadOS .mobileconfig containing the root cert and standalone WebClip."""
    raw_host = (host_header or "").split(":", 1)[0].strip()
    if not raw_host or raw_host in ("127.0.0.1", "localhost"):
        target_host = local_ips[0] if local_ips else "127.0.0.1"
    else:
        target_host = raw_host

    der_cert = ssl.PEM_cert_to_DER_cert(CERT_PATH.read_text(encoding="utf-8"))
    target_url = f"https://{target_host}:{PORT}/"

    profile = {
        "PayloadType": "Configuration",
        "PayloadVersion": 1,
        "PayloadIdentifier": "com.local.uvccam.profile",
        "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"uvccam.profile.{target_host}")),
        "PayloadDisplayName": "UVC Cam (iPad 설치 프로파일)",
        "PayloadDescription": "UVC Cam 로컬 HTTPS 인증서와 전체화면 홈 화면 앱 아이콘을 함께 설치합니다.",
        "PayloadOrganization": "UVC Cam Local",
        "PayloadContent": [
            {
                "PayloadType": "com.apple.security.root",
                "PayloadVersion": 1,
                "PayloadIdentifier": "com.local.uvccam.cert",
                "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_DNS, "uvccam.cert")),
                "PayloadDisplayName": "UVC Cam Local Server",
                "PayloadCertificateFileName": "uvc-cam-ca.cer",
                "PayloadContent": der_cert,
            },
            {
                "PayloadType": "com.apple.webClip.managed",
                "PayloadVersion": 1,
                "PayloadIdentifier": "com.local.uvccam.webclip",
                "PayloadUUID": str(uuid.uuid5(uuid.NAMESPACE_DNS, f"uvccam.webclip.{target_host}")),
                "PayloadDisplayName": "UVC Cam 홈 화면 아이콘",
                "Label": "UVC Cam",
                "URL": target_url,
                "FullScreen": True,
                "IsRemovable": True,
                "Precomposed": True,
            },
        ],
    }
    return plistlib.dumps(profile, fmt=plistlib.FMT_XML)


class PwaRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Static file handler adding PWA MIME types, mobileconfig, cert download, and no-store HTML."""

    local_ips: list[str] = []

    extensions_map = {
        **http.server.SimpleHTTPRequestHandler.extensions_map,
        ".svg": "image/svg+xml",
        ".json": "application/manifest+json",
        ".js": "application/javascript; charset=utf-8",
        ".html": "text/html; charset=utf-8",
        ".cer": "application/x-x509-ca-cert",
        ".crt": "application/x-x509-ca-cert",
        ".mobileconfig": "application/x-apple-aspen-config",
    }

    def _serve_dynamic(self, send_body: bool) -> bool:
        req_path = self.path.split("?", 1)[0]
        if req_path == "/install.mobileconfig":
            if not CERT_PATH.exists():
                self.send_error(404, "Certificate not found")
                return True
            data = build_mobileconfig(self.headers.get("Host", ""), self.local_ips)
            self._write_payload(
                data,
                "application/x-apple-aspen-config",
                'attachment; filename="UVC_Cam_iPad.mobileconfig"',
                "no-store",
                send_body,
            )
            return True

        if req_path in ("/cert.cer", "/ca.crt"):
            if not CERT_PATH.exists():
                self.send_error(404, "Certificate not found")
                return True
            data = CERT_PATH.read_bytes()
            self._write_payload(
                data,
                "application/x-x509-ca-cert",
                'attachment; filename="uvc-cam-ca.cer"',
                None,
                send_body,
            )
            return True
        return False

    def _write_payload(
        self,
        data: bytes,
        content_type: str,
        disposition: str,
        cache_control: str | None,
        send_body: bool,
    ) -> None:
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Disposition", disposition)
        self.send_header("Content-Length", str(len(data)))
        if cache_control:
            self.send_header("Cache-Control", cache_control)
        self.end_headers()
        if send_body:
            self.wfile.write(data)

    def do_GET(self) -> None:
        if not self._serve_dynamic(send_body=True):
            super().do_GET()

    def do_HEAD(self) -> None:
        if not self._serve_dynamic(send_body=False):
            super().do_HEAD()

    def end_headers(self) -> None:
        req_path = self.path.split("?", 1)[0]
        if req_path in ("/", "/index.html", "/sw.js", "/manifest.json"):
            self.send_header("Cache-Control", "no-cache")
        super().end_headers()


class ReusableThreadingHTTPServer(http.server.ThreadingHTTPServer):
    allow_reuse_address = True


def main() -> None:
    local_ips = detect_local_ips()
    ensure_certificate(local_ips)
    PwaRequestHandler.local_ips = local_ips

    handler = functools.partial(PwaRequestHandler, directory=str(BASE_DIR))
    httpd = ReusableThreadingHTTPServer(("0.0.0.0", PORT), handler)

    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    ctx.load_cert_chain(certfile=str(CERT_PATH), keyfile=str(KEY_PATH))
    httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)

    print("============================================================")
    print("  iPad용 UVC Cam HTTPS 서버가 실행되었습니다.")
    print(f"  로컬 확인: https://127.0.0.1:{PORT}")
    if local_ips:
        for ip in local_ips:
            label = "USB 직결" if ip.startswith("169.254.") else "Wi-Fi/LAN"
            print(f"  iPad 접속 주소 ({label}): https://{ip}:{PORT}")
        print(f"  원터치 프로파일 설치: https://{local_ips[0]}:{PORT}/install.mobileconfig")
    else:
        print(f"  iPad 접속 주소: https://<Mac-IP>:{PORT}")
    print("  종료하려면 Ctrl+C를 누르세요.")
    print("============================================================", flush=True)

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n서버를 종료합니다.")
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
