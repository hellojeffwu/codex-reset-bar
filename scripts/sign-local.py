#!/usr/bin/env python3
"""Sign this local app with a persistent identity; never change system trust."""

import hashlib
import os
from pathlib import Path
import plistlib
import secrets
import shlex
import shutil
import subprocess
import sys

APP_ID = "local.benxin.codex-reset-bar"
SIGNING_DIR = Path.home() / "Library/Application Support/CodexResetBar/signing"


def run(arguments, step, input_text=None):
    # security's interactive mode accepts passwords on stdin, not argv. Neither
    # commands nor captured output are printed, including on a failed operation.
    try:
        result = subprocess.run(arguments, input=input_text, text=True,
                                capture_output=True, timeout=90)
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{step}超时；已有签名资料已保留。") from None
    if result.returncode:
        raise RuntimeError(f"{step}失败（退出码 {result.returncode}）；已有签名资料已保留。")
    return result.stdout


def security(command, *arguments):
    run(["/usr/bin/security", "-i"], f"钥匙串操作 {command}",
        shlex.join([command, *map(str, arguments)]) + "\n")


def main():
    if len(sys.argv) != 2:
        raise RuntimeError("用法：python3 scripts/sign-local.py <本应用的 .app 路径>")
    app = Path(sys.argv[1]).resolve()
    with (app / "Contents/Info.plist").open("rb") as stream:
        if plistlib.load(stream).get("CFBundleIdentifier") != APP_ID:
            raise RuntimeError("只允许签名 Codex 额度提醒应用。")

    original_search = shlex.split(run(["/usr/bin/security", "list-keychains", "-d", "user"], "读取钥匙串搜索列表"))
    try:
        sign(app, original_search)
    finally:
        try:
            security("list-keychains", "-d", "user", "-s", *original_search)
        finally:
            keychain = SIGNING_DIR / "local-signing.keychain-db"
            if keychain.exists():
                security("lock-keychain", keychain)


def sign(app, original_search):
    os.umask(0o077)
    SIGNING_DIR.mkdir(parents=True, exist_ok=True, mode=0o700)
    SIGNING_DIR.chmod(0o700)
    keychain = SIGNING_DIR / "local-signing.keychain-db"
    password_file = SIGNING_DIR / "keychain-password"
    certificate = SIGNING_DIR / "certificate.der"
    marker = SIGNING_DIR / "identity.sha1"

    if not marker.exists():
        if any(SIGNING_DIR.iterdir()):
            raise RuntimeError("签名目录已有资料但初始化未完成；请检查后修复，不会覆盖或重建身份。")
        openssl = shutil.which("openssl")
        if not openssl:
            raise RuntimeError("找不到 OpenSSL，无法创建本机签名身份。")
        password = secrets.token_urlsafe(32)
        password_file.write_text(password)
        private_key = SIGNING_DIR / "private-key.pem"
        public_cert = SIGNING_DIR / "certificate.pem"
        package = SIGNING_DIR / "identity.p12"
        config = SIGNING_DIR / "certificate.cnf"
        config.write_text("[req]\nprompt=no\ndistinguished_name=dn\nx509_extensions=codesign\n"
                          "[dn]\nCN=Codex Reset Bar Local Signing\n[codesign]\n"
                          "basicConstraints=critical,CA:false\nkeyUsage=critical,digitalSignature\n"
                          "extendedKeyUsage=critical,codeSigning\n")
        run([openssl, "req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-sha256",
             "-days", "3650", "-config", str(config), "-keyout", str(private_key),
             "-out", str(public_cert)], "生成专用代码签名证书")
        run([openssl, "x509", "-in", str(public_cert), "-outform", "DER", "-out", str(certificate)],
            "导出公开签名证书")
        # Legacy PKCS12 envelope algorithms keep macOS Security import compatible
        # with OpenSSL 3. The certificate itself uses RSA/SHA-256, not SHA-1.
        run([openssl, "pkcs12", "-export", "-inkey", str(private_key), "-in", str(public_cert),
             "-out", str(package), "-passout", "file:" + str(password_file), "-keypbe", "PBE-SHA1-3DES",
             "-certpbe", "PBE-SHA1-3DES", "-macalg", "sha1"], "准备专用身份导入")
        security("create-keychain", "-p", password, keychain)
        security("unlock-keychain", "-p", password, keychain)
        security("import", package, "-k", keychain, "-f", "pkcs12", "-P", password,
                 "-x", "-T", "/usr/bin/codesign")
        # This keychain contains only our signing identity. Its private key ACL
        # names codesign; do not apply partition changes to any other keychain.
        security("set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", password, keychain)
        marker.write_text(hashlib.sha1(certificate.read_bytes()).hexdigest().upper())
        private_key.unlink()
        package.unlink()

    if not all(path.is_file() for path in [keychain, password_file, certificate, marker]):
        raise RuntimeError("已有签名身份资料不完整；请恢复资料，不会生成替代身份。")
    fingerprint = hashlib.sha1(certificate.read_bytes()).hexdigest().upper()
    if marker.read_text().strip() != fingerprint:
        raise RuntimeError("签名证书与记录不一致；停止签名以保留原应用身份。")
    for path in SIGNING_DIR.iterdir():
        if path.is_file():
            path.chmod(0o600)
    security("unlock-keychain", "-p", password_file.read_text(), keychain)
    requirement = f'designated => identifier "{APP_ID}" and anchor H"{fingerprint}"'
    # macOS still searches this list for the identity despite --keychain.
    security("list-keychains", "-d", "user", "-s", *original_search, keychain)
    run(["/usr/bin/codesign", "--force", "--sign", fingerprint, "--keychain", str(keychain),
         "--timestamp=none", "--requirements", "=" + requirement, str(app)], "固定身份签名")
    run(["/usr/bin/codesign", "--verify", "--strict", str(app)], "验证代码签名")
    print("已使用本机固定身份签名并验证。")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        print(f"签名未完成：{error}", file=sys.stderr)
        sys.exit(1)
