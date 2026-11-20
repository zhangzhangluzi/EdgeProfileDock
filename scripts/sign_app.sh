#!/bin/bash
set -euo pipefail
umask 077

APP="${1:?缺少待签名的应用路径}"
BUNDLE_ID="com.local.EdgeProfileDock"
SIGNING_DIR="$HOME/Library/Application Support/EdgeProfileDock Signing"
IDENTITY="$SIGNING_DIR/identity.p12"
KEYCHAIN_ACCOUNT="EdgeProfileDock"
KEYCHAIN_SERVICE="$BUNDLE_ID.build-signing"
SIGNER="$SIGNING_DIR/rcodesign-0.29.0-arm64"
SIGNER_SHA256="6c4623db45f1d89af439a2ce42fd65798ef56aaaa3e4ced48879be05f750aacb"

fail() {
    printf '签名失败：%s\n' "$1" >&2
    exit 1
}

read_password() {
    /usr/bin/security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w
}

installed_requirement() {
    /usr/bin/codesign -d -r- "$1" 2>&1 | /usr/bin/sed -n 's/^designated => //p'
}

[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" == "$BUNDLE_ID" ]] \
    || fail "签名仅用于 EdgeProfileDock。"

mkdir -p "$SIGNING_DIR"
WORK="$(mktemp -d "$SIGNING_DIR/.build-signing.XXXXXXXX")"
trap 'find "$WORK" -depth -delete' EXIT

if [[ ! -f "$SIGNER" ]]; then
    RELEASE="apple-codesign-0.29.0-aarch64-apple-darwin"
    /usr/bin/curl --fail --silent --show-error --location --max-time 60 \
        "https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F0.29.0/$RELEASE.tar.gz" \
        -o "$WORK/rcodesign.tar.gz"
    printf '%s  %s\n' 'd1a532150adaf90048260d76359261aa716abafc45c53c5dc18845029184334a' "$WORK/rcodesign.tar.gz" \
        | /usr/bin/shasum -a 256 -c - >/dev/null
    /usr/bin/tar -xzf "$WORK/rcodesign.tar.gz" -C "$WORK" "$RELEASE/rcodesign"
    /usr/bin/ditto --hfsCompression "$WORK/$RELEASE/rcodesign" "$WORK/rcodesign"
    mv "$WORK/rcodesign" "$SIGNER"
fi
printf '%s  %s\n' "$SIGNER_SHA256" "$SIGNER" | /usr/bin/shasum -a 256 -c - >/dev/null

if [[ ! -e "$IDENTITY" ]]; then
    for installed in /Applications/EdgeProfileDock.app "$HOME/Applications/EdgeProfileDock.app"; do
        [[ -d "$installed" ]] || continue
        [[ -z "$(installed_requirement "$installed")" ]] \
            || fail "已安装版本使用固定签名。请恢复原来的本机签名文件。"
    done

    if ! password="$(read_password 2>/dev/null)"; then
        password="$(/usr/bin/openssl rand -hex 32)"
        # 通过标准输入交给钥匙串工具，避免在进程参数中传递口令。
        printf 'add-generic-password -a %s -s %s -l %s -T /usr/bin/security -w %s\n' \
            "$KEYCHAIN_ACCOUNT" "$KEYCHAIN_SERVICE" "EdgeProfileDock-Build-Signing" "$password" \
            | /usr/bin/security -i -q >/dev/null 2>&1
        password="$(read_password 2>/dev/null)" || fail "无法保存签名口令，请检查登录钥匙串。"
    fi

    cat > "$WORK/certificate.conf" <<'EOF'
[req]
distinguished_name = subject
prompt = no
x509_extensions = code_signing
[subject]
CN = EdgeProfileDock Local Build Signing
[code_signing]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF
    /usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
        -config "$WORK/certificate.conf" -keyout "$WORK/key.pem" -out "$WORK/certificate.pem" \
        2>"$WORK/openssl.log" || fail "无法创建本机代码签名证书。"
    printf '%s\n' "$password" | /usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" \
        -in "$WORK/certificate.pem" -out "$WORK/identity.p12" -passout stdin
    # 同时首次打包时，两个进程都使用最先写入的签名身份。
    ln "$WORK/identity.p12" "$IDENTITY" 2>/dev/null || [[ -s "$IDENTITY" ]]
fi

password="$(read_password 2>/dev/null)" || fail "找不到本机签名口令，请解锁钥匙串或恢复原来的签名口令。"
fingerprint="$(printf '%s\n' "$password" | /usr/bin/openssl pkcs12 -in "$IDENTITY" -clcerts -nokeys -passin stdin \
    | /usr/bin/openssl x509 -noout -fingerprint -sha1 | /usr/bin/sed 's/.*=//; s/://g')"
[[ "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]] || fail "无法读取本机签名证书。"
requirement="identifier \"$BUNDLE_ID\" and certificate leaf = H\"$fingerprint\""
/usr/bin/csreq -r "=$requirement" -b "$WORK/requirement"

echo "==> 使用本机固定身份签名"
printf '%s\n' "$password" | "$SIGNER" --config-file /dev/null sign --shallow --timestamp-url none \
    --p12-file "$IDENTITY" --p12-password-file /dev/stdin --code-requirements-file "$WORK/requirement" "$APP"
unset password
/usr/bin/codesign --verify --strict -R="$requirement" "$APP"

for installed in /Applications/EdgeProfileDock.app "$HOME/Applications/EdgeProfileDock.app"; do
    [[ -d "$installed" ]] || continue
    previous="$(installed_requirement "$installed")"
    [[ -n "$previous" ]] || continue
    /usr/bin/codesign --verify --strict -R="$previous" "$APP" \
        || fail "候选应用与已安装版本的签名身份不同，已停止打包。"
done
