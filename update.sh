#!/bin/bash
set -e

# Config
KEY_ID="EAF9167959BFE60C"       # your GPG key ID
BRANCH="gh-pages"               # branch hosting your repo
REPO_DIR="$(pwd)"               # assumes script is run in repo root or docs/

# 1. Regenerate Packages.gz
echo "[*] Generating Packages.gz..."
dpkg-scanpackages . /dev/null | gzip -9c > Packages.gz

# 2. Write Release config
cat > release.conf <<EOF
APT::FTPArchive::Release {
  Origin "isaac_ros";
  Label "isaac_ros";
  Suite "stable";
  Codename "jammy";
  Architectures "amd64";
  Components "main";
  Description "isaac_ros VPI deb repository";
}
EOF

# 3. Generate Release
echo "[*] Generating Release..."
apt-ftparchive -c=release.conf release . > Release

# 4. Sign Release
echo "[*] Signing Release with GPG key $KEY_ID..."
gpg --default-key "$KEY_ID" -abs -o Release.gpg Release

# 5. Export public key
echo "[*] Exporting public key..."
gpg --armor --export "$KEY_ID" > isaac_ros.gpg

# 6. Commit and push
echo "[*] Committing and pushing to $BRANCH..."
git add Packages.gz Release Release.gpg isaac_ros.gpg
git commit -m "Update APT repo metadata"
git push origin "$BRANCH"

echo "[*] Done. Repo updated!"

